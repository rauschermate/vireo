import Foundation

/// The result of one scan of a list-marker prefix: the indent, the bullet or
/// the ordered number, the whitespace after it, and an optional task box.
public struct ListMarkerScan: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case bullet(Character)
        case ordered(ordinal: Int, delimiter: Character)
    }

    public let kind: Kind
    /// Offset of the first marker character. Everything before it is indent.
    public let markerStart: Int
    /// Offset just past the bullet character, or just past the ordered
    /// delimiter. The marker text is `markerStart ..< markerEnd`.
    public let markerEnd: Int
    /// True when at least one space or tab follows the marker. False only when
    /// the marker runs to the line end.
    public let hasWhitespaceAfterMarker: Bool
    /// Set when a `[ ]` / `[x]` / `[X]` box follows the marker.
    public let taskChecked: Bool?
    /// Offset of the first content character — past the indent, the marker, its
    /// whitespace, the task box, and the whitespace after the box.
    public let contentStart: Int
    /// The first newline in the scanned range, or the range end.
    public let lineEnd: Int

    public var isOrdered: Bool {
        if case .ordered = kind { return true }
        return false
    }

    /// True when the line holds a marker and nothing else.
    public var isMarkerOnly: Bool { contentStart >= lineEnd }
}

/// The one scanner for list-marker syntax.
///
/// Three call sites need this shape: `MarkdownParser.scanMarkerLength`,
/// `MarkdownParser.synthesizeDanglingItem`, and `ListLine.parse`. Each one used
/// to carry its own copy, and the copies disagreed — on tabs after the marker,
/// on the nine-digit ordinal cap, and on a task box after an ordered marker.
///
/// The scanner reports the syntax. Each caller keeps its own acceptance rule on
/// top: the dangling-item path rejects a marker that runs to the line end,
/// because a lone `-` under a paragraph is a setext underline.
public enum ListMarkerScanner {
    /// CommonMark caps an ordered marker at nine digits. A tenth digit makes
    /// the line a paragraph, so the scan must fail rather than truncate.
    public static let maxOrdinalDigits = 9

    /// Scan the first line of `range` in `ns`. Returns nil when the line does
    /// not open a list item.
    public static func scan(_ ns: NSString, in range: NSRange) -> ListMarkerScan? {
        let start = max(0, range.location)
        guard start < min(range.upperBound, ns.length) else { return nil }

        // A marker lives on one line. Stop at the first newline.
        var end = start
        let limit = min(range.upperBound, ns.length)
        while end < limit, ns.character(at: end) != 0x0A { end += 1 }
        let lineEnd = end

        var i = start
        while i < end, isBlank(ns.character(at: i)) { i += 1 }
        let markerStart = i
        guard i < end else { return nil }

        let kind: ListMarkerScan.Kind
        let first = ns.character(at: i)
        if first == 0x2D || first == 0x2A || first == 0x2B { // - * +
            kind = .bullet(character(first))
            i += 1
        } else if isDigit(first) {
            var j = i
            while j < end, isDigit(ns.character(at: j)), j - i < maxOrdinalDigits { j += 1 }
            guard j < end else { return nil }
            let delimiter = ns.character(at: j)
            guard delimiter == 0x2E || delimiter == 0x29 else { return nil } // . or )
            let digits = ns.substring(with: NSRange(location: i, length: j - i))
            kind = .ordered(ordinal: Int(digits) ?? 1, delimiter: character(delimiter))
            i = j + 1
        } else {
            return nil
        }
        let markerEnd = i

        // Whitespace after the marker is required, because `-x` is a paragraph.
        // A marker that runs to the line end is the exception — that is the
        // empty item Tab or Enter just created.
        var hasWhitespaceAfterMarker = false
        while i < end, isBlank(ns.character(at: i)) {
            i += 1
            hasWhitespaceAfterMarker = true
        }
        guard hasWhitespaceAfterMarker || i >= end else { return nil }

        // A task box needs whitespace or the line end after it, per GFM.
        // swift-markdown reports a checkbox on ordered items too, so the box is
        // not restricted to bullets.
        var taskChecked: Bool?
        if i + 3 <= end, ns.character(at: i) == 0x5B, ns.character(at: i + 2) == 0x5D { // [ ]
            let checked: Bool?
            switch ns.character(at: i + 1) {
            case 0x20: checked = false
            case 0x78, 0x58: checked = true // x X
            default: checked = nil
            }
            let afterBox = i + 3
            if let checked, afterBox >= end || isBlank(ns.character(at: afterBox)) {
                taskChecked = checked
                i = afterBox
                while i < end, isBlank(ns.character(at: i)) { i += 1 }
            }
        }

        return ListMarkerScan(kind: kind,
                              markerStart: markerStart,
                              markerEnd: markerEnd,
                              hasWhitespaceAfterMarker: hasWhitespaceAfterMarker,
                              taskChecked: taskChecked,
                              contentStart: i,
                              lineEnd: lineEnd)
    }

    private static func isBlank(_ c: unichar) -> Bool { c == 0x20 || c == 0x09 }
    private static func isDigit(_ c: unichar) -> Bool { c >= 0x30 && c <= 0x39 }
    private static func character(_ c: unichar) -> Character {
        Character(UnicodeScalar(c) ?? " ")
    }
}
