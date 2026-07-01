import SwiftUI

struct TOCSidebar: View {
    @ObservedObject var document: DocumentModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Contents")
                .font(.caption).bold()
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(document.toc) { entry in
                        Button {
                            document.controller.scroll(to: entry.location)
                        } label: {
                            Text(entry.title)
                                .font(.callout)
                                .lineLimit(1)
                                .foregroundStyle(.primary)
                                .padding(.leading, CGFloat(entry.level - 1) * 12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 3)
                        .contentShape(Rectangle())
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .frame(maxHeight: .infinity)
        .background(.regularMaterial)
    }
}
