import XCTest
import AppKit
import MarkdownEngine
import MarkdownRender
@testable import MarkdownEditor

@MainActor
final class RichTableEditingTests: XCTestCase {
    private let source = "| Name | Role |\n| --- | --- |\n| Ada | Engineer |\n"

    @MainActor
    private final class Harness {
        let controller: EditorController
        let textView: MarkdownTextView
        let window: NSWindow

        init(source: String) {
            controller = EditorController()
            controller.automaticallyFocusTableEditors = false
            let (scroll, textView) = MarkdownSourceView.makeTextStack(
                source: source, controller: controller
            )
            self.textView = textView
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = scroll
            window.makeKeyAndOrderFront(nil)
            scroll.frame = window.contentView!.bounds
            textView.frame.size.width = scroll.contentSize.width
            controller.restyle()
            textView.layoutManager?.ensureLayout(for: textView.textContainer!)
            textView.sizeToFit()
            drawTableGeometry()
        }

        var layout: MarkdownLayoutManager { textView.layoutManager as! MarkdownLayoutManager }

        func settle() {
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
            textView.layoutManager?.ensureLayout(for: textView.textContainer!)
            drawTableGeometry()
        }

        private func drawTableGeometry() {
            let canvas = NSImage(size: NSSize(width: 760, height: max(500, textView.frame.height)))
            canvas.lockFocus()
            let glyphs = layout.glyphRange(for: textView.textContainer!)
            layout.drawGlyphs(forGlyphRange: glyphs, at: textView.textContainerOrigin)
            canvas.unlockFocus()
            controller.tableGeometryDidChange()
        }
    }

    func testRenderedTablePublishesCellHitGeometry() {
        let harness = Harness(source: source)
        XCTAssertEqual(harness.layout.tableCellGeometries.count, 4)
        let first = TableCellID(tableAnchor: 0, row: 0, column: 0)
        let body = TableCellID(tableAnchor: 0, row: 1, column: 1)
        XCTAssertTrue(harness.layout.geometry(for: first)!.isHeader)
        XCTAssertFalse(harness.layout.geometry(for: body)!.isHeader)
        XCTAssertGreaterThanOrEqual(harness.layout.geometry(for: first)!.rect.width, 72)
    }

    func testClickingRenderedCellMountsItsEditor() throws {
        let harness = Harness(source: source)
        let id = TableCellID(tableAnchor: 0, row: 1, column: 0)
        let geometry = try XCTUnwrap(harness.layout.geometry(for: id))
        let pointInView = NSPoint(x: geometry.rect.midX, y: geometry.rect.midY)
        let pointInWindow = harness.textView.convert(pointInView, to: nil)
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: pointInWindow,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: harness.window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        ))

        harness.textView.mouseDown(with: event)

        XCTAssertEqual(harness.controller.activeTableCellID, id)
        XCTAssertEqual(
            harness.textView.subviews.compactMap { $0 as? TableCellEditorOverlay }.count,
            1
        )
    }

    func testCellEditorCommitsVisibleTextAndTabMovesToNextCell() {
        let harness = Harness(source: source)
        let id = TableCellID(tableAnchor: 0, row: 1, column: 0)
        harness.controller.beginTableCellEditing(harness.layout.geometry(for: id)!)
        let overlay = harness.textView.subviews.compactMap { $0 as? TableCellEditorOverlay }.first!
        let field = overlay.subviews.compactMap { $0 as? NSTextField }.first!
        field.stringValue = "Grace"
        XCTAssertTrue(overlay.control(field, textView: NSTextView(),
                                      doCommandBy: #selector(NSResponder.insertTab(_:))))
        harness.settle()

        XCTAssertTrue(harness.textView.string.contains("| Grace | Engineer |"))
        XCTAssertEqual(harness.controller.activeTableCellID,
                       TableCellID(tableAnchor: 0, row: 1, column: 1))
        XCTAssertFalse(harness.textView.string.contains("| --- | Engineer"),
                       "editing must never target the hidden separator row")
    }

    func testCellEditParticipatesInUndoAndRedo() {
        let harness = Harness(source: source)
        let original = harness.textView.string
        let id = TableCellID(tableAnchor: 0, row: 1, column: 0)
        harness.controller.beginTableCellEditing(harness.layout.geometry(for: id)!)
        let overlay = harness.textView.subviews.compactMap { $0 as? TableCellEditorOverlay }.first!
        let field = overlay.subviews.compactMap { $0 as? NSTextField }.first!
        field.stringValue = "Grace"
        XCTAssertTrue(overlay.control(field, textView: NSTextView(),
                                      doCommandBy: #selector(NSResponder.insertTab(_:))))
        harness.settle()

        XCTAssertTrue(harness.textView.undoManager?.canUndo == true)
        harness.textView.undoManager?.undo()
        harness.settle()
        XCTAssertEqual(harness.textView.string, original)

        XCTAssertTrue(harness.textView.undoManager?.canRedo == true)
        harness.textView.undoManager?.redo()
        harness.settle()
        XCTAssertTrue(harness.textView.string.contains("| Grace | Engineer |"))
    }

    func testTabFromLastCellAppendsBodyRow() {
        let harness = Harness(source: source)
        let id = TableCellID(tableAnchor: 0, row: 1, column: 1)
        harness.controller.beginTableCellEditing(harness.layout.geometry(for: id)!)
        let overlay = harness.textView.subviews.compactMap { $0 as? TableCellEditorOverlay }.first!
        let field = overlay.subviews.compactMap { $0 as? NSTextField }.first!
        XCTAssertTrue(overlay.control(field, textView: NSTextView(),
                                      doCommandBy: #selector(NSResponder.insertTab(_:))))
        harness.settle()

        let parsed = MarkdownParser().parse(harness.textView.string)
        XCTAssertEqual(parsed.tables.first?.rows.count, 3)
        XCTAssertEqual(harness.controller.activeTableCellID?.row, 2)
        XCTAssertEqual(harness.controller.activeTableCellID?.column, 0)
    }

    func testCellActionCanInsertColumnWithoutExposingSource() {
        let harness = Harness(source: source)
        let id = TableCellID(tableAnchor: 0, row: 0, column: 0)
        harness.controller.beginTableCellEditing(harness.layout.geometry(for: id)!)
        guard let overlay = harness.textView.subviews.compactMap({ $0 as? TableCellEditorOverlay }).first else {
            let table = harness.controller.parsed.tables.first
            let model = table.flatMap { EditableMarkdownTable(table: $0, source: harness.textView.string) }
            XCTFail("overlay missing; active=\(String(describing: harness.controller.activeTableCellID)); anchor=\(String(describing: table?.anchor)); rows=\(String(describing: model?.rowCount)); visible=\(String(describing: model?.visibleText(row: 0, column: 0))); subviews=\(harness.textView.subviews)")
            return
        }
        overlay.onAction?(overlay.currentText, .insertColumnRight)
        harness.settle()

        let parsed = MarkdownParser().parse(harness.textView.string)
        XCTAssertEqual(parsed.tables.first?.columnCount, 3)
        XCTAssertEqual(harness.controller.activeTableCellID?.column, 1)
    }

    func testSelectionInsideTableNeverSwitchesToRawSourceStyling() {
        let harness = Harness(source: source)
        harness.textView.setSelectedRange(NSRange(location: 3, length: 0))
        harness.controller.selectionChanged()
        let color = harness.textView.textStorage?.attribute(.foregroundColor, at: 0,
                                                            effectiveRange: nil) as? NSColor
        XCTAssertEqual(color, NSColor.clear)
        XCTAssertNotNil(harness.textView.textStorage?.attribute(.vireoTable, at: 0,
                                                                effectiveRange: nil))
    }

    func testSourceCaretOnSeparatorMapsToFirstBodyRow() {
        let harness = Harness(source: source)
        let separator = harness.controller.parsed.tables[0].separatorRange!
        XCTAssertTrue(harness.controller.beginTableCellEditing(
            atSourceLocation: separator.location + 2
        ))
        XCTAssertEqual(harness.controller.activeTableCellID?.row, 1)
        XCTAssertEqual(harness.controller.activeTableCellID?.column, 0)
    }
}
