import SwiftUI
import AppKit
import MarkdownEditor
import VireoCore

/// The single document window: custom tab strip on top (hidden in focus
/// mode), file sidebar / editor / TOC below.
struct DocumentWindowView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            if !state.focusMode {
                ChromeBar()
                    .zIndex(1) // tab tooltips hang below the bar, over the editor
                Divider()
            }
            HStack(spacing: 0) {
                if state.showFileSidebar && !state.focusMode, state.rootFolder != nil {
                    FileSidebar().frame(width: 240)
                    Divider()
                }
                if let doc = state.activeDocument {
                    EditorPane(doc: doc)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Color(nsColor: .textBackgroundColor)
                }
            }
        }
        .animation(.easeInOut(duration: 0.18), value: state.showFileSidebar)
        .animation(.easeInOut(duration: 0.18), value: state.showTOC)
        .animation(.easeInOut(duration: 0.18), value: state.focusMode)
        // Pull the chrome up into the title-bar zone, beside the traffic
        // lights (the transparent titlebar otherwise remains an empty strip).
        // Focus mode keeps the safe area so text doesn't hide under the lights.
        .ignoresSafeArea(.container, edges: state.focusMode ? [] : .top)
        .background(WindowConfigurator(title: state.activeDocument?.displayTitle ?? "Vireo",
                                       url: state.activeDocument?.url,
                                       edited: state.activeDocument?.isDirty ?? false))
    }
}

/// One document's editor + TOC (kept per-document so switching tabs swaps the
/// whole editing surface, preserving each document's undo stack and scroll).
private struct EditorPane: View {
    @ObservedObject var doc: DocumentModel
    @EnvironmentObject private var state: AppState

    var body: some View {
        HStack(spacing: 0) {
            MarkdownSourceView(source: doc.source, controller: doc.controller)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .id(doc.id)
            if state.showTOC && !state.focusMode, !doc.toc.isEmpty {
                TOCSidebar(document: doc).frame(width: 220)
            }
        }
    }
}

/// Bridges to the hosting `NSWindow`: title / dirty dot / proxy icon, and a
/// close-prompt that walks every open tab.
struct WindowConfigurator: NSViewRepresentable {
    let title: String
    let url: URL?
    let edited: Bool

    func makeNSView(context: Context) -> NSView {
        let view = TrackingView()
        view.onWindow = { [weak coordinator = context.coordinator] window in
            apply(to: window)
            coordinator?.setup(window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let window = nsView.window { apply(to: window) }
    }

    private func apply(to window: NSWindow) {
        window.tabbingMode = .disallowed // we draw our own tabs
        // No system state restoration — stale scene state from earlier builds
        // can silently suppress window presentation, and tabs are ours anyway.
        window.isRestorable = false
        // The tab strip lives in the title-bar zone: hide the system title and
        // let content extend to the top; the ChromeBar handles window dragging.
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        window.title = title // still used by Mission Control / the Window menu
        window.representedURL = url
        window.isDocumentEdited = edited
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        private var configured = Set<ObjectIdentifier>()
        private var proxies: [ObjectIdentifier: WindowDelegateProxy] = [:]

        func setup(_ window: NSWindow) {
            let key = ObjectIdentifier(window)
            guard !configured.contains(key) else { return }
            configured.insert(key)
            let proxy = WindowDelegateProxy(original: window.delegate)
            proxies[key] = proxy
            window.delegate = proxy
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

/// Window delegate that prompts for every tab with unsaved changes before the
/// window closes, forwarding everything else to SwiftUI's original delegate.
@MainActor
final class WindowDelegateProxy: NSObject, NSWindowDelegate {
    nonisolated(unsafe) weak var original: NSWindowDelegate?

    init(original: NSWindowDelegate?) {
        self.original = original
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
        for doc in AppState.shared.documents {
            guard AppState.shared.confirmDiscardIfNeeded(doc) else { return false }
            doc.flushPendingSave()
            if doc.isDirty, doc.url != nil { doc.saveNow() }
        }
        if let original,
           original.responds(to: #selector(NSWindowDelegate.windowShouldClose(_:))) {
            return original.windowShouldClose?(sender) ?? true
        }
        return true
    }
}
