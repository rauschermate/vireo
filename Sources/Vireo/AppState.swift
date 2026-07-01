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

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var documents: [DocumentModel] = []
    @Published var selectedID: DocumentModel.ID?
    @Published var rootFolder: FileNode?

    @Published var showFileSidebar = true
    @Published var showTOC = true
    @Published var focusMode = false
    @Published var zoom: CGFloat = 1.0 { didSet { applyZoom() } }

    var selected: DocumentModel? {
        documents.first { $0.id == selectedID }
    }

    private func applyZoom() {
        for doc in documents { doc.controller.zoom = zoom }
    }

    // MARK: Documents

    func newDocument() {
        let doc = DocumentModel(untitled: "")
        wire(doc)
        documents.append(doc)
        selectedID = doc.id
    }

    @discardableResult
    func openFile(_ url: URL) -> DocumentModel? {
        if let existing = documents.first(where: { $0.url == url }) {
            selectedID = existing.id
            return existing
        }
        do {
            let doc = try DocumentModel(url: url)
            wire(doc)
            documents.append(doc)
            selectedID = doc.id
            doc.controller.zoom = zoom
            Preferences.shared.addRecent(url)
            return doc
        } catch {
            NSLog("Vireo open failed: \(error)")
            return nil
        }
    }

    private func wire(_ doc: DocumentModel) {
        doc.openLinkHandler = { [weak self] target in _ = self?.openFile(target) }
    }

    func closeDocument(_ id: DocumentModel.ID) {
        guard let idx = documents.firstIndex(where: { $0.id == id }) else { return }
        let doc = documents[idx]
        if doc.isDirty, doc.url != nil { doc.saveNow() }
        documents.remove(at: idx)
        if selectedID == id {
            selectedID = documents.indices.contains(idx) ? documents[idx].id : documents.last?.id
        }
    }

    // MARK: Panels

    func openFilePanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = markdownTypes()
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            for url in panel.urls { _ = openFile(url) }
        }
    }

    func openFolderPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        if panel.runModal() == .OK, let url = panel.url {
            openFolder(url)
        }
    }

    func openFolder(_ url: URL) {
        rootFolder = buildTree(url)
        showFileSidebar = true
    }

    func saveAsPanel() {
        guard let doc = selected else { return }
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
