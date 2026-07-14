import AppKit
import XCTest
@testable import MarkdownEditor

@MainActor
final class AsyncImageUpdateTests: XCTestCase {
    func testImageCompletionRestylesOnlyItsParagraphWithoutReparsing() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VireoAsyncImageTests-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try writePNG(to: directory.appendingPathComponent("tall.png"),
                     width: 120, height: 240)

        let source = "![Tall](tall.png)\n\nFar paragraph stays untouched.\n"
        let controller = EditorController()
        controller.baseURL = directory
        var parseNotifications = 0
        controller.onParsed = { _ in parseNotifications += 1 }
        let (_, textView) = MarkdownSourceView.makeTextStack(
            source: source, controller: controller
        )
        controller.restyle()

        let sentinel = NSAttributedString.Key("AsyncImageUpdateTests.sentinel")
        let farRange = (source as NSString).range(of: "Far paragraph")
        textView.textStorage?.addAttribute(sentinel, value: true, range: farRange)
        let initialHeight = paragraphHeight(in: textView, at: 0)

        let deadline = ContinuousClock.now + .seconds(2)
        while paragraphHeight(in: textView, at: 0) <= initialHeight,
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertGreaterThan(paragraphHeight(in: textView, at: 0), initialHeight)
        XCTAssertEqual(parseNotifications, 1,
                       "an image completion must not parse/restyle the document")
        XCTAssertNotNil(textView.textStorage?.attribute(
            sentinel, at: farRange.location, effectiveRange: nil
        ), "attributes outside the affected image paragraph must remain untouched")
    }

    private func paragraphHeight(in textView: NSTextView, at location: Int) -> CGFloat {
        (textView.textStorage?.attribute(.paragraphStyle, at: location,
                                         effectiveRange: nil) as? NSParagraphStyle)?
            .minimumLineHeight ?? 0
    }

    private func writePNG(to url: URL, width: Int, height: Int) throws {
        let representation = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ))
        let color = NSColor(deviceRed: 0.1, green: 0.5, blue: 0.8, alpha: 1)
        for y in 0..<height {
            for x in 0..<width {
                representation.setColor(color, atX: x, y: y)
            }
        }
        let data = try XCTUnwrap(representation.representation(using: .png,
                                                               properties: [:]))
        try data.write(to: url)
    }
}
