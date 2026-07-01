import AppKit

/// Loads and caches inline images. Local files load synchronously; remote URLs
/// load asynchronously and invoke `onChange` when a fetch completes so the
/// editor can re-render (PRD §6: never block layout on a network image).
@MainActor
public final class ImageLoader {
    private var cache: [String: NSImage] = [:]
    private var inFlight: Set<String> = []
    public var onChange: (() -> Void)?

    public init() {}

    /// Returns a cached image, or nil while (a)synchronously loading.
    public func image(forSource src: String, baseURL: URL?) -> NSImage? {
        if let cached = cache[src] { return cached }

        guard let url = resolve(src, baseURL: baseURL) else { return nil }
        if url.isFileURL {
            if let img = NSImage(contentsOf: url) {
                cache[src] = img
                return img
            }
            return nil
        }

        // Remote: fetch once, cache, notify.
        if !inFlight.contains(src) {
            inFlight.insert(src)
            Task { [weak self] in
                let data = try? await URLSession.shared.data(from: url).0
                await MainActor.run {
                    guard let self else { return }
                    self.inFlight.remove(src)
                    if let data, let img = NSImage(data: data) {
                        self.cache[src] = img
                        self.onChange?()
                    }
                }
            }
        }
        return nil
    }

    private func resolve(_ src: String, baseURL: URL?) -> URL? {
        if let u = URL(string: src), u.scheme == "http" || u.scheme == "https" {
            return u
        }
        if src.hasPrefix("/") { return URL(fileURLWithPath: src) }
        if let base = baseURL { return base.appendingPathComponent(src) }
        return URL(string: src)
    }
}
