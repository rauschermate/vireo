import XCTest
import MarkdownEditor
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
}
