import AppKit
import ImageIO
import MarkdownEngine

private struct DecodedImage: @unchecked Sendable {
    let image: NSImage
    let decodedCost: Int
}

/// Image I/O and ImageIO decoding deliberately live outside ImageLoader's main
/// actor. AppKit owns the cache and callbacks; this worker only creates the
/// immutable image that will be handed back to it.
private enum ImageDecoder {
    static func load(_ url: URL, maxPixelSize: Int) async -> DecodedImage? {
        if url.isFileURL {
            return downsampledImage(from: url, maxPixelSize: maxPixelSize)
        }
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse).map({ 200..<300 ~= $0.statusCode }) ?? true else {
            return nil
        }
        return downsampledImage(from: data, maxPixelSize: maxPixelSize)
    }

    private static func downsampledImage(from url: URL,
                                         maxPixelSize: Int) -> DecodedImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return NSImage(contentsOf: url).flatMap(fallback)
        }
        return downsample(source, maxPixelSize: maxPixelSize)
            ?? NSImage(contentsOf: url).flatMap(fallback)
    }

    private static func downsampledImage(from data: Data,
                                         maxPixelSize: Int) -> DecodedImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return NSImage(data: data).flatMap(fallback)
        }
        return downsample(source, maxPixelSize: maxPixelSize)
            ?? NSImage(data: data).flatMap(fallback)
    }

    /// Decode straight to a thumbnail so a full-resolution source bitmap is
    /// never materialised just to draw inside the reading column.
    private static func downsample(_ source: CGImageSource,
                                   maxPixelSize: Int) -> DecodedImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(
            source, 0, options as CFDictionary
        ) else { return nil }
        let pointSize = pointSize(of: source)
            ?? NSSize(width: cg.width, height: cg.height)
        return DecodedImage(image: NSImage(cgImage: cg, size: pointSize),
                            decodedCost: max(1, cg.bytesPerRow * cg.height))
    }

    /// Force an unsupported/animated format to provide a representation on the
    /// worker too, avoiding a deferred first decode in the paint path.
    private static func fallback(_ image: NSImage) -> DecodedImage? {
        var proposed = NSRect(origin: .zero, size: image.size)
        guard let cg = image.cgImage(forProposedRect: &proposed,
                                    context: nil, hints: nil) else { return nil }
        return DecodedImage(image: image,
                            decodedCost: max(1, cg.bytesPerRow * cg.height))
    }

    private static func pointSize(of source: CGImageSource) -> NSSize? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let pixelWidth = properties[kCGImagePropertyPixelWidth] as? CGFloat,
              let pixelHeight = properties[kCGImagePropertyPixelHeight] as? CGFloat,
              pixelWidth > 0, pixelHeight > 0 else { return nil }
        let dpiWidth = (properties[kCGImagePropertyDPIWidth] as? CGFloat) ?? 72
        let dpiHeight = (properties[kCGImagePropertyDPIHeight] as? CGFloat) ?? 72
        return NSSize(width: pixelWidth * (dpiWidth > 0 ? 72 / dpiWidth : 1),
                      height: pixelHeight * (dpiHeight > 0 ? 72 / dpiHeight : 1))
    }
}

/// Resolves, loads, downsamples and cost-bounds inline images. Cache ownership
/// stays on the main actor because NSImage is consumed by AppKit drawing, while
/// every file/network read and decode runs in a detached worker.
@MainActor
public final class ImageLoader {
    private struct CacheEntry {
        let image: NSImage
        let decodedCost: Int
        var accessOrder: UInt64
    }

    private var cache: [URL: CacheEntry] = [:]
    private var cachedCost = 0
    private var accessOrder: UInt64 = 0
    private var inFlight: Set<URL> = []
    private var failedUntil: [URL: Date] = [:]
    private var pendingChanges: Set<URL> = []
    private var changeDeliveryTask: Task<Void, Never>?

    private let cacheCostLimit: Int
    private let changeCoalescingInterval: Duration
    private let failureRetryInterval: TimeInterval
    private let maxPixelSize = 1_600

    /// Resolved URLs whose images became available in the same coalesced batch.
    public var onChange: ((Set<URL>) -> Void)?

    public init() {
        cacheCostLimit = 96 * 1_024 * 1_024
        changeCoalescingInterval = .milliseconds(16)
        failureRetryInterval = 30
    }

    init(cacheCostLimit: Int, changeCoalescingInterval: Duration,
         failureRetryInterval: TimeInterval = 30) {
        self.cacheCostLimit = max(1, cacheCostLimit)
        self.changeCoalescingInterval = changeCoalescingInterval
        self.failureRetryInterval = failureRetryInterval
    }

    /// Returns a cached image, or nil while the resolved URL is loading.
    public func image(forSource source: String, baseURL: URL?) -> NSImage? {
        guard let url = resolvedURL(forSource: source, baseURL: baseURL) else {
            return nil
        }
        if var entry = cache[url] {
            accessOrder &+= 1
            entry.accessOrder = accessOrder
            cache[url] = entry
            return entry.image
        }
        if let retry = failedUntil[url] {
            guard retry <= Date() else { return nil }
            failedUntil.removeValue(forKey: url)
        }
        guard inFlight.insert(url).inserted else { return nil }
        startLoading(url)
        return nil
    }

    /// Canonical cache key. Relative paths are made absolute against the
    /// document first; URL fragments are ignored because they do not change
    /// the fetched image resource.
    public func resolvedURL(forSource source: String, baseURL: URL?) -> URL? {
        let url: URL
        if let absolute = URL(string: source),
           let scheme = absolute.scheme?.lowercased() {
            guard scheme == "http" || scheme == "https" || scheme == "file" else {
                return nil
            }
            url = absolute
        } else if source.hasPrefix("/") {
            url = URL(fileURLWithPath: source)
        } else if let baseURL {
            if baseURL.isFileURL {
                url = baseURL.appendingPathComponent(source)
            } else if let relative = URL(string: source, relativeTo: baseURL) {
                url = relative.absoluteURL
            } else {
                return nil
            }
        } else {
            return nil
        }

        if url.isFileURL { return url.standardizedFileURL }
        guard var components = URLComponents(url: url.absoluteURL,
                                             resolvingAgainstBaseURL: true) else {
            return url.absoluteURL
        }
        components.fragment = nil
        return components.url
    }

    /// Paragraphs whose reserved height must be recomputed for a completion
    /// batch. Multiple images in the same/adjacent paragraph are merged.
    public func paragraphRanges(forLoadedURLs loadedURLs: Set<URL>,
                                images: [ImageRun], source: String,
                                baseURL: URL?) -> [NSRange] {
        guard !loadedURLs.isEmpty else { return [] }
        let text = source as NSString
        let full = NSRange(location: 0, length: text.length)
        let ranges = images.compactMap { image -> NSRange? in
            guard let url = resolvedURL(forSource: image.source, baseURL: baseURL),
                  loadedURLs.contains(url), image.range.location <= text.length else {
                return nil
            }
            return text.paragraphRange(for: NSIntersectionRange(image.range, full))
        }.sorted { $0.location < $1.location }

        var merged: [NSRange] = []
        for range in ranges {
            guard let last = merged.last else {
                merged.append(range)
                continue
            }
            if range.location <= last.upperBound {
                merged[merged.count - 1] = NSUnionRange(last, range)
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    private func startLoading(_ url: URL) {
        let maxPixelSize = maxPixelSize
        let worker = Task.detached(priority: .utility) {
            await ImageDecoder.load(url, maxPixelSize: maxPixelSize)
        }
        Task { @MainActor [weak self] in
            let decoded = await worker.value
            guard let self else { return }
            self.inFlight.remove(url)
            guard let decoded else {
                self.failedUntil[url] = Date().addingTimeInterval(self.failureRetryInterval)
                return
            }
            self.insert(decoded, for: url)
            self.enqueueChange(for: url)
        }
    }

    private func insert(_ decoded: DecodedImage, for url: URL) {
        if let old = cache.removeValue(forKey: url) {
            cachedCost -= old.decodedCost
        }
        accessOrder &+= 1
        cache[url] = CacheEntry(image: decoded.image,
                                decodedCost: decoded.decodedCost,
                                accessOrder: accessOrder)
        cachedCost += decoded.decodedCost

        while cachedCost > cacheCostLimit, cache.count > 1,
              let leastRecent = cache.min(by: {
                  $0.value.accessOrder < $1.value.accessOrder
              })?.key,
              let removed = cache.removeValue(forKey: leastRecent) {
            cachedCost -= removed.decodedCost
        }
    }

    private func enqueueChange(for url: URL) {
        pendingChanges.insert(url)
        guard changeDeliveryTask == nil else { return }
        let interval = changeCoalescingInterval
        changeDeliveryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: interval)
            guard let self, !Task.isCancelled else { return }
            let changed = self.pendingChanges
            self.pendingChanges.removeAll(keepingCapacity: true)
            self.changeDeliveryTask = nil
            if !changed.isEmpty { self.onChange?(changed) }
        }
    }

    // Test-only observability through @testable import.
    var cachedDecodedCost: Int { cachedCost }
    var cachedImageCount: Int { cache.count }
    var inFlightCount: Int { inFlight.count }
}
