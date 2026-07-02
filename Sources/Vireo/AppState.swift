import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VireoCore

/// A node in the opened-folder file tree (left sidebar).
struct FileNode: Identifiable, Hashable {
    let id: URL
    var url: URL { id }
    var name: String
    var isDirectory: Bool
    var children: [FileNode]?
}

/// Central registry. With native window tabs each document lives in its own
/// window (one per `DocumentModel`); this holds the shared registry, the opened
/// folder, global view toggles, and the currently-focused document (so menu
/// commands can target it).
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published private(set) var documents: [UUID: DocumentModel] = [:]
    @Published var rootFolder: FileNode?
    @Published var activeDocID: UUID?

    @Published var showFileSidebar = true
    @Published var showTOC = true
    @Published var focusMode = false
    @Published var zoom: CGFloat = 1.0 { didSet { applyZoom() } }

    /// Requests a fresh window from the (plain) WindowGroup. Set by a live window.
    var openWindowProxy: (() -> Void)?
    /// FIFO of document ids the next opened window(s) should adopt.
    var windowQueue: [UUID] = []
    /// URLs queued before a window existed to service them.
    var pendingURLs: [URL] = []

    func dequeueDocID() -> UUID? {
        windowQueue.isEmpty ? nil : windowQueue.removeFirst()
    }

    func focusWindow(for id: UUID) {
        let ident = "vireo-\(id)"
        for window in NSApp.windows where window.identifier?.rawValue == ident {
            window.makeKeyAndOrderFront(nil)
            return
        }
    }

    var activeDocument: DocumentModel? {
        activeDocID.flatMap { documents[$0] }
    }

    private func applyZoom() {
        for doc in documents.values { doc.controller.zoom = zoom }
    }

    // MARK: Registry

    func document(for id: UUID?) -> DocumentModel? {
        id.flatMap { documents[$0] }
    }

    func register(_ doc: DocumentModel) {
        documents[doc.id] = doc
        doc.controller.zoom = zoom
        doc.openLinkHandler = { [weak self] target in self?.requestOpen(target) }
    }

    func newDocument() -> DocumentModel {
        let doc = DocumentModel(untitled: "")
        register(doc)
        return doc
    }

    func makeDocument(for url: URL) -> DocumentModel? {
        if let existing = documents.values.first(where: { $0.url == url }) { return existing }
        do {
            let doc = try DocumentModel(url: url)
            register(doc)
            Preferences.shared.addRecent(url)
            return doc
        } catch {
            NSLog("Vireo open failed: \(error)")
            return nil
        }
    }

    /// Remove a document from the registry when its window closes: flush any
    /// pending autosave, save if dirty, and let the model (and its file
    /// watcher) deallocate. The save-changes *prompt* happens earlier, in
    /// `WindowDelegateProxy.windowShouldClose`.
    func discard(_ id: UUID) {
        if let doc = documents[id], doc.url != nil {
            doc.flushPendingSave()
            if doc.isDirty { doc.saveNow() }
        }
        documents[id] = nil
        if activeDocID == id { activeDocID = nil }
    }

    // MARK: Opening (routes through the window layer)

    /// Open a URL in a new tabbed window, focusing an existing one if already open.
    func requestOpen(_ url: URL) {
        if let existing = documents.values.first(where: { $0.url == url }) {
            focusWindow(for: existing.id)
            return
        }
        guard let doc = makeDocument(for: url) else { return }
        if let proxy = openWindowProxy {
            windowQueue.append(doc.id)
            proxy()
        } else {
            pendingURLs.append(url)
        }
    }

    func openFilePanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = markdownTypes()
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            for url in panel.urls { requestOpen(url) }
        }
    }

    func openFolderPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        if panel.runModal() == .OK, let url = panel.url { openFolder(url) }
    }

    func openFolder(_ url: URL) {
        rootFolder = buildTree(url)
        showFileSidebar = true
    }

    func saveActiveAs() {
        guard let doc = activeDocument else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = doc.title.hasSuffix(".md") ? doc.title : doc.title + ".md"
        if panel.runModal() == .OK, let url = panel.url {
            doc.save(to: url)
            Preferences.shared.addRecent(url)
        }
    }

    private func markdownTypes() -> [UTType] {
        var types: [UTType] = [.plainText]
        if let md = UTType(filenameExtension: "md") { types.append(md) }
        if let markdown = UTType(filenameExtension: "markdown") { types.append(markdown) }
        return types
    }

    private func buildTree(_ url: URL) -> FileNode {
        let fm = FileManager.default
        var children: [FileNode] = []
        let contents = (try? fm.contentsOfDirectory(at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])) ?? []
        for child in contents.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
            let isDir = (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDir {
                let node = buildTree(child)
                if !(node.children?.isEmpty ?? true) { children.append(node) }
            } else if FileService.isMarkdown(child) {
                children.append(FileNode(id: child, name: child.lastPathComponent, isDirectory: false, children: nil))
            }
        }
        return FileNode(id: url, name: url.lastPathComponent, isDirectory: true,
                        children: children.isEmpty ? nil : children)
    }
}
