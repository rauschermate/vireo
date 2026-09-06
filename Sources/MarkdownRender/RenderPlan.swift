import AppKit
import MarkdownEngine

/// Final attributed-string mutations expressed once, then resolved in a sorted
/// boundary sweep. The old renderer repeatedly split and re-merged a large
/// attributed string for every overlapping AST run; this plan resolves the
/// winning attributes before touching AppKit storage.
@MainActor
struct RenderPlan {
    private struct Mutation {
        let range: NSRange
        let additions: [NSAttributedString.Key: Any]
        let removals: [NSAttributedString.Key]
    }

    private struct Event {
        let position: Int
        let mutation: Int
        let starts: Bool
    }

    let length: Int
    let baseAttributes: [NSAttributedString.Key: Any]
    private var mutations: [Mutation] = []
    private static let trueValue = NSNumber(value: true)
    /// Space kerned on each side of an inline-code pill so it clears the
    /// surrounding text. Must equal `hInset + externalGap` in
    /// `fillBackgroundRectArray`, which splits it into pill and gap.
    static let inlineCodePadKern = NSNumber(value: 6.0)

    init(source: String, parsed: ParsedMarkdown, theme: Theme,
         baseURL: URL?, imageLoader: ImageLoader?, isDark: Bool,
         tableScrollerGutter: CGFloat, originOffset: Int,
         collapsedAnchors: Set<Int>) {
        let ns = source as NSString
        length = ns.length
        let styles = RenderStyleCache(theme: theme, parsed: parsed,
                                      tableScrollerGutter: tableScrollerGutter)
        baseAttributes = styles.bodyAttributes
        guard length > 0 else { return }

        // Hidden-syntax ranges, minus any the reveal window drops — so fence
        // lines below can tell whether they are currently hidden or shown.
        let markerSet = RangeSet(parsed.markerRanges)

        // cmark extends a list item's source range through the blank lines
        // that follow it. A blank between two siblings must keep the list's
        // compact spacing, but blanks after the *last* item belong to the
        // text below — styled as list, they park the caret at the list
        // indent right after Enter exits the list. An item is last when no
        // sibling starts where its range ends.
        let listItemStarts = Set(parsed.blockRuns.compactMap { run -> Int? in
            if case .listItem = run.kind { return run.range.location }
            return nil
        })

        // 1. Block styles.
        for block in parsed.blockRuns {
            let range = NSIntersectionRange(block.range, NSRange(location: 0, length: length))
            guard range.length > 0 else { continue }
            switch block.kind {
            case .heading(let level):
                if let attributes = styles.headingAttributes[level] {
                    add(range, attributes)
                }
            case .paragraph:
                break
            case .blockQuote:
                add(range, styles.quoteAttributes)
            case .codeBlock:
                add(range, styles.codeBlockAttributes)
                addFencePadding(in: range, source: ns,
                                paragraph: styles.codeFenceParagraph,
                                surfaceColor: theme.codeBackground,
                                hiddenMarkers: markerSet)
            case .listItem(let depth, _):
                if let paragraph = styles.listParagraphs[depth] {
                    let styled = listItemStarts.contains(range.upperBound)
                        ? range
                        : rangeWithoutTrailingBlankLines(range, in: ns)
                    if styled.length > 0 {
                        add(styled, [.paragraphStyle: paragraph])
                    }
                }
            case .tableRow(let isHeader):
                add(range, isHeader ? styles.tableHeaderRowAttributes
                                    : styles.tableBodyRowAttributes)
            case .thematicBreak:
                add(range, styles.ruleAttributes)
                let content = rangeWithoutTrailingNewline(range, in: ns)
                if content.length > 0 {
                    add(NSRange(location: content.location, length: 1),
                        [.vireoThematicBreak: theme.ruleColor])
                    add(content, [.vireoMarker: Self.trueValue])
                }
            }
        }

        // 2. Inline styles.
        for run in parsed.inlineRuns where run.range.upperBound <= length {
            var attributes: [NSAttributedString.Key: Any]
            if run.code {
                attributes = styles.inlineCodeAttributes
                // Kern space around the pill so it clears neighbouring text: the
                // char before the (zero-width) opening backticks and the last
                // code char. At a line start the char before is a newline — skip
                // it; the pill clamps to the margin there instead.
                var before = run.range.location - 1
                while before >= 0, ns.character(at: before) == 0x60 { before -= 1 }
                if before >= 0 {
                    let ch = ns.character(at: before)
                    if ch != 0x0A, ch != 0x0D {
                        add(NSRange(location: before, length: 1),
                            [.kern: Self.inlineCodePadKern])
                    }
                }
                add(NSRange(location: run.range.upperBound - 1, length: 1),
                    [.kern: Self.inlineCodePadKern])
            } else {
                attributes = [.font: styles.inlineFont(bold: run.bold, italic: run.italic)]
            }
            if run.strikethrough {
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            if run.underline {
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            if run.highlight {
                attributes[.backgroundColor] = theme.highlightColor
            }
            if let link = run.link {
                attributes[.foregroundColor] = theme.linkColor
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
                attributes[.vireoLink] = link as NSString
                attributes[.toolTip] = "⌘-click to open \(link)" as NSString
            }
            add(run.range, attributes)
        }

        // 3. Code tokens, with an explicit large-block degradation.
        let highlighter = CodeHighlighter()
        for block in parsed.blockRuns {
            guard case .codeBlock = block.kind else { continue }
            let range = NSIntersectionRange(block.range, NSRange(location: 0, length: length))
            guard range.length > 0,
                  range.length <= MarkdownRenderer.syntaxHighlightingUTF16Limit else { continue }
            let code = ns.substring(with: range)
            for token in highlighter.tokens(in: code, offset: range.location, isDark: isDark)
            where token.range.upperBound <= length {
                add(token.range, [.foregroundColor: token.color])
            }
        }

        // 4. Image line geometry and draw anchors.
        for image in parsed.images where image.range.upperBound <= length {
            let loaded = imageLoader?.image(forSource: image.source, baseURL: baseURL)
            let paragraph = NSMutableParagraphStyle()
            let height: CGFloat
            if let loaded, loaded.size.width > 0 {
                let scale = min(1, theme.contentMaxWidth / loaded.size.width)
                height = max(24, loaded.size.height * scale) + 12
            } else {
                height = 44
            }
            paragraph.minimumLineHeight = height
            paragraph.maximumLineHeight = height
            add(image.range, [.paragraphStyle: paragraph])
            add(NSRange(location: image.anchor, length: 1),
                [.vireoImage: image.source as NSString,
                 .vireoImageAlt: image.alt as NSString])
        }

        // 5. Tables.
        for table in parsed.tables {
            let range = NSIntersectionRange(table.range, NSRange(location: 0, length: length))
            guard range.length > 0 else { continue }
            add(range, [
                .foregroundColor: NSColor.clear,
                .paragraphStyle: styles.tableRowParagraph,
            ])
            if let separator = table.separatorRange, separator.upperBound <= length {
                add(separator, [.paragraphStyle: styles.tableSeparatorParagraph])
            }
            if tableScrollerGutter > 0,
               let lastCell = table.rows.last?.cells.first,
               lastCell.range.location < length {
                let lastLine = ns.lineRange(
                    for: NSRange(location: lastCell.range.location, length: 0)
                )
                let visibleLastLine = NSIntersectionRange(lastLine, range)
                if visibleLastLine.length > 0 {
                    add(visibleLastLine,
                        [.paragraphStyle: styles.tableLastRowParagraph])
                }
            }
            if table.anchor < length {
                add(NSRange(location: table.anchor, length: 1),
                    [.vireoTable: NSNumber(value: originOffset + table.anchor)])
            }
        }

        // 6–8. Drawn list/task/heading anchors.
        for marker in parsed.listMarkers where marker.anchor < length {
            add(NSRange(location: marker.anchor, length: 1),
                [.vireoBullet: marker.text as NSString])
        }
        for task in parsed.tasks where task.anchor < length {
            add(NSRange(location: task.anchor, length: 1),
                [.vireoCheckbox: NSNumber(value: task.checked)])
        }
        for heading in parsed.headings
        where heading.anchor < length && heading.subtreeRange != nil {
            add(NSRange(location: heading.anchor, length: 1),
                [.vireoHeading: NSNumber(value: heading.level)])
        }

        // 9. Metadata and HTML support-contract placeholders. Source-only
        // blocks retain one transparent anchor glyph for the native pill and
        // keep newlines as near-zero-height fragments. Inline HTML similarly
        // keeps one anchor for its compact replacement.
        for block in parsed.sourceBlocks where block.range.upperBound <= length {
            let range = NSIntersectionRange(block.range,
                                            NSRange(location: 0, length: length))
            guard range.length > 0, block.anchor < length else { continue }
            let label: String
            switch block.kind {
            case .metadata(let value), .unsupportedHTML(let value):
                label = value
            }
            add(range, [
                .foregroundColor: NSColor.clear,
                .paragraphStyle: styles.metadataHiddenParagraph,
                .vireoMetadata: Self.trueValue,
            ], removing: [.backgroundColor])

            let firstLine = NSIntersectionRange(
                ns.lineRange(for: NSRange(location: block.anchor, length: 0)),
                range
            )
            if firstLine.length > 0 {
                add(firstLine, [.paragraphStyle: styles.metadataVisibleParagraph])
            }
            add(NSRange(location: block.anchor, length: 1),
                [.vireoSourceBlock: label as NSString])
        }
        for html in parsed.inlineHTML where html.anchor < length {
            let value: String
            let tooltip: String
            let kern: Double
            switch html.kind {
            case .lineBreak:
                value = "line-break"
                tooltip = "HTML line break"
                kern = 2
            case .unsupported(let tag):
                value = "html:\(tag)"
                tooltip = "HTML \(tag) element is not rendered"
                kern = 12
            }
            add(NSRange(location: html.anchor, length: 1), [
                .vireoInlineHTML: value as NSString,
                .foregroundColor: NSColor.clear,
                .toolTip: tooltip as NSString,
                .kern: NSNumber(value: kern),
            ])
        }

        // 10. Coalesced hidden syntax ranges. Clip, don't drop, a marker running
        // past the slice: a windowed restyle can end mid-fence-marker (its range
        // carries the trailing newline), and dropping it leaves the fence shown.
        let markers = markerSet
        for range in markers.ranges {
            let clipped = NSIntersectionRange(range, NSRange(location: 0, length: length))
            guard clipped.length > 0 else { continue }
            add(clipped, [.vireoMarker: Self.trueValue])
        }

        // 11. Typographic prose arrows, classified from source ranges rather
        // than attributed-run lookups.
        var excluded = markers.ranges
        excluded.append(contentsOf: parsed.inlineRuns.compactMap { $0.code ? $0.range : nil })
        excluded.append(contentsOf: parsed.blockRuns.compactMap {
            if case .codeBlock = $0.kind { return $0.range }
            return nil
        })
        excluded.append(contentsOf: parsed.tables.map(\.range))
        excluded.append(contentsOf: parsed.images.map(\.range))
        let arrowExclusions = RangeSet(excluded)
        var search = NSRange(location: 0, length: length)
        while search.length > 0 {
            let arrow = ns.range(of: "->", options: [], range: search)
            guard arrow.location != NSNotFound else { break }
            search = NSRange(location: arrow.upperBound, length: length - arrow.upperBound)
            guard !arrowExclusions.contains(arrow.location),
                  !arrowExclusions.contains(arrow.location + 1) else { continue }
            add(NSRange(location: arrow.location, length: 1),
                [.vireoArrow: Self.trueValue])
            add(NSRange(location: arrow.location + 1, length: 1),
                [.vireoMarker: Self.trueValue])
        }

        // 12. Folded subtrees win last, including removal of code backgrounds.
        if !collapsedAnchors.isEmpty {
            let subtrees = parsed.listMarkers.map { ($0.anchor, $0.subtreeRange) }
                + parsed.tasks.map { ($0.anchor, $0.subtreeRange) }
                + parsed.headings.map { ($0.anchor, $0.subtreeRange) }
            let hidden = RangeSet(subtrees.compactMap { anchor, subtree -> NSRange? in
                guard collapsedAnchors.contains(originOffset + anchor),
                      var subtree, subtree.upperBound <= length else { return nil }
                if subtree.location > 0 {
                    subtree = NSRange(location: subtree.location - 1,
                                      length: subtree.length + 1)
                }
                return subtree
            })
            for range in hidden.ranges {
                add(range, [
                    .vireoCollapsed: Self.trueValue,
                    .paragraphStyle: styles.collapsedParagraph,
                ], removing: [.backgroundColor])
            }
        }
    }

    /// Give a hidden fence line a short fragment that becomes the surface's
    /// vertical padding. A revealed fence (caret in the block) isn't in
    /// `hiddenMarkers`, so it keeps the normal code line height and reads as an
    /// ordinary line inside the surface. Indented code blocks have no fences.
    mutating private func addFencePadding(in range: NSRange, source: NSString,
                                          paragraph: NSParagraphStyle,
                                          surfaceColor: NSColor,
                                          hiddenMarkers: RangeSet) {
        let firstLine = source.lineRange(
            for: NSRange(location: range.location, length: 0)
        )
        guard isFenceLine(firstLine, in: source) else { return }

        var lastCharacter = max(range.location, range.upperBound - 1)
        while lastCharacter > range.location {
            let character = source.character(at: lastCharacter)
            guard character == 0x0A || character == 0x0D else { break }
            lastCharacter -= 1
        }
        let lastLine = source.lineRange(
            for: NSRange(location: lastCharacter, length: 0)
        )
        func compress(_ line: NSRange) {
            guard hiddenMarkers.contains(line.location) else { return }
            add(line, [.paragraphStyle: paragraph, .vireoCodeBlock: surfaceColor])
        }
        compress(firstLine)
        if lastLine.location != firstLine.location, isFenceLine(lastLine, in: source) {
            compress(lastLine)
        }
    }

    private func isFenceLine(_ range: NSRange, in source: NSString) -> Bool {
        guard range.length > 0 else { return false }
        let line = source.substring(with: range)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return line.hasPrefix("```") || line.hasPrefix("~~~")
    }

    /// Drop whitespace-only lines from the end of `range`, keeping the
    /// newline that terminates the last content line.
    private func rangeWithoutTrailingBlankLines(_ range: NSRange,
                                                in source: NSString) -> NSRange {
        var end = range.upperBound
        while end > range.location {
            let line = source.lineRange(for: NSRange(location: end - 1, length: 0))
            let text = source.substring(with: NSIntersectionRange(line, range))
            guard text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { break }
            end = max(range.location, line.location)
        }
        return NSRange(location: range.location, length: end - range.location)
    }

    private func rangeWithoutTrailingNewline(_ range: NSRange,
                                             in source: NSString) -> NSRange {
        var result = range
        while result.length > 0 {
            let character = source.character(at: result.upperBound - 1)
            guard character == 0x0A || character == 0x0D else { break }
            result.length -= 1
        }
        return result
    }

    mutating private func add(_ range: NSRange,
                              _ attributes: [NSAttributedString.Key: Any],
                              removing: [NSAttributedString.Key] = []) {
        let clipped = NSIntersectionRange(range, NSRange(location: 0, length: length))
        guard clipped.length > 0 else { return }
        mutations.append(Mutation(range: clipped, additions: attributes,
                                  removals: removing))
    }

    func apply(to text: NSMutableAttributedString, at offset: Int) {
        guard offset >= 0, offset + length <= text.length else { return }
        text.beginEditing()
        defer { text.endEditing() }
        enumerateRuns { range, attributes in
            text.setAttributes(attributes,
                               range: NSRange(location: range.location + offset,
                                              length: range.length))
        }
    }

    func materialize(source: String) -> NSAttributedString {
        guard length > 0 else { return NSAttributedString(string: source) }
        let ns = source as NSString
        let result = NSMutableAttributedString()
        result.beginEditing()
        enumerateRuns { range, attributes in
            result.append(NSAttributedString(string: ns.substring(with: range),
                                             attributes: attributes))
        }
        result.endEditing()
        return result
    }

    private func enumerateRuns(_ body: (NSRange, [NSAttributedString.Key: Any]) -> Void) {
        var events: [Event] = []
        events.reserveCapacity(mutations.count * 2)
        for (index, mutation) in mutations.enumerated() {
            events.append(Event(position: mutation.range.location,
                                mutation: index, starts: true))
            events.append(Event(position: mutation.range.upperBound,
                                mutation: index, starts: false))
        }
        events.sort {
            if $0.position != $1.position { return $0.position < $1.position }
            if $0.starts != $1.starts { return !$0.starts } // endings first
            return $0.mutation < $1.mutation
        }

        var active: [Int] = [] // sorted by mutation/application order
        var eventIndex = 0
        var cursor = 0
        while cursor < length {
            while eventIndex < events.count, events[eventIndex].position == cursor {
                let event = events[eventIndex]
                if event.starts {
                    let insertion = active.partitioningIndex { $0 >= event.mutation }
                    active.insert(event.mutation, at: insertion)
                } else if let removal = active.binaryIndex(of: event.mutation) {
                    active.remove(at: removal)
                }
                eventIndex += 1
            }
            let next = min(length, eventIndex < events.count ? events[eventIndex].position : length)
            guard next > cursor else {
                cursor += 1
                continue
            }
            var attributes = baseAttributes
            for index in active {
                let mutation = mutations[index]
                for key in mutation.removals { attributes.removeValue(forKey: key) }
                for (key, value) in mutation.additions { attributes[key] = value }
            }
            body(NSRange(location: cursor, length: next - cursor), attributes)
            cursor = next
        }
    }
}

private extension Array where Element == Int {
    func partitioningIndex(where predicate: (Int) -> Bool) -> Int {
        var low = 0
        var high = count
        while low < high {
            let middle = (low + high) / 2
            if predicate(self[middle]) { high = middle }
            else { low = middle + 1 }
        }
        return low
    }

    func binaryIndex(of value: Int) -> Int? {
        let index = partitioningIndex { $0 >= value }
        return index < count && self[index] == value ? index : nil
    }
}
