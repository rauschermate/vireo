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
        controller.onParsed = { [weak self] parsed in
            guard let self else { return }
            if self.toc != parsed.toc { self.toc = parsed.toc }
            if let anchor = self.pendingAnchor, !self.toc.isEmpty {
                self.pendingAnchor = nil
                self.scrollToAnchor(anchor)
            }
        }
        controller.onSourceChange = { [weak self] text in self?.handleEdit(text) }
        controller.onOpenLink = { [weak self] dest in self?.openLink(dest) }
    }

    var openLinkHandler: ((URL, String?) -> Void)?
    /// Anchor to scroll to once the document has been parsed (cross-file links).
    var pendingAnchor: String?

    private func openLink(_ dest: String) {
        if let u = URL(string: dest), u.scheme == "http" || u.scheme == "https" {
            NSWorkspace.shared.open(u)
            return
        }
        // same-document anchor: `#section`
        if dest.hasPrefix("#") {
            scrollToAnchor(String(dest.dropFirst()))
            return
        }
        // internal link relative to this document's folder, optionally `file.md#anchor`
        guard let base = url?.deletingLastPathComponent() else { return }
        let parts = dest.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let path = String(parts[0])
        let anchor = parts.count > 1 ? String(parts[1]) : nil
        let target = base.appendingPathComponent(path).standardizedFileURL
        if FileManager.default.fileExists(atPath: target.path) {
            openLinkHandler?(target, anchor)
        }
    }

    /// Scroll to the heading whose GitHub-style slug matches `anchor`.
    func scrollToAnchor(_ anchor: String) {
        let want = Self.slug(anchor.removingPercentEncoding ?? anchor)
        guard !want.isEmpty else { return }
        if let entry = toc.first(where: { Self.slug($0.title) == want }) {
            controller.scroll(to: entry.location)
        }
    }

    /// GitHub-style heading slug: lowercase, punctuation dropped, spaces → "-".
    static func slug(_ s: String) -> String {
        var out = ""
        for ch in s.lowercased() {
            if ch.isLetter || ch.isNumber || ch == "-" || ch == "_" { out.append(ch) }
            else if ch == " " { out.append("-") }
        }
        return out
    }

    /// Load a file into a pristine untitled document (Finder open reuses the
    /// initial empty window instead of leaving a stray Untitled behind).
    func adopt(_ newURL: URL) {
        guard url == nil, let text = try? FileService.load(newURL) else { return }
        url = newURL
        title = newURL.lastPathComponent
        source = text
        isDirty = false
        controller.baseURL = newURL.deletingLastPathComponent()
        controller.replaceEntireSource(text)
        startWatching()
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

    /// Flush a debounced autosave immediately (used when the window closes, so
    /// the trailing ≤0.5 s of typing isn't lost with the deallocated model).
    func flushPendingSave() {
        guard saveWork != nil else { return }
        saveWork?.cancel()
        saveWork = nil
        saveNow()
    }

    func saveNow() {
        guard let url else { return }
        saveWork?.cancel()
        saveWork = nil
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
