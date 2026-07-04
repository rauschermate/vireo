import SwiftUI
import AppKit

/// Obsidian-style tab strip, hosted in the window's unified toolbar (same row
/// as the traffic lights, native Liquid Glass chrome). Tabs have a min/max
/// width and grow with their title; the active tab reads as a white card; the
/// ✕ is a bare icon; hovering shows a custom dark tooltip bubble under the
/// tab after a short debounce.
struct TabStrip: View {
    @EnvironmentObject private var state: AppState

    private static let minTabWidth: CGFloat = 60
    private static let maxTabWidth: CGFloat = 190
    private static let spacing: CGFloat = 3
    /// Traffic lights + sidebar button + overflow chevron + toolbar margins.
    /// Generous on purpose: if the strip's width ever exceeded the toolbar's
    /// available space, AppKit would collapse it into the native » overflow
    /// and every tab would vanish.
    private static let reservedChrome: CGFloat = 250
    private static let plusButtonWidth: CGFloat = 30

    var body: some View {
        let stripWidth = max(Self.minTabWidth + Self.plusButtonWidth,
                             state.contentWidth - Self.reservedChrome)
        let visible = visibleDocuments(stripWidth: stripWidth)
        HStack(spacing: Self.spacing) {
            ForEach(Array(visible.enumerated()), id: \.element.id) { index, doc in
                if index > 0,
                   visible[index - 1].id != state.selectedID,
                   doc.id != state.selectedID {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.3))
                        .frame(width: 1, height: 14)
                }
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
        .frame(width: stripWidth, alignment: .leading)
    }

    /// Tabs stack from the left and shrink toward the minimum width; once even
    /// minimum-width tabs can't all fit, show as many as do — always including
    /// the active tab (swapped into the last slot when it would overflow).
    private func visibleDocuments(stripWidth: CGFloat) -> [DocumentModel] {
        let available = stripWidth - Self.plusButtonWidth
        let perTab = Self.minTabWidth + Self.spacing
        let capacity = max(1, Int((available + Self.spacing) / perTab))
        let docs = state.documents
        guard docs.count > capacity else { return docs }

        var shown = Array(docs.prefix(capacity))
        if let selected = state.selectedID,
           !shown.contains(where: { $0.id == selected }),
           let active = docs.first(where: { $0.id == selected }) {
            shown[capacity - 1] = active
        }
        return shown
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
        }
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
    @EnvironmentObject private var state: AppState
    @State private var hovering = false
    @State private var tooltipTask: Task<Void, Never>?
    @State private var anchorBox = ViewBox()
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
            .opacity(isSelected || hovering ? 1 : 0)
        }
        .padding(.leading, 10)
        .padding(.trailing, 5)
        .frame(height: 26)
        .frame(minWidth: 60, maxWidth: 190, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color(nsColor: .textBackgroundColor)
                                 : hovering ? Color.primary.opacity(0.05) : Color.clear)
                .shadow(color: isSelected ? .black.opacity(0.10) : .clear, radius: 1.5, y: 0.5)
        )
        .contentShape(Rectangle())
        .background(AnchorGrabber(box: anchorBox))
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
        }
        .animation(.easeInOut(duration: 0.12), value: hovering)
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
                try? await Task.sleep(nanoseconds: 550_000_000)
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
        panel.contentView = content

        let x = tabScreenRect.midX - content.frame.width / 2
        let y = tabScreenRect.minY - content.frame.height - 2
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
