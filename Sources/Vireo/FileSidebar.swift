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
    @State private var expanded: Set<URL> = []

    var body: some View {
        Group {
            if let root = state.rootFolder {
                VStack(alignment: .leading, spacing: 0) {
                    header(root)
                    List(selection: $selection) {
                        ForEach(root.children ?? []) { node in
                            FileTree(node: node, expanded: $expanded)
                        }
                    }
                    .listStyle(.sidebar)
                    .scrollContentBackground(.hidden) // let the vibrancy show through
                    .environment(\.defaultMinListRowHeight, 30)
                    .onChange(of: selection) { _, url in openIfFile(url) }
                    .onChange(of: state.activeDocument?.url) { _, url in selection = url }
                    .onAppear { selection = state.activeDocument?.url }
                }
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .modifier(SidebarBackground())
    }

    /// App name over the root folder name, with a little breathing room before
    /// the file tree.
    private func header(_ root: FileNode) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("Vireo")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.primary)
            Text(root.name)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .padding(.top, 16)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Only files are selectable (folders toggle their own disclosure), so a
    /// selection always means "open this file". If a stray tap clears it, keep
    /// the pill on the active file.
    private func openIfFile(_ url: URL?) {
        guard let url else {
            selection = state.activeDocument?.url
            return
        }
        if url != state.activeDocument?.url { state.requestOpen(url) }
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

/// Recursive tree row. Files are selectable (tagged) so selecting one opens it;
/// folders aren't selectable — the whole folder row toggles its own disclosure,
/// so a click expands/collapses it just like clicking the chevron.
private struct FileTree: View {
    let node: FileNode
    @Binding var expanded: Set<URL>

    var body: some View {
        if node.isDirectory {
            DisclosureGroup(isExpanded: isExpanded) {
                ForEach(node.children ?? []) { child in
                    FileTree(node: child, expanded: $expanded)
                }
            } label: {
                // A Button (not onTapGesture) so the whole folder row reliably
                // toggles its disclosure — clicking the row, not just the caret.
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { isExpanded.wrappedValue.toggle() }
                } label: {
                    FileRow(node: node)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        } else {
            FileRow(node: node).tag(node.url)
        }
    }

    private var isExpanded: Binding<Bool> {
        Binding(
            get: { expanded.contains(node.url) },
            set: { open in
                if open { expanded.insert(node.url) } else { expanded.remove(node.url) }
            }
        )
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

/// Sidebar backdrop: the real macOS 26 Liquid Glass when available (the bright,
/// luminous glass Finder uses on Tahoe), falling back to the legacy
/// `.behindWindow` sidebar vibrancy on macOS 15.
private struct SidebarBackground: ViewModifier {
    // Concentric with the window's ~18pt corner: inner = outer − 8pt inset.
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 10, style: .continuous) }

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .clipShape(shape)
                .background { Color.clear.glassEffect(.regular, in: shape) }
        } else {
            content
                .background(SidebarVibrancy())
                .clipShape(shape)
        }
    }
}

/// A `.behindWindow` sidebar-material blur — the native Finder-sidebar backdrop
/// that samples and blurs the desktop behind the window (pre-Liquid-Glass).
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
