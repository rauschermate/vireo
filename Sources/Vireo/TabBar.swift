import SwiftUI
import AppKit

/// The titlebar-accessory chrome row: sidebar toggle, tab strip, and the
/// always-present overflow chevron pinned right.
struct ChromeRow: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 6) {
            SidebarToggleButton(state: state)

            // Slide the tab strip right so it clears the full-height sidebar
            // (the toggle stays pinned by the traffic lights).
            if state.tabStripInset > 0 {
                Color.clear.frame(width: state.tabStripInset)
            }

            TabStrip()

            Spacer(minLength: 4)

            TabOverflowMenu()
                .padding(.trailing, 10)
        }
        // The accessory starts 78pt into the window; 14pt more puts the
        // toggle at x=92, clear of the traffic lights.
        .padding(.leading, 14)
        .frame(maxHeight: .infinity)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14),
                   value: state.showFileSidebar)
    }
}

/// The sidebar toggle by the traffic lights: a quiet outline glyph that
/// brightens and gains a soft fill on hover.
private struct SidebarToggleButton: View {
    @ObservedObject var state: AppState
    @State private var hovering = false

    var body: some View {
        Button {
            state.toggleFileSidebar()
        } label: {
            SidebarIcon.sidebarLeft.view(size: 18)
                .foregroundStyle(Color.primary)
                .opacity(hovering ? 1 : SidebarPalette.dimmed)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(hovering ? SidebarPalette.hover : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(state.showFileSidebar ? "Hide sidebar" : "Show sidebar")
        .help(state.showFileSidebar ? "Hide sidebar" : "Show sidebar")
    }
}

/// Obsidian-style tab strip, hosted in the titlebar accessory (same row as
/// the traffic lights, native Liquid Glass chrome). Tabs have a min/max
/// width and grow with their title; the active tab reads as a white card; the
/// ✕ is a bare icon; hovering shows a custom dark tooltip bubble under the
/// tab after a short debounce.
struct TabStrip: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let minTabWidth: CGFloat = 72
    /// The active tab stays readable: it never shrinks below this even when
    /// the others are squeezed to `minTabWidth`.
    private static let activeMinTabWidth: CGFloat = 96
    private static let maxTabWidth: CGFloat = 200
    private static let spacing: CGFloat = 3
    /// Traffic lights + sidebar button + overflow chevron + margins.
    private static let reservedChrome: CGFloat = 190
    private static let plusButtonWidth: CGFloat = 30
    private static let dividerWidth: CGFloat = 1

    var body: some View {
        let sidebarInset = state.tabStripInset
        let stripWidth = max(Self.minTabWidth + Self.plusButtonWidth,
                             state.contentWidth - Self.reservedChrome - sidebarInset)
        let widths = tabWidths(stripWidth: stripWidth)
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Self.spacing) {
                    ForEach(Array(state.documents.enumerated()), id: \.element.id) { index, doc in
                        if index > 0,
                           state.documents[index - 1].id != state.selectedID,
                           doc.id != state.selectedID {
                            Rectangle()
                                .fill(Color.secondary.opacity(0.3))
                                .frame(width: Self.dividerWidth, height: 14)
                        }
                        TabItem(doc: doc,
                                isSelected: doc.id == state.selectedID,
                                width: doc.id == state.selectedID ? widths.active : widths.tab)
                            .id(doc.id)
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
                    .accessibilityLabel("New tab")
                    .help("New tab (⌘T)")
                }
                // Room for the active tab's shadow — the scroll view clips
                // exactly at its bounds.
                .padding(.vertical, 3)
            }
            .frame(width: stripWidth, alignment: .leading)
            .onChange(of: state.selectedID) { _, id in
                guard let id else { return }
                if reduceMotion {
                    proxy.scrollTo(id)
                } else {
                    withAnimation(.easeInOut(duration: 0.15)) { proxy.scrollTo(id) }
                }
            }
            .onAppear {
                if let id = state.selectedID { proxy.scrollTo(id) }
            }
        }
    }

    /// Tabs share one width, shrinking from the maximum toward the minimum as
    /// tabs are added; once even minimum-width tabs can't all fit, the strip
    /// scrolls horizontally instead of hiding tabs. Below `activeMinTabWidth`
    /// the active tab stops shrinking and the rest absorb the difference.
    private func tabWidths(stripWidth: CGFloat) -> (tab: CGFloat, active: CGFloat) {
        let count = max(1, state.documents.count)
        // One gap per tab (between tabs and before the + button), plus a
        // worst-case allowance for the inter-tab dividers.
        let gaps = CGFloat(count) * Self.spacing
        let dividers = CGFloat(max(0, count - 2)) * (Self.dividerWidth + Self.spacing)
        let available = stripWidth - Self.plusButtonWidth - gaps - dividers
        let equal = min(Self.maxTabWidth, max(Self.minTabWidth, available / CGFloat(count)))
        guard equal < Self.activeMinTabWidth, count > 1 else { return (equal, equal) }
        let rest = max(Self.minTabWidth,
                       (available - Self.activeMinTabWidth) / CGFloat(count - 1))
        return (rest, Self.activeMinTabWidth)
    }
}

/// Chevron at the toolbar's right edge — always present — listing every open
/// tab behind a search field (autofocused; Enter selects the first match).
struct TabOverflowMenu: View {
    @EnvironmentObject private var state: AppState
    @State private var showing = false
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    private var filtered: [DocumentModel] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return state.documents }
        return state.documents.filter { $0.displayTitle.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        Button {
            showing.toggle()
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Show all tabs")
        .help("Show all tabs")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            VStack(spacing: 0) {
                TextField("Search tabs", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .focused($searchFocused)
                    .onSubmit {
                        if let first = filtered.first {
                            state.selectedID = first.id
                            showing = false
                        }
                    }
                    .padding(8)
                Divider()
                ScrollView {
                    VStack(spacing: 1) {
                        ForEach(filtered) { doc in
                            TabMenuRow(doc: doc, isSelected: doc.id == state.selectedID) {
                                state.selectedID = doc.id
                                showing = false
                            }
                        }
                        if filtered.isEmpty {
                            Text("No matching tabs")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 12)
                        }
                    }
                    .padding(6)
                }
                .frame(maxHeight: 320)
            }
            .frame(width: 260)
            .onAppear {
                query = ""
                DispatchQueue.main.async { searchFocused = true }
            }
        }
    }
}

private struct TabMenuRow: View {
    @ObservedObject var doc: DocumentModel
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(doc.displayTitle)
                    .font(.system(size: 12.5))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                if case .failed(let message) = doc.saveState {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.red)
                        .help("Save failed: \(message)")
                }
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovering ? Color.primary.opacity(0.07) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct TabItem: View {
    @ObservedObject var doc: DocumentModel
    let isSelected: Bool
    let width: CGFloat
    @EnvironmentObject private var state: AppState
    @State private var hovering = false
    @State private var tooltipTask: Task<Void, Never>?
    @State private var anchorBox = ViewBox()
    @State private var renaming = false
    @State private var draftName = ""
    @FocusState private var renameFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                    .font(.system(size: 12.5, weight: isSelected ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(isSelected ? Color.primary : Color.secondary)
            }

            switch doc.saveState {
            case .saving:
                ProgressView()
                    .controlSize(.mini)
                    .frame(width: 10, height: 10)
                    .help("Saving…")
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.red)
                    .help("Save failed: \(message)")
            case .saved, .unsaved:
                EmptyView()
            }

            Spacer(minLength: 0) // title hugs the left edge, ✕ the right

            Button {
                state.closeTab(doc.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close \(doc.displayTitle)")
            .opacity(isSelected || hovering ? 1 : 0)
        }
        .padding(.leading, 10)
        .padding(.trailing, 5)
        .frame(height: 26)
        .frame(width: width, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color(nsColor: .textBackgroundColor)
                                 : hovering ? Color.primary.opacity(0.05) : Color.clear)
                .shadow(color: isSelected ? .black.opacity(0.10) : .clear, radius: 1.5, y: 0.5)
        )
        .contentShape(Rectangle())
        .background(AnchorGrabber(box: anchorBox))
        // Middle-click (scroll-wheel button) closes the tab, like Chrome.
        .overlay(MiddleClickCatcher { state.closeTab(doc.id) })
        .onHover(perform: hoverChanged)
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
            if let url = doc.url {
                Divider()
                Button { state.revealInSidebar(url) } label: {
                    Label("Reveal in Sidebar", systemImage: "sidebar.left")
                }
                Button { state.copyToPasteboard(url.path) } label: {
                    Label("Copy Path", systemImage: "doc.on.doc")
                }
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.12),
                   value: hovering)
        .onDisappear {
            tooltipTask?.cancel()
            TabTooltipPanel.shared.hide()
        }
    }

    private func hoverChanged(_ inside: Bool) {
        hovering = inside
        tooltipTask?.cancel()
        if inside {
            tooltipTask = Task {
                try? await Task.sleep(nanoseconds: 900_000_000)
                guard !Task.isCancelled, !renaming else { return }
                if let view = anchorBox.view, let window = view.window {
                    let inWindow = view.convert(view.bounds, to: nil)
                    let onScreen = window.convertToScreen(inWindow)
                    TabTooltipPanel.shared.show(text: doc.displayTitle, under: onScreen)
                }
            }
        } else {
            TabTooltipPanel.shared.hide()
        }
    }

    private func beginRename() {
        TabTooltipPanel.shared.hide()
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

// MARK: - Screen-position anchor

@MainActor
final class ViewBox {
    weak var view: NSView?
}

/// Invisible bridge that exposes the hosting NSView so the tab can compute
/// its screen rect (the toolbar clips overlays, so tooltips float in a panel).
private struct AnchorGrabber: NSViewRepresentable {
    let box: ViewBox
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        box.view = view
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        box.view = nsView
    }
}

// MARK: - Middle-click to close

/// Transparent overlay that closes the tab on a middle-click (scroll-wheel
/// button), like Chrome. It claims the hit *only* while a middle-mouse event is
/// being routed; left-click (select), double-click (full screen), right-click
/// (context menu) and hover all fall straight through to the SwiftUI tab.
private struct MiddleClickCatcher: NSViewRepresentable {
    let action: () -> Void
    func makeNSView(context: Context) -> MiddleClickView { MiddleClickView(action: action) }
    func updateNSView(_ nsView: MiddleClickView, context: Context) { nsView.action = action }
}

private final class MiddleClickView: NSView {
    var action: () -> Void
    init(action: @escaping () -> Void) {
        self.action = action
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Only intercept middle-button events; return nil for everything else so
    /// the click reaches the tab's own gestures/buttons underneath.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let event = NSApp.currentEvent else { return nil }
        switch event.type {
        case .otherMouseDown, .otherMouseUp, .otherMouseDragged:
            return event.buttonNumber == 2 ? self : nil
        default:
            return nil
        }
    }

    // Accept the press so the matching release is delivered here; fire on the
    // release, and only if it lands back on the tab (Chrome behaviour).
    override func otherMouseDown(with event: NSEvent) {}
    override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == 2,
              bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        action()
    }
}

// MARK: - Tooltip panel

/// Floating dark tooltip bubble with an up-arrow, shown under a tab. A panel
/// (not an overlay) so the toolbar can't clip it; fades/slides in subtly.
@MainActor
final class TabTooltipPanel {
    static let shared = TabTooltipPanel()
    private var panel: NSPanel?

    func show(text: String, under tabScreenRect: NSRect) {
        hide()
        let content = NSHostingView(rootView: TooltipBubble(text: text))
        content.frame.size = content.fittingSize

        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: content.frame.size),
                            styleMask: [.nonactivatingPanel, .borderless],
                            backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hasShadow = false // the bubble draws its own
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = true // never float over other apps
        panel.contentView = content

        let x = tabScreenRect.midX - content.frame.width / 2
        let y = tabScreenRect.minY - content.frame.height - 2
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.setFrameOrigin(NSPoint(x: x, y: y))
            panel.alphaValue = 1
            panel.orderFront(nil)
            self.panel = panel
            return
        }
        panel.setFrameOrigin(NSPoint(x: x, y: y + 4)) // start slightly high…
        panel.alphaValue = 0
        panel.orderFront(nil)
        self.panel = panel

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            panel.animator().setFrameOrigin(NSPoint(x: x, y: y)) // …and settle down
        }
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
    }
}

private struct TooltipBubble: View {
    let text: String

    var body: some View {
        VStack(spacing: 0) {
            TooltipArrow()
                .fill(Color.black.opacity(0.88))
                .frame(width: 14, height: 6)
            Text(text)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.black.opacity(0.88), in: RoundedRectangle(cornerRadius: 7))
        }
        .fixedSize()
        .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
        .padding(6) // room for the shadow inside the panel
    }
}

private struct TooltipArrow: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}
