import AppKit
import SwiftUI
import MarkdownRender

/// SwiftUI wrapper around the AppKit editing surface. Builds the TextKit-1 stack
/// (required for the null-glyph syntax hiding) with our custom layout manager,
/// centered in a readable column.
public struct MarkdownSourceView: NSViewRepresentable {
    private let initialSource: String
    @ObservedObject private var controller: EditorController

    public init(source: String, controller: EditorController) {
        self.initialSource = source
        self.controller = controller
    }

    /// Build the TextKit stack + scroll view. Factored out of `makeNSView` so
    /// tests can assert scrolling invariants (the text view must be able to
    /// grow past its initial frame).
    public static func makeTextStack(source: String,
                                     controller: EditorController) -> (scroll: NSScrollView, textView: MarkdownTextView) {
        let storage = NSTextStorage(string: source)
        let layout = MarkdownLayoutManager()
        storage.addLayoutManager(layout)

        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 8
        layout.addTextContainer(container)

        let textView = MarkdownTextView(frame: .zero, textContainer: container)
        textView.controller = controller
        textView.isEditable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.drawsBackground = true
        textView.backgroundColor = NSColor.textBackgroundColor
        textView.textContainerInset = NSSize(width: 24, height: 28)
        textView.autoresizingMask = [NSView.AutoresizingMask.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        // maxSize defaults to the initial frame (zero here); without lifting it
        // the text view can never grow vertically — killing all scrolling.
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)

        controller.textView = textView
        controller.layoutManager = layout
        layout.imageProvider = { [weak controller] src in
            MainActor.assumeIsolated { controller?.imageLoader.image(forSource: src, baseURL: controller?.baseURL) }
        }

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.documentView = textView
        return (scroll, textView)
    }

    public func makeNSView(context: Context) -> NSScrollView {
        let (scroll, textView) = Self.makeTextStack(source: initialSource, controller: controller)
        textView.delegate = context.coordinator
        let controller = self.controller

        // Scrolling detaches the floating toolbar from its selection — hide it.
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scroll.contentView, queue: .main) { [weak controller] _ in
            Task { @MainActor in controller?.hideFloatingToolbar() }
        }

        DispatchQueue.main.async { controller.restyle() }
        return scroll
    }

    public func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? MarkdownTextView else { return }
        // Keep the reading column centered with a max width.
        let available = scroll.contentSize.width
        let target = min(available, controller.theme.contentMaxWidth + 48)
        let side = max(24, (available - target) / 2)
        let inset = textView.textContainerInset
        if abs(inset.width - side) > 0.5 {
            textView.textContainerInset = NSSize(width: side, height: inset.height)
        }
    }

    public func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }

    public final class Coordinator: NSObject, NSTextViewDelegate {
        let controller: EditorController
        init(controller: EditorController) { self.controller = controller }

        public func textDidChange(_ notification: Notification) {
            controller.scheduleRestyle()
        }

        public func textViewDidChangeSelection(_ notification: Notification) {
            controller.selectionChanged()
        }
    }
}
