import SwiftUI

/// Left panel: a tree of the active tab's containing folder — subfolders and
/// markdown files only (the app can't open anything else). Re-roots to the new
/// document's folder whenever the active tab changes.
struct FileSidebar: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let root = state.rootFolder {
                HStack(spacing: 6) {
                    Image(systemName: "folder")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(root.name)
                        .font(.caption).bold()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

                List {
                    OutlineGroup(root.children ?? [], children: \.children) { node in
                        FileRow(node: node)
                    }
                }
                .listStyle(.sidebar)
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
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
    @EnvironmentObject private var state: AppState

    var body: some View {
        if node.isDirectory {
            Label(node.name, systemImage: "folder")
                .font(.callout)
        } else {
            Label(node.name, systemImage: "doc.text")
                .font(.callout)
                .foregroundStyle(state.activeDocument?.url == node.url ? Color.accentColor : .primary)
                .contentShape(Rectangle())
                .onTapGesture { state.requestOpen(node.url) }
        }
    }
}
