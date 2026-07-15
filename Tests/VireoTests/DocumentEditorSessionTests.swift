import XCTest
@testable import MarkdownEditor
@testable import Vireo

@MainActor
final class DocumentEditorSessionTests: XCTestCase {
    func testDocumentOwnsOneSessionForItsLifetime() {
        weak var releasedSession: EditorSession?
        autoreleasepool {
            var document: DocumentModel? = DocumentModel(untitled: "hello")
            let first = document!.editorSession
            releasedSession = first

            XCTAssertTrue(first === document!.editorSession)
            document = nil
        }
        XCTAssertNil(releasedSession)
    }

    func testWindowUndoManagerRoutesCommandHistoryToEditorSession() {
        let source = "**X** 👩🏽‍💻"
        let controller = EditorController()
        let session = EditorSession(source: source, controller: controller)
        let coordinator = MarkdownSourceView.Coordinator(controller: controller,
                                                          session: session)
        let scrollView = session.mount(delegate: coordinator)
        controller.restyle()

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let proxy = WindowDelegateProxy(original: nil)
        window.delegate = proxy
        window.contentView = scrollView
        XCTAssertTrue(window.makeFirstResponder(session.textView))

        session.textView.setSelectedRange(NSRange(location: 5, length: 0))
        session.textView.deleteBackward(nil)
        XCTAssertEqual(session.textView.string, " 👩🏽‍💻")

        let manager = window.undoManager
        XCTAssertTrue(manager === session.textView.undoManager)
        XCTAssertTrue(manager?.canUndo == true)
        manager?.undo()
        XCTAssertEqual(session.textView.string, source)

        withExtendedLifetime((coordinator, proxy)) {}
    }
}
