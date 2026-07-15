import XCTest
import MarkdownEngine
@testable import MarkdownEditor

final class EditableMarkdownTableTests: XCTestCase {
    private let source = "| **Name** | Link |\n| :--- | ---: |\n| Ada | [Site](https://example.com) |"

    private func table() -> EditableMarkdownTable {
        let parsed = MarkdownParser().parse(source)
        return EditableMarkdownTable(table: parsed.tables[0], source: source)!
    }

    func testPreservesRawFormattingButExposesVisibleCellText() {
        let value = table()
        XCTAssertEqual(value.rawText(row: 0, column: 0), "**Name**")
        XCTAssertEqual(value.visibleText(row: 0, column: 0), "Name")
        XCTAssertEqual(value.visibleText(row: 1, column: 1), "Site")
    }

    func testCanonicalSerializationPreservesUntouchedMarkdownAndAlignment() {
        XCTAssertEqual(table().markdownSource(),
                       "| **Name** | Link |\n| :--- | ---: |\n| Ada | [Site](https://example.com) |")
    }

    func testInsertAndRemoveRows() {
        var value = table()
        value.insertRow(at: 2)
        value.replaceVisibleText("Grace", row: 2, column: 0)
        XCTAssertEqual(value.rowCount, 3)
        XCTAssertTrue(value.markdownSource().contains("| Grace |  |"))
        value.removeRow(at: 2)
        XCTAssertEqual(value.rowCount, 2)
        value.removeRow(at: 0)
        XCTAssertEqual(value.rowCount, 2, "the header row is structural and cannot be removed")
    }

    func testInsertRemoveAndAlignColumns() {
        var value = table()
        value.insertColumn(at: 1)
        value.replaceVisibleText("Role", row: 0, column: 1)
        value.setAlignment(.center, column: 1)
        XCTAssertEqual(value.columnCount, 3)
        XCTAssertTrue(value.markdownSource().contains("| :--- | :---: | ---: |"))
        value.removeColumn(at: 1)
        XCTAssertEqual(value.columnCount, 2)
    }

    func testVisibleInputIsSafelyEscapedForGFMCells() {
        var value = table()
        value.replaceVisibleText("A | B\\C\nD", row: 1, column: 0)
        XCTAssertEqual(value.rawText(row: 1, column: 0), "A \\| B\\\\C D")
        XCTAssertEqual(EditableMarkdownTable.visibleText(fromMarkdown: "A \\| B"), "A | B")
    }

    func testVisibleEditsPreserveInlineFormattingAndLinkDestinations() {
        XCTAssertEqual(EditableMarkdownTable.updating(markdown: "**Name**",
                                                       toVisibleText: "Names"),
                       "**Names**")
        XCTAssertEqual(EditableMarkdownTable.updating(
            markdown: "[Site](https://example.com)", toVisibleText: "Home"
        ), "[Home](https://example.com)")
        XCTAssertEqual(EditableMarkdownTable.updating(markdown: "**Name**",
                                                       toVisibleText: ""), "")
    }

    func testInlineFormatToggleUsesVisibleCellRanges() {
        let full = NSRange(location: 0, length: 4)
        let bold = EditableMarkdownTable.toggling(
            .bold, in: "Name", visibleRange: full
        )
        XCTAssertEqual(bold, "**Name**")
        XCTAssertTrue(EditableMarkdownTable.activeFormats(
            in: bold, visibleRange: full
        ).bold)
        XCTAssertEqual(EditableMarkdownTable.toggling(
            .bold, in: bold, visibleRange: full
        ), "Name")

        let boldItalic = EditableMarkdownTable.toggling(
            .italic, in: bold, visibleRange: full
        )
        XCTAssertEqual(boldItalic, "***Name***")
        let active = EditableMarkdownTable.activeFormats(
            in: boldItalic, visibleRange: full
        )
        XCTAssertTrue(active.bold)
        XCTAssertTrue(active.italic)
    }

    func testInlineFormatMappingSkipsEscapedPipeSourceCharacter() {
        let markdown = "A \\| B"
        let formatted = EditableMarkdownTable.toggling(
            .italic, in: markdown, visibleRange: NSRange(location: 4, length: 1)
        )

        XCTAssertEqual(formatted, "A \\| *B*")
        XCTAssertEqual(EditableMarkdownTable.visibleText(fromMarkdown: formatted),
                       "A | B")
    }
}
