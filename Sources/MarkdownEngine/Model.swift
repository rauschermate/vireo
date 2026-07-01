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
    public init(anchor: Int, checked: Bool) {
        self.anchor = anchor
        self.checked = checked
    }
}

/// A list bullet / number drawn to the left of `anchor` (first content char).
public struct ListMarker: Sendable, Equatable {
    public var anchor: Int
    public var text: String   // "•" for unordered, "1." etc. for ordered
    public var depth: Int
    public init(anchor: Int, text: String, depth: Int) {
        self.anchor = anchor
        self.text = text
        self.depth = depth
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
public struct ParsedMarkdown: Sendable {
    /// Syntax delimiter ranges to hide (`#`, `**`, `` ` ``, `[`, `](url)`, list bullets, fences, …).
    public var markerRanges: [NSRange]
    public var inlineRuns: [InlineRun]
    public var blockRuns: [BlockRun]
    public var images: [ImageRun]
    public var tasks: [TaskMark]
    public var listMarkers: [ListMarker]
    public var toc: [TOCEntry]

    public init(markerRanges: [NSRange] = [], inlineRuns: [InlineRun] = [],
                blockRuns: [BlockRun] = [], images: [ImageRun] = [],
                tasks: [TaskMark] = [], listMarkers: [ListMarker] = [], toc: [TOCEntry] = []) {
        self.markerRanges = markerRanges
        self.inlineRuns = inlineRuns
        self.blockRuns = blockRuns
        self.images = images
        self.tasks = tasks
        self.listMarkers = listMarkers
        self.toc = toc
    }
}
