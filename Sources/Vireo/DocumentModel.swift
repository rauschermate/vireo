import AppKit
import SwiftUI
import Combine
import MarkdownEngine
import MarkdownEditor
import VireoCore

/// One open document / tab. Owns the source of truth string, its editor
/// controller, autosave, TOC and external-change reconciliation.
enum DocumentSaveState: Equatable {
    case saved
    case unsaved
    case saving
    case failed(String)

    var failureMessage: String? {
        guard case .failed(let message) = self else { return nil }
        return message
    }
}

enum DocumentConflictResolution { case keepMine, reloadDisk, cancel }

struct DocumentConflict: Equatable {
    var url: URL
    var disk: FileSnapshot
}

@MainActor
final class DocumentModel: ObservableObject, Identifiable {
    let id = UUID()
    @Published var url: URL?
    @Published var title: String
    @Published var toc: [TOCEntry] = []
    /// TOC visibility is per-document: the "dynamic" default depends on each
    /// file's length, and a manual toggle should stick to its tab.
    @Published var showTOC = true
    @Published private(set) var isDirty = false
    @Published private(set) var saveState: DocumentSaveState = .saved
    /// Word and character counts of `source`. Nil while the preference is off.
    @Published private(set) var textStatistics: TextStatistics?
    /// The bundled welcome tour, opened on first launch. It closes without a
    /// save prompt until the user edits it (see `confirmDiscardIfNeeded`).
    var isEphemeralWelcome = false
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
    lazy var editorSession = EditorSession(source: source, controller: controller)
    private(set) var source: String {
        didSet { scheduleTextStatistics(enabled: preferences.showWordCount) }
    }
    private let preferences: Preferences
    private let writer: DocumentWriter
    private let autosaveDelay: TimeInterval
    private let watchesExternalChanges: Bool
    private var watcher: FileWatcher?
    private var saveWork: DispatchWorkItem?
    private var preferenceObserver: AnyCancellable?
    private var statisticsObserver: AnyCancellable?
    private var statisticsTask: Task<Void, Never>?
    private var diskRevision: FileRevision?
    private var editGeneration = 0
    private var activeWriteID = 0
    private var writeInFlight = false
    private var inFlightSource: String?
    private var saveAfterCurrentWrite = false
    private var externalChangePending = false
    private var externalReadID = 0
    private(set) var pendingConflict: DocumentConflict?

    var onSaveFailure: ((String) -> Void)?
    var onSaveConflict: ((DocumentConflict) -> Void)?

    init(url: URL, preferences: Preferences = .shared,
         writer: DocumentWriter = .shared, autosaveDelay: TimeInterval = 0.5,
         watchesExternalChanges: Bool = true) throws {
        let snapshot = try FileService.loadSnapshot(url)
        self.url = url
        self.source = snapshot.source
        self.title = url.lastPathComponent
        self.showTOC = Self.defaultTOCVisibility(for: snapshot.source)
        self.preferences = preferences
        self.writer = writer
        self.autosaveDelay = autosaveDelay
        self.watchesExternalChanges = watchesExternalChanges
        self.diskRevision = snapshot.revision
        configure()
        startWatching()
    }

    init(untitled: String = "", preferences: Preferences = .shared,
         writer: DocumentWriter = .shared, autosaveDelay: TimeInterval = 0.5,
         watchesExternalChanges: Bool = true) {
        self.url = nil
        self.source = untitled
        self.title = "Untitled"
        self.showTOC = Self.defaultTOCVisibility(for: source)
        self.preferences = preferences
        self.writer = writer
        self.autosaveDelay = autosaveDelay
        self.watchesExternalChanges = watchesExternalChanges
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
        preferenceObserver = preferences.$autoSave.dropFirst().sink { [weak self] enabled in
            self?.autoSavePreferenceChanged(enabled)
        }
        // `$showWordCount` emits before the property changes, so pass the
        // emitted value instead of reading the preference back.
        statisticsObserver = preferences.$showWordCount.sink { [weak self] enabled in
            self?.scheduleTextStatistics(enabled: enabled)
        }
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
        if isDirty {
            switch saveSynchronously(notifyFailure: false) {
            case .success: break
            case .failure(let message): return message
            case .conflict: return "The file changed on disk. Resolve that change before renaming."
            }
        }
        do {
            try FileManager.default.moveItem(at: url, to: dest)
        } catch {
            return error.localizedDescription
        }
        relocate(to: dest)
        return nil
    }

    /// The file moved on disk (sidebar rename or drag): follow it without
    /// touching the buffer.
    func relocate(to newURL: URL) {
        url = newURL
        title = newURL.lastPathComponent
        controller.baseURL = newURL.deletingLastPathComponent()
        startWatching() // re-arm on the new path
        Preferences.shared.addRecent(newURL)
    }

    /// Load a file into a pristine untitled document (Finder open reuses the
    /// initial empty window instead of leaving a stray Untitled behind).
    func adopt(_ newURL: URL) {
        guard url == nil, let snapshot = try? FileService.loadSnapshot(newURL) else { return }
        url = newURL
        title = newURL.lastPathComponent
        source = snapshot.source
        diskRevision = snapshot.revision
        showTOC = Self.defaultTOCVisibility(for: snapshot.source) // pristine tab: re-resolve for the real content
        isDirty = false
        saveState = .saved
        controller.baseURL = newURL.deletingLastPathComponent()
        controller.replaceEntireSource(snapshot.source)
        startWatching()
    }

    // MARK: Editing / saving

    func handleEdit(_ text: String) {
        source = text
        editGeneration += 1
        isDirty = true
        pendingConflict = nil
        if preferences.autoSave, url != nil {
            scheduleAutosave()
        } else {
            saveWork?.cancel()
            saveWork = nil
            saveAfterCurrentWrite = false
            if !writeInFlight { saveState = .unsaved }
        }
    }

    /// Counts run off the main thread after a short pause, so typing in a
    /// large document never waits on them.
    private func scheduleTextStatistics(enabled: Bool) {
        statisticsTask?.cancel()
        guard enabled else {
            textStatistics = nil
            return
        }
        let text = source
        statisticsTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            let stats = await Task.detached(priority: .utility) { TextStatistics.measure(text) }.value
            guard !Task.isCancelled else { return }
            self?.textStatistics = stats
        }
    }

    private func autoSavePreferenceChanged(_ enabled: Bool) {
        guard url != nil, isDirty else { return }
        if enabled {
            scheduleAutosave(delay: 0)
        } else {
            saveWork?.cancel()
            saveWork = nil
            saveAfterCurrentWrite = false
            if !writeInFlight, saveState.failureMessage == nil { saveState = .unsaved }
        }
    }

    private func scheduleAutosave(delay: TimeInterval? = nil) {
        saveWork?.cancel()
        if !writeInFlight { saveState = .unsaved }
        let work = DispatchWorkItem { [weak self] in
            self?.saveWork = nil
            self?.beginSave()
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (delay ?? autosaveDelay), execute: work)
    }

    func saveNow() {
        guard let url else { return }
        saveWork?.cancel()
        saveWork = nil
        pendingConflict = nil
        beginSave(to: url)
    }

    private func beginSave(to destination: URL? = nil) {
        guard let target = destination ?? url else { return }
        if writeInFlight {
            saveAfterCurrentWrite = true
            saveState = .saving
            return
        }
        let generation = editGeneration
        let snapshot = source
        activeWriteID += 1
        let writeID = activeWriteID
        writeInFlight = true
        inFlightSource = snapshot
        saveState = .saving
        writer.write(source: snapshot, to: target, expected: diskRevision) { [weak self] result in
            Task { @MainActor in
                self?.finishWrite(result, generation: generation, writeID: writeID, target: target)
            }
        }
    }

    private func finishWrite(_ result: DocumentWriteResult, generation: Int,
                             writeID: Int, target: URL) {
        guard writeID == activeWriteID else { return }
        writeInFlight = false
        inFlightSource = nil
        apply(result, generation: generation, notifyFailure: true, conflictURL: target)

        let succeeded: Bool
        if case .success = result { succeeded = true } else { succeeded = false }
        let shouldSaveAgain = succeeded && saveAfterCurrentWrite && isDirty
            && preferences.autoSave && pendingConflict == nil
        saveAfterCurrentWrite = false
        if shouldSaveAgain { beginSave() }
        if externalChangePending {
            externalChangePending = false
            externalChange()
        }
    }

    @discardableResult
    func saveSynchronously(notifyFailure: Bool = true) -> DocumentWriteResult {
        guard let url else { return .failure("Choose a file location first.") }
        saveWork?.cancel()
        saveWork = nil
        saveAfterCurrentWrite = false
        activeWriteID += 1 // invalidate any queued main-actor completion
        let generation = editGeneration
        let snapshot = source
        var result = writer.writeSynchronously(source: snapshot, to: url, expected: diskRevision)

        // A previously queued write may have completed on the serial I/O lane
        // while its main-actor completion was waiting behind this close/save.
        // Recognize that exact snapshot as ours, advance the revision, and retry
        // the newest generation without weakening external-change checks.
        if case .conflict(let disk) = result, writeInFlight, disk.source == inFlightSource {
            diskRevision = disk.revision
            result = writer.writeSynchronously(source: snapshot, to: url, expected: disk.revision)
        }
        writeInFlight = false
        inFlightSource = nil
        apply(result, generation: generation, notifyFailure: notifyFailure, conflictURL: url)
        return result
    }

    private func apply(_ result: DocumentWriteResult, generation: Int, notifyFailure: Bool,
                       conflictURL: URL? = nil) {
        switch result {
        case .success(let revision):
            diskRevision = revision
            pendingConflict = nil
            if generation == editGeneration {
                isDirty = false
                saveState = .saved
            } else {
                isDirty = true
                saveState = preferences.autoSave ? .saving : .unsaved
            }
        case .failure(let message):
            isDirty = true
            saveState = .failed(message)
            if notifyFailure { onSaveFailure?(message) }
        case .conflict(let disk):
            guard let conflictURL = conflictURL ?? url else {
                let message = "The destination changed before Vireo could finish saving."
                isDirty = true
                saveState = .failed(message)
                if notifyFailure { onSaveFailure?(message) }
                return
            }
            let conflict = DocumentConflict(url: conflictURL, disk: disk)
            pendingConflict = conflict
            isDirty = true
            saveState = .failed("The file changed on disk before Vireo could save.")
            saveWork?.cancel()
            saveWork = nil
            saveAfterCurrentWrite = false
            if notifyFailure { onSaveConflict?(conflict) }
        }
    }

    /// Save to a new URL (Save As / first save of an untitled doc).
    @discardableResult
    func save(to newURL: URL) -> Bool {
        saveWork?.cancel()
        saveWork = nil
        activeWriteID += 1
        let result = writer.writeSynchronously(source: source, to: newURL, expected: nil)
        guard case .success(let revision) = result else {
            apply(result, generation: editGeneration, notifyFailure: true, conflictURL: newURL)
            return false
        }
        url = newURL
        title = newURL.lastPathComponent
        diskRevision = revision
        isDirty = false
        saveState = .saved
        writeInFlight = false
        inFlightSource = nil
        controller.baseURL = newURL.deletingLastPathComponent()
        startWatching()
        return true
    }

    // MARK: External changes

    private func startWatching() {
        guard watchesExternalChanges, let url else { return }
        watcher?.stop()
        watcher = FileWatcher(url: url) { [weak self] in
            Task { @MainActor in self?.externalChange() }
        }
    }

    private func externalChange() {
        guard let url else { return }
        if writeInFlight {
            externalChangePending = true
            return
        }
        externalReadID += 1
        let readID = externalReadID
        writer.read(url) { [weak self] result in
            Task { @MainActor in self?.finishExternalRead(result, readID: readID, url: url) }
        }
    }

    private func finishExternalRead(_ result: DocumentReadResult, readID: Int, url: URL) {
        guard readID == externalReadID, self.url == url else { return }
        switch result {
        case .failure(let message):
            isDirty = true
            saveState = .failed(message)
            onSaveFailure?(message)
        case .success(let disk):
            guard disk.revision != diskRevision else { return }
            if isDirty {
                apply(.conflict(disk), generation: editGeneration, notifyFailure: true)
            } else {
                reload(disk)
            }
        }
    }

    func resolveConflict(_ resolution: DocumentConflictResolution,
                         conflict: DocumentConflict? = nil) {
        guard let conflict = conflict ?? pendingConflict else { return }
        switch resolution {
        case .keepMine:
            diskRevision = conflict.disk.revision
            pendingConflict = nil
            beginSave()
        case .reloadDisk:
            reload(conflict.disk)
        case .cancel:
            break
        }
    }

    func acceptConflictForSynchronousOverwrite(_ conflict: DocumentConflict) {
        diskRevision = conflict.disk.revision
        pendingConflict = nil
        saveState = .unsaved
        isDirty = true
    }

    private func reload(_ disk: FileSnapshot) {
        activeWriteID += 1
        saveWork?.cancel()
        saveWork = nil
        saveAfterCurrentWrite = false
        pendingConflict = nil
        source = disk.source
        diskRevision = disk.revision
        editGeneration += 1
        controller.replaceEntireSource(disk.source)
        isDirty = false
        saveState = .saved
    }

    var autoSaveEnabled: Bool { preferences.autoSave }
}
