import XCTest
import Combine
@testable import MarkdownEditor
@testable import Vireo

@MainActor
final class EditorUndoCommandStateTests: XCTestCase {
    func testMenuStateAndCommandsFollowTheActiveEditorHistory() async {
        let state = AppState()
        let commands = EditorUndoCommandState(state: state)
        var commandStateUpdates = 0
        let commandStateObserver = commands.objectWillChange.sink {
            commandStateUpdates += 1
        }
        let first = state.newDocument()
        let firstCoordinator = mount(first)

        XCTAssertFalse(commands.canUndo)
        XCTAssertEqual(commands.undoTitle, "Undo")

        first.editorSession.textView.insertText(
            "first",
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        await waitUntil { commands.canUndo }
        XCTAssertTrue(commands.undoTitle.hasPrefix("Undo"))

        let second = state.newDocument()
        let secondCoordinator = mount(second)
        await waitUntil { !commands.canUndo }

        second.editorSession.textView.insertText(
            "second",
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        await waitUntil { commands.canUndo }
        commands.undo()
        XCTAssertEqual(second.editorSession.textView.string, "")
        await waitUntil { commands.canRedo }
        XCTAssertTrue(commands.redoTitle.hasPrefix("Redo"))
        commands.redo()
        XCTAssertEqual(second.editorSession.textView.string, "second")

        state.selectedID = first.id
        await waitUntil { commands.canUndo }
        commands.undo()
        XCTAssertEqual(first.editorSession.textView.string, "")
        XCTAssertEqual(second.editorSession.textView.string, "second")

        // Reading UndoManager's dynamic titles emits a checkpoint. The command
        // model must not observe that checkpoint and create a refresh loop.
        try? await Task.sleep(for: .milliseconds(50))
        let settledUpdateCount = commandStateUpdates
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(commandStateUpdates, settledUpdateCount)

        withExtendedLifetime((firstCoordinator, secondCoordinator,
                              commandStateObserver)) {}
    }

    private func mount(_ document: DocumentModel) -> MarkdownSourceView.Coordinator {
        let session = document.editorSession
        let coordinator = MarkdownSourceView.Coordinator(controller: document.controller,
                                                          session: session)
        _ = session.mount(delegate: coordinator)
        document.controller.restyle()
        return coordinator
    }

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("condition not met before timeout")
    }
}
