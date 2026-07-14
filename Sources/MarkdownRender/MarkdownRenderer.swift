import AppKit
import MarkdownEngine

/// Turns a source string + its `ParsedMarkdown` into a styled `NSAttributedString`
/// whose characters are byte-identical to the source (the source stays the single
/// source of truth). Syntax delimiters are tagged `.vireoMarker` for the layout
/// manager to hide; bullets, checkboxes and images are tagged for it to draw.
@MainActor
public struct MarkdownRenderer {
    public var theme: Theme
    public var baseURL: URL?
    public weak var imageLoader: ImageLoader?
    public var isDark: Bool
    /// Table whose raw source is shown for editing (caret inside it) instead
    /// of the drawn grid, identified by its absolute anchor position.
    public var revealTableAnchor: Int?
    /// When rendering a slice of the document, the slice's absolute start —
    /// lets position-carrying attributes (tables) stay in document coordinates.
    public var originOffset: Int = 0
    /// List items whose subtrees are hidden (absolute anchor positions).
    public var collapsedAnchors: Set<Int> = []

    /// Shared boolean marker value — reused for every `.vireoMarker` /
    /// `.vireoArrow` range so a full render doesn't allocate one `NSNumber` per
    /// range (tens of thousands on a large document).
    private static let trueValue = NSNumber(value: true)

    public init(theme: Theme, baseURL: URL? = nil, imageLoader: ImageLoader? = nil, isDark: Bool = false) {
        self.theme = theme
        self.baseURL = baseURL
        self.imageLoader = imageLoader
        self.isDark = isDark
    }

    public func render(source: String, parsed: ParsedMarkdown) -> NSAttributedString {
        let text = NSMutableAttributedString(string: source)
        let full = NSRange(location: 0, length: text.length)

        // 1. Base body attributes.
        let base = bodyParagraph()
        text.addAttributes([
            .font: theme.bodyFont,
            .foregroundColor: theme.textColor,
            .paragraphStyle: base,
        ], range: full)

        // 2. Block-level styling.
        for block in parsed.blockRuns {
            applyBlock(block, to: text)
        }

        // 3. Inline styling.
        for run in parsed.inlineRuns where run.range.upperBound <= text.length {
            applyInline(run, to: text)
        }

        // 4. Code syntax highlighting.
        highlightCode(in: parsed, text: text, source: source)

        // 5. Images (draw-anchor + tall line height on their paragraph).
        for image in parsed.images where image.range.upperBound <= text.length {
            applyImage(image, to: text)
        }

        // 5b. Tables: reserve row height and tag the anchor for drawing.
        for (i, table) in parsed.tables.enumerated() {
            applyTable(table, index: i, to: text)
        }

        // 6. List bullets / numbers.
        for m in parsed.listMarkers where m.anchor < text.length {
            text.addAttribute(.vireoBullet, value: m.text as NSString,
                              range: NSRange(location: m.anchor, length: 1))
        }

        // 7. Task checkboxes.
        for t in parsed.tasks where t.anchor < text.length {
            text.addAttribute(.vireoCheckbox, value: NSNumber(value: t.checked),
                              range: NSRange(location: t.anchor, length: 1))
        }

        // 7b. Foldable headings: tag the anchor for chevron/`…` hit-testing.
        for h in parsed.headings where h.anchor < text.length && h.subtreeRange != nil {
            text.addAttribute(.vireoHeading, value: NSNumber(value: h.level),
                              range: NSRange(location: h.anchor, length: 1))
        }

        // 8. Hide syntax markers (applied last so nothing clobbers it).
        for r in parsed.markerRanges where r.upperBound <= text.length {
            text.addAttribute(.vireoMarker, value: Self.trueValue, range: r)
        }

        // 9. Typographic arrows: display `->` as → in prose (never in code or
        //    inside hidden syntax). The source keeps the literal characters —
        //    the `-` is glyph-substituted at layout time and the `>` hidden.
        applyArrowSubstitutions(to: text)

        // 10. Collapse: hide the subtrees of collapsed list items and headings.
        if !collapsedAnchors.isEmpty {
            let subtrees = parsed.listMarkers.map { ($0.anchor, $0.subtreeRange) }
                + parsed.tasks.map { ($0.anchor, $0.subtreeRange) }
                + parsed.headings.map { ($0.anchor, $0.subtreeRange) }
            for (anchor, subtree) in subtrees {
                guard collapsedAnchors.contains(originOffset + anchor),
                      let subtree, subtree.upperBound <= text.length else { continue }
                // Hide from the newline *before* the subtree through its end.
                var hide = subtree
                if hide.location > 0 {
                    hide = NSRange(location: hide.location - 1, length: hide.length + 1)
                }
                text.addAttribute(.vireoCollapsed, value: NSNumber(value: true), range: hide)
                // The layout manager keeps the hidden newlines (see
                // shouldGenerateGlyphs), so collapse each hidden line's
                // fragment to ~zero height — same trick as table separators.
                let flat = NSMutableParagraphStyle()
                flat.minimumLineHeight = 0.01
                flat.maximumLineHeight = 0.01
                text.addAttribute(.paragraphStyle, value: flat, range: hide)
                // Null glyphs are zero-width but their background still draws —
                // an inline-code span in the hidden range would leave a thin
                // colored sliver at the collapse point.
                text.removeAttribute(.backgroundColor, range: hide)
            }
        }

        return text
    }

    // MARK: Block styling

    private func applyBlock(_ block: BlockRun, to text: NSMutableAttributedString) {
        let r = NSIntersectionRange(block.range, NSRange(location: 0, length: text.length))
        guard r.length > 0 else { return }
        switch block.kind {
        case .heading(let level):
            let p = bodyParagraph()
            p.paragraphSpacingBefore = theme.baseSize * 0.8
            p.paragraphSpacing = theme.baseSize * 0.3
            text.addAttributes([.font: theme.headingFont(level), .paragraphStyle: p], range: r)

        case .paragraph:
            break // base already applied

        case .blockQuote:
            let p = bodyParagraph()
            p.firstLineHeadIndent = 20
            p.headIndent = 20
            text.addAttributes([
                .foregroundColor: theme.secondaryColor,
                .paragraphStyle: p,
                .font: theme.italicFont,
            ], range: r)

        case .codeBlock:
            let p = NSMutableParagraphStyle()
            p.lineHeightMultiple = 1.2
            p.firstLineHeadIndent = 12
            p.headIndent = 12
            text.addAttributes([
                .font: theme.codeFont,
                .foregroundColor: theme.codeColor,
                .backgroundColor: theme.codeBackground,
                .paragraphStyle: p,
            ], range: r)

        case .listItem(let depth, _):
            let p = bodyParagraph()
            let indent = CGFloat(depth + 1) * 22
            p.firstLineHeadIndent = indent
            p.headIndent = indent
            // Lists read as one unit — much tighter than paragraph spacing.
            p.paragraphSpacing = theme.baseSize * 0.15
            text.addAttribute(.paragraphStyle, value: p, range: r)

        case .tableRow:
            text.addAttributes([.font: theme.codeFont, .foregroundColor: theme.secondaryColor], range: r)

        case .thematicBreak:
            let p = NSMutableParagraphStyle()
            p.alignment = .center
            text.addAttributes([.foregroundColor: theme.ruleColor, .paragraphStyle: p], range: r)
        }
    }

    // MARK: Inline styling

    private func applyInline(_ run: InlineRun, to text: NSMutableAttributedString) {
        let r = run.range
        if run.code {
            text.addAttributes([
                .font: theme.codeFont,
                .foregroundColor: theme.codeColor,
                .backgroundColor: theme.codeBackground,
            ], range: r)
        } else {
            let font: NSFont
            if run.bold && run.italic { font = theme.boldItalicFont }
            else if run.bold { font = theme.boldFont }
            else if run.italic { font = theme.italicFont }
            else { font = theme.bodyFont }
            text.addAttribute(.font, value: font, range: r)
        }
        if run.strikethrough {
            text.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: r)
        }
        if let link = run.link {
            text.addAttributes([
                .foregroundColor: theme.linkColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .vireoLink: link as NSString,
                .toolTip: "⌘-click to open \(link)" as NSString,
            ], range: r)
        }
    }

    // MARK: Code highlighting

    private func highlightCode(in parsed: ParsedMarkdown, text: NSMutableAttributedString, source: String) {
        let hl = CodeHighlighter()
        let ns = source as NSString
        for block in parsed.blockRuns {
            guard case .codeBlock = block.kind else { continue }
            let r = NSIntersectionRange(block.range, NSRange(location: 0, length: text.length))
            guard r.length > 0 else { continue }
            let code = ns.substring(with: r)
            for token in hl.tokens(in: code, offset: r.location, isDark: isDark)
            where token.range.upperBound <= text.length {
                text.addAttribute(.foregroundColor, value: token.color, range: token.range)
            }
        }
    }

    // MARK: Images

    private func applyImage(_ image: ImageRun, to text: NSMutableAttributedString) {
        // Reserve vertical space via line height on the image's paragraph and
        // tag the anchor so the layout manager draws the raster there.
        let loaded = imageLoader?.image(forSource: image.source, baseURL: baseURL)
        let height = imageDrawHeight(for: loaded)
        let p = NSMutableParagraphStyle()
        p.minimumLineHeight = height
        p.maximumLineHeight = height
        text.addAttribute(.paragraphStyle, value: p, range: image.range)
        text.addAttribute(.vireoImage, value: image.source as NSString,
                          range: NSRange(location: image.anchor, length: 1))
        text.addAttribute(.vireoImageAlt, value: image.alt as NSString,
                          range: NSRange(location: image.anchor, length: 1))
    }

    // MARK: Typographic arrows

    private func applyArrowSubstitutions(to text: NSMutableAttributedString) {
        let ns = text.string as NSString
        var search = NSRange(location: 0, length: ns.length)
        while search.length > 0 {
            let r = ns.range(of: "->", options: [], range: search)
            guard r.location != NSNotFound else { break }
            search = NSRange(location: r.upperBound, length: ns.length - r.upperBound)

            let attrs = text.attributes(at: r.location, effectiveRange: nil)
            let inCode = (attrs[.font] as? NSFont)?.isFixedPitch == true
            let hidden = attrs[.vireoMarker] != nil || attrs[.vireoTable] != nil
            guard !inCode, !hidden else { continue }

            text.addAttribute(.vireoArrow, value: Self.trueValue,
                              range: NSRange(location: r.location, length: 1))
            text.addAttribute(.vireoMarker, value: Self.trueValue,
                              range: NSRange(location: r.location + 1, length: 1))
        }
    }

    // MARK: Tables

    private func applyTable(_ table: TableInfo, index: Int, to text: NSMutableAttributedString) {
        let full = NSRange(location: 0, length: text.length)
        let r = NSIntersectionRange(table.range, full)
        guard r.length > 0 else { return }

        // Caret inside this table → reveal the raw source for editing (the
        // transparent-text grid would otherwise take invisible keystrokes).
        if originOffset + table.anchor == revealTableAnchor {
            let p = NSMutableParagraphStyle()
            p.lineHeightMultiple = 1.2
            text.addAttributes([
                .font: theme.codeFont,
                .foregroundColor: theme.codeColor,
                .backgroundColor: theme.codeBackground,
                .paragraphStyle: p,
            ], range: r)
            return // no transparency, no anchor → no grid drawn
        }

        // Make the raw source transparent (keeps line fragments — and thus their
        // reserved height — alive, unlike null glyphs) and give each row `rh`.
        let rh = theme.tableRowHeight
        text.addAttribute(.foregroundColor, value: NSColor.clear, range: r)
        let rowStyle = NSMutableParagraphStyle()
        rowStyle.minimumLineHeight = rh
        rowStyle.maximumLineHeight = rh
        text.addAttribute(.paragraphStyle, value: rowStyle, range: r)

        // Collapse the separator row so it adds no visible height.
        if let sep = table.separatorRange, sep.upperBound <= text.length {
            let collapsed = NSMutableParagraphStyle()
            collapsed.minimumLineHeight = 0.01
            collapsed.maximumLineHeight = 0.01
            text.addAttribute(.paragraphStyle, value: collapsed, range: sep)
        }

        if table.anchor < text.length {
            // Value = the table's *absolute* anchor; the layout manager looks
            // its TableInfo up by anchor (index-stable across slice renders).
            text.addAttribute(.vireoTable, value: NSNumber(value: originOffset + table.anchor),
                              range: NSRange(location: table.anchor, length: 1))
        }
    }

    private func imageDrawHeight(for image: NSImage?) -> CGFloat {
        guard let image, image.size.width > 0 else { return 44 }
        let maxW = theme.contentMaxWidth
        let scale = min(1, maxW / image.size.width)
        return max(24, image.size.height * scale) + 12
    }

    // MARK: Helpers

    private func bodyParagraph() -> NSMutableParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineHeightMultiple = theme.lineHeightMultiple
        p.paragraphSpacing = theme.baseSize * 0.5
        return p
    }
}
