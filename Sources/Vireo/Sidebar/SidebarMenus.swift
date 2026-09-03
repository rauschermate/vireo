import SwiftUI
import VireoCore

/// Context menu for a file row.
struct FileRowMenu: View {
    @ObservedObject var state: AppState
    @ObservedObject var model: SidebarModel
    let node: FileNode
    /// Rows in the tree rename inline; flat rows (Pinned, Recents) use a prompt.
    var inlineRename = true

    var body: some View {
        Button("Open") { state.requestOpen(node.url) }
        Button(model.isPinned(node.url) ? "Unpin" : "Pin") { model.togglePin(node.url) }
        Divider()
        Button("Duplicate") { state.duplicateSidebarEntry(node) }
        Divider()
        Button("Copy relative path") { state.copyToPasteboard(state.relativePath(node.url)) }
        Button("Copy absolute path") { state.copyToPasteboard(node.url.path) }
        Divider()
        Button("Reveal in Finder") { state.revealInFinder(node.url) }
        Divider()
        Button("Rename...") {
            if inlineRename { model.beginRename(node.url) } else { state.promptRename(node) }
        }
        Button("Delete") { state.deleteSidebarEntries([node]) }
    }
}

/// Context menu for a folder row.
struct FolderRowMenu: View {
    @ObservedObject var state: AppState
    @ObservedObject var model: SidebarModel
    let node: FileNode

    var body: some View {
        Button("New File") { state.createSidebarEntry(.file, in: node.url) }
        Button("New Folder") { state.createSidebarEntry(.folder, in: node.url) }
        Divider()
        Button("Copy relative path") { state.copyToPasteboard(state.relativePath(node.url)) }
        Button("Copy absolute path") { state.copyToPasteboard(node.url.path) }
        Divider()
        Button("Open in Terminal") { state.openInTerminal(node.url) }
        Button("Reveal in Finder") { state.revealInFinder(node.url) }
        Divider()
        Button("Rename...") { model.beginRename(node.url) }
        Button("Delete") { state.deleteSidebarEntries([node]) }
    }
}

/// Context menu when several rows are selected.
struct BulkRowMenu: View {
    @ObservedObject var state: AppState
    let nodes: [FileNode]

    var body: some View {
        let count = nodes.count
        Button("Copy \(count) relative paths") {
            state.copyToPasteboard(nodes.map { state.relativePath($0.url) }.joined(separator: "\n"))
        }
        Button("Copy \(count) absolute paths") {
            state.copyToPasteboard(nodes.map(\.url.path).joined(separator: "\n"))
        }
        Divider()
        Button("Delete \(count) items") { state.deleteSidebarEntries(nodes) }
    }
}

/// Context menu on empty sidebar space and section headers: workspace-root
/// actions plus the Search / Recents visibility checks.
struct SidebarSurfaceMenu: View {
    @ObservedObject var state: AppState
    @ObservedObject var prefs: Preferences

    var body: some View {
        if let root = state.workspaceRoot {
            Button("New File") { state.createSidebarEntry(.file, in: root) }
            Button("New Folder") { state.createSidebarEntry(.folder, in: root) }
            Divider()
            Button("Open in Terminal") { state.openInTerminal(root) }
            Button("Open in Finder") { state.openInFinder(root) }
            Divider()
        }
        Toggle("Search", isOn: $prefs.sidebarShowSearch)
        Toggle("Recents", isOn: $prefs.sidebarShowRecents)
    }
}
