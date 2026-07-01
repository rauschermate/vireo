import SwiftUI
import MarkdownEditor

struct ContentView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        HStack(spacing: 0) {
            if state.showFileSidebar && !state.focusMode, state.rootFolder != nil {
                FileSidebar()
                    .frame(width: 240)
                Divider()
            }

            VStack(spacing: 0) {
                if state.documents.count > 1 && !state.focusMode {
                    TabBar()
                    Divider()
                }
                editorArea
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if state.showTOC && !state.focusMode, let doc = state.selected, !doc.toc.isEmpty {
                Divider()
                TOCSidebar(document: doc)
                    .frame(width: 220)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: state.showFileSidebar)
        .animation(.easeInOut(duration: 0.18), value: state.showTOC)
        .animation(.easeInOut(duration: 0.18), value: state.focusMode)
    }

    @ViewBuilder private var editorArea: some View {
        if let doc = state.selected {
            MarkdownSourceView(source: doc.source, controller: doc.controller)
                .id(doc.id)
        } else {
            EmptyStateView()
        }
    }
}

struct EmptyStateView: View {
    @EnvironmentObject private var state: AppState
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.text")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(.tertiary)
            Text("No document open")
                .font(.title3)
                .foregroundStyle(.secondary)
            HStack {
                Button("New") { state.newDocument() }
                Button("Open…") { state.openFilePanel() }
                Button("Open Folder…") { state.openFolderPanel() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }
}
