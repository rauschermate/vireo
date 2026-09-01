import Foundation
import Markdown

/// Parses GFM markdown into a `ParsedMarkdown` — a set of style/marker ranges
/// over the *untouched* source string. The source string always remains the
/// single source of truth (see docs/eng-design.md §3).
public struct MarkdownParser {
    public init() {}

    public func parse(_ source: String) -> ParsedMarkdown {
        parse(source, recognizesFrontMatter: true)
    }

    /// Slice parsing disables document-only constructs that would otherwise be
    /// misclassified when a local window happens to start with `---`.
    func parse(_ source: String, recognizesFrontMatter: Bool) -> ParsedMarkdown {
        let bench = ProcessInfo.processInfo.environment["VIREO_BENCH"] != nil
        func stamp() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
        func report(_ label: String, _ t0: UInt64) {
            if bench { print(String(format: "  %@: %.1f ms", label,
                                    Double(stamp() - t0) / 1_000_000)) }
        }

        var t = stamp()
        let map = SourceMapping(source)
        report("source mapping", t)

        t = stamp()
        let ns = source as NSString
        let doc = Document(parsing: source)
        report("cmark parse", t)

        t = stamp()
        var acc = Accumulator(map: map, ns: ns)
        for child in doc.children {
            acc.visitBlock(child, listDepth: 0, inQuote: false)
        }
        acc.scanDocumentMetadata(recognizesFrontMatter: recognizesFrontMatter)
        report("AST walk", t)

        acc.result.markerRanges = acc.result.markerRanges
            .filter { $0.length > 0 }
            .sorted { $0.location < $1.location }
        acc.result.sourceBlocks.sort { $0.range.location < $1.range.location }
        acc.result.inlineHTML.sort { $0.range.location < $1.range.location }
        acc.result.headings = Self.computeHeadingMarks(source: ns, toc: acc.result.toc)
        return acc.result
    }

    /// Foldable heading sections, derived from the TOC as a whole-document
    /// post-pass. A heading's subtree ends at the next heading of the same or
    /// higher level — a *non-local* boundary, so the incremental parser also
    /// recomputes this over the full spliced document (splicing local heading
    /// marks would keep stale fold ranges). Must stay a pure function of
    /// (source, toc) to preserve the incremental == full-parse invariant.
    static func computeHeadingMarks(source ns: NSString, toc: [TOCEntry]) -> [HeadingMark] {
        guard !toc.isEmpty else { return [] }

        // Each heading's subtree ends at the next heading of level ≤ its own.
        // Resolve every boundary in one reverse pass with a monotonic stack of
        // still-open headings (O(n)), instead of an O(n²) forward scan per
        // heading.
        var boundary = [Int](repeating: ns.length, count: toc.count)
        var open: [Int] = [] // indices, strictly increasing level from the base
        for i in stride(from: toc.count - 1, through: 0, by: -1) {
            while let top = open.last, toc[top].level > toc[i].level { open.removeLast() }
            boundary[i] = open.last.map { toc[$0].location } ?? ns.length
            open.append(i)
        }

        var out: [HeadingMark] = []
        out.reserveCapacity(toc.count)
        for (i, entry) in toc.enumerated() {
            // Anchor = first visible char: past the ATX `#`s and following
            // spaces (setext headings have no prefix — anchor at the start).
            var anchor = entry.location
            var hashes = 0
            while anchor < ns.length, hashes < 6, ns.character(at: anchor) == 0x23 { anchor += 1; hashes += 1 }
            if hashes > 0 {
                while anchor < ns.length, ns.character(at: anchor) == 0x20 { anchor += 1 }
            } else {
                anchor = entry.location
            }

            // Subtree = after the heading line, up to the boundary computed above.
            var lineEnd = anchor
            while lineEnd < ns.length, ns.character(at: lineEnd) != 0x0A { lineEnd += 1 }
            let start = lineEnd + 1
            var end = boundary[i]
            // Keep one trailing newline visible so the collapsed heading's line
            // fragment still terminates (mirrors the list-subtree convention:
            // the renderer hides the *leading* newline instead).
            if end > start, ns.character(at: end - 1) == 0x0A { end -= 1 }
            // Empty (all-whitespace) sections aren't foldable. Scan in place
            // rather than materialising and trimming the whole section string.
            var subtree: NSRange?
            if start < end {
                var k = start
                var hasContent = false
                while k < end {
                    let c = ns.character(at: k)
                    if c != 0x20, c != 0x09, c != 0x0A, c != 0x0D { hasContent = true; break }
                    k += 1
                }
                if hasContent { subtree = NSRange(location: start, length: end - start) }
            }
            out.append(HeadingMark(anchor: min(anchor, ns.length), level: entry.level, subtreeRange: subtree))
        }
        return out
    }
}

public extension MarkdownParser {
    /// Bullet glyph cycles by depth: • ◦ ▪ then repeats.
    static func bulletGlyph(forDepth depth: Int) -> String {
        switch depth % 3 {
        case 0: return "•"
        case 1: return "◦"
        default: return "▪"
        }
    }

    /// Ordered markers cycle 1. → a. → i. by depth (the 4th level wraps back
    /// to numbers), preserving the source's delimiter.
    static func orderedMarkerText(ordinal: Int, delimiter: String, depth: Int) -> String {
        switch depth % 3 {
        case 0: return "\(ordinal)\(delimiter)"
        case 1: return alpha(ordinal) + delimiter
        default: return roman(ordinal) + delimiter
        }
    }

    /// 1 → a, 2 → b, … 27 → aa.
    static func alpha(_ n: Int) -> String {
        var n = max(1, n)
        var out = ""
        while n > 0 {
            n -= 1
            out = String(UnicodeScalar(UInt8(97 + n % 26))) + out
            n /= 26
        }
        return out
    }

    /// 1 → i, 4 → iv, 9 → ix, …
    static func roman(_ n: Int) -> String {
        var n = max(1, n)
        let table: [(Int, String)] = [(1000, "m"), (900, "cm"), (500, "d"), (400, "cd"),
                                      (100, "c"), (90, "xc"), (50, "l"), (40, "xl"),
                                      (10, "x"), (9, "ix"), (5, "v"), (4, "iv"), (1, "i")]
        var out = ""
        for (value, symbol) in table {
            while n >= value { out += symbol; n -= value }
        }
        return out
    }
}

/// Inline style state inherited down the inline tree.
private struct InlineStyle {
    var bold = false
    var italic = false
    var strike = false
    var code = false
    var underline = false
    var highlight = false
    var link: String?
}

private struct Accumulator {
    let map: SourceMapping
    let ns: NSString
    var result = ParsedMarkdown()
    var htmlStyleStack: [String] = []

    // MARK: Block level

    mutating func visitBlock(_ node: Markup, listDepth: Int, inQuote: Bool) {
        switch node {
        case let heading as Heading:
            guard let r = map.nsRange(heading.range) else { return }
            // A `-` setext underline is really an (indented) empty list marker:
            // `text\n- ` (Enter makes a fresh bullet), or `- one\n    - \n- two`
            // (Tab indents a fresh bullet mid-list). cmark reads the `-` line as
            // a setext-H2 underline and can inflate the heading's range past the
            // following list siblings — so derive the underline from the text's
            // own line, not `r.upperBound`, and if it's a marker-only line,
            // render the text as a paragraph plus a drawn (nested) marker instead
            // of flashing a heading. ATX headings (leading `#`) never apply.
            let textLine = ns.lineRange(for: NSRange(location: r.location, length: 0))
            if heading.level == 2, r.location < ns.length, ns.character(at: r.location) != 0x23,
               textLine.upperBound < ns.length {
                let underline = ns.lineRange(for: NSRange(location: textLine.upperBound, length: 0))
                if synthesizeDanglingItem(endingAt: NSRange(location: r.location,
                                                            length: underline.upperBound - r.location),
                                          listDepth: listDepth) {
                    if !inQuote, textLine.upperBound - 1 > r.location {
                        let para = NSRange(location: r.location,
                                           length: textLine.upperBound - 1 - r.location)
                        result.blockRuns.append(BlockRun(range: para, kind: .paragraph))
                    }
                    visitInlineChildren(heading.children)
                    return
                }
            }
            result.blockRuns.append(BlockRun(range: r, kind: .heading(level: heading.level)))
            addSubtractionMarkers(parent: r, children: heading.children)
            // Only document-level headings join the TOC (and so become
            // foldable). A heading nested in a list item or block quote
            // (`inQuote`) is styled but not an outline entry — its fold subtree
            // is computed against document-order headings and would otherwise
            // run past the container, hiding sibling/parent content.
            if !inQuote {
                result.toc.append(TOCEntry(level: heading.level,
                                           title: plainText(heading).trimmingCharacters(in: .whitespaces),
                                           location: r.location))
            }
            visitInlineChildren(heading.children)

        case let para as Paragraph:
            if let r = map.nsRange(para.range), !inQuote {
                result.blockRuns.append(BlockRun(range: r, kind: .paragraph))
            }
            visitInlineChildren(para.children)
            // An empty item can't interrupt a paragraph (CommonMark), so the
            // marker-only line Tab just created rides along as lazy
            // continuation text — draw its marker anyway.
            if let r = map.nsRange(para.range) {
                synthesizeDanglingItem(endingAt: r, listDepth: listDepth)
            }

        case let quote as BlockQuote:
            guard let r = map.nsRange(quote.range) else { return }
            result.blockRuns.append(BlockRun(range: r, kind: .blockQuote))
            addQuoteMarkers(in: r)
            for c in quote.children { visitBlock(c, listDepth: listDepth, inQuote: true) }

        case let code as CodeBlock:
            guard let r = map.nsRange(code.range) else { return }
            result.blockRuns.append(BlockRun(range: r, kind: .codeBlock(language: code.language)))
            addFenceMarkers(in: r)

        case let list as UnorderedList:
            recordWholeListRun(list)
            for item in list.listItems {
                visitListItem(item, depth: listDepth, ordered: false)
            }

        case let list as OrderedList:
            recordWholeListRun(list)
            // Displayed numbers are the item's *ordinal* (list start + position),
            // not the raw source digits — inserting an item mid-list renumbers
            // everything after it on screen even while the source lags behind.
            let start = Int(list.startIndex)
            for (i, item) in list.listItems.enumerated() {
                visitListItem(item, depth: listDepth, ordered: true, ordinal: start + i)
            }

        case let table as Table:
            visitTable(table)

        case is ThematicBreak:
            if let r = map.nsRange(node.range) {
                result.blockRuns.append(BlockRun(range: r, kind: .thematicBreak))
            }

        case let html as HTMLBlock:
            if let r = map.nsRange(html.range) {
                result.blockRuns.append(BlockRun(range: r, kind: .paragraph))
                let trimmed = html.rawHTML.trimmingCharacters(in: .whitespacesAndNewlines)
                let kind: SourceBlockKind
                if trimmed.hasPrefix("<!--") {
                    kind = .metadata(label: "HTML comment")
                } else {
                    let name = htmlTagName(trimmed)
                    let label = name.isEmpty ? "HTML block · not rendered"
                        : "HTML \(name) block · not rendered"
                    kind = .unsupportedHTML(label: label)
                }
                result.sourceBlocks.append(SourceBlockRun(range: r, anchor: r.location,
                                                           kind: kind))
                result.markerRanges.append(r)
            }

        default:
            // Anything else: leave visible, recurse for safety.
            for c in node.children { visitBlock(c, listDepth: listDepth, inQuote: inQuote) }
        }
    }

    /// Whole-list block run (styling no-op, like HTML blocks): item ordinals
    /// depend on the entire list, so the incremental parser's window expansion
    /// must never re-parse a list from the middle — a slice starting at item
    /// 3 would restart its numbering at that item's raw digits.
    private mutating func recordWholeListRun(_ list: Markup) {
        if let r = map.nsRange(list.range) {
            result.blockRuns.append(BlockRun(range: r, kind: .paragraph))
        }
    }

    mutating func visitListItem(_ item: ListItem, depth: Int, ordered: Bool, ordinal: Int = 1) {
        guard let itemRange = map.nsRange(item.range) else { return }
        result.blockRuns.append(BlockRun(range: itemRange, kind: .listItem(depth: depth, ordered: ordered)))

        // Leading marker = from item start to first child block's start
        // (covers `- `, `1. ` and, for tasks, `- [ ] `). Hidden entirely; the
        // renderer draws a bullet / number / checkbox to the left of `anchor`.
        // Empty items (`- ` just typed) get the same treatment with the anchor
        // on the trailing newline, so continuing a list never flashes raw
        // syntax or shifts the text when content arrives.
        let anchor: Int
        let markerRange: NSRange
        if let firstChild = item.children.first(where: { $0.range != nil }),
           let childRange = map.nsRange(firstChild.range) {
            markerRange = NSRange(location: itemRange.location,
                                  length: childRange.location - itemRange.location)
            anchor = childRange.location
        } else {
            // On an empty item cmark's range starts at the line, not at the
            // marker. Hide from the marker on, so the leading indent stays a
            // visible glyph run exactly as it is on a filled item — otherwise
            // revealing the caret's line un-hides spaces the layout never
            // accounted for and the text jumps right.
            let scan = ListMarkerScanner.scan(ns, in: itemRange)
            let markerStart = scan?.markerStart ?? itemRange.location
            anchor = scan?.contentStart ?? itemRange.location
            markerRange = NSRange(location: markerStart, length: anchor - markerStart)
            guard anchor < ns.length else {
                // nothing (not even a newline) to carry the drawn marker —
                // leave the raw `- ` visible rather than losing it entirely
                return
            }
        }
        if markerRange.length > 0 {
            result.markerRanges.append(markerRange)
        }

        let subtree = subtreeRange(of: itemRange, afterFirstLineFrom: anchor)

        if let box = item.checkbox {
            result.tasks.append(TaskMark(anchor: anchor, checked: box == .checked,
                                         subtreeRange: subtree))
        } else if ordered {
            let raw = ns.substring(with: markerRange)
                .trimmingCharacters(in: .whitespaces)
            let delimiter = raw.hasSuffix(")") ? ")" : "."
            result.listMarkers.append(ListMarker(anchor: anchor,
                                                 text: MarkdownParser.orderedMarkerText(ordinal: ordinal,
                                                                                        delimiter: delimiter,
                                                                                        depth: depth),
                                                 depth: depth,
                                                 subtreeRange: subtree))
        } else {
            result.listMarkers.append(ListMarker(anchor: anchor,
                                                 text: MarkdownParser.bulletGlyph(forDepth: depth),
                                                 depth: depth,
                                                 subtreeRange: subtree))
        }

        for c in item.children {
            // paragraphs inside a list item shouldn't add their own block run
            visitBlock(c, listDepth: depth + 1, inQuote: true)
        }
    }

    /// A marker-only line (`    1. `, `- `, `- [ ] `) that Tab or Enter just
    /// created doesn't parse as a list item: an empty item can't interrupt a
    /// paragraph, so cmark folds it into the previous block. Detect it as the
    /// block's trailing line and synthesize the item it is about to become —
    /// drawn marker at the depth a nested list would get here, raw syntax
    /// hidden — so indenting never flashes `1.` (or the wrong marker style)
    /// before content arrives. Returns false if the line isn't marker-only.
    @discardableResult
    private mutating func synthesizeDanglingItem(endingAt r: NSRange, listDepth: Int) -> Bool {
        guard r.length > 0, r.upperBound <= ns.length else { return false }
        let line = ns.lineRange(for: NSRange(location: r.upperBound - 1, length: 0))
        guard line.location > r.location else { return false } // first line would be a real item

        guard let scan = ListMarkerScanner.scan(ns, in: line) else { return false }
        // Whitespace after the marker is required here: a bare `-` under text
        // is a deliberate setext underline, and an item needs the space anyway.
        guard scan.hasWhitespaceAfterMarker else { return false }
        // Marker-only means nothing else on the line, and a newline must exist
        // to carry the drawn marker (same rule as empty items in visitListItem).
        guard scan.isMarkerOnly, scan.lineEnd < ns.length else { return false }
        let anchor = scan.lineEnd

        // Start at the marker, not at the line: that is where a real item's
        // range starts, and both consumers depend on it. The hidden range must
        // leave the leading indent a visible glyph run, or revealing the
        // caret's line un-hides spaces the layout never accounted for. The
        // block run must not reach the line's first character, or its own
        // depth — not the parent's — sets the paragraph indent, and the line
        // steps back one level as soon as content arrives.
        let itemRange = NSRange(location: scan.markerStart,
                                length: anchor - scan.markerStart)
        result.markerRanges.append(itemRange)
        result.blockRuns.append(BlockRun(range: itemRange,
                                         kind: .listItem(depth: listDepth,
                                                         ordered: scan.isOrdered)))
        if let checked = scan.taskChecked {
            result.tasks.append(TaskMark(anchor: anchor, checked: checked))
        } else if case .ordered(let ordinal, let delimiter) = scan.kind {
            result.listMarkers.append(ListMarker(anchor: anchor,
                                                 text: MarkdownParser.orderedMarkerText(ordinal: ordinal,
                                                                                        delimiter: String(delimiter),
                                                                                        depth: listDepth),
                                                 depth: listDepth))
        } else {
            result.listMarkers.append(ListMarker(anchor: anchor,
                                                 text: MarkdownParser.bulletGlyph(forDepth: listDepth),
                                                 depth: listDepth))
        }
        return true
    }

    /// Everything below the item's first line — hidden when collapsed.
    private func subtreeRange(of itemRange: NSRange, afterFirstLineFrom anchor: Int) -> NSRange? {
        let end = itemRange.location + itemRange.length
        var i = anchor
        while i < end, ns.character(at: i) != 0x0A { i += 1 }
        let start = i + 1
        guard start < end else { return nil }
        let rest = ns.substring(with: NSRange(location: start, length: end - start))
        guard !rest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return NSRange(location: start, length: end - start)
    }


    mutating func visitTable(_ table: Table) {
        guard let tableRange = map.nsRange(table.range) else { return }
        let aligns = table.columnAlignments
        func alignment(_ col: Int) -> TableAlignment {
            guard col < aligns.count, let a = aligns[col] else { return .none }
            switch a {
            case .left: return .left
            case .center: return .center
            case .right: return .right
            }
        }

        var rows: [TableRow] = []
        var columnCount = 0

        func makeRow(_ cellNodes: [Markup], isHeader: Bool) {
            var cells: [TableCell] = []
            for (col, node) in cellNodes.enumerated() {
                guard let r = map.nsRange(node.range) else { continue }
                var contentRange = trim(r)
                // swift-markdown can anchor an empty GFM cell to one of its
                // structural `|` delimiters. The delimiter is table plumbing,
                // never cell content; represent the cell as a zero-length
                // insertion point so drawing and editing both see it as blank.
                if contentRange.length == 1,
                   ns.character(at: contentRange.location) == 0x7C {
                    contentRange.length = 0
                }
                cells.append(TableCell(range: contentRange, column: col,
                                       alignment: alignment(col)))
                // Table cells are still inline Markdown. Record emphasis,
                // code, links and their delimiters just like paragraph text so
                // the drawn grid can present rich content without raw syntax.
                for child in node.children {
                    visitInline(child, style: InlineStyle())
                }
            }
            columnCount = max(columnCount, cells.count)
            rows.append(TableRow(isHeader: isHeader, cells: cells))
        }

        makeRow(Array(table.head.cells), isHeader: true)
        for row in table.body.rows {
            makeRow(Array(row.cells), isHeader: false)
        }

        // The separator row is the 2nd source line of the table.
        var lines: [NSRange] = []
        enumerateLines(in: tableRange) { lines.append($0) }
        let separator = lines.count > 1 ? lines[1] : nil
        if let headerLine = lines.first {
            result.blockRuns.append(BlockRun(range: headerLine,
                                             kind: .tableRow(isHeader: true)))
        }
        for line in lines.dropFirst(2) {
            result.blockRuns.append(BlockRun(range: line,
                                             kind: .tableRow(isHeader: false)))
        }

        result.tables.append(TableInfo(range: tableRange, rows: rows,
                                       columnCount: columnCount, anchor: tableRange.location,
                                       separatorRange: separator))
        // NB: the table's raw glyphs are made transparent (not null-hidden) by the
        // renderer so the line fragments still reserve height for the drawn grid.
    }

    /// Trim leading/trailing ASCII whitespace from a range.
    private func trim(_ r: NSRange) -> NSRange {
        var loc = r.location
        var end = r.location + r.length
        while loc < end, isSpace(ns.character(at: loc)) { loc += 1 }
        while end > loc, isSpace(ns.character(at: end - 1)) { end -= 1 }
        return NSRange(location: loc, length: end - loc)
    }

    private func isSpace(_ c: unichar) -> Bool { c == 0x20 || c == 0x09 }

    // MARK: Inline level

    /// HTML styling is allowed to span inline siblings within one block, but a
    /// malformed opening tag must not leak into the next paragraph or heading.
    private mutating func visitInlineChildren(_ children: MarkupChildren) {
        htmlStyleStack.removeAll(keepingCapacity: true)
        for child in children { visitInline(child, style: InlineStyle()) }
        htmlStyleStack.removeAll(keepingCapacity: true)
    }

    mutating func visitInline(_ node: Markup, style: InlineStyle) {
        var style = style
        for tag in htmlStyleStack {
            switch tag {
            case "b", "strong": style.bold = true
            case "i", "em": style.italic = true
            case "del", "s", "strike": style.strike = true
            case "code", "kbd": style.code = true
            case "u": style.underline = true
            case "mark": style.highlight = true
            default: break
            }
        }
        switch node {
        case let strong as Strong:
            addSubtractionMarkers(parent: map.nsRange(strong.range), children: strong.children)
            var s = style; s.bold = true
            for c in strong.children { visitInline(c, style: s) }

        case let em as Emphasis:
            addSubtractionMarkers(parent: map.nsRange(em.range), children: em.children)
            var s = style; s.italic = true
            for c in em.children { visitInline(c, style: s) }

        case let strike as Strikethrough:
            addSubtractionMarkers(parent: map.nsRange(strike.range), children: strike.children)
            var s = style; s.strike = true
            for c in strike.children { visitInline(c, style: s) }

        case let link as Link:
            let range = map.nsRange(link.range)
            addSubtractionMarkers(parent: range, children: link.children)
            if let range {
                let children = link.children.compactMap { map.nsRange($0.range) }
                    .filter { $0.length > 0 }
                    .sorted { $0.location < $1.location }
                let labelRange: NSRange
                if let first = children.first, let last = children.last {
                    labelRange = NSRange(location: first.location,
                                         length: last.upperBound - first.location)
                } else {
                    // Empty-label links still need an insertion point between
                    // their opening and closing brackets.
                    labelRange = NSRange(location: min(range.upperBound, range.location + 1),
                                         length: 0)
                }
                result.links.append(LinkRun(range: range, labelRange: labelRange,
                                            label: plainText(link),
                                            destination: link.destination ?? ""))
            }
            var s = style; s.link = link.destination ?? ""
            for c in link.children { visitInline(c, style: s) }

        case let image as Image:
            if let r = map.nsRange(image.range) {
                result.images.append(ImageRun(range: r,
                                              source: image.source ?? "",
                                              alt: plainText(image),
                                              anchor: r.location))
                // The source expression is drawing metadata, not visible text.
                // Keep every character in the backing store but null its glyphs;
                // `.vireoImage` on the first character remains the draw anchor.
                result.markerRanges.append(r)
            }

        case let code as InlineCode:
            guard let r = map.nsRange(code.range) else { return }
            let inner = innerCodeRange(r)
            emit(inner, style: style, code: true)
            // backtick delimiters on both sides
            if inner.location > r.location {
                result.markerRanges.append(NSRange(location: r.location,
                                                   length: inner.location - r.location))
            }
            let tail = (r.location + r.length) - (inner.location + inner.length)
            if tail > 0 {
                result.markerRanges.append(NSRange(location: inner.location + inner.length, length: tail))
            }

        case let text as Text:
            if let r = map.nsRange(text.range) { emit(r, style: style, code: style.code) }

        case let html as InlineHTML:
            handleInlineHTML(html)

        case is SoftBreak, is LineBreak:
            break // visible whitespace / passthrough

        default:
            for c in node.children { visitInline(c, style: style) }
        }
    }

    private mutating func emit(_ range: NSRange, style: InlineStyle, code: Bool = false) {
        guard range.length > 0 else { return }
        if !style.bold && !style.italic && !style.strike && !style.underline
            && !style.highlight && style.link == nil && !code { return }
        result.inlineRuns.append(InlineRun(range: range,
                                           bold: style.bold,
                                           italic: style.italic,
                                           code: code,
                                           strikethrough: style.strike,
                                           underline: style.underline,
                                           highlight: style.highlight,
                                           link: style.link))
    }

    private mutating func handleInlineHTML(_ html: InlineHTML) {
        guard let range = map.nsRange(html.range), range.length > 0 else { return }
        let raw = html.rawHTML.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = raw.lowercased()
        if lower.hasPrefix("<!--") {
            result.markerRanges.append(range)
            return
        }
        let name = htmlTagName(lower)
        guard !name.isEmpty else {
            result.markerRanges.append(range)
            result.inlineHTML.append(InlineHTMLRun(range: range, anchor: range.location,
                                                   kind: .unsupported(tag: "HTML")))
            return
        }
        let closing = lower.hasPrefix("</")
        let selfClosing = lower.hasSuffix("/>")
        let styled = Set(["b", "strong", "i", "em", "del", "s", "strike",
                          "code", "kbd", "u", "mark"])
        result.markerRanges.append(range)

        if styled.contains(name) {
            if closing {
                if let index = htmlStyleStack.lastIndex(of: name) {
                    htmlStyleStack.remove(at: index)
                }
            } else if !selfClosing {
                htmlStyleStack.append(name)
            }
        } else if name == "br" {
            result.inlineHTML.append(InlineHTMLRun(range: range, anchor: range.location,
                                                   kind: .lineBreak))
        } else if !closing {
            result.inlineHTML.append(InlineHTMLRun(range: range, anchor: range.location,
                                                   kind: .unsupported(tag: name)))
        }
    }

    private func htmlTagName(_ raw: String) -> String {
        var value = raw[...]
        guard value.first == "<" else { return "" }
        value = value.dropFirst()
        if value.first == "/" { value = value.dropFirst() }
        while value.first == " " { value = value.dropFirst() }
        let name = value.prefix { $0.isLetter || $0.isNumber || $0 == "-" }
        return name.lowercased()
    }

    // MARK: Source metadata

    mutating func scanDocumentMetadata(recognizesFrontMatter: Bool) {
        var lines: [NSRange] = []
        enumerateLines(in: NSRange(location: 0, length: ns.length)) { lines.append($0) }
        var frontMatterRange: NSRange?
        // A definition-like line inside code, a table, ordinary paragraph
        // continuation, or an HTML block is literal content. cmark has already
        // classified those ranges, so never let the metadata fallback hide
        // them merely because their trimmed text starts with `[label]:`.
        let literalContent = result.blockRuns.compactMap { run -> NSRange? in
            switch run.kind {
            case .paragraph, .codeBlock, .tableRow:
                return run.range
            default:
                return nil
            }
        }
        func isLiteralContent(_ line: NSRange) -> Bool {
            literalContent.contains { NSIntersectionRange($0, line).length > 0 }
        }

        if recognizesFrontMatter, lines.count >= 2, trimmedLine(lines[0]) == "---" {
            for index in 1..<lines.count {
                let delimiter = trimmedLine(lines[index])
                if delimiter == "---" || delimiter == "..." {
                    let fields = lines[1..<index].filter { trimmedLine($0).contains(":") }.count
                    // Avoid treating an ordinary pair of thematic breaks as
                    // front matter. A metadata envelope must contain at least
                    // one YAML-like key/value field.
                    guard fields > 0 else { break }
                    let range = NSRange(location: 0, length: lines[index].upperBound)
                    let label = fields == 1 ? "Front matter · 1 field"
                        : "Front matter · \(fields) fields"
                    result.sourceBlocks.append(SourceBlockRun(range: range, anchor: 0,
                                                               kind: .metadata(label: label)))
                    result.markerRanges.append(range)
                    result.blockRuns.append(BlockRun(range: range, kind: .paragraph))
                    frontMatterRange = range
                    break
                }
            }
        }

        var index = 0
        while index < lines.count {
            if let frontMatterRange, NSIntersectionRange(lines[index], frontMatterRange).length > 0 {
                index += 1
                continue
            }
            guard !isLiteralContent(lines[index]),
                  referenceLabel(in: lines[index]) != nil else {
                index += 1
                continue
            }
            let start = lines[index].location
            var end = lines[index].upperBound
            var count = 1
            index += 1
            while index < lines.count {
                if !isLiteralContent(lines[index]),
                   referenceLabel(in: lines[index]) != nil {
                    end = lines[index].upperBound
                    count += 1
                    index += 1
                    continue
                }
                // CommonMark permits a reference title on the following,
                // indented line. It is source plumbing too, so collapse it with
                // the definition instead of leaving a lone quoted title behind.
                if !isLiteralContent(lines[index]),
                   isReferenceTitleContinuation(lines[index]) {
                    end = lines[index].upperBound
                    index += 1
                    continue
                }
                break
            }
            let label = count == 1 ? "1 link reference" : "\(count) link references"
            let range = NSRange(location: start, length: end - start)
            result.sourceBlocks.append(SourceBlockRun(range: range, anchor: start,
                                                       kind: .metadata(label: label)))
            result.markerRanges.append(range)
            result.blockRuns.append(BlockRun(range: range, kind: .paragraph))
        }

        // Metadata owns its presentation; discard accidental cmark block/TOC
        // interpretations (for example YAML delimiters read as thematic rules).
        let metadata = result.sourceBlocks.compactMap { block -> NSRange? in
            if case .metadata = block.kind { return block.range }
            return nil
        }
        result.toc.removeAll { entry in metadata.contains { NSLocationInRange(entry.location, $0) } }
    }

    private func trimmedLine(_ range: NSRange) -> String {
        ns.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func referenceLabel(in range: NSRange) -> String? {
        let line = trimmedLine(range)
        guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { return nil }
        let after = line.index(after: close)
        guard after < line.endIndex, line[after] == ":" else { return nil }
        let destination = line[line.index(after: after)...]
            .trimmingCharacters(in: .whitespaces)
        guard !destination.isEmpty else { return nil }
        let label = String(line[line.index(after: line.startIndex)..<close])
            .trimmingCharacters(in: .whitespaces)
        return label.isEmpty ? nil : label
    }

    private func isReferenceTitleContinuation(_ range: NSRange) -> Bool {
        let raw = ns.substring(with: range)
        guard raw.first == " " || raw.first == "\t" else { return false }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = value.first else { return false }
        return (first == "\"" && value.last == "\"")
            || (first == "'" && value.last == "'")
            || (first == "(" && value.last == ")")
    }

    // MARK: Marker helpers

    /// Markers = parent range minus the union of children ranges.
    private mutating func addSubtractionMarkers(parent: NSRange?, children: MarkupChildren) {
        guard let parent else { return }
        addSubtractionMarkers(parent: parent, children: Array(children))
    }

    private mutating func addSubtractionMarkers(parent: NSRange, children: [Markup]) {
        let childRanges = children.compactMap { map.nsRange($0.range) }
            .filter { $0.length > 0 }
            .sorted { $0.location < $1.location }
        var cursor = parent.location
        let end = parent.location + parent.length
        for cr in childRanges {
            if cr.location > cursor {
                result.markerRanges.append(NSRange(location: cursor, length: cr.location - cursor))
            }
            cursor = max(cursor, cr.location + cr.length)
        }
        if cursor < end {
            result.markerRanges.append(NSRange(location: cursor, length: end - cursor))
        }
    }

    /// Hide leading `>` quote markers on each line inside the quote range.
    private mutating func addQuoteMarkers(in range: NSRange) {
        enumerateLines(in: range) { lineRange in
            var i = lineRange.location
            let end = lineRange.location + lineRange.length
            var spaces = 0
            while i < end, spaces < 4, ns.character(at: i) == 0x20 { i += 1; spaces += 1 }
            if i < end, ns.character(at: i) == 0x3E { // '>'
                var j = i + 1
                if j < end, ns.character(at: j) == 0x20 { j += 1 } // optional single space
                result.markerRanges.append(NSRange(location: lineRange.location, length: j - lineRange.location))
            }
        }
    }

    /// Hide ``` / ~~~ fence lines of a fenced code block.
    private mutating func addFenceMarkers(in range: NSRange) {
        var lines: [NSRange] = []
        enumerateLines(in: range) { lines.append($0) }
        guard let first = lines.first else { return }
        func isFence(_ r: NSRange) -> Bool {
            var i = r.location
            let end = r.location + r.length
            while i < end, ns.character(at: i) == 0x20 { i += 1 }
            guard i < end else { return false }
            let c = ns.character(at: i)
            return c == 0x60 || c == 0x7E // ` or ~
        }
        if isFence(first) {
            result.markerRanges.append(first) // includes trailing newline
        }
        if lines.count > 1, let last = lines.last, isFence(last) {
            var m = last
            let after = last.location + last.length
            if after < ns.length, ns.character(at: after) == 0x0A { m.length += 1 }
            result.markerRanges.append(m)
        }
    }

    // MARK: Range utilities

    private func enumerateLines(in range: NSRange, _ body: (NSRange) -> Void) {
        var start = range.location
        let end = range.location + range.length
        while start < end {
            var lineEnd = start
            while lineEnd < end, ns.character(at: lineEnd) != 0x0A { lineEnd += 1 }
            let includeNewline = lineEnd < end ? lineEnd + 1 : lineEnd
            body(NSRange(location: start, length: includeNewline - start))
            start = includeNewline
        }
    }

    /// Inner content range of an inline code span (strip backtick runs).
    private func innerCodeRange(_ r: NSRange) -> NSRange {
        var lead = 0
        while lead < r.length, ns.character(at: r.location + lead) == 0x60 { lead += 1 }
        var trail = 0
        while trail < r.length - lead, ns.character(at: r.location + r.length - 1 - trail) == 0x60 { trail += 1 }
        // Optional single padding space each side (`` ` x ` ``).
        var innerLoc = r.location + lead
        var innerLen = r.length - lead - trail
        if innerLen >= 2, ns.character(at: innerLoc) == 0x20, ns.character(at: innerLoc + innerLen - 1) == 0x20 {
            innerLoc += 1; innerLen -= 2
        }
        return NSRange(location: innerLoc, length: max(0, innerLen))
    }

    private func plainText(_ node: Markup) -> String {
        var out = ""
        func walk(_ n: Markup) {
            if let t = n as? Text { out += t.string }
            else if let c = n as? InlineCode { out += c.code }
            else { for ch in n.children { walk(ch) } }
        }
        walk(node)
        return out
    }
}
