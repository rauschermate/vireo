import SwiftUI
import AppKit
import MarkdownEditor

/// One window = one document. macOS groups these into native tabs
/// (`tabbingMode = .preferred`, shared `tabbingIdentifier`).
struct DocumentWindowView: View {
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var state: AppState
    @State private var doc: DocumentModel?

    var body: some View {
        Group {
            if let doc {
                layout(doc)
            } else {
                Color(nsColor: .textBackgroundColor)
            }
        }
        .onAppear(perform: bootstrap)
        .background(WindowConfigurator { configure($0) })
    }

    @ViewBuilder private func layout(_ doc: DocumentModel) -> some View {
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

    private func configure(_ window: NSWindow) {
        window.tabbingMode = .preferred
        window.tabbingIdentifier = "vireo-document"
        window.title = doc?.title ?? "Untitled"
        if let id = doc?.id { window.identifier = NSUserInterfaceItemIdentifier("vireo-\(id)") }
    }
}

/// Bridges to the hosting `NSWindow` to configure native tabbing / title and to
/// mark this document active when its window becomes key.
struct WindowConfigurator: NSViewRepresentable {
    let configure: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = TrackingView()
        view.onWindow = { window in
            configure(window)
            context.coordinator.setup(window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let window = nsView.window { configure(window) }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        private var configured = Set<ObjectIdentifier>()

        func setup(_ window: NSWindow) {
            let key = ObjectIdentifier(window)
            guard !configured.contains(key) else { return }
            configured.insert(key)

            // Track focus so menu commands target the frontmost document. Read
            // the identifier from the notification's window (it may be assigned
            // after this observer is installed).
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
