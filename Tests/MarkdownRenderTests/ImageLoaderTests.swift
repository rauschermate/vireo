import AppKit
import XCTest
import MarkdownEngine
@testable import MarkdownRender

@MainActor
final class ImageLoaderTests: XCTestCase {
    func testResolvedURLIsCanonicalAndIgnoresRemoteFragments() throws {
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let loader = ImageLoader()

        XCTAssertEqual(loader.resolvedURL(forSource: "images/../diagram.png",
                                          baseURL: base),
                       base.appendingPathComponent("diagram.png").standardizedFileURL)
        XCTAssertEqual(loader.resolvedURL(forSource: "./diagram.png", baseURL: base),
                       loader.resolvedURL(forSource: "diagram.png", baseURL: base))
        XCTAssertEqual(loader.resolvedURL(
            forSource: "https://example.com/diagram.png#preview", baseURL: base
        )?.absoluteString, "https://example.com/diagram.png")
    }

    func testLocalLoadsAreAsynchronousDeduplicatedAndCompletionIsCoalesced() async throws {
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        try writePNG(to: base.appendingPathComponent("one.png"), size: 40)
        try writePNG(to: base.appendingPathComponent("two.png"), size: 40)
        let loader = ImageLoader(cacheCostLimit: 1_000_000,
                                 changeCoalescingInterval: .milliseconds(100))
        let completed = expectation(description: "coalesced image completion")
        var batches: [Set<URL>] = []
        loader.onChange = { urls in
            batches.append(urls)
            completed.fulfill()
        }

        XCTAssertNil(loader.image(forSource: "one.png", baseURL: base))
        XCTAssertNil(loader.image(forSource: "./one.png", baseURL: base))
        XCTAssertNil(loader.image(forSource: "two.png", baseURL: base))
        XCTAssertEqual(loader.inFlightCount, 2,
                       "equivalent source strings must share a resolved-URL load")

        await fulfillment(of: [completed], timeout: 2)

        XCTAssertEqual(batches.count, 1)
        XCTAssertEqual(batches[0], Set([
            base.appendingPathComponent("one.png").standardizedFileURL,
            base.appendingPathComponent("two.png").standardizedFileURL,
        ]))
        XCTAssertNotNil(loader.image(forSource: "one.png", baseURL: base))
        XCTAssertNotNil(loader.image(forSource: "two.png", baseURL: base))
        XCTAssertEqual(loader.cachedImageCount, 2)
        XCTAssertGreaterThan(loader.cachedDecodedCost, 0)
        XCTAssertLessThanOrEqual(loader.cachedDecodedCost, 1_000_000)
    }

    func testDecodedCostLimitEvictsLeastRecentlyUsedImages() async throws {
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        try writePNG(to: base.appendingPathComponent("one.png"), size: 100)
        try writePNG(to: base.appendingPathComponent("two.png"), size: 100)
        let loader = ImageLoader(cacheCostLimit: 60_000,
                                 changeCoalescingInterval: .milliseconds(40))
        let completed = expectation(description: "images loaded")
        var completedURLs: Set<URL> = []
        loader.onChange = { urls in
            completedURLs.formUnion(urls)
            if completedURLs.count == 2 { completed.fulfill() }
        }

        _ = loader.image(forSource: "one.png", baseURL: base)
        _ = loader.image(forSource: "two.png", baseURL: base)
        await fulfillment(of: [completed], timeout: 2)

        XCTAssertEqual(loader.cachedImageCount, 1)
        XCTAssertLessThanOrEqual(loader.cachedDecodedCost, 60_000)
    }

    func testCompletionRangesIncludeOnlyMatchingImageParagraphs() throws {
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let source = "![First](one.png)\n\nBody\n\n![Second](two.png)\n"
        let parsed = MarkdownParser().parse(source)
        let loader = ImageLoader()
        let one = try XCTUnwrap(loader.resolvedURL(forSource: "./one.png",
                                                   baseURL: base))

        let ranges = loader.paragraphRanges(forLoadedURLs: [one],
                                            images: parsed.images,
                                            source: source, baseURL: base)
        let expected = (source as NSString).paragraphRange(for: parsed.images[0].range)

        XCTAssertEqual(ranges, [expected])
        XCTAssertFalse(NSIntersectionRange(ranges[0], parsed.images[1].range).length > 0)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("VireoImageLoaderTests-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: url,
                                                withIntermediateDirectories: true)
        return url
    }

    private func writePNG(to url: URL, size: Int) throws {
        let representation = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ))
        let color = NSColor(deviceRed: 0.1, green: 0.4, blue: 0.9, alpha: 1)
        for y in 0..<size {
            for x in 0..<size {
                representation.setColor(color, atX: x, y: y)
            }
        }
        let data = try XCTUnwrap(representation.representation(using: .png,
                                                               properties: [:]))
        try data.write(to: url)
    }
}
