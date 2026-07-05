import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VireoCore
import VireoUpdater

/// A node in the opened-folder file tree (left sidebar).
struct FileNode: Identifiable, Hashable {
    let id: URL
    var url: URL { id }
    var name: String
    var isDirectory: Bool
    var children: [FileNode]?
}

/// Single window, custom Obsidian-style tab strip: ordered documents, one
/// selected. (Native NSWindow tabs were tried first — the system bar can't do
/// min/max-width tabs, inline rename, or custom titles; see eng-design §14.)
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    /// Auto-updater (Sparkle-backed). Drives the update pill; dormant on
    /// unconfigured dev builds. Started once from the app delegate.
    let updater = UpdateController()

    @Published private(set) var documents: [DocumentModel] = []
    @Published var selectedID: UUID?
    @Published var rootFolder: FileNode?

    @Published var showFileSidebar = true
    @Published var focusMode = false
    @Published var zoom: CGFloat = 1.0 { didSet { applyZoom() } }
    /// Window content width — drives how many tabs fit before overflow.
    @Published var contentWidth: CGFloat = 900

    /// URLs from Finder / the CLI that arrived before the window existed.
    var pendingURLs: [URL] = []

    var activeDocument: DocumentModel? {
        documents.first { $0.id == selectedID }
    }

    private func applyZoom() {
        for doc in documents { doc.controller.zoom = zoom }
    }

    // MARK: Tabs

    func document(for id: UUID?) -> DocumentModel? {
        documents.first { $0.id == id }
    }

    @discardableResult
    func newDocument(select: Bool = true) -> DocumentModel {
        let doc = DocumentModel(untitled: "")
        register(doc)
        documents.append(doc)
        if select { selectedID = doc.id }
        return doc
    }

    private func register(_ doc: DocumentModel) {
        doc.controller.zoom = zoom
        doc.openLinkHandler = { [weak self] target, anchor in
            guard let self, let opened = self.requestOpen(target) else { return }
            if let anchor {
                if opened.toc.isEmpty { opened.pendingAnchor = anchor }
                else { opened.scrollToAnchor(anchor) }
            }
        }
    }

    /// Close a tab, prompting for unsaved changes first. Keeps at least one
    /// tab alive (a fresh untitled buffer when the last one closes).
    func closeTab(_ id: UUID) {
        guard let doc = document(for: id) else { return }
        _ = close(doc)
        if documents.isEmpty { newDocument() }
    }

    /// Close every tab except `id`; stops if the user cancels a save prompt.
    func closeOtherTabs(keeping id: UUID) {
        for doc in documents where doc.id != id {
            guard close(doc) else { return }
        }
        selectedID = id
    }

    /// Close all tabs after `id` (left-to-right order); stops on cancel.
    func closeTabsToTheRight(of id: UUID) {
        guard let idx = documents.firstIndex(where: { $0.id == id }) else { return }
        for doc in Array(documents.dropFirst(idx + 1)) {
            guard close(doc) else { return }
        }
        if document(for: selectedID) == nil { selectedID = id }
    }

    /// Prompt-close a single tab. Returns false when the user cancelled.
    private func close(_ doc: DocumentModel) -> Bool {
        guard confirmDiscardIfNeeded(doc) else { return false }
        doc.flushPendingSave()
        if doc.isDirty, doc.url != nil { doc.saveNow() }
        guard let idx = documents.firstIndex(where: { $0.id == doc.id }) else { return true }
        documents.remove(at: idx)
        if selectedID == doc.id {
            selectedID = documents.indices.contains(idx) ? documents[idx].id : documents.last?.id
        }
        return true
    }

    /// Save-changes prompt when closing would lose work. Returns true when
    /// it's OK to proceed.
    func confirmDiscardIfNeeded(_ doc: DocumentModel) -> Bool {
        let needsPrompt: Bool
        if doc.url == nil {
            needsPrompt = !doc.source.isEmpty
        } else {
            needsPrompt = doc.isDirty && !Preferences.shared.autoSave
        }
        guard needsPrompt else { return true }

        selectedID = doc.id // show what's being asked about
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Save changes to “\(doc.displayTitle)”?"
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            if doc.url == nil {
                let panel = NSSavePanel()
                panel.nameFieldStringValue = "\(doc.displayTitle).md"
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

    /// Rename a tab (inline rename / context menu); shows an alert on failure.
    func rename(_ doc: DocumentModel, to name: String) {
        if let message = doc.rename(to: name) {
            let alert = NSAlert()
            alert.messageText = "Couldn't rename"
            alert.informativeText = message
            alert.runModal()
            return
        }
        if let root = rootFolder { openFolder(root.url) } // refresh sidebar
    }

    // MARK: Opening

    /// Open a URL in a tab — focusing it if already open, adopting a pristine
    /// untitled tab if one is selected, else appending a new tab.
    @discardableResult
    func requestOpen(_ url: URL) -> DocumentModel? {
        if let existing = documents.first(where: { $0.url == url }) {
            selectedID = existing.id
            return existing
        }
        if let pristine = documents.first(where: { $0.url == nil && $0.source.isEmpty }) {
            pristine.adopt(url)
            Preferences.shared.addRecent(url)
            selectedID = pristine.id
            return pristine
        }
        do {
            let doc = try DocumentModel(url: url)
            register(doc)
            documents.append(doc)
            selectedID = doc.id
            Preferences.shared.addRecent(url)
            return doc
        } catch {
            NSLog("Vireo open failed: \(error)")
            return nil
        }
    }

    /// ⌘N: create a real `.md` on disk — in the active document's folder, else
    /// the opened sidebar folder, else wherever the user picks — and open it.
    func createNewFile() {
        let folder = activeDocument?.url?.deletingLastPathComponent() ?? rootFolder?.url
        if let folder {
            let url = availableUntitledURL(in: folder)
            do {
                try FileService.save("", to: url)
            } catch {
                let alert = NSAlert()
                alert.messageText = "Couldn't create “\(url.lastPathComponent)”"
                alert.informativeText = error.localizedDescription
                alert.runModal()
                return
            }
            if let root = rootFolder { openFolder(root.url) } // refresh sidebar
            Preferences.shared.addRecent(url)
            requestOpen(url)
        } else {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "Untitled.md"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try? FileService.save("", to: url)
            Preferences.shared.addRecent(url)
            requestOpen(url)
        }
    }

    /// First free "Untitled.md" / "Untitled 2.md" / … in `folder`.
    private func availableUntitledURL(in folder: URL) -> URL {
        var candidate = folder.appendingPathComponent("Untitled.md")
        var i = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("Untitled \(i).md")
            i += 1
        }
        return candidate
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
        panel.nameFieldStringValue = doc.title.hasSuffix(".md") ? doc.title : doc.displayTitle + ".md"
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
