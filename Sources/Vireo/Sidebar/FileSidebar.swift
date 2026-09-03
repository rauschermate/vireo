import SwiftUI
import AppKit
import VireoCore

/// Left panel: the workspace folder as Pinned / Recents / Everything sections
/// under a search button, with the workspace switcher pinned to the bottom.
/// Full window height, flush left, on the same surface as the document, with
/// a hairline on its right edge.
struct FileSidebar: View {
    @EnvironmentObject private var state: AppState
    /// Height of the window chrome above the content; the sidebar leaves it
    /// clear for the traffic lights and the toggle button.
    let topInset: CGFloat

    var body: some View {
        SidebarSurface(state: state, model: state.sidebar, prefs: Preferences.shared,
                       topInset: topInset)
    }
}

private struct SidebarSurface: View {
    @ObservedObject var state: AppState
    @ObservedObject var model: SidebarModel
    @ObservedObject var prefs: Preferences
    let topInset: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(height: max(topInset, SidebarMetrics.chromeHeight))
            FileBrowser(state: state, model: model, prefs: prefs)
                .frame(maxHeight: .infinity)
            WorkspaceSwitcher(state: state)
                .padding(SidebarMetrics.surfacePadding)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(SidebarPalette.divider)
                .frame(width: 1)
                .padding(.vertical, 1)
        }
        .contentShape(Rectangle())
        .contextMenu { SidebarSurfaceMenu(state: state, prefs: prefs) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("File sidebar")
    }
}

/// Search button over the scrolling section list. Owns the scroll position so
/// a drag can auto-scroll and "Reveal in Sidebar" can jump to a row.
private struct FileBrowser: View {
    @ObservedObject var state: AppState
    @ObservedObject var model: SidebarModel
    @ObservedObject var prefs: Preferences
    @State private var scrollPosition = ScrollPosition()
    @State private var fade = ScrollFadeState()

    var body: some View {
        VStack(spacing: 0) {
            if prefs.sidebarShowSearch {
                SidebarSearchButton { model.quickOpenPresented = true }
                    .padding(.vertical, SidebarMetrics.controlPadding)
            }
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    SidebarNavigator(state: state, model: model, prefs: prefs, proxy: proxy)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        // Empty space between and below the sections is
                        // still the sidebar surface for right-clicks.
                        .contentShape(Rectangle())
                        .contextMenu { SidebarSurfaceMenu(state: state, prefs: prefs) }
                }
                // The scroll view itself owns the space below its content.
                .contextMenu { SidebarSurfaceMenu(state: state, prefs: prefs) }
                .scrollIndicators(.hidden)
                .scrollPosition($scrollPosition)
                .onScrollGeometryChange(for: ScrollFadeState.self, of: { geometry in
                    ScrollFadeState(
                        offset: geometry.contentOffset.y,
                        scrolledStart: geometry.contentOffset.y > 4,
                        scrolledEnd: geometry.contentSize.height - geometry.contentOffset.y
                            - geometry.containerSize.height > 4)
                }) { _, next in
                    fade = next
                    model.scrollOffset = next.offset
                }
                .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) {
                    model.scrollFrame = $0
                }
                .mask { fadeMask }
                .onAppear {
                    model.scrollTo = { y in scrollPosition.scrollTo(y: y) }
                }
            }
        }
        .padding(.horizontal, SidebarMetrics.surfacePadding)
    }

    /// Soft edges once the list scrolls past either end.
    private var fadeMask: some View {
        VStack(spacing: 0) {
            if fade.scrolledStart {
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                    .frame(height: SidebarMetrics.fadeSize)
            }
            Color.black
            if fade.scrolledEnd {
                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: SidebarMetrics.fadeSize)
            }
        }
    }
}

private struct ScrollFadeState: Equatable {
    var offset: CGFloat = 0
    var scrolledStart = false
    var scrolledEnd = false
}

/// Pinned, Recents and Everything, in that order. Empty Pinned / Recents stay
/// hidden; Recents needs a workspace of at least ten files.
private struct SidebarNavigator: View {
    @ObservedObject var state: AppState
    @ObservedObject var model: SidebarModel
    @ObservedObject var prefs: Preferences
    let proxy: ScrollViewProxy

    var body: some View {
        if let root = state.rootFolder {
            let files = root.allFiles
            let pinnedNodes = model.pinned.compactMap { root.node(for: $0) }.filter { !$0.isDirectory }
            let recents = recentFiles(files)
            VStack(alignment: .leading, spacing: SidebarMetrics.sectionGap) {
                if !pinnedNodes.isEmpty {
                    SidebarSection(title: "Pinned") {
                        flatRows(Array(pinnedNodes.prefix(model.pinnedVisibleCount)), label: "Pinned files",
                                 showMore: pinnedNodes.count > model.pinnedVisibleCount
                                    ? { model.pinnedVisibleCount += SidebarModel.pinnedPageSize } : nil)
                    }
                }
                if !recents.isEmpty {
                    SidebarSection(title: "Recents") {
                        flatRows(Array(recents.prefix(model.recentsVisibleCount)), label: "Recents",
                                 showMore: recents.count > model.recentsVisibleCount
                                    ? { model.recentsVisibleCount += SidebarModel.recentsPageSize } : nil)
                    }
                }
                SidebarSection(title: "Everything", collapsed: $model.everythingCollapsed) {
                    FileTreeView(state: state, model: model, root: root, proxy: proxy)
                }
            }
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if state.workspaceRoot == nil {
            Text("No folder open")
                .font(.system(size: SidebarMetrics.fontSize))
                .foregroundStyle(SidebarPalette.muted)
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if let error = state.fileTreeError {
            VStack(alignment: .leading, spacing: 8) {
                Text("Couldn’t load folder")
                    .font(.system(size: SidebarMetrics.fontSize, weight: .medium))
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(SidebarPalette.muted)
                    .lineLimit(3)
                Button("Try Again") { state.refreshFileTree() }
                    .controlSize(.small)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text("Loading…")
                .font(.system(size: SidebarMetrics.fontSize))
                .foregroundStyle(SidebarPalette.muted)
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func recentFiles(_ files: [FileNode]) -> [FileNode] {
        guard prefs.sidebarShowRecents, files.count >= SidebarModel.recentsMinimumFileCount else { return [] }
        let pinned = Set(model.pinned)
        return files.filter { !pinned.contains($0.url) }
            .sorted { lhs, rhs in
                if lhs.modifiedAt != rhs.modifiedAt { return lhs.modifiedAt > rhs.modifiedAt }
                return lhs.url.path < rhs.url.path
            }
    }

    /// Flat file rows (Pinned, Recents): open on click, no selection, no drag.
    /// "Show More" sits in the same 1pt-gapped column as the rows.
    private func flatRows(_ nodes: [FileNode], label: String,
                          showMore: (() -> Void)?) -> some View {
        VStack(spacing: SidebarMetrics.rowGap) {
            ForEach(nodes) { node in
                SidebarRow(node: node, depth: 0,
                           label: state.sidebarLabel(for: node),
                           isExpanded: false,
                           isActive: state.activeDocument?.url == node.url,
                           isSelected: false,
                           hoverSuspended: model.drag?.started == true)
                    .onTapGesture { state.requestOpen(node.url) }
                    .contextMenu { FileRowMenu(state: state, model: model, node: node, inlineRename: false) }
            }
            if let showMore {
                ShowMoreRow(action: showMore)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }
}

/// Invisible strip on the sidebar's right edge. Dragging it resizes the
/// panel; a hairline appears on hover and stays while dragging.
struct SidebarResizeHandle: View {
    @ObservedObject var state: AppState
    let windowWidth: CGFloat
    @State private var hovering = false
    @State private var dragging = false
    @State private var startWidth: CGFloat?

    var body: some View {
        Rectangle()
            .fill(.clear)
            .frame(width: 8)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .overlay(alignment: .trailing) {
                Rectangle()
                    .fill(hovering || dragging ? SidebarPalette.line : .clear)
                    .frame(width: 1)
            }
            .onHover { inside in
                hovering = inside
                if inside {
                    NSCursor.resizeLeftRight.push()
                } else if !dragging {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { value in
                        if startWidth == nil {
                            startWidth = state.sidebarWidth
                            dragging = true
                        }
                        let proposed = (startWidth ?? state.sidebarWidth) + value.translation.width
                        state.sidebarWidth = SidebarMetrics.clampWidth(proposed, windowWidth: windowWidth)
                    }
                    .onEnded { _ in
                        dragging = false
                        startWidth = nil
                        if !hovering { NSCursor.pop() }
                    }
            )
            .accessibilityLabel("Resize sidebar")
    }
}

/// The cursor-following copy of the grabbed row, drawn over the whole window
/// so it is never clipped by the sidebar.
struct SidebarDragOverlay: View {
    @ObservedObject var state: AppState
    @ObservedObject var model: SidebarModel

    var body: some View {
        if let drag = model.drag, drag.started {
            SidebarDragGhost(drag: drag, label: state.sidebarLabel(for: drag.primary))
                .offset(x: drag.pointer.x - drag.grabOffset.width,
                        y: drag.pointer.y - drag.grabOffset.height)
                .allowsHitTesting(false)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}
