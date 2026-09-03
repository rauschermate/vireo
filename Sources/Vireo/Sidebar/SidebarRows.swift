import SwiftUI
import AppKit
import VireoCore

/// One file or folder row: a 16pt glyph in a 20pt box, then the label. Idle
/// rows sit at 60% and brighten on hover; the open file and any selection get
/// a soft fill. Hovering a folder swaps its glyph for a disclosure chevron.
struct SidebarRow: View {
    let node: FileNode
    let depth: Int
    let label: String
    let isExpanded: Bool
    let isActive: Bool
    let isSelected: Bool
    var isDragging = false
    /// While any drag runs, rows stop reacting to the pointer so the tree does
    /// not flicker under the ghost.
    var hoverSuspended = false
    @State private var hovering = false

    private var hovered: Bool { hovering && !hoverSuspended }
    private var highlighted: Bool { isActive || isSelected }

    var body: some View {
        HStack(spacing: SidebarMetrics.iconGap) {
            ZStack {
                if node.isDirectory {
                    (isExpanded ? SidebarIcon.folderOpen : SidebarIcon.folderClosed)
                        .view(size: SidebarMetrics.iconSize)
                        .opacity(hovered ? 0 : SidebarPalette.dimmed)
                    SidebarIcon.chevron.view(size: SidebarMetrics.iconSize)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .animation(.easeOut(duration: 0.2), value: isExpanded)
                        .opacity(hovered ? 1 : 0)
                } else {
                    SidebarIcon.file.view(size: SidebarMetrics.iconSize)
                        .opacity(hovered ? 1 : SidebarPalette.dimmed)
                }
            }
            .frame(width: SidebarMetrics.iconBox, height: SidebarMetrics.iconBox)
            Text(label)
                .font(.system(size: SidebarMetrics.fontSize))
                .lineLimit(1)
                .truncationMode(.tail)
                .opacity(highlighted || hovered ? 1 : SidebarPalette.dimmed)
            Spacer(minLength: 0)
        }
        .foregroundStyle(Color.primary)
        .padding(.leading, SidebarMetrics.indent(depth: depth))
        .padding(.trailing, SidebarMetrics.rowTrailing)
        .frame(height: SidebarMetrics.rowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: SidebarMetrics.rowRadius, style: .continuous)
                .fill(background)
        )
        .contentShape(Rectangle())
        .opacity(isDragging ? 0.4 : 1)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(node.isDirectory ? "\(node.name) folder" : label)
        .accessibilityAddTraits(.isButton)
    }

    private var background: Color {
        if isSelected { return SidebarPalette.selected }
        if isActive || hovered { return SidebarPalette.hover }
        return .clear
    }
}

/// The row while its name is being edited inline. Files edit the stem only;
/// the extension comes back on commit.
struct SidebarRenameRow: View {
    let node: FileNode
    let depth: Int
    let isExpanded: Bool
    let isActive: Bool
    let onCommit: (String) -> Void
    let onCancel: () -> Void

    @State private var value: String
    @State private var finished = false
    @State private var appearedAt = Date()
    @State private var focusAttempts = 0
    @FocusState private var focused: Bool

    init(node: FileNode, depth: Int, isExpanded: Bool, isActive: Bool,
         onCommit: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.node = node
        self.depth = depth
        self.isExpanded = isExpanded
        self.isActive = isActive
        self.onCommit = onCommit
        self.onCancel = onCancel
        _value = State(initialValue: node.isDirectory ? node.name : node.stem)
    }

    var body: some View {
        HStack(spacing: SidebarMetrics.iconGap) {
            Group {
                if node.isDirectory {
                    (isExpanded ? SidebarIcon.folderOpen : SidebarIcon.folderClosed)
                        .view(size: SidebarMetrics.iconSize)
                } else {
                    SidebarIcon.file.view(size: SidebarMetrics.iconSize)
                }
            }
            .frame(width: SidebarMetrics.iconBox, height: SidebarMetrics.iconBox)
            TextField("", text: $value)
                .textFieldStyle(.plain)
                .font(.system(size: SidebarMetrics.fontSize))
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.accentColor, lineWidth: 1)
                )
                .focused($focused)
                .onSubmit { finish { onCommit(value) } }
                .onExitCommand { finish(onCancel) }
                .onChange(of: focused) { _, isFocused in
                    guard !isFocused, !finished else { return }
                    // Right after the row appears, the closing context menu
                    // hands focus back to the previous responder. Take it
                    // again rather than treating that as a blur.
                    if Date().timeIntervalSince(appearedAt) < 0.5, focusAttempts < 6 {
                        requestFocus()
                    } else {
                        finish { onCommit(value) }
                    }
                }
                .accessibilityLabel("Rename \(node.name)")
        }
        .foregroundStyle(Color.primary)
        .padding(.leading, SidebarMetrics.indent(depth: depth))
        .padding(.trailing, SidebarMetrics.rowTrailing)
        .frame(height: SidebarMetrics.rowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: SidebarMetrics.rowRadius, style: .continuous)
                .fill(isActive ? SidebarPalette.hover : .clear)
        )
        .onAppear {
            appearedAt = Date()
            requestFocus()
        }
    }

    private func requestFocus() {
        focusAttempts += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
            guard !finished else { return }
            focused = true
            // Select the whole name so typing replaces it.
            DispatchQueue.main.async {
                (NSApp.keyWindow?.firstResponder as? NSTextView)?.selectAll(nil)
            }
        }
    }

    /// Submit, blur and Escape can all fire for one edit; only the first counts.
    private func finish(_ action: () -> Void) {
        guard !finished else { return }
        finished = true
        action()
    }
}

/// A section title ("Pinned", "Recents", "Everything") with a caret that
/// turns when the section is open. The whole label toggles the section.
struct SidebarSectionHeader: View {
    let title: String
    let isCollapsed: Bool
    let toggle: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                SidebarIcon.caret.view(size: 12)
                    .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                    .animation(.easeOut(duration: 0.15), value: isCollapsed)
            }
            .foregroundStyle(SidebarPalette.muted)
            .opacity(hovering ? 1 : SidebarPalette.dimmed)
            .frame(height: SidebarMetrics.sectionHeaderHeight)
            .padding(.leading, SidebarMetrics.surfacePadding)
            .padding(.trailing, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(title)
        .accessibilityValue(isCollapsed ? "collapsed" : "expanded")
    }
}

/// A collapsible section. Without a binding the collapsed state is local.
struct SidebarSection<Content: View>: View {
    let title: String
    var collapsed: Binding<Bool>?
    @ViewBuilder let content: () -> Content
    @State private var localCollapsed = false

    private var isCollapsed: Bool { collapsed?.wrappedValue ?? localCollapsed }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SidebarSectionHeader(title: title, isCollapsed: isCollapsed) {
                if let collapsed {
                    collapsed.wrappedValue.toggle()
                } else {
                    localCollapsed.toggle()
                }
            }
            if !isCollapsed { content() }
        }
    }
}

/// "Show More" at the end of a paged section.
struct ShowMoreRow: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: SidebarMetrics.iconGap) {
                SidebarIcon.ellipsis.view(size: SidebarMetrics.iconSize)
                    .frame(width: SidebarMetrics.iconBox, height: SidebarMetrics.iconBox)
                    .opacity(hovering ? 1 : SidebarPalette.dimmed)
                Text("Show More")
                    .font(.system(size: SidebarMetrics.fontSize))
                    .lineLimit(1)
                    .opacity(hovering ? 1 : SidebarPalette.dimmed)
                Spacer(minLength: 0)
            }
            .foregroundStyle(Color.primary)
            .padding(.leading, 10)
            .padding(.trailing, SidebarMetrics.rowTrailing)
            .frame(height: SidebarMetrics.rowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: SidebarMetrics.rowRadius, style: .continuous)
                    .fill(hovering ? SidebarPalette.hover : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// The search field-shaped button at the top of the sidebar. It opens the
/// quick-open panel (⌘P).
struct SidebarSearchButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: SidebarMetrics.rowRadius, style: .continuous)
                    .fill(SidebarPalette.input)
                SidebarIcon.search.view(size: SidebarMetrics.iconSize)
                    .padding(.leading, 10)
                Text("Search")
                    .font(.system(size: SidebarMetrics.fontSize))
                    .padding(.leading, 34)
                HStack(spacing: 2) {
                    Text("⌘")
                    Text("P")
                }
                .font(.system(size: 11))
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, 10)
            }
            .foregroundStyle(hovering ? Color.primary : SidebarPalette.muted)
            .frame(height: SidebarMetrics.controlHeight)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel("Search")
        .help("Search files (⌘P)")
    }
}

/// Bottom-left workspace switcher: the open folder's name behind a menu of
/// recent folders, Open Folder…, and Close Workspace.
struct WorkspaceSwitcher: View {
    @ObservedObject var state: AppState
    @State private var hovering = false

    private var name: String { state.workspaceRoot?.lastPathComponent ?? "No Workspace" }

    var body: some View {
        Menu {
            let root = state.workspaceRoot
            let others = Preferences.shared.recentWorkspaces.filter { $0.path != root?.path }
            ForEach(others, id: \.path) { url in
                Button(url.lastPathComponent) { state.openWorkspace(url) }
            }
            if !others.isEmpty { Divider() }
            Button("Open Folder…") { state.openFolderPanel() }
            if root != nil {
                Button("Close Workspace") { state.closeWorkspace() }
            }
        } label: {
            HStack(spacing: SidebarMetrics.iconGap) {
                SidebarIcon.switcher.view(size: SidebarMetrics.iconSize)
                    .frame(width: SidebarMetrics.iconBox, height: SidebarMetrics.iconBox)
                Text(name)
                    .font(.system(size: SidebarMetrics.fontSize))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .foregroundStyle(hovering ? Color.primary : SidebarPalette.muted)
            .padding(.leading, 10)
            .padding(.trailing, SidebarMetrics.rowTrailing)
            .frame(height: SidebarMetrics.rowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: SidebarMetrics.rowRadius, style: .continuous)
                    .fill(hovering ? SidebarPalette.hover : .clear)
            )
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .onHover { hovering = $0 }
        .accessibilityLabel("Switch workspace")
    }
}

/// The element that follows the cursor during a drag: a copy of the grabbed
/// row with the selection fill, plus a count badge for a multi-item drag.
struct SidebarDragGhost: View {
    let drag: SidebarDrag
    let label: String

    var body: some View {
        ZStack(alignment: .topTrailing) {
            HStack(spacing: SidebarMetrics.iconGap) {
                Group {
                    if drag.primary.isDirectory {
                        (drag.primaryExpanded ? SidebarIcon.folderOpen : SidebarIcon.folderClosed)
                            .view(size: SidebarMetrics.iconSize)
                    } else {
                        SidebarIcon.file.view(size: SidebarMetrics.iconSize)
                    }
                }
                .frame(width: SidebarMetrics.iconBox, height: SidebarMetrics.iconBox)
                .opacity(SidebarPalette.dimmed)
                Text(label)
                    .font(.system(size: SidebarMetrics.fontSize))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .foregroundStyle(Color.primary)
            .padding(.leading, drag.paddingLeft)
            .padding(.trailing, SidebarMetrics.rowTrailing)
            .frame(width: drag.rowSize.width, height: SidebarMetrics.rowHeight)
            .background(
                RoundedRectangle(cornerRadius: SidebarMetrics.rowRadius, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
            )
            .background(
                RoundedRectangle(cornerRadius: SidebarMetrics.rowRadius, style: .continuous)
                    .fill(SidebarPalette.selected)
            )
            if drag.entries.count > 1 {
                Text("\(drag.entries.count)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .frame(minWidth: 20, minHeight: 20)
                    .background(Capsule().fill(Color.accentColor))
                    .overlay(Capsule().stroke(Color(nsColor: .textBackgroundColor), lineWidth: 2))
                    .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
                    .offset(x: 8, y: -8)
            }
        }
        .fixedSize()
    }
}
