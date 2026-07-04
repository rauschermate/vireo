import SwiftUI
import AppKit

/// The window chrome: traffic-light clearance, a sidebar toggle, and the
/// Obsidian-style tab strip — drawn in the title-bar zone over a subtle glass
/// background. The active tab reads as a white card; ✕ is a bare icon; a
/// custom dark tooltip bubble appears under hovered tabs after a short
/// debounce.
struct ChromeBar: View {
    @EnvironmentObject private var state: AppState
    static let height: CGFloat = 38

    var body: some View {
        HStack(spacing: 6) {
            Color.clear.frame(width: 70) // traffic lights

            Button {
                if state.rootFolder == nil {
                    state.openFolderPanel()
                } else {
                    state.showFileSidebar.toggle()
                }
            } label: {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(state.rootFolder == nil ? "Open folder" : "Toggle file sidebar")

            TabStrip()
        }
        .frame(height: Self.height)
        .background {
            DragToMoveArea()
        }
        .background {
            // Liquid Glass chrome (macOS 26+), material fallback — with the
            // requested whisper of gray on top.
            Group {
                if #available(macOS 26.0, *) {
                    Color.clear.glassEffect(in: .rect)
                } else {
                    Rectangle().fill(.ultraThinMaterial)
                }
            }
            .overlay(Color.primary.opacity(0.035))
            .ignoresSafeArea()
        }
    }
}

/// Empty view that lets the chrome drag the window (the tab strip lives in
/// the title-bar zone, which full-size content would otherwise swallow).
private struct DragToMoveArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragView: NSView {
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
        override var mouseDownCanMoveWindow: Bool { true }
    }
}

// MARK: - Tab strip

/// Hovered-tab tooltip info carried up out of the scroll view (which would
/// clip an in-place overlay).
private struct TabTooltipRequest {
    var title: String
    var anchor: Anchor<CGRect>
}

private struct TabTooltipKey: PreferenceKey {
    static let defaultValue: TabTooltipRequest? = nil
    static func reduce(value: inout TabTooltipRequest?, nextValue: () -> TabTooltipRequest?) {
        value = value ?? nextValue()
    }
}

struct TabStrip: View {
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
            .padding(.trailing, 8)
            .padding(.vertical, 5)
        }
        .overlayPreferenceValue(TabTooltipKey.self) { request in
            GeometryReader { geo in
                if let request {
                    let rect = geo[request.anchor]
                    TabTooltip(text: request.title)
                        .position(x: rect.midX, y: rect.maxY + 22)
                        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
                }
            }
            .allowsHitTesting(false)
            .animation(.easeOut(duration: 0.16), value: request?.title)
        }
    }
}

/// The dark rounded tooltip bubble with an arrow pointing up at the tab.
private struct TabTooltip: View {
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

private struct TabItem: View {
    @ObservedObject var doc: DocumentModel
    let isSelected: Bool
    @EnvironmentObject private var state: AppState
    @State private var hovering = false
    @State private var tooltipShown = false
    @State private var tooltipTask: Task<Void, Never>?
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
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(isSelected || hovering ? 1 : 0)
        }
        .padding(.leading, 10)
        .padding(.trailing, 5)
        .frame(height: 28)
        .frame(minWidth: 90, maxWidth: 190)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color(nsColor: .textBackgroundColor)
                                 : hovering ? Color.primary.opacity(0.05) : Color.clear)
                .shadow(color: isSelected ? .black.opacity(0.10) : .clear, radius: 1.5, y: 0.5)
        )
        .contentShape(Rectangle())
        .onHover { inside in
            hovering = inside
            tooltipTask?.cancel()
            if inside {
                tooltipTask = Task {
                    try? await Task.sleep(nanoseconds: 550_000_000)
                    if !Task.isCancelled { tooltipShown = true }
                }
            } else {
                tooltipShown = false
            }
        }
        .anchorPreference(key: TabTooltipKey.self, value: .bounds) { anchor in
            tooltipShown && !renaming
                ? TabTooltipRequest(title: doc.displayTitle, anchor: anchor)
                : nil
        }
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
