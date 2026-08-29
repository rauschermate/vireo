import Foundation
import MarkdownEngine

/// Pure parsing of a single source line as a markdown list item — drives the
/// Enter-continues-the-list / Enter-on-empty-exits / Tab-indents behavior.
/// Kept UI-free so it's unit-testable.
public struct ListLine: Equatable {
    public var indent: String
    /// "-", "*", "+" for bullets; "3." / "3)" for ordered items.
    public var marker: String
    public var isOrdered: Bool
    public var isTask: Bool
    public var taskChecked: Bool
    /// True when the item has no content after the marker (and task box).
    public var contentIsEmpty: Bool
    /// UTF-16 offset from the line start to the first content character
    /// (everything before it is indent + marker + box + spacing).
    public var markerEndOffset: Int

    /// Parse `line` (without its trailing newline). The syntax scan lives in
    /// `MarkdownEngine.ListMarkerScanner`, which the parser shares — the editor
    /// and the engine must agree on what a marker is.
    public static func parse(_ line: String) -> ListLine? {
        let ns = line as NSString
        guard let scan = ListMarkerScanner.scan(ns, in: NSRange(location: 0, length: ns.length))
        else { return nil }

        let marker = ns.substring(with: NSRange(location: scan.markerStart,
                                                length: scan.markerEnd - scan.markerStart))
        let rest = ns.substring(from: scan.contentStart)
        return ListLine(indent: ns.substring(to: scan.markerStart),
                        marker: marker,
                        isOrdered: scan.isOrdered,
                        isTask: scan.taskChecked != nil,
                        taskChecked: scan.taskChecked ?? false,
                        contentIsEmpty: rest.trimmingCharacters(in: .whitespaces).isEmpty,
                        markerEndOffset: scan.contentStart)
    }

    /// One source rewrite produced by `orderedSiblingRenumberEdits`:
    /// replace the digits in `range` with `String(number)`.
    public struct RenumberEdit: Equatable {
        public var range: NSRange
        public var number: Int
        public var replacement: String { String(number) }
    }

    /// Source edits that make the ordered siblings *after* the item on
    /// `location`'s line count on from that item's own number. Deeper-indented
    /// lines are one sibling's subtree and pass through untouched. The walk
    /// ends at a shallower line, a different marker style, two consecutive
    /// blank lines, or content at the margin.
    public static func orderedSiblingRenumberEdits(in source: NSString,
                                                   afterLineAt location: Int) -> [RenumberEdit] {
        guard source.length > 0 else { return [] }
        let baseLine = source.lineRange(
            for: NSRange(location: min(location, source.length), length: 0))
        var baseText = source.substring(with: baseLine)
        if baseText.hasSuffix("\n") { baseText.removeLast() }
        guard let base = parse(baseText), base.isOrdered,
              var counter = Int(base.marker.dropLast()) else { return [] }
        let delimiter = base.marker.hasSuffix(")") ? ")" : "."
        let indentLength = (base.indent as NSString).length

        var edits: [RenumberEdit] = []
        var position = baseLine.upperBound
        var blankRun = 0
        while position < source.length {
            let line = source.lineRange(for: NSRange(location: position, length: 0))
            guard line.upperBound > position else { break }
            position = line.upperBound
            var text = source.substring(with: line)
            if text.hasSuffix("\n") { text.removeLast() }

            if text.trimmingCharacters(in: .whitespaces).isEmpty {
                blankRun += 1
                if blankRun >= 2 { break }
                continue
            }
            guard let item = parse(text) else {
                // Indented text continues the previous item; anything at the
                // margin ends the list.
                let leading = text.prefix { $0 == " " || $0 == "\t" }
                if (String(leading) as NSString).length >= indentLength + 2 {
                    blankRun = 0
                    continue
                }
                break
            }
            let itemIndent = (item.indent as NSString).length
            if itemIndent > indentLength { blankRun = 0; continue }
            if itemIndent < indentLength { break }
            guard item.isOrdered, item.marker.hasSuffix(delimiter) else { break }
            blankRun = 0
            counter += 1
            let digits = String(item.marker.dropLast())
            if digits != String(counter) {
                edits.append(RenumberEdit(
                    range: NSRange(location: line.location + itemIndent,
                                   length: (digits as NSString).length),
                    number: counter))
            }
        }
        return edits
    }

    /// Prefix that continues this list on the next line: same indent and
    /// bullet (unchecked box for tasks), incremented number for ordered lists.
    public var continuationPrefix: String {
        // An ordered item can carry a task box too, so the box is independent
        // of the marker style.
        let box = isTask ? "[ ] " : ""
        if isOrdered {
            let delim = marker.hasSuffix(")") ? ")" : "."
            let n = Int(marker.dropLast()) ?? 0
            return "\(indent)\(n + 1)\(delim) \(box)"
        }
        return "\(indent)\(marker) \(box)"
    }
}
