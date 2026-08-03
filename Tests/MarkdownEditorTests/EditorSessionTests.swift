import XCTest
import AppKit
@testable import MarkdownEditor

@MainActor
final class EditorSessionTests: XCTestCase {
    private final class Delegate: NSObject, NSTextViewDelegate {}

    func testInitializationDoesNotLayOutLargeDocumentBeforeItHasAViewport() {
        let line = "## Section with **bold** and [a link](https://example.com)\n\n"
        let source = Array(repeating: line, count: 5_000).joined()
        let controller = EditorController()

        let session = EditorSession(source: source, controller: controller)

        XCTAssertTrue(session.layoutManager.allowsNonContiguousLayout)
        XCTAssertEqual(session.layoutManager.firstUnlaidCharacterIndex(), 0,
                       "constructing an unmounted editor must leave layout deferred")
    }

    func testRemountKeepsTextKitSelectionScrollAndUndoObjects() {
        let source = Array(repeating: "A persistent editor line.\n", count: 200).joined()
        let controller = EditorController()
        let session = EditorSession(source: source, controller: controller)
        let firstDelegate = Delegate()

        let firstMount = session.mount(delegate: firstDelegate)
        firstMount.frame = NSRect(x: 0, y: 0, width: 500, height: 220)
        session.textView.frame.size.width = 500
        session.layoutManager.ensureLayout(for: session.textView.textContainer!)
        session.textView.sizeToFit()
        session.textView.setSelectedRange(NSRange(location: 37, length: 8))
        firstMount.contentView.scroll(to: NSPoint(x: 0, y: 600))
        firstMount.reflectScrolledClipView(firstMount.contentView)

        let selection = session.textView.selectedRange()
        let scrollOrigin = firstMount.contentView.bounds.origin
        let undoManager = session.textView.undoManager
        XCTAssertEqual(session.observerCount, 2)

        session.unmount(delegate: firstDelegate)
        let secondDelegate = Delegate()
        let secondMount = session.mount(delegate: secondDelegate)

        XCTAssertTrue(firstMount === secondMount)
        XCTAssertTrue(secondMount.documentView === session.textView)
        XCTAssertTrue(controller.textView === session.textView)
        XCTAssertTrue(controller.layoutManager === session.layoutManager)
        XCTAssertEqual(session.textView.selectedRange(), selection)
        XCTAssertEqual(secondMount.contentView.bounds.origin.y, scrollOrigin.y, accuracy: 0.5)
        XCTAssertTrue(session.textView.undoManager === undoManager)
        XCTAssertEqual(session.observerCount, 2, "remounting must not register duplicate observers")
    }

    func testUndoHistorySurvivesUnmountAndRemount() {
        let controller = EditorController()
        let session = EditorSession(source: "hello", controller: controller)
        let firstDelegate = Delegate()
        _ = session.mount(delegate: firstDelegate)
        session.textView.setSelectedRange(NSRange(location: 5, length: 0))
        session.textView.insertText("!", replacementRange: NSRange(location: 5, length: 0))
        XCTAssertEqual(session.storage.string, "hello!")
        XCTAssertTrue(session.textView.undoManager?.canUndo == true)

        session.unmount(delegate: firstDelegate)
        _ = session.mount(delegate: Delegate())
        session.textView.undoManager?.undo()

        XCTAssertEqual(session.storage.string, "hello")
    }

    func testSessionDoesNotLeakAfterDocumentOwnershipEnds() {
        weak var released: EditorSession?
        autoreleasepool {
            let controller = EditorController()
            var session: EditorSession? = EditorSession(source: "hello", controller: controller)
            released = session
            XCTAssertEqual(session?.observerCount, 2)
            session = nil
        }
        XCTAssertNil(released)
    }
}
