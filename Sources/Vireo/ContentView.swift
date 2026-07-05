import SwiftUI
import AppKit
import MarkdownEditor
import VireoCore
import VireoUpdaterUI

/// The single document window: custom tab strip on top (hidden in focus
/// mode), file sidebar / editor / TOC below.
struct DocumentWindowView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
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
        .animation(.easeInOut(duration: 0.18), value: state.showFileSidebar)
        .animation(.easeInOut(duration: 0.18), value: state.focusMode)
        // The tab strip lives in a titlebar *accessory* — inside the titlebar
        // hierarchy next to the traffic lights (like Xcode's tabs): native
        // glass and dragging, and none of NSToolbar's » item-overflow, which
        // kept swallowing the strip during live resizes.
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width in
            if abs(state.contentWidth - width) > 0.5 { state.contentWidth = width }
        }
        .background(WindowConfigurator(title: state.activeDocument?.displayTitle ?? "Vireo",
                                       url: state.activeDocument?.url,
                                       edited: state.activeDocument?.isDirty ?? false,
                                       chromeHidden: state.focusMode))
        // The auto-update pill floats in the bottom-left corner of the window.
        .overlay(alignment: .bottomLeading) {
            UpdatePill(model: state.updater.model)
                .padding(.leading, 12)
                .padding(.bottom, 10)
                .allowsHitTesting(true)
        }
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
            if doc.showTOC && !state.focusMode, !doc.toc.isEmpty {
                TOCSidebar(document: doc).frame(width: 220)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: doc.showTOC)
    }
}

/// Bridges to the hosting `NSWindow`: title / dirty dot / proxy icon, and a
/// close-prompt that walks every open tab.
struct WindowConfigurator: NSViewRepresentable {
    let title: String
    let url: URL?
    let edited: Bool
    let chromeHidden: Bool

    func makeNSView(context: Context) -> NSView {
        let view = TrackingView()
        view.onWindow = { [weak coordinator = context.coordinator] window in
            apply(to: window)
            coordinator?.setup(window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let window = nsView.window {
            apply(to: window)
            context.coordinator.setChromeHidden(chromeHidden, in: window)
        }
    }

    private func apply(to window: NSWindow) {
        window.tabbingMode = .disallowed // we draw our own tabs
        // No system state restoration — stale scene state from earlier builds
        // can silently suppress window presentation, and tabs are ours anyway.
        window.isRestorable = false
        // Tabs occupy the titlebar accessory; no title text next to them.
        window.titleVisibility = .hidden
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
            installChromeAccessory(in: window)
        }

        /// The tab strip as a titlebar accessory (Xcode-style): part of the
        /// titlebar hierarchy — native glass and dragging, and no NSToolbar
        /// »-overflow to swallow the tabs mid-resize. Width is managed
        /// explicitly here and on every window resize (via the proxy).
        private func installChromeAccessory(in window: NSWindow) {
            guard !window.titlebarAccessoryViewControllers
                .contains(where: { $0.identifier == Self.accessoryID }) else { return }

            let host = NSHostingView(rootView: ChromeRow().environmentObject(AppState.shared))
            let vc = NSTitlebarAccessoryViewController()
            vc.identifier = Self.accessoryID
            vc.view = host
            vc.layoutAttribute = .left
            window.addTitlebarAccessoryViewController(vc)
            Self.layoutAccessory(in: window)
        }

        static let accessoryID = NSUserInterfaceItemIdentifier("vireo-chrome")

        static func layoutAccessory(in window: NSWindow) {
            guard let vc = window.titlebarAccessoryViewControllers
                .first(where: { $0.identifier == accessoryID }) else { return }
            let width = max(160, window.frame.width - 92) // clear the traffic lights
            vc.view.frame = NSRect(x: 0, y: 0, width: width, height: 34)
        }

        func setChromeHidden(_ hidden: Bool, in window: NSWindow) {
            guard let vc = window.titlebarAccessoryViewControllers
                .first(where: { $0.identifier == Self.accessoryID }) else { return }
            if vc.isHidden != hidden { vc.isHidden = hidden }
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

    func windowDidResize(_ notification: Notification) {
        if let window = notification.object as? NSWindow {
            WindowConfigurator.Coordinator.layoutAccessory(in: window)
        }
        // SwiftUI's delegate may also care about resizes — keep it informed.
        if let original,
           original.responds(to: #selector(NSWindowDelegate.windowDidResize(_:))) {
            original.windowDidResize?(notification)
        }
    }
}
