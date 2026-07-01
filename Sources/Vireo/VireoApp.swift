import SwiftUI
import AppKit
import VireoCore

@main
struct VireoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var state = AppState.shared
    @ObservedObject private var prefs = Preferences.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(state)
                .frame(minWidth: 720, minHeight: 480)
        }
        .commands { commands }

        Settings {
            PreferencesView().environmentObject(prefs)
        }
    }

    @CommandsBuilder private var commands: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New") { state.newDocument() }.keyboardShortcut("n")
            Button("Open…") { state.openFilePanel() }.keyboardShortcut("o")
            Button("Open Folder…") { state.openFolderPanel() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            RecentMenu()
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save") {
                if state.selected?.url == nil { state.saveAsPanel() } else { state.selected?.saveNow() }
            }
            .keyboardShortcut("s")
            .disabled(prefs.autoSave && state.selected?.url != nil)
            Button("Save As…") { state.saveAsPanel() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            Button("Close") { if let id = state.selectedID { state.closeDocument(id) } }
                .keyboardShortcut("w")
        }
        CommandMenu("Format") {
            Button("Bold") { state.selected?.controller.toggleBold() }.keyboardShortcut("b")
            Button("Italic") { state.selected?.controller.toggleItalic() }.keyboardShortcut("i")
            Button("Strikethrough") { state.selected?.controller.toggleStrikethrough() }
            Button("Inline Code") { state.selected?.controller.toggleInlineCode() }
            Divider()
            Button("Heading 1") { state.selected?.controller.makeHeading(1) }
                .keyboardShortcut("1", modifiers: [.command, .control])
            Button("Heading 2") { state.selected?.controller.makeHeading(2) }
                .keyboardShortcut("2", modifiers: [.command, .control])
            Button("Bulleted List") { state.selected?.controller.toggleBulletList() }
            Button("Quote") { state.selected?.controller.toggleQuote() }
            Button("Link…") { state.selected?.controller.insertLink() }.keyboardShortcut("k")
        }
        CommandGroup(after: .textEditing) {
            Button("Find…") { state.selected?.controller.performFind() }.keyboardShortcut("f")
        }
        CommandGroup(after: .toolbar) {
            Button(state.showFileSidebar ? "Hide File Sidebar" : "Show File Sidebar") {
                state.showFileSidebar.toggle()
            }.keyboardShortcut("\\", modifiers: [.command])
            Button(state.showTOC ? "Hide Table of Contents" : "Show Table of Contents") {
                state.showTOC.toggle()
            }.keyboardShortcut("\\", modifiers: [.command, .option])
            Button(state.focusMode ? "Exit Focus Mode" : "Focus Mode") {
                state.focusMode.toggle()
            }.keyboardShortcut(".", modifiers: [.command, .shift])
            Divider()
            Button("Zoom In") { state.zoom = min(3, state.zoom + 0.1) }.keyboardShortcut("+")
            Button("Zoom Out") { state.zoom = max(0.6, state.zoom - 0.1) }.keyboardShortcut("-")
            Button("Actual Size") { state.zoom = 1 }.keyboardShortcut("0")
        }
    }
}

/// Handles files opened from Finder / the command line.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
        var opened = false
        for path in args {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: url.path) {
                _ = AppState.shared.openFile(url)
                opened = true
            }
        }
        if !opened, AppState.shared.documents.isEmpty {
            AppState.shared.newDocument()
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { _ = AppState.shared.openFile(url) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct RecentMenu: View {
    @ObservedObject private var prefs = Preferences.shared
    var body: some View {
        Menu("Open Recent") {
            ForEach(prefs.recentFiles, id: \.self) { url in
                Button(url.lastPathComponent) { _ = AppState.shared.openFile(url) }
            }
        }
    }
}

struct PreferencesView: View {
    @EnvironmentObject private var prefs: Preferences
    var body: some View {
        Form {
            Toggle("Auto-save changes", isOn: $prefs.autoSave)
            Text("When off, use ⌘S to save. Vireo warns before closing documents with unsaved changes.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 360)
    }
}
