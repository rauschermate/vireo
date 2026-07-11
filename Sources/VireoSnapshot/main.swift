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
            if args.contains("--bench") {
                bench(inputPath: inputPath)
            } else {
                render(inputPath: inputPath, outPath: outPath, dark: dark)
            }
        }
    }

    /// `--bench`: time the parse and render stages separately (no drawing).
    @MainActor
    static func bench(inputPath: String) {
        guard let source = try? String(contentsOfFile: inputPath, encoding: .utf8) else {
            FileHandle.standardError.write("cannot read \(inputPath)\n".data(using: .utf8)!)
            exit(1)
        }
        let bytes = source.utf8.count
        let parser = MarkdownParser()
        let loader = ImageLoader()
        let renderer = MarkdownRenderer(theme: Theme(zoom: 1.0), imageLoader: loader, isDark: false)

        // warm-up
        _ = parser.parse(source)

        func time(_ label: String, _ block: () -> Void) {
            let t0 = DispatchTime.now().uptimeNanoseconds
            block()
            let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
            print(String(format: "%@: %.1f ms", label, ms))
        }

        var parsed = ParsedMarkdown()
        time("full parse (incl. source mapping)") { parsed = parser.parse(source) }
        time("full render (attributed string)") { _ = renderer.render(source: source, parsed: parsed) }

        // Simulate a keystroke mid-document through the incremental path.
        let incremental = IncrementalParser()
        _ = incremental.update(source)
        let ns = source as NSString
        let mid = ns.length / 2
        let insertAt = ns.range(of: "\n", options: [], range: NSRange(location: mid, length: ns.length - mid)).location + 1
        let edited = ns.replacingCharacters(in: NSRange(location: insertAt, length: 0), with: "x")
        var update: IncrementalUpdate?
        time("incremental keystroke (parse+splice)") { update = incremental.update(edited) }
        if let update {
            if let dirty = update.dirtyRange {
                var sliceMS = 0.0
                let t0 = DispatchTime.now().uptimeNanoseconds
                let sliceSource = (edited as NSString).substring(with: dirty)
                let sliceParsed = update.parsed.slice(dirty)
                _ = renderer.render(source: sliceSource, parsed: sliceParsed)
                sliceMS = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
                print(String(format: "incremental slice render: %.1f ms (dirty %d chars)", sliceMS, dirty.length))
            } else {
                print("incremental keystroke fell back to full")
            }
        }
        print("size: \(bytes / 1024) KB, blocks: \(parsed.blockRuns.count), markers: \(parsed.markerRanges.count)")
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
        var renderer = MarkdownRenderer(theme: Theme(zoom: 1.0),
                                        baseURL: URL(fileURLWithPath: inputPath).deletingLastPathComponent(),
                                        imageLoader: loader, isDark: dark)
        let args = CommandLine.arguments
        // --collapse-first: collapse the first collapsible list item
        var collapsed: Set<Int> = []
        if args.contains("--collapse-first"),
           let anchor = (parsed.listMarkers.first { $0.subtreeRange != nil }?.anchor)
            ?? (parsed.tasks.first { $0.subtreeRange != nil }?.anchor) {
            collapsed.insert(anchor)
        }
        // --collapse-heading <n>: collapse the nth foldable heading (0-based)
        if let i = args.firstIndex(of: "--collapse-heading"), i + 1 < args.count,
           let n = Int(args[i + 1]) {
            let foldable = parsed.headings.filter { $0.subtreeRange != nil }
            if foldable.indices.contains(n) { collapsed.insert(foldable[n].anchor) }
        }
        renderer.collapsedAnchors = collapsed
        let attributed = renderer.render(source: source, parsed: parsed)

        let width: CGFloat = 760
        let inset: CGFloat = 24
        let storage = NSTextStorage(attributedString: attributed)
        let layout = MarkdownLayoutManager()
        layout.markerColor = .secondaryLabelColor
        layout.bulletFont = .systemFont(ofSize: 16)
        let theme = Theme(zoom: 1.0)
        layout.tables = parsed.tables
        layout.tableRowHeight = theme.tableRowHeight
        layout.tableFont = theme.tableFont
        layout.tableHeaderFont = theme.tableHeaderFont
        layout.listMarkers = parsed.listMarkers
        layout.taskMarks = parsed.tasks
        layout.headingMarks = parsed.headings
        layout.collapsedAnchors = collapsed
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

        // --select A,B: draw a selection highlight over character range [A,B),
        // mimicking how NSTextView fills selection rects, to verify the
        // text-only highlight in MarkdownLayoutManager.fillBackgroundRectArray.
        if let i = args.firstIndex(of: "--select"), i + 1 < args.count {
            let parts = args[i + 1].split(separator: ",").compactMap { Int($0) }
            if parts.count == 2 {
                let sel = NSRange(location: parts[0], length: max(0, parts[1] - parts[0]))
                NSColor.selectedTextBackgroundColor.setFill()
                var count = 0
                // Mirror how NSTextView draws selection: ask the layout manager
                // for the selection rects (now trimmed to the glyph extent) and
                // fill them, offset to the draw origin.
                let rects = layout.rectArray(forCharacterRange: sel,
                                             withinSelectedCharacterRange: sel,
                                             in: container, rectCount: &count)
                if let rects {
                    for k in 0..<count {
                        NSBezierPath(rect: rects[k].offsetBy(dx: origin.x, dy: origin.y)).fill()
                    }
                }
            }
        }

        layout.drawGlyphs(forGlyphRange: glyphRange, at: origin)

        NSGraphicsContext.restoreGraphicsState()
        cg.restoreGState()

        guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
        try? png.write(to: URL(fileURLWithPath: outPath))
        print("wrote \(outPath) (\(Int(width))×\(Int(height)))")
    }
}
