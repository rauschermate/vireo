import AppKit
import XCTest
import MarkdownEngine
@testable import MarkdownEditor

@MainActor
final class EditorExperienceRegressionTests: XCTestCase {
    func testTypingRoundTripsThroughNativeUndoAndRedo() throws {
        let harness = Harness(source: "Hello")
        harness.textView.setSelectedRange(NSRange(location: 5, length: 0))

        harness.textView.insertText("!", replacementRange: harness.textView.selectedRange())
        harness.textView.breakUndoCoalescing()
        XCTAssertEqual(harness.textView.string, "Hello!")
        XCTAssertEqual(harness.controller.markerIndex.visibleString(
            in: harness.textView.string as NSString), "Hello!")

        let undo = try XCTUnwrap(harness.textView.undoManager)
        undo.undo()
        XCTAssertEqual(harness.textView.string, "Hello")
        XCTAssertEqual(harness.controller.markerIndex.visibleString(
            in: harness.textView.string as NSString), "Hello")

        undo.redo()
        XCTAssertEqual(harness.textView.string, "Hello!")
        XCTAssertEqual(harness.controller.markerIndex.visibleString(
            in: harness.textView.string as NSString), "Hello!")
    }

    func testFormattingRoundTripsThroughNativeUndoAndRedo() throws {
        let harness = Harness(source: "Hello world")
        harness.textView.setSelectedRange(NSRange(location: 0, length: 5))

        harness.controller.toggleBold()
        harness.textView.breakUndoCoalescing()
        XCTAssertEqual(harness.textView.string, "**Hello** world")
        XCTAssertEqual(harness.controller.markerIndex.visibleString(
            in: harness.textView.string as NSString), "Hello world")

        let undo = try XCTUnwrap(harness.textView.undoManager)
        undo.undo()
        XCTAssertEqual(harness.textView.string, "Hello world")
        XCTAssertEqual(harness.controller.markerIndex.visibleString(
            in: harness.textView.string as NSString), "Hello world")

        undo.redo()
        XCTAssertEqual(harness.textView.string, "**Hello** world")
        XCTAssertEqual(harness.controller.markerIndex.visibleString(
            in: harness.textView.string as NSString), "Hello world")
    }

    func testMarkedTextDefersRestyleUntilCompositionCommits() {
        let harness = Harness(source: "**Hello** world")
        harness.textView.setSelectedRange(NSRange(location: 6, length: 0))

        harness.textView.setMarkedText(
            "日本", selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )

        XCTAssertTrue(harness.textView.hasMarkedText())
        XCTAssertEqual(harness.textView.string, "**Hell日本o** world")
        XCTAssertNotNil(harness.textView.textStorage?.attribute(
            .vireoMarker, at: 0, effectiveRange: nil),
            "composition must not tear down presentation attributes")

        harness.textView.unmarkText()
        harness.controller.scheduleRestyle()

        XCTAssertFalse(harness.textView.hasMarkedText())
        XCTAssertEqual(harness.controller.markerIndex.visibleString(
            in: harness.textView.string as NSString), "Hell日本o world")
        XCTAssertNotNil(harness.textView.textStorage?.attribute(
            .vireoMarker, at: 0, effectiveRange: nil))
    }

    func testTextInputServiceReplacementUsesTheNormalEditPipeline() {
        let harness = Harness(source: "A **short** note")
        let short = (harness.textView.string as NSString).range(of: "short")

        harness.textView.insertText("dictated phrase", replacementRange: short)

        XCTAssertEqual(harness.textView.string, "A **dictated phrase** note")
        XCTAssertEqual(harness.controller.markerIndex.visibleString(
            in: harness.textView.string as NSString), "A dictated phrase note")
        XCTAssertEqual(harness.textView.accessibilityValue(),
                       "A dictated phrase note")
    }
}

@MainActor
private final class Harness {
    let controller = EditorController()
    let textView: MarkdownTextView
    let window: NSWindow
    private let coordinator: MarkdownSourceView.Coordinator

    init(source: String) {
        let stack = MarkdownSourceView.makeTextStack(source: source,
                                                     controller: controller)
        textView = stack.textView
        coordinator = MarkdownSourceView.Coordinator(controller: controller)
        textView.delegate = coordinator
        window = NSWindow(contentRect: NSRect(x: 0, y: 0,
                                              width: 700, height: 500),
                          styleMask: [.titled], backing: .buffered,
                          defer: false)
        window.contentView = stack.scroll
        window.makeFirstResponder(textView)
        controller.restyle()
    }
}
