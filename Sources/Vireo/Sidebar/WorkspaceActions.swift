import AppKit
import VireoCore

/// What the sidebar can do to files: the single write path for renames and
/// moves, plus create, duplicate, delete and the Finder / Terminal hand-offs.
/// Every mutation rewrites open tabs and sidebar state, then refreshes the tree.
extension AppState {
    enum SidebarEntryKind { case file, folder }

    enum MoveOutcome {
        case moved, skipped, exists, failed(String)
    }

    // MARK: Rename / move

    /// Rename or move `node` to `newURL` on disk and keep every reference to it
    /// (open tabs, expansion, pins, selection) pointing at the new location.
    func applyPathChange(_ node: FileNode, to newURL: URL) throws {
        try FileManager.default.moveItem(at: node.url, to: newURL)
        for doc in documents {
            guard let url = doc.url else { continue }
            if url == node.url {
                doc.relocate(to: newURL)
            } else if node.isDirectory, SidebarTree.isDescendant(url, of: node.url) {
                let suffix = String(url.path.dropFirst(node.url.path.count))
                doc.relocate(to: URL(fileURLWithPath: newURL.path + suffix).standardizedFileURL)
            }
        }
        sidebar.rewrite(from: node.url, to: newURL)
        refreshFileTree()
    }

    /// Inline rename: files take a new stem (the extension stays), folders a new name.
    func renameSidebarEntry(_ node: FileNode, to rawValue: String) {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        let parent = SidebarTree.parent(of: node.url)
        let newURL: URL
        let conflictMessage: String
        if node.isDirectory {
            guard value != node.name else { return }
            newURL = parent.appendingPathComponent(value, isDirectory: true)
            conflictMessage = "A folder named “\(value)” already exists."
        } else {
            guard value != node.stem else { return }
            let ext = (node.name as NSString).pathExtension
            let fileName = ext.isEmpty ? value : "\(value).\(ext)"
            newURL = parent.appendingPathComponent(fileName)
            conflictMessage = "A file named “\(fileName)” already exists."
        }
        guard newURL.standardizedFileURL != node.url else { return }
        if FileManager.default.fileExists(atPath: newURL.path) {
            presentSidebarError(conflictMessage)
            return
        }
        do {
            try applyPathChange(node, to: newURL.standardizedFileURL)
        } catch {
            presentSidebarError("Failed to rename: \(error.localizedDescription)")
        }
    }

    /// Move `node` into `destination`, keeping its name.
    func moveSidebarEntry(_ node: FileNode, into destination: URL) -> MoveOutcome {
        guard SidebarTree.canMoveInto(node.url, isDirectory: node.isDirectory, dest: destination) else {
            return .skipped
        }
        let newURL = destination.appendingPathComponent(node.name, isDirectory: node.isDirectory)
            .standardizedFileURL
        if FileManager.default.fileExists(atPath: newURL.path) { return .exists }
        do {
            try applyPathChange(node, to: newURL)
            return .moved
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Drop a batch of entries into `destination`, then reveal the folder and
    /// summarise anything that could not move.
    func moveSidebarEntries(_ nodes: [FileNode], into destination: URL) {
        var failures: [String] = []
        for node in nodes {
            switch moveSidebarEntry(node, into: destination) {
            case .moved, .skipped:
                break
            case .exists:
                failures.append("• “\(node.name)” — an item with that name already exists")
            case .failed(let message):
                failures.append("• “\(node.name)” — \(message)")
            }
        }
        sidebar.clearSelection()
        if let root = workspaceRoot, destination.path != root.path {
            sidebar.expand(destination)
        }
        if !failures.isEmpty {
            presentSidebarError("Couldn’t move \(failures.count) item\(failures.count > 1 ? "s" : ""):\n"
                                + failures.joined(separator: "\n"))
        }
    }

    // MARK: Create

    /// Create "Untitled.md" / "Untitled Folder" (numbered when taken) inside
    /// `parent`, expand it, and start an inline rename on the new entry.
    func createSidebarEntry(_ kind: SidebarEntryKind, in parent: URL) {
        let url = Self.availableSidebarURL(kind, in: parent)
        do {
            switch kind {
            case .file:
                try FileService.save("", to: url)
            case .folder:
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            }
        } catch {
            presentSidebarError("Failed to create \(kind == .file ? "file" : "folder"): \(error.localizedDescription)")
            return
        }
        if let root = workspaceRoot, parent.path != root.path {
            sidebar.expand(parent)
        }
        sidebar.everythingCollapsed = false
        if kind == .file { Preferences.shared.addRecent(url) }
        refreshFileTree { [weak self] in
            self?.sidebar.renaming = url
        }
    }

    static func availableSidebarURL(_ kind: SidebarEntryKind, in folder: URL) -> URL {
        let manager = FileManager.default
        var index = 1
        while true {
            let name: String
            switch kind {
            case .file: name = index == 1 ? "Untitled.md" : "Untitled \(index).md"
            case .folder: name = index == 1 ? "Untitled Folder" : "Untitled Folder \(index)"
            }
            let candidate = folder.appendingPathComponent(name, isDirectory: kind == .folder)
                .standardizedFileURL
            if !manager.fileExists(atPath: candidate.path) { return candidate }
            index += 1
        }
    }

    // MARK: Duplicate

    /// "note copy.md", "note copy 2.md", … next to the original. An open,
    /// unsaved document duplicates what is on screen, not what is on disk.
    func duplicateSidebarEntry(_ node: FileNode) {
        let parent = SidebarTree.parent(of: node.url)
        let ext = (node.name as NSString).pathExtension
        func candidate(_ n: Int) -> URL {
            let stem = n == 1 ? "\(node.stem) copy" : "\(node.stem) copy \(n)"
            return parent.appendingPathComponent(ext.isEmpty ? stem : "\(stem).\(ext)").standardizedFileURL
        }
        var n = 1
        var target = candidate(n)
        while FileManager.default.fileExists(atPath: target.path) {
            n += 1
            target = candidate(n)
        }
        do {
            if let open = documents.first(where: { $0.url == node.url }), open.isDirty {
                try FileService.save(open.source, to: target)
            } else {
                try FileManager.default.copyItem(at: node.url, to: target)
            }
        } catch {
            presentSidebarError("Failed to duplicate: \(error.localizedDescription)")
            return
        }
        refreshFileTree()
        requestOpen(target)
    }

    // MARK: Delete

    /// Move `nodes` to the Trash. Open tabs close without a save prompt once
    /// the user has confirmed; only unsaved edits ask first.
    func deleteSidebarEntries(_ nodes: [FileNode]) {
        guard !nodes.isEmpty else { return }
        let dirtyCount = nodes.reduce(0) { count, node in
            count + documents.filter { doc in
                guard let url = doc.url, doc.isDirty else { return false }
                return url == node.url || (node.isDirectory && SidebarTree.isDescendant(url, of: node.url))
            }.count
        }
        let question: String?
        if nodes.count == 1, let node = nodes.first {
            if dirtyCount == 0 {
                question = nil
            } else if node.isDirectory {
                question = "“\(node.name)” contains \(dirtyCount) unsaved file\(dirtyCount > 1 ? "s" : ""). Delete anyway?"
            } else {
                question = "“\(node.name)” has unsaved changes. Delete anyway?"
            }
        } else if dirtyCount > 0 {
            question = "\(dirtyCount) of \(nodes.count) selected items have unsaved changes. Delete anyway?"
        } else {
            question = "Delete \(nodes.count) items?"
        }
        if let question, !confirmSidebarAction(question, button: "Delete") { return }

        for node in nodes {
            for doc in documents {
                guard let url = doc.url else { continue }
                if url == node.url || (node.isDirectory && SidebarTree.isDescendant(url, of: node.url)) {
                    discard(doc)
                }
            }
            do {
                try FileManager.default.trashItem(at: node.url, resultingItemURL: nil)
            } catch {
                presentSidebarError("Failed to delete “\(node.name)”: \(error.localizedDescription)")
            }
            sidebar.forget(node.url)
        }
        sidebar.clearSelection()
        refreshFileTree()
    }

    // MARK: Hand-offs

    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Open the folder itself in a Finder window (used for the workspace root).
    func openInFinder(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    func openInTerminal(_ directory: URL) {
        let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open([directory], withApplicationAt: terminal,
                                configuration: configuration) { [weak self] _, error in
            guard let error else { return }
            Task { @MainActor in
                self?.presentSidebarError("Failed to open terminal: \(error.localizedDescription)")
            }
        }
    }

    func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Path relative to the workspace root, or the full path outside it.
    func relativePath(_ url: URL) -> String {
        guard let root = workspaceRoot, SidebarTree.isDescendant(url, of: root) else { return url.path }
        return String(url.path.dropFirst(root.path.count + 1))
    }

    /// Rename through a dialog (for rows outside the tree, such as Pinned).
    func promptRename(_ node: FileNode) {
        let alert = NSAlert()
        alert.messageText = node.isDirectory ? "Rename folder" : "Rename file"
        let field = NSTextField(string: node.isDirectory ? node.name : node.stem)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        renameSidebarEntry(node, to: field.stringValue)
    }

    // MARK: Alerts

    func presentSidebarError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.runModal()
    }

    private func confirmSidebarAction(_ message: String, button: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
