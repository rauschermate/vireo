import AppKit
import MarkdownEngine
import MarkdownRender

// Headless snapshot: run the real parse → render → TextKit layout pipeline into
// an offscreen PNG so hidden-syntax rendering can be verified without a window.

@main
struct Snapshot {
    static func main() {
        let args = CommandLine.arguments
        let inputPath = args.count > 1 ? args[1] : "samples/welcome.md"
        let outPath = args.count > 2 ? args[2] : "/tmp/vireo-snapshot.png"
        let dark = args.contains("--dark")

        MainActor.assumeIsolated {
            render(inputPath: inputPath, outPath: outPath, dark: dark)
        }
    }

    @MainActor
    static func render(inputPath: String, outPath: String, dark: Bool) {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        NSAppearance.current = appearance

        guard let source = try? String(contentsOfFile: inputPath, encoding: .utf8) else {
            FileHandle.standardError.write("cannot read \(inputPath)\n".data(using: .utf8)!)
            exit(1)
        }

        let parsed = MarkdownParser().parse(source)
        let loader = ImageLoader()
        let renderer = MarkdownRenderer(theme: Theme(zoom: 1.0),
                                        baseURL: URL(fileURLWithPath: inputPath).deletingLastPathComponent(),
                                        imageLoader: loader, isDark: dark)
        let attributed = renderer.render(source: source, parsed: parsed)

        let width: CGFloat = 760
        let inset: CGFloat = 24
        let storage = NSTextStorage(attributedString: attributed)
        let layout = MarkdownLayoutManager()
        layout.markerColor = .secondaryLabelColor
        layout.bulletFont = .systemFont(ofSize: 16)
        layout.imageProvider = { loader.image(forSource: $0, baseURL: URL(fileURLWithPath: inputPath).deletingLastPathComponent()) }
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: width - inset * 2, height: 100_000))
        container.lineFragmentPadding = 8
        layout.addTextContainer(container)
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        let height = ceil(used.height) + inset * 2

        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: Int(width), pixelsHigh: Int(height),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else {
            FileHandle.standardError.write("no bitmap context\n".data(using: .utf8)!)
            exit(1)
        }

        // Wrap the bitmap's CGContext in a *flipped* NSGraphicsContext (top-left
        // origin, y down) so NSLayoutManager draws upright text top-to-bottom,
        // matching a real (flipped) NSTextView.
        let cg = ctx.cgContext
        cg.saveGState()
        cg.translateBy(x: 0, y: height)
        cg.scaleBy(x: 1, y: -1)
        let flipped = NSGraphicsContext(cgContext: cg, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = flipped

        (dark ? NSColor(white: 0.12, alpha: 1) : NSColor.textBackgroundColor).setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()

        let glyphRange = layout.glyphRange(for: container)
        let origin = NSPoint(x: inset, y: inset)
        layout.drawBackground(forGlyphRange: glyphRange, at: origin)
        layout.drawGlyphs(forGlyphRange: glyphRange, at: origin)

        NSGraphicsContext.restoreGraphicsState()
        cg.restoreGState()

        guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
        try? png.write(to: URL(fileURLWithPath: outPath))
        print("wrote \(outPath) (\(Int(width))×\(Int(height)))")
    }
}
