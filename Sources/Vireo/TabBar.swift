import SwiftUI

struct TabBar: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(state.documents) { doc in
                    TabItem(doc: doc, isSelected: doc.id == state.selectedID)
                        .onTapGesture { state.selectedID = doc.id }
                    Divider().frame(height: 18)
                }
            }
        }
        .frame(height: 36)
        .background(.bar)
    }
}

private struct TabItem: View {
    @ObservedObject var doc: DocumentModel
    let isSelected: Bool
    @EnvironmentObject private var state: AppState
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Text(doc.title)
                .font(.callout)
                .lineLimit(1)
                .foregroundStyle(isSelected ? .primary : .secondary)
            if doc.isDirty {
                Circle().fill(.secondary).frame(width: 6, height: 6)
            }
            Button {
                state.closeDocument(doc.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
            .opacity(hovering || isSelected ? 1 : 0)
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(isSelected ? Color(nsColor: .textBackgroundColor) : Color.clear)
        .onHover { hovering = $0 }
    }
}
