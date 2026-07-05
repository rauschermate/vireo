import XCTest
import AppKit
import MarkdownEngine
@testable import MarkdownEditor

@MainActor
final class EnterOutdentTests: XCTestCase {
    private func editor(_ source: String) -> (EditorController, MarkdownTextView) {
        let controller = EditorController()
        let (scroll, tv) = MarkdownSourceView.makeTextStack(source: source, controller: controller)
        scroll.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        controller.restyle()
        return (controller, tv)
    }
    // Put the caret at the end of the given (1-based) line.
    private func caretAtEndOfLine(_ tv: MarkdownTextView, _ oneBased: Int) {
        let ns = tv.textStorage!.string as NSString
        var loc = 0, line = 1
        while line < oneBased {
            let lr = ns.lineRange(for: NSRange(location: loc, length: 0))
            loc = lr.upperBound; line += 1
        }
        let lr = ns.lineRange(for: NSRange(location: loc, length: 0))
        var end = lr.upperBound
        if end > lr.location, ns.character(at: end - 1) == 0x0A { end -= 1 }
        tv.setSelectedRange(NSRange(location: end, length: 0))
    }

    func testEnterOnNestedEmptyItemOutdents() {
        let (_, tv) = editor("- one\n    - \n")
        caretAtEndOfLine(tv, 2)               // empty nested bullet
        tv.insertNewline(nil)
        XCTAssertEqual(tv.textStorage!.string, "- one\n- \n", "nested empty item should outdent one level")
    }

    func testEnterOnTopLevelEmptyItemExitsListToParagraph() {
        let (_, tv) = editor("- one\n- \n")
        caretAtEndOfLine(tv, 2)               // empty top-level bullet
        tv.insertNewline(nil)
        // A blank line must separate the list from the caret, else typed text
        // is a lazy continuation and renders inside the list.
        XCTAssertEqual(tv.textStorage!.string, "- one\n\n\n")
        // Typing where the caret landed must produce a real paragraph.
        tv.insertText("asd", replacementRange: tv.selectedRange())
        let src = tv.textStorage!.string
        let p = MarkdownParser().parse(src)
        let asd = (src as NSString).range(of: "asd")
        let inList = p.blockRuns.contains {
            if case .listItem = $0.kind { return NSIntersectionRange($0.range, asd).length > 0 }
            return false
        }
        XCTAssertFalse(inList, "text typed after exiting the list must not be a list item")
    }

    func testEnterOnNonEmptyItemContinues() {
        let (_, tv) = editor("- one\n")
        caretAtEndOfLine(tv, 1)
        tv.insertNewline(nil)
        XCTAssertEqual(tv.textStorage!.string, "- one\n- \n", "non-empty item continues the list")
    }

    func testDeepNestOutdentsOneLevelPerEnter() {
        let (_, tv) = editor("- a\n    - b\n        - \n")
        caretAtEndOfLine(tv, 3)               // empty depth-2 item
        tv.insertNewline(nil)
        XCTAssertEqual(tv.textStorage!.string, "- a\n    - b\n    - \n", "one level per Enter")
    }
}
