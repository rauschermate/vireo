import SwiftUI
import AppKit
import VireoCore

/// The "Everything" tree: the workspace flattened into visible rows. Owns
/// selection (click, ⌘-click, ⇧-click), inline rename, context menus and
/// drag-to-move. A press settles selection first, then either becomes a drag
/// (past 4pt) or, on release, a click that opens a file or toggles a folder.
struct FileTreeView: View {
    @ObservedObject var state: AppState
    @ObservedObject var model: SidebarModel
    let root: FileNode
    let proxy: ScrollViewProxy

    private var flattened: [FlatTreeItem] {
        var rows: [FlatTreeItem] = []
        SidebarTree.flatten(root.children ?? [], expanded: model.expanded, into: &rows)
        return rows
    }

    var body: some View {
        let rows = flattened
        if rows.isEmpty {
            Text("No files")
                .font(.system(size: SidebarMetrics.fontSize))
                .foregroundStyle(SidebarPalette.muted)
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            LazyVStack(spacing: SidebarMetrics.rowGap) {
                ForEach(rows) { item in
                    row(item, rows: rows)
                }
            }
            .background(alignment: .top) {
                if let highlight = model.dropHighlight {
                    RoundedRectangle(cornerRadius: SidebarMetrics.rowRadius, style: .continuous)
                        .fill(SidebarPalette.hover)
                        .frame(height: highlight.height)
                        .offset(y: highlight.minY)
                }
            }
            .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) {
                model.treeFrame = $0
            }
            .onChange(of: rows) { _, newRows in
                attemptReveal(rows: newRows)
                refreshDropHighlight(rows: newRows)
            }
            .onChange(of: model.revealTarget) { attemptReveal(rows: rows) }
            .onAppear { attemptReveal(rows: rows) }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("File tree")
        }
    }

    // MARK: Rows

    @ViewBuilder
    private func row(_ item: FlatTreeItem, rows: [FlatTreeItem]) -> some View {
        let node = item.node
        let isActive = state.activeDocument?.url == node.url
        let isExpanded = node.isDirectory && model.expanded.contains(node.url)
        if model.renaming == node.url {
            // A distinct identity from the normal row so swapping the branch
            // re-inserts the subtree — otherwise SwiftUI keeps the slot
            // "appeared" and the field's onAppear (which grabs focus) never fires.
            SidebarRenameRow(node: node, depth: item.depth, isExpanded: isExpanded, isActive: isActive,
                             onCommit: { value in
                                 model.renaming = nil
                                 state.renameSidebarEntry(node, to: value)
                             },
                             onCancel: { model.renaming = nil })
                .id("rename:\(node.url.path)")
        } else {
            SidebarRow(node: node, depth: item.depth,
                       label: state.sidebarLabel(for: node),
                       isExpanded: isExpanded,
                       isActive: isActive,
                       isSelected: model.selection.contains(node.url),
                       isDragging: isDragging(node.url),
                       hoverSuspended: model.drag?.started == true)
                .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) {
                    model.rowFrames[node.url] = $0
                }
                .onDisappear { model.rowFrames.removeValue(forKey: node.url) }
                .gesture(pressGesture(item, rows: rows))
                .contextMenu { contextMenu(for: item, rows: rows) }
                .id(node.url)
        }
    }

    private func isDragging(_ url: URL) -> Bool {
        guard let drag = model.drag, drag.started else { return false }
        return drag.entries.contains { $0.url == url }
    }

    @ViewBuilder
    private func contextMenu(for item: FlatTreeItem, rows: [FlatTreeItem]) -> some View {
        if model.selection.count >= 2, model.selection.contains(item.id) {
            BulkRowMenu(state: state, nodes: rows.filter { model.selection.contains($0.id) }.map(\.node))
        } else if item.node.isDirectory {
            FolderRowMenu(state: state, model: model, node: item.node)
        } else {
            FileRowMenu(state: state, model: model, node: item.node)
        }
    }

    // MARK: Press → click or drag

    private func pressGesture(_ item: FlatTreeItem, rows: [FlatTreeItem]) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                if model.drag == nil, !model.pressHandled {
                    pointerDown(item, rows: rows, at: value.startLocation)
                }
                guard var drag = model.drag else { return }
                drag.pointer = value.location
                if !drag.started {
                    let dx = value.location.x - drag.start.x
                    let dy = value.location.y - drag.start.y
                    if dx * dx + dy * dy < SidebarTree.dragThreshold * SidebarTree.dragThreshold {
                        model.drag = drag
                        return
                    }
                    drag.started = true
                    NSCursor.closedHand.push()
                    model.startDragTimer { tick() }
                }
                model.drag = drag
                updateDropTarget()
            }
            .onEnded { _ in
                let drag = model.drag
                let destination = model.dropTarget
                let handled = model.pressHandled
                endDrag()
                if handled { return } // a ⌘/⇧ press adjusted the selection
                guard let drag else { return }
                if drag.started {
                    if let destination { state.moveSidebarEntries(drag.entries, into: destination) }
                } else {
                    click(item)
                }
            }
    }

    /// Selection settles on press, before any drag, so a drag always carries
    /// the right set and a click never sees a stale one.
    private func pointerDown(_ item: FlatTreeItem, rows: [FlatTreeItem], at location: CGPoint) {
        let flags = NSApp.currentEvent?.modifierFlags ?? []
        let url = item.id
        if flags.contains(.shift) {
            model.pressHandled = true
            let anchor = model.selectionAnchor ?? rows.first?.id
            guard let anchor,
                  let anchorIndex = rows.firstIndex(where: { $0.id == anchor }),
                  let targetIndex = rows.firstIndex(where: { $0.id == url }) else { return }
            let range = min(anchorIndex, targetIndex)...max(anchorIndex, targetIndex)
            model.selection = Set(rows[range].map(\.id))
            return
        }
        if flags.contains(.command) {
            model.pressHandled = true
            if model.selection.contains(url) {
                model.selection.remove(url)
            } else {
                model.selection.insert(url)
            }
            model.selectionAnchor = url
            return
        }

        let dragged: [FileNode]
        if model.selection.count >= 2, model.selection.contains(url) {
            var set = rows.filter { model.selection.contains($0.id) }.map(\.node)
            if !set.contains(where: { $0.url == url }) { set.append(item.node) }
            dragged = set
        } else {
            if !model.selection.isEmpty { model.selection = [] }
            model.selectionAnchor = url
            dragged = [item.node]
        }
        let frame = model.rowFrames[url] ?? CGRect(origin: location, size: .zero)
        model.drag = SidebarDrag(
            entries: dragged,
            primary: item.node,
            primaryExpanded: item.node.isDirectory && model.expanded.contains(url),
            pointer: location,
            start: location,
            grabOffset: CGSize(width: location.x - frame.minX, height: location.y - frame.minY),
            rowSize: frame.size,
            paddingLeft: SidebarMetrics.indent(depth: item.depth))
    }

    /// A plain click: folders toggle, files open. Any multi-selection collapses.
    private func click(_ item: FlatTreeItem) {
        model.selection = []
        model.selectionAnchor = item.id
        if item.node.isDirectory {
            model.toggleExpanded(item.id)
        } else {
            state.requestOpen(item.id)
        }
    }

    private func endDrag() {
        let wasDragging = model.drag?.started == true
        model.stopDragTimer()
        model.drag = nil
        model.dropTarget = nil
        model.dropHighlight = nil
        model.pressHandled = false
        if wasDragging { NSCursor.pop() }
    }

    // MARK: Drop targeting

    /// Runs every frame during a drag: auto-scroll near the edges and keep the
    /// target in sync while the pointer rests.
    private func tick() {
        guard let drag = model.drag, drag.started, let scrollTo = model.scrollTo else { return }
        let frame = model.scrollFrame
        let y = drag.pointer.y
        if y < frame.minY + SidebarTree.autoScrollEdge {
            scrollTo(max(0, model.scrollOffset - SidebarTree.autoScrollSpeed))
        } else if y > frame.maxY - SidebarTree.autoScrollEdge {
            scrollTo(model.scrollOffset + SidebarTree.autoScrollSpeed)
        }
        updateDropTarget()
    }

    /// Resolve the folder under the pointer; highlight it when at least one
    /// dragged item can legally move there.
    private func updateDropTarget() {
        guard let drag = model.drag, drag.started else { return }
        let rows = flattened
        var destination: URL?
        if model.treeFrame.contains(drag.pointer) {
            let frames = model.rowFrames.map { (id: $0.key, frame: $0.value) }
            let hit = SidebarTree.rowAt(y: drag.pointer.y, frames: frames)
            let target = hit.flatMap { id in rows.first { $0.id == id }?.node }
            destination = SidebarTree.resolveDropDir(target: target, root: root.url)
        }
        let valid = destination.map { dest in
            drag.entries.contains { SidebarTree.canMoveInto($0.url, isDirectory: $0.isDirectory, dest: dest) }
        } ?? false
        let next = valid ? destination : nil
        if model.dropTarget != next { model.dropTarget = next }
        refreshDropHighlight(rows: rows)
    }

    /// The destination folder's row plus its visible descendants as one block,
    /// in the tree's own coordinates.
    private func refreshDropHighlight(rows: [FlatTreeItem]) {
        guard let destination = model.dropTarget,
              let range = SidebarTree.resolveDropRange(rows: rows, destDir: destination, root: root.url) else {
            if model.dropHighlight != nil { model.dropHighlight = nil }
            return
        }
        let inRange = rows.drop { $0.id != range.start }.prefix { _ in true }
        var minY = CGFloat.greatestFiniteMagnitude
        var maxY = -CGFloat.greatestFiniteMagnitude
        for item in inRange {
            if let frame = model.rowFrames[item.id] {
                minY = min(minY, frame.minY)
                maxY = max(maxY, frame.maxY)
            }
            if item.id == range.end { break }
        }
        guard minY < maxY else {
            if model.dropHighlight != nil { model.dropHighlight = nil }
            return
        }
        let tree = model.treeFrame
        let rect = CGRect(x: 0, y: minY - tree.minY, width: tree.width, height: maxY - minY)
        if model.dropHighlight != rect { model.dropHighlight = rect }
    }

    // MARK: Reveal

    private func attemptReveal(rows: [FlatTreeItem]) {
        guard let target = model.revealTarget, rows.contains(where: { $0.id == target }) else { return }
        DispatchQueue.main.async {
            proxy.scrollTo(target, anchor: nil)
            model.revealTarget = nil
        }
    }
}
