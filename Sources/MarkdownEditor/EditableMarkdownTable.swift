import Foundation
import MarkdownEngine

/// Source-preserving editing model for one GFM table. Cell text remains raw
/// Markdown internally so structural operations do not strip formatting from
/// untouched cells; the UI asks `visibleText` for syntax-free field content.
public struct EditableMarkdownTable: Equatable {
    public let sourceRange: NSRange
    public let anchor: Int
    public private(set) var rows: [[String]]
    public private(set) var alignments: [TableAlignment]

    public var columnCount: Int { alignments.count }
    public var rowCount: Int { rows.count }

    public init?(table: TableInfo, source: String) {
        guard table.columnCount > 0, !table.rows.isEmpty else { return nil }
        let ns = source as NSString
        sourceRange = table.range
        anchor = table.anchor
        alignments = (0..<table.columnCount).map { column in
            table.rows.first?.cells.first(where: { $0.column == column })?.alignment ?? .none
        }
        rows = table.rows.map { row in
            (0..<table.columnCount).map { column in
                guard let cell = row.cells.first(where: { $0.column == column }) else { return "" }
                let range = NSIntersectionRange(cell.range,
                                                NSRange(location: 0, length: ns.length))
                return range.length > 0 ? ns.substring(with: range) : ""
            }
        }
    }

    public func rawText(row: Int, column: Int) -> String? {
        guard rows.indices.contains(row), rows[row].indices.contains(column) else { return nil }
        return rows[row][column]
    }

    public func visibleText(row: Int, column: Int) -> String? {
        rawText(row: row, column: column).map(Self.visibleText(fromMarkdown:))
    }

    public mutating func replaceVisibleText(_ text: String, row: Int, column: Int) {
        guard rows.indices.contains(row), rows[row].indices.contains(column) else { return }
        rows[row][column] = Self.updating(markdown: rows[row][column], toVisibleText: text)
    }

    public mutating func insertRow(at index: Int) {
        let insertion = min(max(1, index), rows.count)
        rows.insert(Array(repeating: "", count: columnCount), at: insertion)
    }

    public mutating func removeRow(at index: Int) {
        guard index > 0, rows.indices.contains(index) else { return }
        rows.remove(at: index)
    }

    public mutating func insertColumn(at index: Int) {
        let insertion = min(max(0, index), columnCount)
        alignments.insert(.none, at: insertion)
        for row in rows.indices { rows[row].insert("", at: insertion) }
    }

    public mutating func removeColumn(at index: Int) {
        guard columnCount > 1, alignments.indices.contains(index) else { return }
        alignments.remove(at: index)
        for row in rows.indices where rows[row].indices.contains(index) {
            rows[row].remove(at: index)
        }
    }

    public mutating func setAlignment(_ alignment: TableAlignment, column: Int) {
        guard alignments.indices.contains(column) else { return }
        alignments[column] = alignment
    }

    public func markdownSource() -> String {
        guard let header = rows.first else { return "" }
        let headerLine = Self.line(cells: header, columns: columnCount)
        let separator = "| " + alignments.map(Self.separator).joined(separator: " | ") + " |"
        let body = rows.dropFirst().map { Self.line(cells: $0, columns: columnCount) }
        return ([headerLine, separator] + body).joined(separator: "\n")
    }

    public static func visibleText(fromMarkdown markdown: String) -> String {
        let ns = markdown as NSString
        let parsed = MarkdownParser().parse(markdown)
        let result = NSMutableString(string: markdown)
        for marker in parsed.markerRanges.sorted(by: { $0.location > $1.location }) {
            let range = NSIntersectionRange(marker, NSRange(location: 0, length: ns.length))
            if range.length > 0 { result.deleteCharacters(in: range) }
        }
        return unescapeMarkdownPunctuation(result as String)
    }

    public static func markdownLiteral(forVisibleText text: String) -> String {
        escapeVisibleText(text.trimmingCharacters(in: .whitespaces))
    }

    private static func escapeVisibleText(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "|", with: "\\|")
    }

    /// Apply the visible-text diff inside the existing inline Markdown rather
    /// than replacing the whole cell. Editing `**Name**` to “Names” therefore
    /// yields `**Names**`; changing a link label preserves its destination.
    public static func updating(markdown original: String, toVisibleText newText: String) -> String {
        let oldText = visibleText(fromMarkdown: original)
        guard oldText != newText else { return original }
        guard !newText.isEmpty else { return "" }

        let oldCharacters = Array(oldText)
        let newCharacters = Array(newText)
        var prefix = 0
        while prefix < min(oldCharacters.count, newCharacters.count),
              oldCharacters[prefix] == newCharacters[prefix] {
            prefix += 1
        }
        var suffix = 0
        while suffix < oldCharacters.count - prefix,
              suffix < newCharacters.count - prefix,
              oldCharacters[oldCharacters.count - 1 - suffix]
                == newCharacters[newCharacters.count - 1 - suffix] {
            suffix += 1
        }

        let oldPrefix = String(oldCharacters.prefix(prefix))
        let oldChanged = String(oldCharacters[prefix..<(oldCharacters.count - suffix)])
        let replacementVisible = String(newCharacters[prefix..<(newCharacters.count - suffix)])
        let visibleStart = (oldPrefix as NSString).length
        let visibleEnd = visibleStart + (oldChanged as NSString).length

        let raw = original as NSString
        let markers = normalizedMarkers(MarkdownParser().parse(original).markerRanges,
                                        sourceLength: raw.length)
        let insertion = visibleStart == visibleEnd
        let startDownstream = !insertion || visibleStart == 0
        let sourceStart = sourceOffset(forVisibleOffset: visibleStart, markers: markers,
                                       sourceLength: raw.length, downstream: startDownstream)
        let sourceEnd = insertion ? sourceStart : sourceOffset(
            forVisibleOffset: visibleEnd, markers: markers,
            sourceLength: raw.length, downstream: false
        )
        let result = NSMutableString(string: original)
        result.replaceCharacters(
            in: NSRange(location: sourceStart, length: max(0, sourceEnd - sourceStart)),
            with: escapeVisibleText(replacementVisible)
        )
        return result as String
    }

    private static func normalizedMarkers(_ ranges: [NSRange], sourceLength: Int) -> [NSRange] {
        let sorted = ranges.compactMap { range -> NSRange? in
            let lower = min(max(0, range.location), sourceLength)
            let upper = min(max(lower, range.upperBound), sourceLength)
            return upper > lower ? NSRange(location: lower, length: upper - lower) : nil
        }.sorted { $0.location < $1.location }
        var result: [NSRange] = []
        for range in sorted {
            if let last = result.last, range.location <= last.upperBound {
                result[result.count - 1] = NSRange(
                    location: last.location,
                    length: max(last.upperBound, range.upperBound) - last.location
                )
            } else {
                result.append(range)
            }
        }
        return result
    }

    private static func sourceOffset(forVisibleOffset offset: Int, markers: [NSRange],
                                     sourceLength: Int, downstream: Bool) -> Int {
        let visibleLength = sourceLength - markers.reduce(0) { $0 + $1.length }
        let target = min(max(0, offset), visibleLength)
        var hidden = 0
        for marker in markers {
            let visualBoundary = marker.location - hidden
            if target < visualBoundary { return target + hidden }
            if target == visualBoundary {
                return downstream ? marker.upperBound : marker.location
            }
            hidden += marker.length
        }
        return min(sourceLength, target + hidden)
    }

    private static func line(cells: [String], columns: Int) -> String {
        let values = (0..<columns).map { $0 < cells.count ? cells[$0] : "" }
        return "| " + values.joined(separator: " | ") + " |"
    }

    private static func separator(_ alignment: TableAlignment) -> String {
        switch alignment {
        case .left: return ":---"
        case .center: return ":---:"
        case .right: return "---:"
        case .none: return "---"
        }
    }

    private static func unescapeMarkdownPunctuation(_ text: String) -> String {
        let escapable = Set("!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~")
        let characters = Array(text)
        var output = ""
        var index = 0
        while index < characters.count {
            if characters[index] == "\\", index + 1 < characters.count,
               escapable.contains(characters[index + 1]) {
                output.append(characters[index + 1])
                index += 2
            } else {
                output.append(characters[index])
                index += 1
            }
        }
        return output
    }
}
