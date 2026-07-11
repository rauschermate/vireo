import XCTest
import AppKit
@testable import MarkdownEditor

@MainActor
final class MarkerInteractionTests: XCTestCase {
    private func makeEditor(_ source: String) -> (EditorController, MarkdownTextView) {
        let controller = EditorController()
        let (_, textView) = MarkdownSourceView.makeTextStack(source: source, controller: controller)
        controller.restyle()
        return (controller, textView)
    }

    func testArrowKeysCrossInlineMarkersWithoutInvisibleStops() {
        let (controller, textView) = makeEditor("a **b** c")
        textView.setSelectedRange(NSRange(location: 1, length: 0))

        textView.moveRight(nil)
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 4, length: 0))
        textView.moveRight(nil)
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 7, length: 0))
        textView.moveLeft(nil)
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 2, length: 0))
        withExtendedLifetime(controller) {}
    }

    func testShiftSelectionCannotOwnHalfADelimiter() {
        let (controller, _) = makeEditor("a **bold** c")
        XCTAssertEqual(controller.normalizedSelection(NSRange(location: 3, length: 3)),
                       NSRange(location: 2, length: 4))
    }

    func testBackspaceOnOnlyVisibleCharacterRemovesFormattingAtomically() {
        let (controller, textView) = makeEditor("a **b** c")
        textView.setSelectedRange(NSRange(location: 7, length: 0))
        textView.deleteBackward(nil)
        XCTAssertEqual(textView.string, "a  c")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 2, length: 0))
        withExtendedLifetime(controller) {}
    }

    func testDeleteAtOpeningBoundaryRemovesWholeSingleCharacterConstruct() {
        let (controller, textView) = makeEditor("a **b** c")
        textView.setSelectedRange(NSRange(location: 2, length: 0))
        textView.deleteForward(nil)
        XCTAssertEqual(textView.string, "a  c")
        withExtendedLifetime(controller) {}
    }

    func testCopyPublishesOnlyVisibleText() {
        let (controller, textView) = makeEditor("a **bold** c")
        textView.setSelectedRange(NSRange(location: 2, length: 8))
        textView.copy(nil)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "bold")
        XCTAssertNotNil(NSPasteboard.general.data(forType: .rtf))
        withExtendedLifetime(controller) {}
    }

    func testFinderSearchModelOmitsHiddenURLAndDelimiters() {
        let (controller, textView) = makeEditor("A [link](https://secret.example) here")
        let client = VisibleTextFinderClient(textView: textView)
        XCTAssertEqual(client.string, "A link here")
        XCTAssertEqual((client.string as NSString).range(of: "secret").location, NSNotFound)

        let visibleLink = (client.string as NSString).range(of: "link")
        client.selectedRanges = [NSValue(range: visibleLink)]
        XCTAssertEqual((textView.string as NSString).substring(with: textView.selectedRange()), "link")
        withExtendedLifetime(controller) {}
    }

    func testFinderReplacementPreservesFormattingSource() {
        let (controller, textView) = makeEditor("A **bold** word")
        let client = VisibleTextFinderClient(textView: textView)
        let match = (client.string as NSString).range(of: "bold")
        client.replaceCharacters(in: match, with: "strong")
        XCTAssertEqual(textView.string, "A **strong** word")
        withExtendedLifetime(controller) {}
    }

    func testAccessibilityExposesTheSameVisibleStringAndRanges() {
        let (controller, textView) = makeEditor("A **bold** word")
        textView.setSelectedRange(NSRange(location: 4, length: 4))
        XCTAssertEqual(textView.accessibilityValue(), "A bold word")
        XCTAssertEqual(textView.accessibilityNumberOfCharacters(), 11)
        XCTAssertEqual(textView.accessibilitySelectedText(), "bold")
        XCTAssertEqual(textView.accessibilitySelectedTextRange(), NSRange(location: 2, length: 4))
        XCTAssertEqual(textView.accessibilityString(for: NSRange(location: 2, length: 4)), "bold")
        withExtendedLifetime(controller) {}
    }

    func testExistingConstructKeepsMarkersHiddenWhileTemporarilyIncomplete() {
        let (controller, textView) = makeEditor("**bold**\nnext")
        let deletion = NSRange(location: 7, length: 1)
        XCTAssertTrue(textView.shouldChangeText(in: deletion, replacementString: ""))
        textView.textStorage!.replaceCharacters(in: deletion, with: "")
        textView.didChangeText()
        controller.scheduleRestyle()

        XCTAssertEqual(controller.markerIndex.visibleString(in: textView.string as NSString),
                       "bold\nnext")
        XCTAssertNotNil(textView.textStorage!.attribute(.vireoMarker, at: 0,
                                                        effectiveRange: nil))

        let repair = NSRange(location: 7, length: 0)
        XCTAssertTrue(textView.shouldChangeText(in: repair, replacementString: "*"))
        textView.textStorage!.replaceCharacters(in: repair, with: "*")
        textView.didChangeText()
        controller.scheduleRestyle()
        XCTAssertEqual(controller.markerIndex.visibleString(in: textView.string as NSString),
                       "bold\nnext")
    }

    func testNewUnpairedDelimiterRemainsLiteral() {
        let (controller, textView) = makeEditor("word")
        let insertion = NSRange(location: 4, length: 0)
        XCTAssertTrue(textView.shouldChangeText(in: insertion, replacementString: "*"))
        textView.textStorage!.replaceCharacters(in: insertion, with: "*")
        textView.didChangeText()
        controller.scheduleRestyle()
        XCTAssertEqual(controller.markerIndex.visibleString(in: textView.string as NSString), "word*")
    }
}
