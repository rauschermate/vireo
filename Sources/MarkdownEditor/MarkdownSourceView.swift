import AppKit
import SwiftUI

/// SwiftUI wrapper that mounts a document-owned `EditorSession`. Recreating this
/// representable during tab changes never recreates the TextKit stack.
public struct MarkdownSourceView: NSViewRepresentable {
    private let session: EditorSession
    @ObservedObject private var controller: EditorController

    public init(session: EditorSession) {
        self.session = session
        self.controller = session.controller
    }

    /// Convenience for standalone callers. Document tabs should pass a
    /// persistent session with `init(session:)`.
    public init(source: String, controller: EditorController) {
        self.session = EditorSession(source: source, controller: controller)
        self.controller = controller
    }

    /// Build the TextKit stack + scroll view. Factored out of `makeNSView` so
    /// tests can assert scrolling invariants (the text view must be able to
    /// grow past its initial frame).
    public static func makeTextStack(source: String,
                                     controller: EditorController) -> (scroll: NSScrollView, textView: MarkdownTextView) {
        let session = EditorSession(source: source, controller: controller)
        return (session.scrollView, session.textView)
    }

    public func makeNSView(context: Context) -> NSScrollView {
        session.mount(delegate: context.coordinator)
    }

    public func updateNSView(_ scroll: NSScrollView, context: Context) {
        controller.recenterContent()
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(controller: controller, session: session)
    }

    public static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.session?.unmount(delegate: coordinator)
    }

    public final class Coordinator: NSObject, NSTextViewDelegate {
        let controller: EditorController
        weak var session: EditorSession?
        init(controller: EditorController, session: EditorSession? = nil) {
            self.controller = controller
            self.session = session
        }

        public func textDidChange(_ notification: Notification) {
            controller.scheduleRestyle()
        }

        public func textViewDidChangeSelection(_ notification: Notification) {
            controller.selectionChanged()
        }

        /// Mouse drags, Find, services and accessibility can change selection
        /// without invoking a key command on MarkdownTextView. Route those
        /// paths through the same atomic marker policy as keyboard movement.
        public func textView(_ textView: NSTextView,
                             willChangeSelectionFromCharacterRange oldRange: NSRange,
                             toCharacterRange newRange: NSRange) -> NSRange {
            controller.normalizedSelection(newRange, previous: oldRange)
        }
    }
}
