import SwiftUI
import AppKit
import MarkdownEditor
import VireoCore

/// One window = one document. macOS groups these into native tabs
/// (`tabbingMode = .preferred`, shared `tabbingIdentifier`).
struct DocumentWindowView: View {
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var state: AppState
    @State private var doc: DocumentModel?

    var body: some View {
        Group {
            if let doc {
                DocumentContentView(doc: doc)
            } else {
                Color(nsColor: .textBackgroundColor)
            }
        }
        .onAppear(perform: bootstrap)
    }

    private func bootstrap() {
        state.openWindowProxy = { openWindow(id: "document") }
        if doc == nil {
            if let queued = state.dequeueDocID(), let d = state.document(for: queued) {
                doc = d
            } else if let url = state.pendingURLs.first, let d = state.makeDocument(for: url) {
                state.pendingURLs.removeFirst()
                doc = d
            } else {
                doc = state.newDocument()
            }
        }
        state.activeDocID = doc?.id
        // Any additional launch/Finder files open as their own tabbed windows.
        let remaining = state.pendingURLs
        state.pendingURLs = []
        for url in remaining { state.requestOpen(url) }
    }
}

/// The per-document layout. Observes the document so the TOC sidebar, window
/// title, dirty indicator and proxy icon all track its state.
private struct DocumentContentView: View {
    @ObservedObject var doc: DocumentModel
    @EnvironmentObject private var state: AppState

    var body: some View {
        HStack(spacing: 0) {
            if state.showFileSidebar && !state.focusMode, state.rootFolder != nil {
                FileSidebar().frame(width: 240)
                Divider()
            }
            MarkdownSourceView(source: doc.source, controller: doc.controller)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if state.showTOC && !state.focusMode, !doc.toc.isEmpty {
                Divider()
                TOCSidebar(document: doc).frame(width: 220)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: state.showFileSidebar)
        .animation(.easeInOut(duration: 0.18), value: state.showTOC)
        .animation(.easeInOut(duration: 0.18), value: state.focusMode)
        .background(WindowConfigurator(docID: doc.id, title: doc.title,
                                       url: doc.url, edited: doc.isDirty))
    }
}

/// Bridges to the hosting `NSWindow`: native tabbing, title / dirty dot /
/// proxy icon, focus tracking, close-prompt (unsaved changes) and cleanup.
struct WindowConfigurator: NSViewRepresentable {
    let docID: UUID
    let title: String
    let url: URL?
    let edited: Bool

    func makeNSView(context: Context) -> NSView {
        let view = TrackingView()
        view.onWindow = { [weak coordinator = context.coordinator] window in
            guard let coordinator else { return }
            apply(to: window)
            coordinator.setup(window, docID: docID)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let window = nsView.window {
            apply(to: window)
            context.coordinator.setup(window, docID: docID)
        }
    }

    private func apply(to window: NSWindow) {
        window.tabbingMode = .preferred
        window.tabbingIdentifier = "vireo-document"
        window.identifier = NSUserInterfaceItemIdentifier("vireo-\(docID)")
        window.title = title
        window.representedURL = url
        window.isDocumentEdited = edited
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        private var configured = Set<ObjectIdentifier>()
        private var proxies: [ObjectIdentifier: WindowDelegateProxy] = [:]

        func setup(_ window: NSWindow, docID: UUID) {
            let key = ObjectIdentifier(window)

            // The delegate proxy carries the doc id; keep it current even if
            // SwiftUI recycles the window for another document.
            if let proxy = proxies[key] {
                proxy.docID = docID
            }
            guard !configured.contains(key) else { return }
            configured.insert(key)

            // Intercept close to prompt for unsaved changes, forwarding
            // everything else to SwiftUI's own delegate.
            let proxy = WindowDelegateProxy(original: window.delegate, docID: docID)
            proxies[key] = proxy
            window.delegate = proxy

            // Track focus so menu commands target the frontmost document.
            NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { note in
                let raw = (note.object as? NSWindow)?.identifier?.rawValue
                Task { @MainActor in
                    if let raw, raw.hasPrefix("vireo-"),
                       let uuid = UUID(uuidString: String(raw.dropFirst("vireo-".count))) {
                        AppState.shared.activeDocID = uuid
                    }
                }
            }

            // Cleanup when the window actually closes: flush pending saves,
            // stop the file watcher, drop the model.
            NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main) { note in
                let raw = (note.object as? NSWindow)?.identifier?.rawValue
                Task { @MainActor in
                    if let raw, raw.hasPrefix("vireo-"),
                       let uuid = UUID(uuidString: String(raw.dropFirst("vireo-".count))) {
                        AppState.shared.discard(uuid)
                    }
                }
            }

            // Merge into the existing document tab group so multiple documents
            // open as native tabs by default (independent of the system
            // "prefer tabs" setting). Deferred so the sibling window is on-screen.
            let ident = window.identifier?.rawValue
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                MainActor.assumeIsolated { Coordinator.merge(identifier: ident) }
            }
        }

        static func merge(identifier: String?) {
            guard let identifier,
                  let window = NSApp.windows.first(where: { $0.identifier?.rawValue == identifier })
            else { return }
            if let group = window.tabGroup, group.windows.count > 1 { return }
            for other in NSApp.windows
            where other !== window
                && (other.identifier?.rawValue.hasPrefix("vireo-") ?? false)
                && other.isVisible
                && other.tabbingIdentifier == window.tabbingIdentifier {
                other.addTabbedWindow(window, ordered: .above)
                window.makeKeyAndOrderFront(nil)
                return
            }
        }
    }

    private final class TrackingView: NSView {
        var onWindow: ((NSWindow) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onWindow?(window) }
        }
    }
}

/// NSWindow delegate that adds a save-changes prompt on close and forwards
/// every other delegate callback to SwiftUI's original delegate.
@MainActor
final class WindowDelegateProxy: NSObject, NSWindowDelegate {
    // Only ever touched on the main thread (AppKit delegate callbacks), but
    // `responds(to:)`/`forwardingTarget(for:)` are nonisolated NSObject entry
    // points, so the compiler can't prove it.
    nonisolated(unsafe) weak var original: NSWindowDelegate?
    var docID: UUID

    init(original: NSWindowDelegate?, docID: UUID) {
        self.original = original
        self.docID = docID
    }

    nonisolated override func responds(to aSelector: Selector!) -> Bool {
        if super.responds(to: aSelector) { return true }
        return original?.responds(to: aSelector) ?? false
    }

    nonisolated override func forwardingTarget(for aSelector: Selector!) -> Any? {
        if original?.responds(to: aSelector) == true { return original }
        return nil
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard shouldAllowClose(sender) else { return false }
        // Chain to SwiftUI's delegate if it also implements this.
        if let original,
           original.responds(to: #selector(NSWindowDelegate.windowShouldClose(_:))) {
            return original.windowShouldClose?(sender) ?? true
        }
        return true
    }

    private func shouldAllowClose(_ window: NSWindow) -> Bool {
        guard let doc = AppState.shared.document(for: docID) else { return true }
        let needsPrompt: Bool
        if doc.url == nil {
            needsPrompt = !doc.source.isEmpty          // untitled with content
        } else {
            needsPrompt = doc.isDirty && !Preferences.shared.autoSave
        }
        guard needsPrompt else { return true }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Save changes to “\(doc.title)”?"
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            if doc.url == nil {
                let panel = NSSavePanel()
                panel.nameFieldStringValue = "Untitled.md"
                guard panel.runModal() == .OK, let saveURL = panel.url else { return false }
                doc.save(to: saveURL)
                Preferences.shared.addRecent(saveURL)
            } else {
                doc.saveNow()
            }
            return true
        case .alertSecondButtonReturn:
            return true
        default:
            return false
        }
    }
}
