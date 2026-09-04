import SwiftUI
import VireoCore

/// ⌘P: a floating card near the top of the window that filters the workspace
/// by title, file name or path. Enter opens the highlighted file.
struct QuickOpenHost: View {
    @ObservedObject var state: AppState
    @ObservedObject var model: SidebarModel

    var body: some View {
        if model.quickOpenPresented {
            QuickOpenView(state: state, model: model)
                .transition(.opacity)
        }
    }
}

private struct QuickOpenView: View {
    @ObservedObject var state: AppState
    @ObservedObject var model: SidebarModel
    @State private var query = ""
    @State private var selectedIndex = 0
    @FocusState private var focused: Bool

    private static let maxResults = 50
    private static let recentCount = 20

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                Color.black.opacity(0.001)
                    .contentShape(Rectangle())
                    .onTapGesture { dismiss() }
                card
                    .frame(width: min(560, geometry.size.width * 0.9))
                    .padding(.top, geometry.size.height * 0.16)
            }
        }
        .onAppear {
            query = ""
            selectedIndex = 0
            DispatchQueue.main.async { focused = true }
        }
    }

    private var card: some View {
        let results = self.results
        return VStack(spacing: 0) {
            TextField("Search files…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(.vertical, 14)
                .padding(.horizontal, 16)
                .focused($focused)
                .onSubmit { open(results, at: selectedIndex) }
                .onExitCommand { dismiss() }
                .onKeyPress(.downArrow) {
                    move(1, count: results.count)
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    move(-1, count: results.count)
                    return .handled
                }
                .onChange(of: query) { _, _ in selectedIndex = 0 }
            Rectangle()
                .fill(SidebarPalette.divider)
                .frame(height: 1)
            if results.isEmpty {
                Text(query.isEmpty ? "No files" : "No results")
                    .font(.system(size: 13))
                    .foregroundStyle(SidebarPalette.muted)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(results.enumerated()), id: \.element.id) { index, node in
                                QuickOpenRow(title: state.sidebarLabel(for: node),
                                             detail: state.relativePath(node.url),
                                             isSelected: index == selectedIndex) {
                                    open(results, at: index)
                                }
                                .onHover { if $0 { selectedIndex = index } }
                                .id(index)
                            }
                        }
                        .padding(6)
                    }
                    .frame(maxHeight: 320)
                    .onChange(of: selectedIndex) { _, index in
                        proxy.scrollTo(index, anchor: nil)
                    }
                }
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(SidebarPalette.divider, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.15), radius: 17, y: 15)
    }

    /// Empty query: most recently modified first. Otherwise a ranked
    /// case-insensitive match: title/name prefix, then title/name, then path.
    private var results: [FileNode] {
        guard let root = state.rootFolder else { return [] }
        let files = root.allFiles
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        if needle.isEmpty {
            return Array(files.sorted { $0.modifiedAt > $1.modifiedAt }.prefix(Self.recentCount))
        }
        var scored: [(node: FileNode, score: Int)] = []
        for node in files {
            let title = state.sidebarLabel(for: node).lowercased()
            let name = node.stem.lowercased()
            let path = state.relativePath(node.url).lowercased()
            let score: Int
            if title.hasPrefix(needle) || name.hasPrefix(needle) {
                score = 0
            } else if title.contains(needle) || name.contains(needle) {
                score = 1
            } else if path.contains(needle) {
                score = 2
            } else {
                continue
            }
            scored.append((node, score))
        }
        return scored
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score < rhs.score }
                return lhs.node.modifiedAt > rhs.node.modifiedAt
            }
            .prefix(Self.maxResults)
            .map(\.node)
    }

    private func move(_ delta: Int, count: Int) {
        guard count > 0 else { return }
        selectedIndex = (selectedIndex + delta + count) % count
    }

    private func open(_ results: [FileNode], at index: Int) {
        guard results.indices.contains(index) else { return }
        state.requestOpen(results[index].url)
        dismiss()
    }

    private func dismiss() {
        model.quickOpenPresented = false
    }
}

private struct QuickOpenRow: View {
    let title: String
    let detail: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.primary.opacity(0.8))
                    .lineLimit(1)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(SidebarPalette.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? SidebarPalette.hover : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
