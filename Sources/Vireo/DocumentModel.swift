import AppKit
import SwiftUI
import MarkdownEngine
import MarkdownEditor
import VireoCore

/// One open document / tab. Owns the source of truth string, its editor
/// controller, autosave, TOC and external-change reconciliation.
@MainActor
final class DocumentModel: ObservableObject, Identifiable {
    let id = UUID()
    @Published var url: URL?
    @Published var title: String
    @Published var toc: [TOCEntry] = []
    @Published var isDirty = false

    let controller = EditorController()
    private(set) var source: String
    private var watcher: FileWatcher?
    private var saveWork: DispatchWorkItem?
    private var suppressReload = false

    init(url: URL) throws {
        self.url = url
        self.source = try FileService.load(url)
        self.title = url.lastPathComponent
        configure()
        startWatching()
    }

    init(untitled: String = "") {
        self.url = nil
        self.source = untitled
        self.title = "Untitled"
        configure()
    }

    private func configure() {
        controller.baseURL = url?.deletingLastPathComponent()
        controller.onParsed = { [weak self] parsed in self?.toc = parsed.toc }
        controller.onSourceChange = { [weak self] text in self?.handleEdit(text) }
        controller.onOpenLink = { [weak self] dest in self?.openLink(dest) }
    }

    var openLinkHandler: ((URL) -> Void)?

    private func openLink(_ dest: String) {
        if let u = URL(string: dest), u.scheme == "http" || u.scheme == "https" {
            NSWorkspace.shared.open(u)
            return
        }
        // internal link relative to this document's folder
        guard let base = url?.deletingLastPathComponent() else { return }
        let target = base.appendingPathComponent(dest)
        if FileManager.default.fileExists(atPath: target.path) {
            openLinkHandler?(target)
        }
    }

    // MARK: Editing / saving

    private func handleEdit(_ text: String) {
        source = text
        if Preferences.shared.autoSave, url != nil {
            scheduleAutosave()
        } else {
            isDirty = true
        }
    }

    private func scheduleAutosave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    func saveNow() {
        guard let url else { return }
        do {
            suppressReload = true
            try FileService.save(source, to: url)
            isDirty = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.suppressReload = false
            }
        } catch {
            suppressReload = false
            NSLog("Vireo save failed: \(error)")
        }
    }

    /// Save to a new URL (Save As / first save of an untitled doc).
    func save(to newURL: URL) {
        url = newURL
        title = newURL.lastPathComponent
        controller.baseURL = newURL.deletingLastPathComponent()
        saveNow()
        startWatching()
    }

    // MARK: External changes

    private func startWatching() {
        guard let url else { return }
        watcher?.stop()
        watcher = FileWatcher(url: url) { [weak self] in
            Task { @MainActor in self?.externalChange() }
        }
    }

    private func externalChange() {
        guard let url, !suppressReload else { return }
        guard let disk = try? FileService.load(url), disk != source else { return }
        if !isDirty || Preferences.shared.autoSave {
            source = disk
            controller.replaceEntireSource(disk)
            isDirty = false
        } else {
            presentConflict(disk: disk, url: url)
        }
    }

    private func presentConflict(disk: String, url: URL) {
        let alert = NSAlert()
        alert.messageText = "“\(url.lastPathComponent)” changed on disk"
        alert.informativeText = "You have unsaved edits. Keep your version or reload the version on disk?"
        alert.addButton(withTitle: "Keep Mine")
        alert.addButton(withTitle: "Reload Theirs")
        if alert.runModal() == .alertSecondButtonReturn {
            source = disk
            controller.replaceEntireSource(disk)
            isDirty = false
        } else {
            saveNow() // keep mine → write back over disk
        }
    }
}
