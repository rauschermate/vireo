import Foundation
import CoreServices

/// Watches a whole folder tree (the sidebar workspace) with FSEvents and
/// reports coalesced changes. Every event is folded into one `onChange` call
/// after a short quiet period, so a `git pull` that touches 200 files triggers
/// one tree rebuild.
public final class WorkspaceWatcher: @unchecked Sendable {
    private let root: URL
    private let debounce: TimeInterval
    private let onChange: @Sendable () -> Void
    private let queue = DispatchQueue(label: "vireo.workspacewatcher")
    private var stream: FSEventStreamRef?
    private var pending: DispatchWorkItem?

    public init(root: URL, debounce: TimeInterval = 0.35,
                onChange: @escaping @Sendable () -> Void) {
        self.root = root
        self.debounce = debounce
        self.onChange = onChange
        start()
    }

    private func start() {
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<WorkspaceWatcher>.fromOpaque(info).takeUnretainedValue()
            // With `kFSEventStreamCreateFlagUseCFTypes` the paths arrive as a CFArray.
            let array = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
            watcher.handle(paths: array.prefix(count).map { $0 })
        }
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes
            | kFSEventStreamCreateFlagFileEvents
            | kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context,
            [root.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.2, flags) else { return }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    private func handle(paths: [String]) {
        // Skip the temp files atomic writes leave behind for a moment, and
        // other dotfiles the sidebar never shows.
        let relevant = paths.contains { path in
            let name = (path as NSString).lastPathComponent
            return !name.hasPrefix(".")
        }
        guard relevant else { return }
        pending?.cancel()
        let work = DispatchWorkItem { [onChange] in onChange() }
        pending = work
        queue.asyncAfter(deadline: .now() + debounce, execute: work)
    }

    public func stop() {
        pending?.cancel()
        pending = nil
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit { stop() }
}
