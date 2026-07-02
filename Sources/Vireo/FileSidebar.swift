import SwiftUI

struct FileSidebar: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let root = state.rootFolder {
                HStack {
                    Text(root.name)
                        .font(.caption).bold()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                List {
                    OutlineGroup(root.children ?? [], children: \.children) { node in
                        FileRow(node: node)
                    }
                }
                .listStyle(.sidebar)
            }
        }
        .frame(maxHeight: .infinity)
        .background(.regularMaterial)
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
