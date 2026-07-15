import XCTest
import AppKit
import MarkdownEngine
import MarkdownRender
@testable import MarkdownEditor

@MainActor
final class RichTableEditingTests: XCTestCase {
    private let source = "| Name | Role |\n| --- | --- |\n| Ada | Engineer |\n"
    private let wideSource = """
    | Project milestone with a deliberately long name | Current delivery status and next action | Responsible team and primary owner | Notes from the latest cross-functional review |
    | --- | --- | --- | --- |
    | Native table editing and interaction polish | Preparing the final release candidate | Editor infrastructure — Maya and Nico | Validate horizontal navigation on both trackpads and mice |
    """

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

        func drawTableGeometry(at origin: NSPoint? = nil) {
            let canvas = NSImage(size: NSSize(width: 760, height: max(500, textView.frame.height)))
            canvas.lockFocus()
            let glyphs = layout.glyphRange(for: textView.textContainer!)
            layout.drawGlyphs(forGlyphRange: glyphs,
                              at: origin ?? textView.textContainerOrigin)
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
        let origin = harness.textView.textContainerOrigin
        let pointInView = NSPoint(x: origin.x + geometry.rect.midX,
                                  y: origin.y + geometry.rect.midY)
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

    func testFocusedCellEditorSurvivesBackingSelectionUpdate() throws {
        let harness = Harness(source: source)
        harness.controller.automaticallyFocusTableEditors = true
        let id = TableCellID(tableAnchor: 0, row: 1, column: 1)
        let geometry = try XCTUnwrap(harness.layout.geometry(for: id))

        harness.controller.beginTableCellEditing(geometry)
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))

        XCTAssertEqual(harness.controller.activeTableCellID, id)
        XCTAssertEqual(
            harness.textView.subviews.compactMap { $0 as? TableCellEditorOverlay }.count,
            1,
            "the field must not commit itself while its backing range is selected"
        )
    }

    func testCellHitGeometryDoesNotDriftWithDrawingOrigin() throws {
        let harness = Harness(source: source)
        let id = TableCellID(tableAnchor: 0, row: 1, column: 0)
        let canonical = try XCTUnwrap(harness.layout.geometry(for: id))
        let origin = harness.textView.textContainerOrigin

        harness.layout.beginTableGeometryPass()
        harness.drawTableGeometry(at: NSPoint(x: origin.x + 137, y: origin.y + 83))

        XCTAssertEqual(try XCTUnwrap(harness.layout.geometry(for: id)).rect,
                       canonical.rect,
                       "hit geometry must stay in text-container coordinates")
    }

    func testWideTableGetsLocalHorizontalScrollerAndStableViewport() throws {
        let harness = Harness(source: wideSource)
        let scroll = try XCTUnwrap(harness.layout.tableScrollGeometry(for: 0))

        XCTAssertTrue(scroll.isOverflowing)
        XCTAssertGreaterThan(scroll.contentWidth, scroll.viewportRect.width)
        XCTAssertEqual(try XCTUnwrap(harness.layout.tableRects[0]).width,
                       scroll.viewportRect.width, accuracy: 0.5)
        XCTAssertEqual(
            harness.textView.subviews.compactMap { $0 as? TableHorizontalScroller }.count,
            1
        )
    }

    func testHorizontalScrollMovesCellsAndClampsToContent() throws {
        let harness = Harness(source: wideSource)
        let id = TableCellID(tableAnchor: 0, row: 1, column: 3)
        let before = try XCTUnwrap(harness.layout.geometry(for: id)).rect
        let scroll = try XCTUnwrap(harness.layout.tableScrollGeometry(for: 0))

        XCTAssertTrue(harness.layout.setTableHorizontalOffset(scroll.maxOffset + 500,
                                                              for: 0))

        let after = try XCTUnwrap(harness.layout.geometry(for: id)).rect
        XCTAssertLessThan(after.minX, before.minX)
        XCTAssertEqual(try XCTUnwrap(harness.layout.tableScrollGeometry(for: 0)).offset,
                       scroll.maxOffset, accuracy: 0.5)
    }

    func testKeyboardRevealScrollsLastColumnIntoViewport() throws {
        let harness = Harness(source: wideSource)
        let id = TableCellID(tableAnchor: 0, row: 1, column: 3)
        let viewport = try XCTUnwrap(
            harness.layout.tableScrollGeometry(for: 0)?.viewportRect
        )

        XCTAssertTrue(harness.layout.revealTableCell(id))

        let revealed = try XCTUnwrap(harness.layout.geometry(for: id)).rect
        XCTAssertLessThanOrEqual(revealed.maxX, viewport.maxX + 0.5)
        XCTAssertGreaterThanOrEqual(revealed.minX, viewport.minX - 0.5)
    }

    func testHiddenLinkDestinationDoesNotMakeTableOverflow() throws {
        let destination = "https://example.com/" + String(repeating: "very-long-path-", count: 40)
        let linked = "| Label | State |\n| --- | --- |\n| [Docs](\(destination)) | Ready |\n"
        let harness = Harness(source: linked)
        let scroll = try XCTUnwrap(harness.layout.tableScrollGeometry(for: 0))

        XCTAssertFalse(scroll.isOverflowing)
        XCTAssertEqual(scroll.contentWidth, scroll.viewportRect.width, accuracy: 0.5)
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
