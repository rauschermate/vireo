import Foundation

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

    /// Parse `line` (without its trailing newline).
    public static func parse(_ line: String) -> ListLine? {
        let chars = Array(line.utf16)
        var i = 0

        // indent
        while i < chars.count, chars[i] == 0x20 || chars[i] == 0x09 { i += 1 }
        let indent = String(utf16CodeUnits: Array(chars[0..<i]), count: i)
        guard i < chars.count else { return nil }

        // marker
        var marker = ""
        var isOrdered = false
        let c = chars[i]
        if c == 0x2D || c == 0x2A || c == 0x2B { // - * +
            marker = String(UnicodeScalar(c)!)
            i += 1
        } else if c >= 0x30, c <= 0x39 { // digits
            var j = i
            while j < chars.count, chars[j] >= 0x30, chars[j] <= 0x39, j - i < 9 { j += 1 }
            guard j < chars.count, chars[j] == 0x2E || chars[j] == 0x29 else { return nil } // . or )
            marker = String(utf16CodeUnits: Array(chars[i...j]), count: j - i + 1)
            isOrdered = true
            i = j + 1
        } else {
            return nil
        }

        // at least one space after the marker (or end of line = empty item)
        var spaces = 0
        while i < chars.count, chars[i] == 0x20 { i += 1; spaces += 1 }
        guard spaces > 0 || i == chars.count else { return nil }

        // optional task box `[ ]` / `[x]`
        var isTask = false
        var taskChecked = false
        if !isOrdered, i + 2 < chars.count,
           chars[i] == 0x5B, chars[i + 2] == 0x5D, // [ ]
           chars[i + 1] == 0x20 || chars[i + 1] == 0x78 || chars[i + 1] == 0x58, // ' ' x X
           i + 3 == chars.count || chars[i + 3] == 0x20 { // followed by space or EOL
            isTask = true
            taskChecked = chars[i + 1] != 0x20
            i += 3
            while i < chars.count, chars[i] == 0x20 { i += 1 }
        }

        let rest = String(utf16CodeUnits: Array(chars[i...]), count: chars.count - i)
        return ListLine(indent: indent,
                        marker: marker,
                        isOrdered: isOrdered,
                        isTask: isTask,
                        taskChecked: taskChecked,
                        contentIsEmpty: rest.trimmingCharacters(in: .whitespaces).isEmpty,
                        markerEndOffset: i)
    }

    /// Prefix that continues this list on the next line: same indent and
    /// bullet (unchecked box for tasks), incremented number for ordered lists.
    public var continuationPrefix: String {
        if isOrdered {
            let delim = marker.hasSuffix(")") ? ")" : "."
            let n = Int(marker.dropLast()) ?? 0
            return "\(indent)\(n + 1)\(delim) "
        }
        if isTask {
            return "\(indent)\(marker) [ ] "
        }
        return "\(indent)\(marker) "
    }
}
