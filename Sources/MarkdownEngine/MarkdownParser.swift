import Foundation
import Markdown

/// Parses GFM markdown into a `ParsedMarkdown` — a set of style/marker ranges
/// over the *untouched* source string. The source string always remains the
/// single source of truth (see docs/eng-design.md §3).
public struct MarkdownParser {
    public init() {}

    public func parse(_ source: String) -> ParsedMarkdown {
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
        report("AST walk", t)

        acc.result.markerRanges = acc.result.markerRanges
            .filter { $0.length > 0 }
            .sorted { $0.location < $1.location }
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
    var link: String?
}

private struct Accumulator {
    let map: SourceMapping
    let ns: NSString
    var result = ParsedMarkdown()

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
                    for c in heading.children { visitInline(c, style: InlineStyle()) }
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
            for c in heading.children { visitInline(c, style: InlineStyle()) }

        case let para as Paragraph:
            if let r = map.nsRange(para.range), !inQuote {
                result.blockRuns.append(BlockRun(range: r, kind: .paragraph))
            }
            for c in para.children { visitInline(c, style: InlineStyle()) }
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
            // Rendered as plain text, but recorded as a block so incremental
            // window expansion sees it (HTML blocks can span blank lines).
            if let r = map.nsRange(html.range) {
                result.blockRuns.append(BlockRun(range: r, kind: .paragraph))
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
        let markerLen: Int
        if let firstChild = item.children.first(where: { $0.range != nil }),
           let childRange = map.nsRange(firstChild.range) {
            markerLen = childRange.location - itemRange.location
            anchor = childRange.location
        } else {
            markerLen = scanMarkerLength(in: itemRange)
            anchor = itemRange.location + markerLen
            guard anchor < ns.length else {
                // nothing (not even a newline) to carry the drawn marker —
                // leave the raw `- ` visible rather than losing it entirely
                return
            }
        }
        if markerLen > 0 {
            result.markerRanges.append(NSRange(location: itemRange.location, length: markerLen))
        }

        let subtree = subtreeRange(of: itemRange, afterFirstLineFrom: anchor)

        if let box = item.checkbox {
            result.tasks.append(TaskMark(anchor: anchor, checked: box == .checked,
                                         subtreeRange: subtree))
        } else if ordered {
            let raw = ns.substring(with: NSRange(location: itemRange.location, length: max(0, markerLen)))
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

        var contentEnd = min(line.upperBound, ns.length)
        if contentEnd > line.location, ns.character(at: contentEnd - 1) == 0x0A { contentEnd -= 1 }

        var i = line.location
        while i < contentEnd, ns.character(at: i) == 0x20 || ns.character(at: i) == 0x09 { i += 1 }
        let markerStart = i
        var ordered = false
        var ordinal = 1
        var delimiter = "."
        switch i < contentEnd ? ns.character(at: i) : 0 {
        case 0x2D, 0x2A, 0x2B: // - * +
            i += 1
        case 0x30...0x39:
            while i < contentEnd, ns.character(at: i) >= 0x30, ns.character(at: i) <= 0x39 { i += 1 }
            guard i < contentEnd,
                  ns.character(at: i) == 0x2E || ns.character(at: i) == 0x29 else { return false }
            ordinal = Int(ns.substring(with: NSRange(location: markerStart,
                                                     length: i - markerStart))) ?? 1
            delimiter = ns.character(at: i) == 0x29 ? ")" : "."
            ordered = true
            i += 1
        default:
            return false
        }
        // Whitespace after the marker is required: a bare `-` under text is a
        // deliberate setext underline, and an item needs the space anyway.
        guard i < contentEnd, ns.character(at: i) == 0x20 || ns.character(at: i) == 0x09 else { return false }
        while i < contentEnd, ns.character(at: i) == 0x20 || ns.character(at: i) == 0x09 { i += 1 }
        var checked: Bool?
        if !ordered, i + 3 <= contentEnd,
           ns.character(at: i) == 0x5B, ns.character(at: i + 2) == 0x5D { // [ ]
            switch ns.character(at: i + 1) {
            case 0x20: checked = false
            case 0x78, 0x58: checked = true // x X
            default: break
            }
            if checked != nil {
                i += 3
                while i < contentEnd, ns.character(at: i) == 0x20 { i += 1 }
            }
        }
        // Marker-only means nothing else on the line, and a newline must exist
        // to carry the drawn marker (same rule as empty items in visitListItem).
        guard i >= contentEnd, contentEnd < ns.length else { return false }
        let anchor = contentEnd

        result.markerRanges.append(NSRange(location: line.location,
                                           length: anchor - line.location))
        result.blockRuns.append(BlockRun(range: NSRange(location: line.location,
                                                        length: anchor - line.location),
                                         kind: .listItem(depth: listDepth, ordered: ordered)))
        if let checked {
            result.tasks.append(TaskMark(anchor: anchor, checked: checked))
        } else if ordered {
            result.listMarkers.append(ListMarker(anchor: anchor,
                                                 text: MarkdownParser.orderedMarkerText(ordinal: ordinal,
                                                                                        delimiter: delimiter,
                                                                                        depth: listDepth),
                                                 depth: listDepth))
        } else {
            result.listMarkers.append(ListMarker(anchor: anchor,
                                                 text: MarkdownParser.bulletGlyph(forDepth: listDepth),
                                                 depth: listDepth))
        }
        return true
    }

    /// Indent + bullet/number + spacing (+ task box) at the start of an item
    /// that has no parsed children (empty item).
    private func scanMarkerLength(in itemRange: NSRange) -> Int {
        var i = itemRange.location
        let end = itemRange.location + itemRange.length
        while i < end, ns.character(at: i) == 0x20 || ns.character(at: i) == 0x09 { i += 1 }
        let c = i < end ? ns.character(at: i) : 0
        if c == 0x2D || c == 0x2A || c == 0x2B { // - * +
            i += 1
        } else if c >= 0x30, c <= 0x39 {
            while i < end, ns.character(at: i) >= 0x30, ns.character(at: i) <= 0x39 { i += 1 }
            if i < end, ns.character(at: i) == 0x2E || ns.character(at: i) == 0x29 { i += 1 }
        } else {
            return 0
        }
        while i < end, ns.character(at: i) == 0x20 { i += 1 }
        // Task box on an otherwise empty item ("- [ ] " just typed) — without
        // this the box syntax stays visible next to the drawn checkbox until
        // the first character of content arrives.
        if i + 2 < end, ns.character(at: i) == 0x5B, ns.character(at: i + 2) == 0x5D { // [ ]
            let mid = ns.character(at: i + 1)
            if mid == 0x20 || mid == 0x78 || mid == 0x58 { // ' ', x, X
                i += 3
                while i < end, ns.character(at: i) == 0x20 { i += 1 }
            }
        }
        return i - itemRange.location
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
                cells.append(TableCell(range: trim(r), column: col, alignment: alignment(col)))
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

    mutating func visitInline(_ node: Markup, style: InlineStyle) {
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
            addSubtractionMarkers(parent: map.nsRange(link.range), children: link.children)
            var s = style; s.link = link.destination ?? ""
            for c in link.children { visitInline(c, style: s) }

        case let image as Image:
            if let r = map.nsRange(image.range) {
                result.images.append(ImageRun(range: r,
                                              source: image.source ?? "",
                                              alt: plainText(image),
                                              anchor: r.location))
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
            if let r = map.nsRange(text.range) { emit(r, style: style) }

        case is SoftBreak, is LineBreak, is InlineHTML:
            break // visible whitespace / passthrough

        default:
            for c in node.children { visitInline(c, style: style) }
        }
    }

    private mutating func emit(_ range: NSRange, style: InlineStyle, code: Bool = false) {
        guard range.length > 0 else { return }
        if !style.bold && !style.italic && !style.strike && style.link == nil && !code { return }
        result.inlineRuns.append(InlineRun(range: range,
                                           bold: style.bold,
                                           italic: style.italic,
                                           code: code,
                                           strikethrough: style.strike,
                                           link: style.link))
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
