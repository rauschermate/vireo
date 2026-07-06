import AppKit
import ImageIO

/// Loads and caches inline images. Local files load synchronously; remote URLs
/// load asynchronously and invoke `onChange` when a fetch completes so the
/// editor can re-render (PRD §6: never block layout on a network image).
///
/// Images are downsampled to display resolution on decode: the reading column
/// is at most `contentMaxWidth` (720pt) wide, so a full-resolution phone photo
/// (4000+ px) would otherwise keep tens of MB of RGBA backing store alive for a
/// picture that never draws larger than ~1440px on a 2× display. Downsampling
/// is visually lossless at the sizes we draw and cuts image memory 10–50×.
@MainActor
public final class ImageLoader {
    private var cache: [String: NSImage] = [:]
    private var inFlight: Set<String> = []
    public var onChange: (() -> Void)?

    /// Longest edge (in pixels) an image is decoded to. 1440 covers the 720pt
    /// content column at 2× Retina; the small headroom keeps it crisp if the
    /// column ever widens. Smaller originals are never upscaled.
    private let maxPixelSize = 1600

    public init() {}

    /// Returns a cached image, or nil while (a)synchronously loading.
    public func image(forSource src: String, baseURL: URL?) -> NSImage? {
        if let cached = cache[src] { return cached }

        guard let url = resolve(src, baseURL: baseURL) else { return nil }
        if url.isFileURL {
            if let img = Self.downsampledImage(from: url, maxPixelSize: maxPixelSize) {
                cache[src] = img
                return img
            }
            return nil
        }

        // Remote: fetch once, cache, notify.
        if !inFlight.contains(src) {
            inFlight.insert(src)
            let maxPixelSize = maxPixelSize
            Task { [weak self] in
                let data = try? await URLSession.shared.data(from: url).0
                let img = data.flatMap { Self.downsampledImage(from: $0, maxPixelSize: maxPixelSize) }
                await MainActor.run {
                    guard let self else { return }
                    self.inFlight.remove(src)
                    if let img {
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

    // MARK: Downsampling

    private static func downsampledImage(from url: URL, maxPixelSize: Int) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            // Fall back so animated/unsupported formats still display.
            return NSImage(contentsOf: url)
        }
        return downsample(source, maxPixelSize: maxPixelSize) ?? NSImage(contentsOf: url)
    }

    private static func downsampledImage(from data: Data, maxPixelSize: Int) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return NSImage(data: data)
        }
        return downsample(source, maxPixelSize: maxPixelSize) ?? NSImage(data: data)
    }

    /// Decode `source` straight to a thumbnail no larger than `maxPixelSize` on
    /// its longest edge. `...ThumbnailFromImageAlways` + `...ShouldCacheImmediately`
    /// makes ImageIO scale during decode, so the full-size bitmap is never
    /// materialised. The NSImage's `size` is set to the original's DPI-aware
    /// point size (exactly what `NSImage(contentsOf:)` would report) so the
    /// drawn size is unchanged — only the backing bitmap shrinks.
    private static func downsample(_ source: CGImageSource, maxPixelSize: Int) -> NSImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        let pointSize = pointSize(of: source) ?? NSSize(width: cg.width, height: cg.height)
        return NSImage(cgImage: cg, size: pointSize)
    }

    /// The image's size in points, honouring DPI metadata the same way
    /// `NSImage` does, so downsampled images draw at the identical size.
    private static func pointSize(of source: CGImageSource) -> NSSize? {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let pw = props[kCGImagePropertyPixelWidth] as? CGFloat,
              let ph = props[kCGImagePropertyPixelHeight] as? CGFloat, pw > 0, ph > 0 else {
            return nil
        }
        let dpiW = (props[kCGImagePropertyDPIWidth] as? CGFloat) ?? 72
        let dpiH = (props[kCGImagePropertyDPIHeight] as? CGFloat) ?? 72
        let scaleW = dpiW > 0 ? 72 / dpiW : 1
        let scaleH = dpiH > 0 ? 72 / dpiH : 1
        return NSSize(width: pw * scaleW, height: ph * scaleH)
    }
}
