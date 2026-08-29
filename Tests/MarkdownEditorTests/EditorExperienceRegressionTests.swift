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
        // The caret sits in the edited block, so its raw syntax is revealed.
        XCTAssertEqual(harness.controller.markerIndex.visibleString(
            in: harness.textView.string as NSString), "**Hello** world")

        let undo = try XCTUnwrap(harness.textView.undoManager)
        undo.undo()
        XCTAssertEqual(harness.textView.string, "Hello world")
        XCTAssertEqual(harness.controller.markerIndex.visibleString(
            in: harness.textView.string as NSString), "Hello world")

        undo.redo()
        XCTAssertEqual(harness.textView.string, "**Hello** world")
        XCTAssertEqual(harness.controller.markerIndex.visibleString(
            in: harness.textView.string as NSString), "**Hello** world")
    }

    func testMarkedTextDefersRestyleUntilCompositionCommits() {
        // The composition happens in the second block; the first block must
        // keep its hidden presentation untouched throughout.
        let harness = Harness(source: "**Hello** world\n\n**Tail** note")
        let caret = (harness.textView.string as NSString).range(of: "Tail").location + 3
        harness.textView.setSelectedRange(NSRange(location: caret, length: 0))

        harness.textView.setMarkedText(
            "日本", selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )

        XCTAssertTrue(harness.textView.hasMarkedText())
        XCTAssertEqual(harness.textView.string, "**Hello** world\n\n**Tai日本l** note")
        XCTAssertNotNil(harness.textView.textStorage?.attribute(
            .vireoMarker, at: 0, effectiveRange: nil),
            "composition must not tear down presentation attributes")

        harness.textView.unmarkText()
        harness.controller.scheduleRestyle()

        XCTAssertFalse(harness.textView.hasMarkedText())
        // The caret's block shows its raw syntax; the first block stays clean.
        XCTAssertEqual(harness.controller.markerIndex.visibleString(
            in: harness.textView.string as NSString),
            "Hello world\n\n**Tai日本l** note")
        XCTAssertNotNil(harness.textView.textStorage?.attribute(
            .vireoMarker, at: 0, effectiveRange: nil))
    }

    func testEnterExitFromANestedTaskListParksTheCaretAtTheMargin() throws {
        let harness = Harness(source: "- [ ] Ship\n    - [ ] asf\n\ntail\n")
        let end = (harness.textView.string as NSString).range(of: "asf").upperBound
        harness.textView.setSelectedRange(NSRange(location: end, length: 0))

        // Enter continues, Enter outdents, Enter exits the list.
        harness.textView.insertNewline(nil)
        harness.textView.insertNewline(nil)
        harness.textView.insertNewline(nil)

        let sel = harness.textView.selectedRange()
        let line = (harness.textView.string as NSString).lineRange(for: sel)
        XCTAssertEqual((harness.textView.string as NSString)
            .substring(with: line), "\n", "the third Enter leaves the list")

        // The exited line must not inherit the list indent — a caret parked
        // at the list column reads as "still inside the list".
        let stored = harness.textView.textStorage?.attribute(
            .paragraphStyle, at: line.location, effectiveRange: nil
        ) as? NSParagraphStyle
        XCTAssertEqual(stored?.firstLineHeadIndent ?? -1, 0)
        let typing = try XCTUnwrap(
            harness.textView.typingAttributes[.paragraphStyle] as? NSParagraphStyle)
        XCTAssertEqual(typing.firstLineHeadIndent, 0)
    }

    func testTextInputServiceReplacementUsesTheNormalEditPipeline() {
        let harness = Harness(source: "A **short** note\n\nplain tail")
        let short = (harness.textView.string as NSString).range(of: "short")

        harness.textView.insertText("dictated phrase", replacementRange: short)

        XCTAssertEqual(harness.textView.string,
                       "A **dictated phrase** note\n\nplain tail")
        // The replacement block holds the caret, so its syntax is revealed;
        // the pipeline still reparses and the untouched block stays clean.
        XCTAssertEqual(harness.controller.markerIndex.visibleString(
            in: harness.textView.string as NSString),
            "A **dictated phrase** note\n\nplain tail")
        XCTAssertEqual(harness.textView.accessibilityValue(),
                       "A **dictated phrase** note\n\nplain tail")
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
