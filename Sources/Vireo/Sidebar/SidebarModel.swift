import SwiftUI
import AppKit
import VireoCore

/// Geometry shared by every sidebar view. The numbers mirror the reference
/// design: 32pt rows with 8pt corners, a 20pt icon box holding a 16pt glyph,
/// 12pt of surface padding, and 12pt of indent per tree level.
enum SidebarMetrics {
    static let rowHeight: CGFloat = 32
    static let rowRadius: CGFloat = 8
    static let iconBox: CGFloat = 20
    static let iconSize: CGFloat = 16
    static let iconGap: CGFloat = 6
    static let rowTrailing: CGFloat = 8
    static let rowGap: CGFloat = 1
    static let surfacePadding: CGFloat = 12
    static let sectionGap: CGFloat = 16
    static let sectionHeaderHeight: CGFloat = 20
    static let controlHeight: CGFloat = 32
    static let controlPadding: CGFloat = 12
    static let chromeHeight: CGFloat = controlHeight + controlPadding * 2
    static let fontSize: CGFloat = 13
    static let minWidth: CGFloat = 220
    static let defaultWidth: CGFloat = CGFloat(Preferences.defaultSidebarWidth)
    static let fadeSize: CGFloat = 24

    static func indent(depth: Int) -> CGFloat {
        depth == 0 ? 10 : CGFloat(depth) * 12 + 6
    }

    /// The height of a run of `rows` list rows, including the 1pt gaps.
    static func listHeight(rows: Int) -> CGFloat {
        guard rows > 0 else { return 0 }
        return CGFloat(rows) * rowHeight + CGFloat(rows - 1) * rowGap
    }

    static func maxWidth(forWindowWidth width: CGFloat) -> CGFloat {
        max(280, min(420, floor(width * 0.35)))
    }

    static func clampWidth(_ width: CGFloat, windowWidth: CGFloat) -> CGFloat {
        max(minWidth, min(maxWidth(forWindowWidth: windowWidth), width.rounded()))
    }
}

/// Colors as fractions of the foreground, like the reference's translucent
/// surfaces at its default contrast. They read the same over light and dark.
enum SidebarPalette {
    static let hover = Color.primary.opacity(0.059)
    static let selected = Color.primary.opacity(0.085)
    static let input = Color.primary.opacity(0.092)
    static let divider = Color.primary.opacity(0.049)
    static let line = Color.primary.opacity(0.079)
    static let muted = Color.primary.opacity(0.54)
    /// Idle rows sit at 60% and brighten to 100% on hover or highlight.
    static let dimmed: Double = 0.6
}

/// One visible row of the flattened tree.
struct FlatTreeItem: Identifiable, Equatable {
    let node: FileNode
    let depth: Int
    var id: URL { node.url }
}

/// A drag in progress inside the tree.
struct SidebarDrag {
    var entries: [FileNode]
    var primary: FileNode
    var primaryExpanded: Bool
    /// Pointer location in the window's global coordinate space.
    var pointer: CGPoint
    var start: CGPoint
    /// Where inside the grabbed row the press landed, so the ghost lifts off in place.
    var grabOffset: CGSize
    var rowSize: CGSize
    var paddingLeft: CGFloat
    /// True once the pointer moved past the threshold; a shorter press is a click.
    var started = false
}

/// Pure tree helpers, kept free of views so they can be unit tested.
enum SidebarTree {
    static let dragThreshold: CGFloat = 4
    static let autoScrollEdge: CGFloat = 28
    static let autoScrollSpeed: CGFloat = 8

    static func flatten(_ nodes: [FileNode], depth: Int = 0, expanded: Set<URL>,
                        into out: inout [FlatTreeItem]) {
        for node in nodes {
            out.append(FlatTreeItem(node: node, depth: depth))
            if node.isDirectory, expanded.contains(node.url) {
                flatten(node.children ?? [], depth: depth + 1, expanded: expanded, into: &out)
            }
        }
    }

    static func parent(of url: URL) -> URL {
        url.deletingLastPathComponent().standardizedFileURL
    }

    static func isDescendant(_ url: URL, of ancestor: URL) -> Bool {
        url.path.hasPrefix(ancestor.path + "/")
    }

    /// Folder target → into it; file target → its parent; nothing → the root.
    static func resolveDropDir(target: FileNode?, root: URL) -> URL {
        guard let target else { return root }
        return target.isDirectory ? target.url : parent(of: target.url)
    }

    /// Reject no-ops (already in `dest`) and moving a folder into itself.
    static func canMoveInto(_ source: URL, isDirectory: Bool, dest: URL) -> Bool {
        if parent(of: source).path == dest.path { return false }
        if isDirectory {
            if dest.path == source.path { return false }
            if isDescendant(dest, of: source) { return false }
        }
        return true
    }

    /// The destination folder's row plus its visible descendants, as first and
    /// last row ids. For the root that is the whole tree.
    static func resolveDropRange(rows: [FlatTreeItem], destDir: URL, root: URL) -> (start: URL, end: URL)? {
        guard let first = rows.first, let last = rows.last else { return nil }
        if destDir.path == root.path { return (first.id, last.id) }
        guard let startIndex = rows.firstIndex(where: { $0.id == destDir }) else { return nil }
        let baseDepth = rows[startIndex].depth
        var endIndex = startIndex
        for index in rows.indices where index > startIndex {
            if rows[index].depth > baseDepth { endIndex = index } else { break }
        }
        return (rows[startIndex].id, rows[endIndex].id)
    }

    /// Row whose vertical band contains `y`; a gap attaches to the row above.
    static func rowAt(y: CGFloat, frames: [(id: URL, frame: CGRect)]) -> URL? {
        var above: URL?
        for row in frames.sorted(by: { $0.frame.minY < $1.frame.minY }) {
            if y < row.frame.minY { break }
            if y <= row.frame.maxY { return row.id }
            above = row.id
        }
        return above
    }

    /// Every folder strictly between `root` and `leaf`.
    static func ancestors(of leaf: URL, below root: URL) -> [URL] {
        guard isDescendant(leaf, of: root) else { return [] }
        var out: [URL] = []
        var current = parent(of: leaf)
        while current.path != root.path, current.path.count > root.path.count {
            out.insert(current, at: 0)
            current = parent(of: current)
        }
        return out
    }
}

/// Transient sidebar state: what is expanded, selected, pinned, being renamed
/// or dragged. Reset whenever the workspace changes.
@MainActor
final class SidebarModel: ObservableObject {
    /// Recents shows this many rows collapsed; "Show More" then reveals the
    /// rest in a scrollable box `recentsExpandedRows` tall.
    static let recentsCollapsedCount = 3
    static let recentsExpandedRows = 5
    static let pinnedPageSize = 6
    static let recentsMinimumFileCount = 10

    @Published var expanded: Set<URL> = []
    @Published var selection: Set<URL> = []
    /// Anchor for Shift range-select. Only read inside handlers.
    var selectionAnchor: URL?
    @Published var renaming: URL?
    @Published private(set) var pinned: [URL] = []
    @Published var everythingCollapsed = false
    @Published var recentsExpanded = false
    @Published var pinnedVisibleCount = SidebarModel.pinnedPageSize
    @Published var quickOpenPresented = false
    /// Set by "Reveal in Sidebar"; the tree scrolls to it once the row exists.
    @Published var revealTarget: URL?
    @Published var drag: SidebarDrag?
    @Published var dropTarget: URL?
    /// The drop target's block, in the tree's coordinates.
    @Published var dropHighlight: CGRect?
    /// A ⌘/⇧ press adjusted the selection; the matching release is not a click.
    var pressHandled = false
    /// Row frames in global space, refreshed by layout. Read only in handlers.
    var rowFrames: [URL: CGRect] = [:]
    var treeFrame: CGRect = .zero
    /// The scroll container, so a drag can auto-scroll near its edges.
    var scrollFrame: CGRect = .zero
    var scrollOffset: CGFloat = 0
    var scrollTo: ((CGFloat) -> Void)?

    private var workspace: URL?
    private var escapeMonitor: Any?
    private var dragTimer: Timer?

    init() {
        // Escape clears a multi-selection, like the reference; the key still
        // reaches the editor.
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53, let self, !self.selection.isEmpty {
                self.clearSelection()
            }
            return event
        }
    }

    func reset(for workspace: URL?, pinned: [URL]) {
        self.workspace = workspace
        expanded = []
        selection = []
        selectionAnchor = nil
        renaming = nil
        self.pinned = pinned
        everythingCollapsed = false
        recentsExpanded = false
        pinnedVisibleCount = Self.pinnedPageSize
        revealTarget = nil
        stopDragTimer()
        drag = nil
        dropTarget = nil
        dropHighlight = nil
        pressHandled = false
        rowFrames = [:]
    }

    // MARK: Drag ticker

    func startDragTimer(_ tick: @escaping @MainActor () -> Void) {
        stopDragTimer()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { _ in
            MainActor.assumeIsolated { tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        dragTimer = timer
    }

    func stopDragTimer() {
        dragTimer?.invalidate()
        dragTimer = nil
    }

    // MARK: Expansion

    func isExpanded(_ url: URL) -> Bool { expanded.contains(url) }

    func toggleExpanded(_ url: URL) {
        if expanded.contains(url) { expanded.remove(url) } else { expanded.insert(url) }
    }

    func expand(_ url: URL) { expanded.insert(url) }

    /// Start an inline rename once the context menu that asked for it has
    /// closed; a field that appears while the menu is still tearing down
    /// loses focus to the previous responder.
    func beginRename(_ url: URL) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.renaming = url
        }
    }

    // MARK: Selection

    func clearSelection() {
        selection = []
        selectionAnchor = nil
    }

    // MARK: Pins

    func isPinned(_ url: URL) -> Bool { pinned.contains(url) }

    func togglePin(_ url: URL) {
        if let index = pinned.firstIndex(of: url) {
            pinned.remove(at: index)
        } else {
            pinned.insert(url, at: 0)
        }
        persistPins()
    }

    func unpin(_ url: URL) {
        guard let index = pinned.firstIndex(of: url) else { return }
        pinned.remove(at: index)
        persistPins()
    }

    private func persistPins() {
        guard let workspace else { return }
        Preferences.shared.setPinnedFiles(pinned, for: workspace)
    }

    // MARK: Path rewrites after rename / move / delete

    /// `from` (a file or folder) now lives at `to`: carry expansion, pins and
    /// selection across so the tree does not lose its state.
    func rewrite(from: URL, to: URL) {
        func map(_ url: URL) -> URL {
            if url == from { return to }
            if SidebarTree.isDescendant(url, of: from) {
                let suffix = String(url.path.dropFirst(from.path.count))
                return URL(fileURLWithPath: to.path + suffix).standardizedFileURL
            }
            return url
        }
        expanded = Set(expanded.map(map))
        selection = Set(selection.map(map))
        selectionAnchor = selectionAnchor.map(map)
        let mapped = pinned.map(map)
        if mapped != pinned {
            pinned = mapped
            persistPins()
        }
    }

    /// `url` (a file or folder) is gone.
    func forget(_ url: URL) {
        func gone(_ candidate: URL) -> Bool {
            candidate == url || SidebarTree.isDescendant(candidate, of: url)
        }
        expanded = expanded.filter { !gone($0) }
        selection = selection.filter { !gone($0) }
        if let anchor = selectionAnchor, gone(anchor) { selectionAnchor = nil }
        let kept = pinned.filter { !gone($0) }
        if kept.count != pinned.count {
            pinned = kept
            persistPins()
        }
        if let renaming, gone(renaming) { self.renaming = nil }
    }
}
