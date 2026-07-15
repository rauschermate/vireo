import AppKit
import Combine

private final class UndoNotificationObserverBag: @unchecked Sendable {
    private var observers: [NSObjectProtocol] = []

    func add(_ observer: NSObjectProtocol) {
        observers.append(observer)
    }

    func removeAll() {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
    }

    deinit { removeAll() }
}

/// Adapts each document-owned NSTextView undo manager to SwiftUI's command
/// system. `NSViewRepresentable` preserves the native manager, but SwiftUI's
/// default Undo/Redo group does not discover it or observe its state.
@MainActor
final class EditorUndoCommandState: ObservableObject {
    static let shared = EditorUndoCommandState(state: .shared)

    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    @Published private(set) var undoTitle = "Undo"
    @Published private(set) var redoTitle = "Redo"

    private weak var manager: UndoManager?
    private weak var textView: NSTextView?
    private var selectionObserver: AnyCancellable?
    private let notificationObservers = UndoNotificationObserverBag()

    init(state: AppState) {
        bind(to: state.document(for: state.selectedID))
        selectionObserver = state.$selectedID.sink { [weak self, weak state] id in
            guard let self, let state else { return }
            self.bind(to: state.document(for: id))
        }
    }

    func undo() {
        guard let manager, manager.canUndo else { return }
        manager.undo()
        refresh()
    }

    func redo() {
        guard let manager, manager.canRedo else { return }
        manager.redo()
        refresh()
    }

    private func bind(to document: DocumentModel?) {
        let nextTextView = document?.editorSession.textView
        let nextManager = nextTextView?.undoManager
        if textView === nextTextView, manager === nextManager {
            refresh()
            return
        }

        removeNotificationObservers()
        textView = nextTextView
        manager = nextManager

        let center = NotificationCenter.default
        if let nextTextView {
            notificationObservers.add(center.addObserver(
                forName: NSText.didChangeNotification,
                object: nextTextView,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            })
        }
        if let nextManager {
            for name in Self.undoNotifications {
                notificationObservers.add(center.addObserver(
                    forName: name,
                    object: nextManager,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor in self?.refresh() }
                })
            }
        }
        refresh()
    }

    private func refresh() {
        canUndo = manager?.canUndo == true
        canRedo = manager?.canRedo == true
        undoTitle = canUndo ? manager?.undoMenuItemTitle ?? "Undo" : "Undo"
        redoTitle = canRedo ? manager?.redoMenuItemTitle ?? "Redo" : "Redo"
    }

    private func removeNotificationObservers() {
        notificationObservers.removeAll()
    }

    private static let undoNotifications: [Notification.Name] = [
        .NSUndoManagerDidCloseUndoGroup,
        .NSUndoManagerDidUndoChange,
        .NSUndoManagerDidRedoChange,
    ]
}
