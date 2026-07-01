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

        // Bullet/number marker = from item start to first child block's start.
        if let firstChild = item.children.first(where: { $0.range != nil }),
           let childRange = map.nsRange(firstChild.range) {
            let markerLen = childRange.location - itemRange.location
            if markerLen > 0 {
                result.markerRanges.append(NSRange(location: itemRange.location, length: markerLen))
            }
        }

        // Task-list checkbox.
        if let box = item.checkbox {
            if let bracket = findCheckbox(in: itemRange) {
                result.tasks.append(TaskMark(range: bracket, checked: box == .checked))
            }
        }

        for c in item.children {
            // paragraphs inside a list item shouldn't add their own block run
            visitBlock(c, listDepth: depth + 1, inQuote: true)
        }
    }

    mutating func visitTable(_ table: Table) {
        // v1: monospace-style each row; pipes remain visible (documented limit).
        if let head = map.nsRange(table.head.range) {
            result.blockRuns.append(BlockRun(range: head, kind: .tableRow(isHeader: true)))
        }
        for row in table.body.rows {
            if let r = map.nsRange(row.range) {
                result.blockRuns.append(BlockRun(range: r, kind: .tableRow(isHeader: false)))
            }
        }
    }

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

    /// Locate the `[ ]` / `[x]` checkbox within a list item marker region.
    private func findCheckbox(in itemRange: NSRange) -> NSRange? {
        let end = itemRange.location + itemRange.length
        var i = itemRange.location
        while i < end - 2 {
            if ns.character(at: i) == 0x5B { // '['
                let mid = ns.character(at: i + 1)
                if ns.character(at: i + 2) == 0x5D, // ']'
                   mid == 0x20 || mid == 0x78 || mid == 0x58 { // space, x, X
                    return NSRange(location: i, length: 3)
                }
            }
            // stop scanning once we hit a non-marker letter run
            if i > itemRange.location + 6 { break }
            i += 1
        }
        return nil
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
