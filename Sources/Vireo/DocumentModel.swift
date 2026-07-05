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
    /// TOC visibility is per-document: the "dynamic" default depends on each
    /// file's length, and a manual toggle should stick to its tab.
    @Published var showTOC = true
    @Published var isDirty = false
    /// User-chosen tab title (rename) for untitled buffers.
    @Published var customTitle: String?
    /// Title derived from the content of an untitled buffer (H1 → first line).
    @Published private(set) var derivedTitle: String?

    /// What the tab shows: rename wins; files show their name without the
    /// extension; untitled buffers take their first heading or first line.
    var displayTitle: String {
        if let customTitle, !customTitle.isEmpty { return customTitle }
        if url != nil { return (title as NSString).deletingPathExtension }
        if let derivedTitle, !derivedTitle.isEmpty { return derivedTitle }
        return "Untitled"
    }

    let controller = EditorController()
    private(set) var source: String
    private var watcher: FileWatcher?
    private var saveWork: DispatchWorkItem?
    private var suppressReload = false

    init(url: URL) throws {
        self.url = url
        self.source = try FileService.load(url)
        self.title = url.lastPathComponent
        self.showTOC = Self.defaultTOCVisibility(for: source)
        configure()
        startWatching()
    }

    init(untitled: String = "") {
        self.url = nil
        self.source = untitled
        self.title = "Untitled"
        self.showTOC = Self.defaultTOCVisibility(for: source)
        configure()
    }

    /// Initial TOC state per the preference. "Dynamic" opens it only for long
    /// documents — ≥ 4,000 characters or ≥ 100 lines, roughly the point where
    /// jumping by heading beats scrolling. Resolved once at open time; the
    /// user's toggle owns it afterwards.
    static func defaultTOCVisibility(for source: String) -> Bool {
        switch Preferences.shared.tocDefault {
        case .on: return true
        case .off: return false
        case .dynamic:
            return source.count >= 4_000
                || source.lazy.filter { $0 == "\n" }.count >= 100
        }
    }

    private func configure() {
        controller.baseURL = url?.deletingLastPathComponent()
        controller.onParsed = { [weak self] parsed in
            guard let self else { return }
            if self.toc != parsed.toc { self.toc = parsed.toc }
            self.updateDerivedTitle()
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

    /// Untitled tabs title themselves from content: the first H1 (or any first
    /// heading), else the first non-empty line.
    private func updateDerivedTitle() {
        guard url == nil, customTitle == nil else { return }
        let fresh: String?
        if let heading = toc.first(where: { $0.level == 1 }) ?? toc.first {
            fresh = heading.title
        } else {
            fresh = source
                .split(separator: "\n", omittingEmptySubsequences: true)
                .first
                .map { String($0.prefix(40)).trimmingCharacters(in: .whitespaces) }
        }
        if derivedTitle != fresh { derivedTitle = fresh }
    }

    /// Rename the tab: file-backed documents rename on disk; untitled buffers
    /// take a custom title. Returns an error message for the UI, nil on success.
    func rename(to rawName: String) -> String? {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        guard let url else {
            customTitle = name
            return nil
        }
        let fileName = name.lowercased().hasSuffix(".md") ? name : name + ".md"
        let dest = url.deletingLastPathComponent().appendingPathComponent(fileName)
        guard dest != url else { return nil }
        guard !FileManager.default.fileExists(atPath: dest.path) else {
            return "A file named “\(fileName)” already exists."
        }
        do {
            try FileManager.default.moveItem(at: url, to: dest)
        } catch {
            return error.localizedDescription
        }
        self.url = dest
        self.title = dest.lastPathComponent
        controller.baseURL = dest.deletingLastPathComponent()
        startWatching() // re-arm on the new path
        Preferences.shared.addRecent(dest)
        return nil
    }

    /// Load a file into a pristine untitled document (Finder open reuses the
    /// initial empty window instead of leaving a stray Untitled behind).
    func adopt(_ newURL: URL) {
        guard url == nil, let text = try? FileService.load(newURL) else { return }
        url = newURL
        title = newURL.lastPathComponent
        source = text
        showTOC = Self.defaultTOCVisibility(for: text) // pristine tab: re-resolve for the real content
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
        // A debounced autosave in flight means the user just typed: don't let a
        // concurrent external change clobber those keystrokes — our save lands
        // in ≤0.5 s and wins (last-writer, active typist prioritized).
        guard saveWork == nil else { return }
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
