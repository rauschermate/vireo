import AppKit
import MarkdownEngine
import MarkdownRender

/// Repeatable release benchmark for the complete initial source-to-pixel path.
/// Fixtures are generated deterministically so multi-megabyte blobs do not live
/// in git. Timing assertions are opt-in because debug builds and developer
/// machines are intentionally not performance-stable environments.
@MainActor
enum RenderBenchmark {
    private struct Fixture {
        let name: String
        let source: String
    }

    private struct Samples {
        var parse: [Double] = []
        var attributedRender: [Double] = []
        var liveApply: [Double] = []
        var layout: [Double] = []
        var draw: [Double] = []
        var openToPixel: [Double] = []
        var visibleGlyphs = 0
    }

    static func run(arguments: [String]) {
        let count = integer(after: "--samples", in: arguments) ?? 5
        let denseKB = integer(after: "--target-kb", in: arguments) ?? 1_720
        let shouldAssert = arguments.contains("--assert-budgets")
        let fixtures = fixtures(denseKB: denseKB)

        print("Vireo source-to-pixel benchmark (\(count) measured samples, 1 warm-up)")
        print("Run with: swift run -c release VireoSnapshot --benchmark-suite --samples \(count)")
        var failed = false
        for fixture in fixtures {
            autoreleasepool { _ = measure(fixture) } // warm-up
            var samples = Samples()
            for _ in 0..<max(1, count) {
                autoreleasepool {
                    let measured = measure(fixture)
                    samples.parse.append(measured.parse)
                    samples.attributedRender.append(measured.attributedRender)
                    samples.liveApply.append(measured.liveApply)
                    samples.layout.append(measured.layout)
                    samples.draw.append(measured.draw)
                    samples.openToPixel.append(measured.openToPixel)
                    samples.visibleGlyphs = measured.visibleGlyphs
                }
            }
            let size = fixture.source.utf8.count
            print("\n\(fixture.name): \(String(format: "%.2f", Double(size) / 1_048_576)) MiB")
            report("parse", samples.parse)
            report("attributed render", samples.attributedRender)
            report("live storage apply", samples.liveApply)
            report("initial viewport layout", samples.layout)
            report("initial viewport draw", samples.draw)
            report("open-to-pixel", samples.openToPixel)
            print("  initial draw glyphs      \(samples.visibleGlyphs)")

            if shouldAssert {
                let renderBudget = 1_000.0
                // The combined guard includes parse, direct live application,
                // initial viewport layout, and visible drawing for an
                // intentionally adversarial formatting-dense fixture. It
                // catches both the historical 7–10 s renderer regression and
                // future source-to-pixel regressions in the integrated stack.
                let pipelineBudget = 4_000.0
                if percentile(samples.attributedRender, 0.95) > renderBudget
                    || percentile(samples.openToPixel, 0.95) > pipelineBudget {
                    failed = true
                    print("BUDGET FAILED: render p95 ≤ 1000 ms, open-to-pixel p95 ≤ 4000 ms")
                }
            }
        }
        if failed { exit(2) }
    }

    /// Export the exact deterministic sources used by the benchmark so a
    /// reviewer can exercise open and edit behavior in the real app.
    static func writeFixtures(arguments: [String]) {
        guard let directory = string(after: "--write-benchmark-fixtures",
                                     in: arguments) else {
            FileHandle.standardError.write(
                "missing directory after --write-benchmark-fixtures\n".data(using: .utf8)!
            )
            exit(1)
        }
        let denseKB = integer(after: "--target-kb", in: arguments) ?? 1_720
        let root = URL(fileURLWithPath: directory, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: root,
                                                    withIntermediateDirectories: true)
            for fixture in fixtures(denseKB: denseKB) {
                let url = root.appendingPathComponent("\(fixture.name).md")
                try fixture.source.write(to: url, atomically: true, encoding: .utf8)
                print("Wrote \(url.path) (\(fixture.source.utf8.count) bytes)")
            }
        } catch {
            FileHandle.standardError.write("fixture export failed: \(error)\n".data(using: .utf8)!)
            exit(1)
        }
    }

    private static func fixtures(denseKB: Int) -> [Fixture] {
        [
            Fixture(name: "formatting-dense",
                    source: denseFixture(targetBytes: denseKB * 1_024)),
            Fixture(name: "single-code-block",
                    source: codeFixture(targetBytes: denseKB * 2 * 1_024)),
        ]
    }

    private static func measure(_ fixture: Fixture) -> (
        parse: Double, attributedRender: Double, liveApply: Double,
        layout: Double, draw: Double, openToPixel: Double, visibleGlyphs: Int
    ) {
        let parser = MarkdownParser()
        let renderer = MarkdownRenderer(theme: Theme(), isDark: false)
        let pipelineStart = now()

        let parseStart = now()
        let parsed = parser.parse(fixture.source)
        let parse = elapsed(since: parseStart)

        let renderStart = now()
        let attributed = renderer.render(source: fixture.source, parsed: parsed)
        let attributedRender = elapsed(since: renderStart)
        withExtendedLifetime(attributed) {}

        let storage = NSTextStorage(string: fixture.source)
        let applyStart = now()
        renderer.apply(source: fixture.source, parsed: parsed, to: storage)
        let liveApply = elapsed(since: applyStart)

        let layoutManager = MarkdownLayoutManager()
        configure(layoutManager, parsed: parsed)
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 720,
                                                      height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 8
        layoutManager.addTextContainer(container)

        let layoutStart = now()
        let initialCharacters = NSRange(location: 0, length: min(storage.length, 50_000))
        layoutManager.ensureLayout(forCharacterRange: initialCharacters)
        let visibleGlyphs = layoutManager.glyphRange(
            forBoundingRect: NSRect(x: 0, y: 0, width: 720, height: 900),
            in: container
        )
        let layout = elapsed(since: layoutStart)

        let drawStart = now()
        draw(layoutManager, glyphRange: visibleGlyphs)
        let draw = elapsed(since: drawStart)
        return (parse, attributedRender, liveApply, layout, draw,
                elapsed(since: pipelineStart) - attributedRender, visibleGlyphs.length)
    }

    private static func configure(_ layout: MarkdownLayoutManager,
                                  parsed: ParsedMarkdown) {
        let theme = Theme()
        layout.markerColor = theme.secondaryColor
        layout.bulletFont = theme.bodyFont
        layout.tables = parsed.tables
        layout.tableRowHeight = theme.tableRowHeight
        layout.tableFont = theme.tableFont
        layout.tableHeaderFont = theme.tableHeaderFont
        layout.listMarkers = parsed.listMarkers
        layout.taskMarks = parsed.tasks
        layout.headingMarks = parsed.headings
    }

    private static func draw(_ layout: MarkdownLayoutManager,
                             glyphRange: NSRange) {
        guard glyphRange.length > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: 760, pixelsHigh: 940,
                                         bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let base = NSGraphicsContext(bitmapImageRep: rep) else { return }
        let cg = base.cgContext
        cg.saveGState()
        cg.translateBy(x: 0, y: 940)
        cg.scaleBy(x: 1, y: -1)
        let flipped = NSGraphicsContext(cgContext: cg, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = flipped
        NSColor.textBackgroundColor.setFill()
        NSRect(x: 0, y: 0, width: 760, height: 940).fill()
        layout.drawBackground(forGlyphRange: glyphRange, at: NSPoint(x: 20, y: 20))
        layout.drawGlyphs(forGlyphRange: glyphRange, at: NSPoint(x: 20, y: 20))
        NSGraphicsContext.restoreGraphicsState()
        cg.restoreGState()
    }

    private static func denseFixture(targetBytes: Int) -> String {
        var result = "# Generated performance fixture\n\n"
        var bytes = result.utf8.count
        var index = 0
        while bytes < targetBytes {
            let block = """
            ## Section \(index)

            Paragraph \(index) has **bold**, *italic*, ~~strike~~, `inline code`, a [link](https://example.com/\(index)), and prose -> arrow.

            - [ ] Task \(index)
            - Item **\(index)** with [details](https://example.com/details/\(index))

            | Name | Value | State |
            |:-----|------:|:-----:|
            | Item \(index) | \(index) | **ready** |

            ```swift
            let value\(index) = \(index) // generated
            ```


            """
            result.append(block)
            bytes += block.utf8.count
            index += 1
        }
        return result
    }

    private static func codeFixture(targetBytes: Int) -> String {
        let line = "let value = 42 // generated code line\n"
        let count = max(1, targetBytes / line.utf8.count)
        return "```swift\n" + String(repeating: line, count: count) + "```\n"
    }

    private static func integer(after flag: String, in arguments: [String]) -> Int? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return Int(arguments[index + 1])
    }

    private static func string(after flag: String,
                               in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag),
              index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    private static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
    private static func elapsed(since start: UInt64) -> Double {
        Double(now() - start) / 1_000_000
    }

    private static func percentile(_ values: [Double], _ fraction: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let index = min(sorted.count - 1,
                        max(0, Int(ceil(Double(sorted.count) * fraction)) - 1))
        return sorted[index]
    }

    private static func report(_ label: String, _ values: [Double]) {
        let padded = label.padding(toLength: 24, withPad: " ", startingAt: 0)
        print(String(format: "  %@ median %8.1f ms   p95 %8.1f ms",
                     padded,
                     percentile(values, 0.5), percentile(values, 0.95)))
    }
}
