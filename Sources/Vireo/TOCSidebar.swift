import SwiftUI
import MarkdownEngine

/// Table of contents: sits directly on the document background — quiet, light
/// entries whose *text* brightens on hover (no box highlight). Hovering the
/// panel reveals a small ✕ that hides it.
struct TOCSidebar: View {
    @ObservedObject var document: DocumentModel
    @EnvironmentObject private var state: AppState
    @State private var hoveringPanel = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Contents")
                    .font(.caption).bold()
                    .foregroundStyle(.tertiary)
                Spacer()
                Button {
                    state.showTOC = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .opacity(hoveringPanel ? 1 : 0)
                .animation(.easeInOut(duration: 0.15), value: hoveringPanel)
                .help("Hide table of contents")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(document.toc) { entry in
                        TOCRow(entry: entry) {
                            document.controller.scroll(to: entry.location)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .frame(maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
        .onHover { hoveringPanel = $0 }
    }
}

private struct TOCRow: View {
    let entry: TOCEntry
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(entry.title)
                .font(.callout)
                .lineLimit(1)
                .foregroundStyle(hovering ? Color.primary.opacity(0.85)
                                          : Color.secondary.opacity(0.7))
                .padding(.leading, CGFloat(entry.level - 1) * 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.vertical, 3)
        .animation(.easeInOut(duration: 0.12), value: hovering)
        .onHover { hovering = $0 }
    }
}
