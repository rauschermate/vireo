import Foundation
import Markdown

/// Parses GFM markdown into a `ParsedMarkdown` — a set of style/marker ranges
/// over the *untouched* source string. The source string always remains the
/// single source of truth (see docs/eng-design.md §3).
public struct MarkdownParser {
    public init() {}

    public func parse(_ source: String) -> ParsedMarkdown {
        let map = SourceMapping(source)
        let ns = source as NSString
        let doc = Document(parsing: source)
        var acc = Accumulator(map: map, ns: ns)
        for child in doc.children {
            acc.visitBlock(child, listDepth: 0, inQuote: false)
        }
        acc.result.markerRanges = acc.result.markerRanges
            .filter { $0.length > 0 }
            .sorted { $0.location < $1.location }
        return acc.result
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
            result.blockRuns.append(BlockRun(range: r, kind: .heading(level: heading.level)))
            addSubtractionMarkers(parent: r, children: heading.children)
            result.toc.append(TOCEntry(level: heading.level,
                                       title: plainText(heading).trimmingCharacters(in: .whitespaces),
                                       location: r.location))
            for c in heading.children { visitInline(c, style: InlineStyle()) }

        case let para as Paragraph:
            if let r = map.nsRange(para.range), !inQuote {
                result.blockRuns.append(BlockRun(range: r, kind: .paragraph))
            }
            for c in para.children { visitInline(c, style: InlineStyle()) }

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
            for item in list.listItems {
                visitListItem(item, depth: listDepth, ordered: false)
            }
            _ = list

        case let list as OrderedList:
            for item in list.listItems {
                visitListItem(item, depth: listDepth, ordered: true)
            }
            _ = list

        case let table as Table:
            visitTable(table)

        case is ThematicBreak:
            if let r = map.nsRange(node.range) {
                result.blockRuns.append(BlockRun(range: r, kind: .thematicBreak))
            }

        default:
            // HTMLBlock and anything else: leave visible, recurse for safety.
            for c in node.children { visitBlock(c, listDepth: listDepth, inQuote: inQuote) }
        }
    }

    mutating func visitListItem(_ item: ListItem, depth: Int, ordered: Bool) {
        guard let itemRange = map.nsRange(item.range) else { return }
        result.blockRuns.append(BlockRun(range: itemRange, kind: .listItem(depth: depth, ordered: ordered)))

        // Leading marker = from item start to first child block's start
        // (covers `- `, `1. ` and, for tasks, `- [ ] `). Hidden entirely; the
        // renderer draws a bullet / number / checkbox to the left of `anchor`.
        if let firstChild = item.children.first(where: { $0.range != nil }),
           let childRange = map.nsRange(firstChild.range) {
            let markerLen = childRange.location - itemRange.location
            if markerLen > 0 {
                result.markerRanges.append(NSRange(location: itemRange.location, length: markerLen))
            }
            let anchor = childRange.location
            if let box = item.checkbox {
                result.tasks.append(TaskMark(anchor: anchor, checked: box == .checked))
            } else if ordered {
                let raw = ns.substring(with: NSRange(location: itemRange.location, length: max(0, markerLen)))
                    .trimmingCharacters(in: .whitespaces)
                result.listMarkers.append(ListMarker(anchor: anchor, text: raw, depth: depth))
            } else {
                result.listMarkers.append(ListMarker(anchor: anchor, text: "•", depth: depth))
            }
        }

        for c in item.children {
            // paragraphs inside a list item shouldn't add their own block run
            visitBlock(c, listDepth: depth + 1, inQuote: true)
        }
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
