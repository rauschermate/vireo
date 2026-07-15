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
        XCTAssertTrue(textView.undoManager?.canUndo == true)
        textView.undoManager?.undo()
        XCTAssertEqual(textView.string, "A **bold** word")
        withExtendedLifetime(controller) {}
    }

    func testCaretGeometryStaysStableAcrossInlineMarkerBoundaries() {
        let source = "A **B** C and D *E* F."
        let (controller, textView) = makeEditor(source)
        textView.frame = NSRect(x: 0, y: 0, width: 600, height: 120)
        textView.textContainer?.containerSize = NSSize(width: 560, height: 120)
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        textView.sizeToFit()
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)

        let ns = source as NSString
        let bold = ns.range(of: "**B**")
        let italic = ns.range(of: "*E*")
        let fallback = NSRect(x: 999, y: 999, width: 1, height: 80)
        func caretRect(_ location: Int) -> NSRect {
            textView.setSelectedRange(NSRange(location: location, length: 0))
            return textView.insertionRect(for: fallback)
        }

        let beforeBoldSource = caretRect(bold.location)
        let beforeBoldContent = caretRect(bold.location + 2)
        let afterBoldContent = caretRect(bold.location + 3)
        let afterBoldSource = caretRect(bold.upperBound)
        XCTAssertEqual(beforeBoldSource.minX, beforeBoldContent.minX, accuracy: 0.5)
        XCTAssertEqual(afterBoldContent.minX, afterBoldSource.minX, accuracy: 0.5)
        XCTAssertLessThan(beforeBoldContent.minX, afterBoldContent.minX)

        let beforeItalicSource = caretRect(italic.location)
        let beforeItalicContent = caretRect(italic.location + 1)
        let afterItalicContent = caretRect(italic.location + 2)
        let afterItalicSource = caretRect(italic.upperBound)
        XCTAssertEqual(beforeItalicSource.minX, beforeItalicContent.minX, accuracy: 0.5)
        XCTAssertEqual(afterItalicContent.minX, afterItalicSource.minX, accuracy: 0.5)
        XCTAssertLessThan(beforeItalicContent.minX, afterItalicContent.minX)

        for rect in [beforeBoldSource, beforeBoldContent, afterBoldContent,
                     afterBoldSource, beforeItalicSource, beforeItalicContent,
                     afterItalicContent, afterItalicSource] {
            XCTAssertEqual(rect.minY, beforeBoldSource.minY, accuracy: 0.5)
            XCTAssertNotEqual(rect.minX, fallback.minX)
        }

        let beforeF = ns.range(of: "F.").location
        textView.setSelectedRange(NSRange(location: beforeF, length: 0))
        textView.moveLeft(nil)
        XCTAssertEqual(
            controller.markerIndex.visibleOffset(
                forSourceOffset: textView.selectedRange().location),
            controller.markerIndex.visibleOffset(
                forSourceOffset: italic.location + 2)
        )
        XCTAssertEqual(textView.insertionRect(for: fallback).minX,
                       afterItalicContent.minX, accuracy: 0.5)

        // The next unmodified Left Arrow crosses the collapsed closing
        // delimiter. This is the boundary that differs from Shift/Option-Left
        // in a live NSTextView.
        textView.moveLeft(nil)
        XCTAssertEqual(
            controller.markerIndex.visibleOffset(
                forSourceOffset: textView.selectedRange().location),
            controller.markerIndex.visibleOffset(
                forSourceOffset: italic.location + 1)
        )
        XCTAssertEqual(textView.insertionRect(for: fallback).minX,
                       beforeItalicContent.minX, accuracy: 0.5)
    }

    func testAtomicFormattedAndEmojiDeletionParticipatesInUndo() {
        let source = "**X** 👩🏽‍💻"
        let (controller, textView) = makeEditor(source)

        let formatted = (source as NSString).range(of: "**X**")
        textView.setSelectedRange(NSRange(location: formatted.upperBound, length: 0))
        textView.deleteBackward(nil)
        XCTAssertEqual(textView.string, " 👩🏽‍💻")
        XCTAssertTrue(textView.undoManager?.canUndo == true)
        textView.undoManager?.undo()
        XCTAssertEqual(textView.string, source)

        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length,
                                          length: 0))
        textView.deleteBackward(nil)
        XCTAssertEqual(textView.string, "**X** ")
        XCTAssertTrue(textView.undoManager?.canUndo == true)
        textView.undoManager?.undo()
        XCTAssertEqual(textView.string, source)
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
