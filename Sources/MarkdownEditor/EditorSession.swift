import AppKit
import MarkdownRender

private final class NotificationObserverBag: @unchecked Sendable {
    private var tokens: [NSObjectProtocol] = []

    var count: Int { tokens.count }

    func add(_ token: NSObjectProtocol) { tokens.append(token) }

    func removeAll() {
        for token in tokens { NotificationCenter.default.removeObserver(token) }
        tokens.removeAll()
    }

    deinit { removeAll() }
}

/// The persistent TextKit surface for one document. SwiftUI may replace its
/// representable when tabs change, but this object—and therefore selection,
/// scrolling, undo history, storage, and layout—lives with the document.
@MainActor
public final class EditorSession {
    public let controller: EditorController
    public let storage: NSTextStorage
    public let layoutManager: MarkdownLayoutManager
    public let textView: MarkdownTextView
    public let scrollView: NSScrollView

    private let observers = NotificationObserverBag()
    private var hasAppliedInitialStyle = false

    public init(source: String, controller: EditorController) {
        self.controller = controller

        let storage = NSTextStorage(string: source)
        let layout = MarkdownLayoutManager()
        storage.addLayoutManager(layout)

        let container = NSTextContainer(size: NSSize(width: 0,
                                                       height: CGFloat.greatestFiniteMagnitude))
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
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)

        let scroll = CenteredFindBarScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.documentView = textView
        scroll.minSideInset = EditorController.minContentSideInset
        scroll.columnMaxWidth = { [weak controller] in
            MainActor.assumeIsolated {
                controller?.contentColumnMaxWidth ?? .greatestFiniteMagnitude
            }
        }

        self.storage = storage
        self.layoutManager = layout
        self.textView = textView
        self.scrollView = scroll

        attachController()
        controller.bootstrapMarkerIndex(sourceLength: storage.length)
        installObservers()
    }

    /// Mounting swaps only the short-lived delegate coordinator. All stateful
    /// AppKit objects remain identical across tab changes.
    func mount(delegate: NSTextViewDelegate) -> NSScrollView {
        attachController()
        textView.delegate = delegate
        if !hasAppliedInitialStyle {
            hasAppliedInitialStyle = true
            // Avoid publishing parsed/TOC state while SwiftUI is inside
            // `makeNSView`; style once on the next main-runloop turn.
            DispatchQueue.main.async { [weak self] in self?.controller.restyle() }
        }
        controller.recenterContent()
        return scrollView
    }

    func unmount(delegate: NSTextViewDelegate) {
        if textView.delegate === delegate { textView.delegate = nil }
        controller.hideFloatingToolbar()
    }

    private func attachController() {
        controller.textView = textView
        controller.layoutManager = layoutManager
        layoutManager.imageProvider = { [weak controller] src in
            MainActor.assumeIsolated {
                controller?.imageLoader.image(forSource: src, baseURL: controller?.baseURL)
            }
        }
    }

    private func installObservers() {
        scrollView.postsFrameChangedNotifications = true
        observers.add(NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: scrollView, queue: .main) { [weak controller] _ in
                Task { @MainActor in controller?.recenterContent() }
            })

        scrollView.contentView.postsBoundsChangedNotifications = true
        observers.add(NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView, queue: .main) { [weak controller] _ in
                Task { @MainActor in controller?.hideFloatingToolbar() }
            })
    }

    // Internal diagnostics used by lifecycle regression tests.
    var observerCount: Int { observers.count }
}
