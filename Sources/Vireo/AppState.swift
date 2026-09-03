import AppKit
import SwiftUI
import UniformTypeIdentifiers
import MarkdownRender
import VireoCore
import VireoUpdater

extension EditorFontOption {
    var themeFamily: Theme.FontFamily {
        switch self {
        case .sans: return .sans
        case .mono: return .mono
        }
    }
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

    /// The folder the sidebar browses. Explicit, like an editor workspace: it
    /// changes only when the user opens a folder, never when tabs switch.
    @Published private(set) var workspaceRoot: URL?
    @Published var rootFolder: FileNode?
    @Published private(set) var isLoadingFileTree = false
    @Published private(set) var fileTreeError: String?

    /// Transient sidebar state (expansion, selection, pins, drag).
    let sidebar = SidebarModel()

    @Published var showFileSidebar: Bool {
        didSet { Preferences.shared.sidebarVisible = showFileSidebar }
    }
    /// Width of the file panel; the tab strip insets itself past it.
    @Published var sidebarWidth: CGFloat {
        didSet { Preferences.shared.sidebarWidth = Double(sidebarWidth) }
    }
    @Published var focusMode = false
    @Published var zoom: CGFloat = 1.0 { didSet { applyZoom() } }
    /// Window content width — drives how many tabs fit before overflow.
    @Published var contentWidth: CGFloat = 900

    /// URLs from Finder / the CLI that arrived before the window existed.
    var pendingURLs: [URL] = []

    private let fileTreeService = FileTreeService()
    private var fileTreeTask: Task<Void, Never>?
    private var fileTreeGeneration = 0
    private var workspaceWatcher: WorkspaceWatcher?

    init() {
        let prefs = Preferences.shared
        showFileSidebar = prefs.sidebarVisible
        sidebarWidth = CGFloat(prefs.sidebarWidth)
    }

    var activeDocument: DocumentModel? {
        documents.first { $0.id == selectedID }
    }

    /// How far the tab strip slides right to clear the sidebar. The toggle
    /// button stays put beside the traffic lights (its box ends 126pt into
    /// the window, plus the strip's 6pt gap), so the strip starts 12pt past
    /// the sidebar's right edge.
    var tabStripInset: CGFloat {
        showFileSidebar && !focusMode ? max(0, sidebarWidth - 120) : 0
    }

    private func applyZoom() {
        for doc in documents { doc.controller.zoom = zoom }
    }

    func applyEditorFont() {
        let family = Preferences.shared.editorFont.themeFamily
        for doc in documents { doc.controller.fontFamily = family }
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
        doc.controller.fontFamily = Preferences.shared.editorFont.themeFamily
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
        remove(doc)
        return true
    }

    /// Close a tab with no save prompt — its file is being deleted.
    func discard(_ doc: DocumentModel) {
        remove(doc)
        if documents.isEmpty { newDocument() }
    }

    private func remove(_ doc: DocumentModel) {
        guard let idx = documents.firstIndex(where: { $0.id == doc.id }) else { return }
        documents.remove(at: idx)
        if selectedID == doc.id {
            selectedID = documents.indices.contains(idx) ? documents[idx].id : documents.last?.id
        }
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
        let oldURL = doc.url
        if let message = doc.rename(to: name) {
            let alert = NSAlert()
            alert.messageText = "Couldn't rename"
            alert.informativeText = message
            alert.runModal()
            return
        }
        if let oldURL, let newURL = doc.url, oldURL != newURL {
            sidebar.rewrite(from: oldURL, to: newURL)
        }
        refreshFileTree()
    }

    /// What a sidebar row shows for `node`: folders their name; files the
    /// document title (live for open tabs) or, by preference, the file name.
    func sidebarLabel(for node: FileNode) -> String {
        if node.isDirectory { return node.name }
        if Preferences.shared.sidebarFileLabel == .filename { return node.stem }
        if let open = documents.first(where: { $0.url == node.url }),
           let first = open.toc.first, first.level == 1,
           !first.title.isEmpty {
            return first.title
        }
        if let title = node.title, !title.isEmpty { return title }
        return node.stem
    }

    // MARK: Opening

    /// Open a URL in a tab — focusing it if already open, adopting a pristine
    /// untitled tab if one is selected, else appending a new tab. With no
    /// workspace open yet, the file's folder becomes the workspace.
    @discardableResult
    func requestOpen(_ url: URL) -> DocumentModel? {
        let url = url.standardizedFileURL
        defer {
            if workspaceRoot == nil, documents.contains(where: { $0.url == url }) {
                openWorkspace(url.deletingLastPathComponent(), revealSidebar: false)
            }
        }
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
    /// the workspace root, else wherever the user picks — and open it.
    func createNewFile() {
        let folder = activeDocument?.url?.deletingLastPathComponent() ?? workspaceRoot
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
            refreshFileTree()
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
            if isDirectory(url) { openWorkspace(url) } else { requestOpen(url) }
        }
    }

    /// File ▸ Open Folder…: pick a workspace for the sidebar.
    func openFolderPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        panel.message = "Choose a folder to browse in the sidebar."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openWorkspace(url)
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? url.hasDirectoryPath
    }

    // MARK: Workspace / file sidebar

    /// Toggle the left file panel.
    func toggleFileSidebar() {
        showFileSidebar.toggle()
        if showFileSidebar, rootFolder == nil { refreshFileTree() }
    }

    /// Browse `url` in the sidebar. Remembered across launches and listed in the
    /// workspace switcher.
    func openWorkspace(_ url: URL, revealSidebar: Bool = true) {
        let root = url.standardizedFileURL
        let prefs = Preferences.shared
        if workspaceRoot != root {
            workspaceRoot = root
            sidebar.reset(for: root, pinned: prefs.pinnedFiles(for: root))
            rootFolder = nil
            workspaceWatcher?.stop()
            workspaceWatcher = WorkspaceWatcher(root: root) { [weak self] in
                Task { @MainActor in self?.refreshFileTree() }
            }
        }
        prefs.addRecentWorkspace(root)
        prefs.lastWorkspace = root
        if revealSidebar { showFileSidebar = true }
        loadFileTree(root)
    }

    func closeWorkspace() {
        workspaceWatcher?.stop()
        workspaceWatcher = nil
        fileTreeTask?.cancel()
        fileTreeTask = nil
        fileTreeGeneration += 1
        workspaceRoot = nil
        rootFolder = nil
        isLoadingFileTree = false
        fileTreeError = nil
        sidebar.reset(for: nil, pinned: [])
        Preferences.shared.lastWorkspace = nil
    }

    /// Rebuild the tree for the current workspace (after a file change on
    /// disk or a sidebar action). `completion` runs once the new tree is in.
    func refreshFileTree(completion: (() -> Void)? = nil) {
        guard let root = workspaceRoot else { completion?(); return }
        loadFileTree(root, completion: completion)
    }

    /// Tab context menu → "Reveal in Sidebar": show the panel, expand every
    /// folder down to the file, and scroll its row into view. A file outside
    /// the workspace is left alone, like the reference.
    func revealInSidebar(_ url: URL) {
        let url = url.standardizedFileURL
        if !showFileSidebar { showFileSidebar = true }
        guard let root = workspaceRoot, SidebarTree.isDescendant(url, of: root) else { return }
        sidebar.everythingCollapsed = false
        for ancestor in SidebarTree.ancestors(of: url, below: root) {
            sidebar.expand(ancestor)
        }
        sidebar.revealTarget = url
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

    private func loadFileTree(_ url: URL, completion: (() -> Void)? = nil) {
        fileTreeTask?.cancel()
        fileTreeGeneration += 1
        let generation = fileTreeGeneration
        let normalizedURL = url.standardizedFileURL
        if rootFolder?.url != normalizedURL { rootFolder = nil }
        isLoadingFileTree = true
        fileTreeError = nil

        let service = fileTreeService
        fileTreeTask = Task { [weak self] in
            let worker = Task.detached(priority: .userInitiated) {
                try service.buildTree(at: normalizedURL)
            }
            let result: Result<FileNode, Error>
            do {
                let root = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }
                result = .success(root)
            } catch {
                result = .failure(error)
            }

            guard let self, self.fileTreeGeneration == generation else { return }
            self.fileTreeTask = nil
            self.isLoadingFileTree = false
            switch result {
            case .success(let root):
                self.rootFolder = root
                completion?()
            case .failure(let error) where error is CancellationError:
                break
            case .failure(let error):
                self.fileTreeError = error.localizedDescription
                NSLog("Vireo file tree failed: \(error)")
            }
        }
    }
}
