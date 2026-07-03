import SwiftUI
import MarkdownEngine

/// Table of contents: sits directly on the document background (no divider,
/// no material) so it reads as part of the page, entries dim until hovered.
struct TOCSidebar: View {
    @ObservedObject var document: DocumentModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Contents")
                .font(.caption).bold()
                .foregroundStyle(.tertiary)
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
                .foregroundStyle(hovering ? Color.primary : Color.secondary)
                .padding(.leading, CGFloat(entry.level - 1) * 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(hovering ? Color.primary.opacity(0.06) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .onHover { hovering = $0 }
    }
}
