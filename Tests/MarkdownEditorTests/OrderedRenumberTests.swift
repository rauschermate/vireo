import XCTest
import AppKit
@testable import MarkdownEditor

/// Enter in the middle of an ordered list renumbers the following siblings
/// so the source stays sequential.
@MainActor
final class OrderedRenumberTests: XCTestCase {
    // MARK: The pure edit computation

    private func edits(_ source: String, afterLineAt location: Int) -> [(Int, String)] {
        ListLine.orderedSiblingRenumberEdits(in: source as NSString,
                                             afterLineAt: location)
            .map { ($0.range.location, $0.replacement) }
    }

    func testFollowingSiblingsCountOnFromTheBaseItem() {
        let source = "1. a\n2. \n2. b\n3. c\n"
        let base = (source as NSString).range(of: "2. \n").location
        XCTAssertEqual(edits(source, afterLineAt: base).map(\.1), ["3", "4"])
    }

    func testChildSubtreesPassThroughUntouched() {
        let source = "1. a\n2. \n    1. x\n    2. y\n2. b\n"
        let base = (source as NSString).range(of: "2. \n").location
        let result = edits(source, afterLineAt: base)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].0, (source as NSString).range(of: "2. b").location)
        XCTAssertEqual(result[0].1, "3")
    }

    func testOneBlankLineKeepsALooseListTogether() {
        let source = "1. a\n2. \n\n2. b\n"
        let base = (source as NSString).range(of: "2. \n\n").location
        XCTAssertEqual(edits(source, afterLineAt: base).map(\.1), ["3"])
    }

    func testMarginContentEndsTheWalk() {
        let source = "1. a\n2. \n\ntext\n\n2. other list\n"
        let base = (source as NSString).range(of: "2. \n").location
        XCTAssertTrue(edits(source, afterLineAt: base).isEmpty)
    }

    func testDifferentDelimiterEndsTheWalk() {
        let source = "1. a\n2. \n2) b\n"
        let base = (source as NSString).range(of: "2. \n").location
        XCTAssertTrue(edits(source, afterLineAt: base).isEmpty)
    }

    func testAlreadySequentialNumbersNeedNoEdits() {
        let source = "1. a\n2. b\n3. c\n"
        XCTAssertTrue(edits(source, afterLineAt: 0).isEmpty)
    }

    func testDigitWidthGrowsPastNine() {
        let source = "8. a\n9. \n9. b\n10. c\n"
        let base = (source as NSString).range(of: "9. \n").location
        XCTAssertEqual(edits(source, afterLineAt: base).map(\.1), ["10", "11"])
    }

    // MARK: Enter inside the editor

    private func makeEditor(_ source: String) -> (EditorController, MarkdownTextView) {
        let controller = EditorController()
        let (_, textView) = MarkdownSourceView.makeTextStack(source: source, controller: controller)
        controller.restyle()
        return (controller, textView)
    }

    func testEnterMidListRenumbersTheRestOfTheList() {
        let (controller, textView) = makeEditor("1. a\n2. b\n3. c\n4. d\n")
        let caret = ("1. a\n2. b" as NSString).length
        textView.setSelectedRange(NSRange(location: caret, length: 0))
        textView.insertNewline(nil)
        XCTAssertEqual(textView.string, "1. a\n2. b\n3. \n4. c\n5. d\n")
        XCTAssertEqual(textView.selectedRange(),
                       NSRange(location: ("1. a\n2. b\n3. " as NSString).length, length: 0))
        withExtendedLifetime(controller) {}
    }

    func testEnterSplitsAnItemAndRenumbers() {
        let (controller, textView) = makeEditor("1. alpha\n2. beta\n")
        let caret = ("1. al" as NSString).length
        textView.setSelectedRange(NSRange(location: caret, length: 0))
        textView.insertNewline(nil)
        XCTAssertEqual(textView.string, "1. al\n2. pha\n3. beta\n")
        withExtendedLifetime(controller) {}
    }

    func testEnterAtTheEndOfTheListChangesNothingElse() {
        let (controller, textView) = makeEditor("1. a\n2. b\n")
        let caret = ("1. a\n2. b" as NSString).length
        textView.setSelectedRange(NSRange(location: caret, length: 0))
        textView.insertNewline(nil)
        XCTAssertEqual(textView.string, "1. a\n2. b\n3. \n")
        withExtendedLifetime(controller) {}
    }

    func testUndoRestoresTheOldNumbering() {
        let (controller, textView) = makeEditor("1. a\n2. b\n3. c\n")
        let caret = ("1. a\n2. b" as NSString).length
        textView.setSelectedRange(NSRange(location: caret, length: 0))
        textView.insertNewline(nil)
        XCTAssertEqual(textView.string, "1. a\n2. b\n3. \n4. c\n")
        textView.undoManager?.undo()
        XCTAssertEqual(textView.string, "1. a\n2. b\n3. c\n")
        withExtendedLifetime(controller) {}
    }
}
