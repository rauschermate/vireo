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

    /// Width of the file panel — shared so the tab strip can inset itself past
    /// the full-height sidebar.
    static let sidebarWidth: CGFloat = 260

    /// Auto-updater (Sparkle-backed). Drives the update pill; dormant on
    /// unconfigured dev builds. Started once from the app delegate.
    let updater = UpdateController()

    @Published private(set) var documents: [DocumentModel] = []
    @Published var selectedID: UUID?
    @Published var rootFolder: FileNode?

    /// The last folder the user explicitly opened — used as a fallback root
    /// when the active tab is untitled (has no containing folder to follow).
    @Published var pinnedFolder: URL?

    @Published var showFileSidebar = false
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
        doc.onSaveFailure = { [weak self, weak doc] message in
            guard let self, let doc else { return }
            self.presentSaveFailure(message, for: doc)
        }
        doc.onSaveConflict = { [weak self, weak doc] conflict in
            guard let self, let doc else { return }
            self.presentSaveConflict(conflict, for: doc)
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
        guard prepareToClose(doc) else { return false }
        guard let idx = documents.firstIndex(where: { $0.id == doc.id }) else { return true }
        documents.remove(at: idx)
        if selectedID == doc.id {
            selectedID = documents.indices.contains(idx) ? documents[idx].id : documents.last?.id
        }
        return true
    }

    /// Save-changes prompt when closing would lose work. Returns true when
    /// it's OK to proceed.
    func prepareToClose(_ doc: DocumentModel) -> Bool {
        if doc.url != nil, doc.isDirty, doc.autoSaveEnabled {
            return handleCloseSaveResult(doc.saveSynchronously(notifyFailure: false), for: doc)
        }
        return confirmDiscardIfNeeded(doc)
    }

    func confirmDiscardIfNeeded(_ doc: DocumentModel) -> Bool {
        let needsPrompt: Bool
        if doc.url == nil {
            needsPrompt = !doc.source.isEmpty
        } else {
            needsPrompt = doc.isDirty
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
                guard doc.save(to: saveURL) else { return false }
                Preferences.shared.addRecent(saveURL)
            } else {
                return handleCloseSaveResult(doc.saveSynchronously(notifyFailure: false), for: doc)
            }
            return true
        case .alertSecondButtonReturn:
            return true
        default:
            return false
        }
    }

    private func handleCloseSaveResult(_ result: DocumentWriteResult,
                                       for doc: DocumentModel) -> Bool {
        switch result {
        case .success:
            return true
        case .conflict(let disk):
            let conflict = DocumentConflict(url: doc.url ?? URL(fileURLWithPath: ""), disk: disk)
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "“\(conflict.url.lastPathComponent)” changed on disk"
            alert.informativeText = "Vireo did not overwrite the newer disk version. Keep your edits, reload the disk version, or cancel closing."
            alert.addButton(withTitle: "Keep Mine")
            alert.addButton(withTitle: "Reload Disk")
            alert.addButton(withTitle: "Cancel")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                doc.acceptConflictForSynchronousOverwrite(conflict)
                return handleCloseSaveResult(doc.saveSynchronously(notifyFailure: false), for: doc)
            case .alertSecondButtonReturn:
                doc.resolveConflict(.reloadDisk, conflict: conflict)
                return true
            default:
                return false
            }
        case .failure(let message):
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "Couldn't save “\(doc.displayTitle)”"
            alert.informativeText = "\(message) Your edits are still in Vireo."
            alert.addButton(withTitle: "Try Again")
            alert.addButton(withTitle: "Close Without Saving")
            alert.addButton(withTitle: "Cancel")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                return handleCloseSaveResult(doc.saveSynchronously(notifyFailure: false), for: doc)
            case .alertSecondButtonReturn:
                return true
            default:
                return false
            }
        }
    }

    private func presentSaveFailure(_ message: String, for doc: DocumentModel) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Couldn't auto-save “\(doc.displayTitle)”"
        alert.informativeText = "\(message) Your edits are still open and marked unsaved."
        alert.addButton(withTitle: "Try Again")
        alert.addButton(withTitle: "OK")
        let retry: (NSApplication.ModalResponse) -> Void = { response in
            if response == .alertFirstButtonReturn { doc.saveNow() }
        }
        if let window = NSApp.keyWindow, window.attachedSheet == nil {
            alert.beginSheetModal(for: window, completionHandler: retry)
        } else {
            retry(alert.runModal())
        }
    }

    private func presentSaveConflict(_ conflict: DocumentConflict, for doc: DocumentModel) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "“\(conflict.url.lastPathComponent)” changed on disk"
        alert.informativeText = "Vireo kept your unsaved edits and did not overwrite the newer disk version."
        alert.addButton(withTitle: "Keep Mine")
        alert.addButton(withTitle: "Reload Disk")
        alert.addButton(withTitle: "Cancel")
        let resolve: (NSApplication.ModalResponse) -> Void = { response in
            if response == .alertFirstButtonReturn {
                doc.resolveConflict(.keepMine, conflict: conflict)
            } else if response == .alertSecondButtonReturn {
                doc.resolveConflict(.reloadDisk, conflict: conflict)
            } else {
                doc.resolveConflict(.cancel, conflict: conflict)
            }
        }
        if let window = NSApp.keyWindow, window.attachedSheet == nil {
            alert.beginSheetModal(for: window, completionHandler: resolve)
        } else {
            resolve(alert.runModal())
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
        if showFileSidebar { refreshFileTree() } // refresh sidebar
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
        let folder = activeDocument?.url?.deletingLastPathComponent() ?? pinnedFolder
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
            if showFileSidebar { refreshFileTree() } // refresh sidebar
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

    /// ⌘O: open markdown files as tabs, or a folder to browse in the sidebar.
    func openFilePanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = markdownTypes()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.prompt = "Open"
        panel.message = "Open markdown files, or choose a folder to browse."
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if isDirectory(url) { openFolder(url) } else { requestOpen(url) }
        }
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? url.hasDirectoryPath
    }

    // MARK: File sidebar

    /// Toggle the left file panel. When opening, (re)build the tree from the
    /// active document's containing folder.
    func toggleFileSidebar() {
        showFileSidebar.toggle()
        if showFileSidebar { refreshFileTree() }
    }

    /// Rebuild the sidebar tree so it follows the active tab: root at the active
    /// document's containing folder, falling back to the last opened folder when
    /// the tab is untitled. `nil` when there's nothing to browse (empty state).
    func refreshFileTree() {
        if let folder = activeDocument?.url?.deletingLastPathComponent() ?? pinnedFolder {
            rootFolder = buildTree(folder)
        } else {
            rootFolder = nil
        }
    }

    /// Open a folder in the sidebar: reveal the panel and show its markdown-only
    /// tree now. It's remembered as the fallback root; from here the sidebar
    /// follows the active tab.
    func openFolder(_ url: URL) {
        pinnedFolder = url
        showFileSidebar = true
        rootFolder = buildTree(url)
    }

    func saveActiveAs() {
        guard let doc = activeDocument else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = doc.title.hasSuffix(".md") ? doc.title : doc.displayTitle + ".md"
        if panel.runModal() == .OK, let url = panel.url {
            if doc.save(to: url) { Preferences.shared.addRecent(url) }
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
