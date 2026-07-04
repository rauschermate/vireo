import SwiftUI
import AppKit

/// Obsidian-style tab strip: tabs stack left-to-right with a min/max width
/// (growing with their title in between), the active tab gets a soft fill,
/// ✕ shows on the active tab and on hover, right-click offers inline rename,
/// and double-click toggles full screen.
struct TabBar: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 3) {
                ForEach(state.documents) { doc in
                    TabItem(doc: doc, isSelected: doc.id == state.selectedID)
                }
                Button {
                    state.newDocument()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("New tab (⌘T)")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct TabItem: View {
    @ObservedObject var doc: DocumentModel
    let isSelected: Bool
    @EnvironmentObject private var state: AppState
    @State private var hovering = false
    @State private var renaming = false
    @State private var draftName = ""
    @FocusState private var renameFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            if renaming {
                TextField("", text: $draftName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .focused($renameFocused)
                    .onSubmit(commitRename)
                    .onExitCommand { renaming = false }
                    .onChange(of: renameFocused) { _, focused in
                        if !focused, renaming { commitRename() }
                    }
            } else {
                Text(doc.displayTitle)
                    .font(.system(size: 12.5, weight: isSelected ? .medium : .regular))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(isSelected ? Color.primary : Color.secondary)
            }

            Button {
                state.closeTab(doc.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
                    .background(Color.primary.opacity(hovering ? 0.06 : 0),
                                in: RoundedRectangle(cornerRadius: 4))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(isSelected || hovering ? 1 : 0)
            .help("Close tab (⌘W)")
        }
        .padding(.leading, 10)
        .padding(.trailing, 5)
        .frame(height: 28)
        .frame(minWidth: 90, maxWidth: 190)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.primary.opacity(0.09)
                                 : hovering ? Color.primary.opacity(0.04) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        // Double-click → full screen with this tab active; single click selects.
        .gesture(TapGesture(count: 2).onEnded {
            state.selectedID = doc.id
            NSApp.keyWindow?.toggleFullScreen(nil)
        })
        .simultaneousGesture(TapGesture(count: 1).onEnded {
            guard !renaming else { return }
            state.selectedID = doc.id
        })
        .contextMenu {
            Button { beginRename() } label: {
                Label("Rename…", systemImage: "pencil")
            }
            Divider()
            Button { state.closeTab(doc.id) } label: {
                Label("Close Tab", systemImage: "xmark")
            }
            Button { state.closeOtherTabs(keeping: doc.id) } label: {
                Label("Close Other Tabs", systemImage: "xmark.square")
            }
            .disabled(state.documents.count < 2)
            Button { state.closeTabsToTheRight(of: doc.id) } label: {
                Label("Close Tabs to the Right", systemImage: "arrow.right.to.line")
            }
            .disabled(state.documents.last?.id == doc.id)
        }
        .help(doc.displayTitle) // full title tooltip for truncated tabs
        .animation(.easeInOut(duration: 0.12), value: hovering)
    }

    private func beginRename() {
        draftName = doc.displayTitle
        renaming = true
        DispatchQueue.main.async { renameFocused = true }
    }

    private func commitRename() {
        renaming = false
        let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != doc.displayTitle else { return }
        state.rename(doc, to: name)
    }
}
