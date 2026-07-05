import Foundation

/// Inline character styling applied over a range of the *source* string.
public struct InlineRun: Sendable, Equatable {
    public var range: NSRange
    public var bold: Bool
    public var italic: Bool
    public var code: Bool
    public var strikethrough: Bool
    /// Link destination if this run is (part of) a link's visible text.
    public var link: String?

    public init(range: NSRange, bold: Bool = false, italic: Bool = false,
                code: Bool = false, strikethrough: Bool = false, link: String? = nil) {
        self.range = range
        self.bold = bold
        self.italic = italic
        self.code = code
        self.strikethrough = strikethrough
        self.link = link
    }
}

public enum BlockKind: Sendable, Equatable {
    case paragraph
    case heading(level: Int)
    case blockQuote
    case codeBlock(language: String?)
    case listItem(depth: Int, ordered: Bool)
    case tableRow(isHeader: Bool)
    case thematicBreak
}

/// Block-level styling applied over a paragraph range of the source string.
public struct BlockRun: Sendable, Equatable {
    public var range: NSRange
    public var kind: BlockKind
    public init(range: NSRange, kind: BlockKind) {
        self.range = range
        self.kind = kind
    }
}

/// An inline image `![alt](src)` occupying `range` in the source.
public struct ImageRun: Sendable, Equatable {
    public var range: NSRange
    public var source: String
    public var alt: String
    /// Character index (within `range`) that carries the drawn attachment.
    public var anchor: Int
    public init(range: NSRange, source: String, alt: String, anchor: Int) {
        self.range = range
        self.source = source
        self.alt = alt
        self.anchor = anchor
    }
}

/// A GFM task-list checkbox. Drawn to the left of `anchor` (first content char);
/// the raw `- [ ] ` syntax is hidden as a marker range.
public struct TaskMark: Sendable, Equatable {
    public var anchor: Int
    public var checked: Bool
    /// Nested content below the item's first line (nil for leaf items) —
    /// the range hidden when the item is collapsed.
    public var subtreeRange: NSRange?
    public init(anchor: Int, checked: Bool, subtreeRange: NSRange? = nil) {
        self.anchor = anchor
        self.checked = checked
        self.subtreeRange = subtreeRange
    }
}

/// A list bullet / number drawn to the left of `anchor` (first content char).
public struct ListMarker: Sendable, Equatable {
    public var anchor: Int
    public var text: String   // "•"/"◦"/"▪" by depth, "1."/"a."/"i." for ordered
    public var depth: Int
    /// Nested content below the item's first line (nil for leaf items) —
    /// the range hidden when the item is collapsed.
    public var subtreeRange: NSRange?
    public init(anchor: Int, text: String, depth: Int, subtreeRange: NSRange? = nil) {
        self.anchor = anchor
        self.text = text
        self.depth = depth
        self.subtreeRange = subtreeRange
    }
}

/// A foldable heading section. Unlike list subtrees, a heading's subtree is
/// non-local — it runs to the next heading of the same or higher level — so
/// these are recomputed over the whole document after every (incremental) parse.
public struct HeadingMark: Sendable, Equatable {
    /// First visible character of the heading text (after the hidden `# `).
    public var anchor: Int
    public var level: Int
    /// Everything between the heading line and the next same-or-higher heading
    /// (nil for empty sections) — the range hidden when the heading is collapsed.
    public var subtreeRange: NSRange?
    public init(anchor: Int, level: Int, subtreeRange: NSRange? = nil) {
        self.anchor = anchor
        self.level = level
        self.subtreeRange = subtreeRange
    }
}

public enum TableAlignment: Sendable, Equatable {
    case left, center, right, none
}

public struct TableCell: Sendable, Equatable {
    public var range: NSRange   // trimmed content range in the source
    public var column: Int
    public var alignment: TableAlignment
    public init(range: NSRange, column: Int, alignment: TableAlignment) {
        self.range = range
        self.column = column
        self.alignment = alignment
    }
}

public struct TableRow: Sendable, Equatable {
    public var isHeader: Bool
    public var cells: [TableCell]
    public init(isHeader: Bool, cells: [TableCell]) {
        self.isHeader = isHeader
        self.cells = cells
    }
}

/// A GFM table. The raw source (pipes + separator row) is hidden; the renderer
/// reserves vertical space per visible row and draws a real grid.
public struct TableInfo: Sendable, Equatable {
    public var range: NSRange
    public var rows: [TableRow]      // header + body (separator excluded)
    public var columnCount: Int
    public var anchor: Int           // char that carries the draw attribute
    public var separatorRange: NSRange?  // the `|---|` line, collapsed to ~0 height
    public init(range: NSRange, rows: [TableRow], columnCount: Int,
                anchor: Int, separatorRange: NSRange? = nil) {
        self.range = range
        self.rows = rows
        self.columnCount = columnCount
        self.anchor = anchor
        self.separatorRange = separatorRange
    }
}

public struct TOCEntry: Sendable, Equatable, Identifiable {
    public var id: Int { location }
    public var level: Int
    public var title: String
    public var location: Int   // UTF-16 offset of the heading in the source
    public init(level: Int, title: String, location: Int) {
        self.level = level
        self.title = title
        self.location = location
    }
}

/// The fully-analysed markdown document: everything the renderer needs,
/// all expressed as ranges over the untouched source string.
public struct ParsedMarkdown: Sendable, Equatable {
    /// Syntax delimiter ranges to hide (`#`, `**`, `` ` ``, `[`, `](url)`, list bullets, fences, …).
    public var markerRanges: [NSRange]
    public var inlineRuns: [InlineRun]
    public var blockRuns: [BlockRun]
    public var images: [ImageRun]
    public var tasks: [TaskMark]
    public var listMarkers: [ListMarker]
    public var tables: [TableInfo]
    public var toc: [TOCEntry]
    public var headings: [HeadingMark]

    public init(markerRanges: [NSRange] = [], inlineRuns: [InlineRun] = [],
                blockRuns: [BlockRun] = [], images: [ImageRun] = [],
                tasks: [TaskMark] = [], listMarkers: [ListMarker] = [],
                tables: [TableInfo] = [], toc: [TOCEntry] = [],
                headings: [HeadingMark] = []) {
        self.markerRanges = markerRanges
        self.inlineRuns = inlineRuns
        self.blockRuns = blockRuns
        self.images = images
        self.tasks = tasks
        self.listMarkers = listMarkers
        self.tables = tables
        self.toc = toc
        self.headings = headings
    }
}

public extension ParsedMarkdown {
    /// The runs intersecting `window`, rebased so `window.location` becomes 0.
    /// Used to restyle only the dirty region after an incremental parse; the
    /// window aligns with block boundaries, so intersecting runs lie inside it.
    func slice(_ window: NSRange) -> ParsedMarkdown {
        let d = -window.location
        func hits(_ r: NSRange) -> Bool {
            NSIntersectionRange(r, window).length > 0
                || (r.length == 0 && NSLocationInRange(r.location, window))
        }
        func shift(_ r: NSRange) -> NSRange { NSRange(location: r.location + d, length: r.length) }

        var out = ParsedMarkdown()
        out.markerRanges = markerRanges.filter(hits).map(shift)
        out.inlineRuns = inlineRuns.filter { hits($0.range) }
            .map { var x = $0; x.range = shift(x.range); return x }
        out.blockRuns = blockRuns.filter { hits($0.range) }
            .map { var x = $0; x.range = shift(x.range); return x }
        out.images = images.filter { hits($0.range) }
            .map { var x = $0; x.range = shift(x.range); x.anchor += d; return x }
        out.tasks = tasks.filter { NSLocationInRange($0.anchor, window) }
            .map { var x = $0
                x.anchor += d
                if let s = x.subtreeRange { x.subtreeRange = shift(s) }
                return x }
        out.listMarkers = listMarkers.filter { NSLocationInRange($0.anchor, window) }
            .map { var x = $0
                x.anchor += d
                if let s = x.subtreeRange { x.subtreeRange = shift(s) }
                return x }
        out.tables = tables.filter { hits($0.range) }.map { t in
            var x = t
            x.range = shift(x.range)
            x.anchor += d
            if let sep = x.separatorRange { x.separatorRange = shift(sep) }
            x.rows = x.rows.map { row in
                var r = row
                r.cells = r.cells.map { var c = $0; c.range = shift(c.range); return c }
                return r
            }
            return x
        }
        out.toc = toc.filter { NSLocationInRange($0.location, window) }
            .map { var x = $0; x.location += d; return x }
        out.headings = headings.filter { NSLocationInRange($0.anchor, window) }
            .map { var x = $0
                x.anchor += d
                if let s = x.subtreeRange { x.subtreeRange = shift(s) }
                return x }
        return out
    }
}
