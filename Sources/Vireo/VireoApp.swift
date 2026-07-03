import SwiftUI
import AppKit
import VireoCore

@main
struct VireoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var state = AppState.shared
    @ObservedObject private var prefs = Preferences.shared

    var body: some Scene {
        Window("Vireo", id: "main") {
            DocumentWindowView()
                .environmentObject(state)
                .frame(minWidth: 640, minHeight: 420)
        }
        .commands { commands }

        Settings {
            PreferencesView().environmentObject(prefs)
        }
    }

    @CommandsBuilder private var commands: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New File") { state.createNewFile() }.keyboardShortcut("n")
            Button("New Tab") { state.newDocument() }.keyboardShortcut("t")
            Button("Open…") { state.openFilePanel() }.keyboardShortcut("o")
            Button("Open Folder…") { state.openFolderPanel() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            RecentMenu()
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save") {
                if state.activeDocument?.url == nil { state.saveActiveAs() } else { state.activeDocument?.saveNow() }
            }
            .keyboardShortcut("s")
            .disabled(prefs.autoSave && state.activeDocument?.url != nil)
            Button("Save As…") { state.saveActiveAs() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            Divider()
            Button("Close Tab") {
                if let id = state.selectedID { state.closeTab(id) }
            }
            .keyboardShortcut("w")
        }
        CommandMenu("Insert") {
            Button("Table") { state.activeDocument?.controller.insertTable() }
            Button("Code Block") { state.activeDocument?.controller.insertCodeBlock() }
                .keyboardShortcut("k", modifiers: [.command, .shift])
            Button("Image…") { state.activeDocument?.controller.insertImageFromPanel() }
            Divider()
            Button("Task") { state.activeDocument?.controller.insertTaskItem() }
            Button("Horizontal Rule") { state.activeDocument?.controller.insertHorizontalRule() }
        }
        CommandMenu("Format") {
            Button("Bold") { state.activeDocument?.controller.toggleBold() }.keyboardShortcut("b")
            Button("Italic") { state.activeDocument?.controller.toggleItalic() }.keyboardShortcut("i")
            Button("Strikethrough") { state.activeDocument?.controller.toggleStrikethrough() }
            Button("Inline Code") { state.activeDocument?.controller.toggleInlineCode() }
            Divider()
            Button("Heading 1") { state.activeDocument?.controller.makeHeading(1) }
                .keyboardShortcut("1", modifiers: [.command, .control])
            Button("Heading 2") { state.activeDocument?.controller.makeHeading(2) }
                .keyboardShortcut("2", modifiers: [.command, .control])
            Button("Bulleted List") { state.activeDocument?.controller.toggleBulletList() }
            Button("Quote") { state.activeDocument?.controller.toggleQuote() }
            Button("Link…") { state.activeDocument?.controller.insertLink() }.keyboardShortcut("k")
        }
        CommandGroup(after: .textEditing) {
            Button("Find…") { state.activeDocument?.controller.performFind() }.keyboardShortcut("f")
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
            // "=" so plain ⌘+ (the =/+ key, unshifted) works — "+" would demand ⇧.
            Button("Zoom In") { state.zoom = min(3, state.zoom + 0.1) }.keyboardShortcut("=")
            Button("Zoom Out") { state.zoom = max(0.6, state.zoom - 0.1) }.keyboardShortcut("-")
            Button("Actual Size") { state.zoom = 1 }.keyboardShortcut("0")
        }
    }
}

struct RecentMenu: View {
    @ObservedObject private var prefs = Preferences.shared
    var body: some View {
        Menu("Open Recent") {
            ForEach(prefs.recentFiles, id: \.self) { url in
                Button(url.lastPathComponent) { AppState.shared.requestOpen(url) }
            }
        }
    }
}

/// Map the preference onto the whole app; nil restores "follow the system".
@MainActor
func applyAppearance(_ option: AppearanceOption) {
    switch option {
    case .system: NSApp.appearance = nil
    case .light: NSApp.appearance = NSAppearance(named: .aqua)
    case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        applyAppearance(Preferences.shared.appearance)
        let args = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
        for path in args {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: url.path) {
                AppState.shared.pendingURLs.append(url)
            }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { AppState.shared.requestOpen(url) }
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct PreferencesView: View {
    @EnvironmentObject private var prefs: Preferences
    var body: some View {
        Form {
            Toggle("Auto-save changes", isOn: $prefs.autoSave)
            Text("When off, use ⌘S to save. Vireo warns before closing documents with unsaved changes.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Appearance", selection: $prefs.appearance) {
                ForEach(AppearanceOption.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .pickerStyle(.menu)
            .onChange(of: prefs.appearance) { _, newValue in
                applyAppearance(newValue)
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}
