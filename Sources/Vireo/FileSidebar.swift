import SwiftUI
import AppKit

/// Left panel: a tree of the active tab's containing folder — subfolders and
/// markdown files only (the app can't open anything else). Re-roots to the new
/// document's folder whenever the active tab changes.
///
/// Styled like a native Finder sidebar: `.behindWindow` vibrancy so the desktop
/// blurs through ("liquid glass"), an uppercased section header, and native
/// rounded selection pills.
struct FileSidebar: View {
    @EnvironmentObject private var state: AppState
    @State private var selection: URL?

    var body: some View {
        Group {
            if let root = state.rootFolder {
                List(selection: $selection) {
                    Section(root.name) {
                        OutlineGroup(root.children ?? [], children: \.children) { node in
                            FileRow(node: node).tag(node.url)
                        }
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden) // let the vibrancy show through
                .environment(\.defaultMinListRowHeight, 30)
                .onChange(of: selection) { _, url in openIfFile(url) }
                .onChange(of: state.activeDocument?.url) { _, url in selection = url }
                .onAppear { selection = state.activeDocument?.url }
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SidebarVibrancy())
    }

    /// A file selection opens it; a folder selection just expands/highlights —
    /// snap the pill back to the active file so it never looks "lost".
    private func openIfFile(_ url: URL?) {
        guard let url else { return }
        let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? url.hasDirectoryPath
        if isDir {
            if selection != state.activeDocument?.url { selection = state.activeDocument?.url }
        } else if url != state.activeDocument?.url {
            state.requestOpen(url)
        }
    }

    /// Shown when the active document is untitled (has no folder to browse).
    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "folder")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.tertiary)
            Text("No folder")
                .font(.callout).bold()
                .foregroundStyle(.secondary)
            Text("Save this document to browse the files alongside it.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct FileRow: View {
    let node: FileNode

    var body: some View {
        Label(node.name, systemImage: node.isDirectory ? "folder" : "doc.text")
            .font(.system(size: 13))
            .lineLimit(1)
            .truncationMode(.middle)
    }
}

/// A `.behindWindow` sidebar-material blur — the native Finder-sidebar backdrop
/// that samples and blurs the desktop behind the window.
private struct SidebarVibrancy: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        view.isEmphasized = true
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = .sidebar
        view.blendingMode = .behindWindow
    }
}
