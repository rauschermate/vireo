import Foundation
import MarkdownEngine

enum TableInlineFormat {
    case bold
    case italic
    case strikethrough
    case code

    var delimiter: String {
        switch self {
        case .bold: return "**"
        case .italic: return "*"
        case .strikethrough: return "~~"
        case .code: return "`"
        }
    }

    func isActive(in run: InlineRun) -> Bool {
        switch self {
        case .bold: return run.bold
        case .italic: return run.italic
        case .strikethrough: return run.strikethrough
        case .code: return run.code
        }
    }
}

struct TableLinkEditSession: Equatable {
    var replacementRange: NSRange
    var labelSource: String?
    var initialLabel: String
    var destination: String
    var originalSelection: NSRange
    var labelVisibleRange: NSRange
    var canRemove: Bool
}

struct TableLinkEditResult: Equatable {
    var markdown: String
    var visibleSelection: NSRange
}

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

    mutating func replaceMarkdown(_ markdown: String, row: Int, column: Int) {
        guard rows.indices.contains(row), rows[row].indices.contains(column) else { return }
        rows[row][column] = markdown
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
        return presentationIndex(for: markdown).visibleString(in: ns)
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

        let index = presentationIndex(for: original)
        let insertion = visibleStart == visibleEnd
        let startDownstream = !insertion || visibleStart == 0
        let sourceStart = index.sourceOffset(
            forVisibleOffset: visibleStart,
            affinity: startDownstream ? .downstream : .upstream
        )
        let sourceEnd = insertion ? sourceStart : index.sourceOffset(
            forVisibleOffset: visibleEnd, affinity: .upstream
        )
        let result = NSMutableString(string: original)
        result.replaceCharacters(
            in: NSRange(location: sourceStart, length: max(0, sourceEnd - sourceStart)),
            with: escapeVisibleText(replacementVisible)
        )
        return result as String
    }

    static func visibleRange(forSourceRange range: NSRange,
                             in markdown: String) -> NSRange {
        presentationIndex(for: markdown).visibleRange(forSourceRange: range)
    }

    static func activeFormats(in markdown: String,
                              visibleRange: NSRange) -> ActiveFormats {
        let index = presentationIndex(for: markdown)
        let selection = clampedVisibleRange(visibleRange, length: index.visibleLength)
        let sourceRange = index.sourceRange(forVisibleRange: selection)
        return ActiveFormats.at(sourceRange, in: MarkdownParser().parse(markdown))
    }

    static func toggling(_ format: TableInlineFormat, in markdown: String,
                         visibleRange: NSRange) -> String {
        let index = presentationIndex(for: markdown)
        let selection = clampedVisibleRange(visibleRange, length: index.visibleLength)
        guard selection.length > 0 else { return markdown }
        let sourceRange = index.sourceRange(forVisibleRange: selection)
        guard sourceRange.length > 0 else { return markdown }

        let parsed = MarkdownParser().parse(markdown)
        let isActive = parsed.inlineRuns.contains { run in
            format.isActive(in: run)
                && run.range.location <= sourceRange.location
                && run.range.upperBound >= sourceRange.upperBound
        }
        let delimiter = format.delimiter
        let delimiterLength = (delimiter as NSString).length
        let source = markdown as NSString
        let directlyWrapped = sourceRange.location >= delimiterLength
            && sourceRange.upperBound + delimiterLength <= source.length
            && source.substring(with: NSRange(
                location: sourceRange.location - delimiterLength,
                length: delimiterLength
            )) == delimiter
            && source.substring(with: NSRange(
                location: sourceRange.upperBound,
                length: delimiterLength
            )) == delimiter

        let result = NSMutableString(string: markdown)
        if isActive, directlyWrapped {
            result.deleteCharacters(in: NSRange(location: sourceRange.upperBound,
                                                length: delimiterLength))
            result.deleteCharacters(in: NSRange(
                location: sourceRange.location - delimiterLength,
                length: delimiterLength
            ))
        } else {
            // Wrapping turns a format on. Splitting an active run at both
            // selection boundaries turns only that selected portion off.
            result.insert(delimiter, at: sourceRange.upperBound)
            result.insert(delimiter, at: sourceRange.location)
        }
        return result as String
    }

    static func linkEditSession(in markdown: String,
                                visibleRange rawSelection: NSRange) -> TableLinkEditSession {
        let index = presentationIndex(for: markdown)
        let selection = clampedVisibleRange(rawSelection, length: index.visibleLength)
        let parsed = MarkdownParser().parse(markdown)
        let existing = parsed.links.first { link in
            let visibleLabel = index.visibleRange(forSourceRange: link.labelRange)
            if selection.length > 0 {
                return NSIntersectionRange(visibleLabel, selection).length > 0
                    || NSIntersectionRange(
                        index.visibleRange(forSourceRange: link.range), selection
                    ).length == selection.length
            }
            return selection.location >= visibleLabel.location
                && selection.location <= visibleLabel.upperBound
        }
        let source = markdown as NSString

        if let existing {
            return TableLinkEditSession(
                replacementRange: existing.range,
                labelSource: source.substring(with: existing.labelRange),
                initialLabel: existing.label,
                destination: existing.destination,
                originalSelection: selection,
                labelVisibleRange: index.visibleRange(forSourceRange: existing.labelRange),
                canRemove: true
            )
        }

        let sourceSelection = index.sourceRange(forVisibleRange: selection)
        let selectedSource = sourceSelection.length > 0
            ? source.substring(with: sourceSelection) : nil
        let visible = visibleText(fromMarkdown: markdown) as NSString
        let label = selection.length > 0
            ? visible.substring(with: selection) : "link"
        return TableLinkEditSession(
            replacementRange: sourceSelection,
            labelSource: selectedSource.flatMap { linkLabelSourceIsSafe($0) ? $0 : nil },
            initialLabel: label,
            destination: "",
            originalSelection: selection,
            labelVisibleRange: selection,
            canRemove: false
        )
    }

    static func applyingLink(_ session: TableLinkEditSession,
                             to markdown: String, label: String,
                             destination rawDestination: String) -> TableLinkEditResult? {
        let source = markdown as NSString
        guard session.replacementRange.upperBound <= source.length,
              let destination = try? LinkDestination.normalize(rawDestination) else { return nil }
        let labelSource: String
        if label == session.initialLabel, let preserved = session.labelSource {
            labelSource = preserved
        } else {
            labelSource = escapedLinkLabel(label)
        }
        let escapedDestination = destination.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "(", with: "\\(")
            .replacingOccurrences(of: ")", with: "\\)")
            .replacingOccurrences(of: "|", with: "\\|")
        let replacement = "[\(labelSource)](\(escapedDestination))"
        let result = NSMutableString(string: markdown)
        result.replaceCharacters(in: session.replacementRange, with: replacement)
        let updated = result as String
        let labelRange = NSRange(location: session.replacementRange.location + 1,
                                 length: (labelSource as NSString).length)
        return TableLinkEditResult(
            markdown: updated,
            visibleSelection: presentationIndex(for: updated)
                .visibleRange(forSourceRange: labelRange)
        )
    }

    static func removingLink(_ session: TableLinkEditSession,
                             from markdown: String) -> TableLinkEditResult? {
        guard session.canRemove, let labelSource = session.labelSource,
              session.replacementRange.upperBound <= (markdown as NSString).length else {
            return nil
        }
        let result = NSMutableString(string: markdown)
        result.replaceCharacters(in: session.replacementRange, with: labelSource)
        let updated = result as String
        let labelRange = NSRange(location: session.replacementRange.location,
                                 length: (labelSource as NSString).length)
        return TableLinkEditResult(
            markdown: updated,
            visibleSelection: presentationIndex(for: updated)
                .visibleRange(forSourceRange: labelRange)
        )
    }

    private static func escapedLinkLabel(_ label: String) -> String {
        label.replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "]", with: "\\]")
            .replacingOccurrences(of: "|", with: "\\|")
    }

    private static func linkLabelSourceIsSafe(_ source: String) -> Bool {
        var precedingBackslashes = 0
        for character in source {
            if character == "\\" {
                precedingBackslashes += 1
                continue
            }
            if character == "]", precedingBackslashes.isMultiple(of: 2) { return false }
            precedingBackslashes = 0
        }
        return true
    }

    private static let escapablePunctuation = Set(
        "!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~".utf16
    )

    private static func presentationIndex(for markdown: String) -> MarkerIndex {
        let ns = markdown as NSString
        var hidden = MarkdownParser().parse(markdown).markerRanges
        var index = 0
        while index + 1 < ns.length {
            if ns.character(at: index) == 0x5C,
               escapablePunctuation.contains(ns.character(at: index + 1)) {
                hidden.append(NSRange(location: index, length: 1))
                index += 2
            } else {
                index += 1
            }
        }
        return MarkerIndex(ranges: hidden, sourceLength: ns.length)
    }

    private static func clampedVisibleRange(_ range: NSRange,
                                            length: Int) -> NSRange {
        guard range.location != NSNotFound else {
            return NSRange(location: length, length: 0)
        }
        let lower = min(max(0, range.location), length)
        let upper = min(max(lower, range.upperBound), length)
        return NSRange(location: lower, length: upper - lower)
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

}
