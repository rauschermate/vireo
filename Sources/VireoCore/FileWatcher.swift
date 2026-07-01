import Foundation

/// Watches a single file for external changes (git pull, another editor) using a
/// vnode dispatch source, and re-arms across atomic replaces (write+rename).
public final class FileWatcher {
    private let url: URL
    private let onChange: @Sendable () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var fd: Int32 = -1
    private let queue = DispatchQueue(label: "vireo.filewatcher")

    public init(url: URL, onChange: @escaping @Sendable () -> Void) {
        self.url = url
        self.onChange = onChange
        start()
    }

    private func start() {
        fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete, .extend], queue: queue)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            let flags = self.source?.data ?? []
            self.onChange() // caller hops to the main actor
            // On rename/delete (atomic replace) the fd is stale — re-arm.
            if flags.contains(.rename) || flags.contains(.delete) {
                self.restart()
            }
        }
        src.setCancelHandler { [weak self] in
            if let fd = self?.fd, fd >= 0 { close(fd) }
        }
        source = src
        src.resume()
    }

    private func restart() {
        source?.cancel()
        source = nil
        // small delay to let the replacement settle
        queue.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.start() }
    }

    public func stop() {
        source?.cancel()
        source = nil
    }

    deinit { source?.cancel() }
}
