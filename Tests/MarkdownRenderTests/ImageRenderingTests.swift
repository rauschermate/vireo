import XCTest
import AppKit
import MarkdownEngine
@testable import MarkdownRender

@MainActor
final class ImageRenderingTests: XCTestCase {
    private struct Snapshot {
        let bitmap: NSBitmapImageRep
        let imageRect: NSRect
        let height: CGFloat
    }

    func testImageMetadataHidesEverySourceGlyphAndKeepsAltText() {
        let source = "![A useful diagram](diagram.png)"
        let parsed = MarkdownParser().parse(source)
        let rendered = MarkdownRenderer(theme: Theme()).render(source: source, parsed: parsed)

        for index in 0..<rendered.length {
            XCTAssertNotNil(rendered.attribute(.vireoMarker, at: index, effectiveRange: nil),
                            "source glyph \(index) must be hidden")
        }
        XCTAssertEqual(rendered.attribute(.vireoImage, at: 0, effectiveRange: nil) as? String,
                       "diagram.png")
        XCTAssertEqual(rendered.attribute(.vireoImageAlt, at: 0, effectiveRange: nil) as? String,
                       "A useful diagram")
    }

    func testLocalAndRemoteImageSnapshotsDrawUpright() throws {
        let testImage = stripedImage()
        for source in ["diagram.png", "https://example.com/diagram.png"] {
            let snapshot = try snapshot(source: "![Diagram](\(source))", width: 180,
                                        imageProvider: { _ in testImage }, appearance: .aqua)
            let x = Int(snapshot.imageRect.midX)
            let visualTopY = snapshot.imageRect.minY + snapshot.imageRect.height * 0.25
            let visualBottomY = snapshot.imageRect.minY + snapshot.imageRect.height * 0.75
            let top = snapshot.bitmap.colorAt(x: x,
                                              y: Int(visualTopY))?.usingColorSpace(.deviceRGB)
            let bottom = snapshot.bitmap.colorAt(x: x,
                                                 y: Int(visualBottomY))?.usingColorSpace(.deviceRGB)
            XCTAssertGreaterThan(top?.redComponent ?? 0, top?.blueComponent ?? 1,
                                 "the red source stripe must remain at the visual top for \(source)")
            XCTAssertGreaterThan(bottom?.blueComponent ?? 0, bottom?.redComponent ?? 1,
                                 "the blue source stripe must remain at the visual bottom for \(source)")
        }
    }

    func testMissingImageFallbackDrawsInLightAndDarkAppearances() throws {
        for appearance: NSAppearance.Name in [.aqua, .darkAqua] {
            let snapshot = try snapshot(source: "![Missing diagram](nope.png)", width: 260,
                                        imageProvider: { _ in nil }, appearance: appearance)
            XCTAssertGreaterThan(snapshot.imageRect.width, 40)
            XCTAssertGreaterThanOrEqual(snapshot.imageRect.height, 32)
            let center = snapshot.bitmap.colorAt(x: Int(snapshot.imageRect.midX),
                                                 y: Int(snapshot.imageRect.midY))
            XCTAssertNotNil(center, "the fallback must produce pixels in \(appearance.rawValue)")
        }
    }

    func testNarrowAndOversizedImagesStayInsideTheReadingColumn() throws {
        let huge = stripedImage(width: 1_200, height: 120)
        let narrow = try snapshot(source: "![Wide](wide.png)", width: 100,
                                  imageProvider: { _ in huge }, appearance: .aqua)
        XCTAssertLessThanOrEqual(narrow.imageRect.width, 60.5)

        let wide = try snapshot(source: "![Wide](wide.png)", width: 900,
                                imageProvider: { _ in huge }, appearance: .aqua)
        XCTAssertLessThanOrEqual(wide.imageRect.width, Theme().contentMaxWidth + 0.5)
    }

    func testSelectedImageDrawsBlueFocusBorder() throws {
        let snapshot = try snapshot(source: "![Selected](selected.png)", width: 180,
                                    imageProvider: { _ in self.stripedImage() },
                                    appearance: .aqua, selectedImageAnchor: 0)
        let edge = snapshot.bitmap.colorAt(x: Int(snapshot.imageRect.minX + 1),
                                           y: Int(snapshot.imageRect.midY))?
            .usingColorSpace(.deviceRGB)
        XCTAssertGreaterThan(edge?.blueComponent ?? 0, edge?.redComponent ?? 1,
                             "selected images need a visible blue focus border")
    }

    func testImageHitRectDoesNotDriftWithDrawingOrigin() throws {
        let image = stripedImage()
        let atZero = try snapshot(source: "![Hit target](image.png)", width: 180,
                                  imageProvider: { _ in image }, appearance: .aqua)
        let translated = try snapshot(source: "![Hit target](image.png)", width: 180,
                                      imageProvider: { _ in image }, appearance: .aqua,
                                      drawOrigin: NSPoint(x: 24, y: 28))

        XCTAssertEqual(atZero.imageRect, translated.imageRect,
                       "scrolling/redrawing must not move the image hit target")
    }

    private func snapshot(source: String, width: CGFloat,
                          imageProvider: @escaping (String) -> NSImage?,
                          appearance name: NSAppearance.Name,
                          selectedImageAnchor: Int? = nil,
                          drawOrigin: NSPoint = .zero) throws -> Snapshot {
        let parsed = MarkdownParser().parse(source)
        let attributed = MarkdownRenderer(theme: Theme()).render(source: source, parsed: parsed)
        let storage = NSTextStorage(attributedString: attributed)
        let layout = MarkdownLayoutManager()
        layout.imageProvider = imageProvider
        layout.imageMaxWidth = Theme().contentMaxWidth
        layout.selectedImageAnchor = selectedImageAnchor
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: width, height: 1_000))
        container.lineFragmentPadding = 8
        layout.addTextContainer(container)
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        let height = ceil(max(80, used.height + 24))

        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
                                            pixelsWide: Int(ceil(width + 24)),
                                            pixelsHigh: Int(height),
                                            bitsPerSample: 8, samplesPerPixel: 4,
                                            hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0),
              let bitmapContext = NSGraphicsContext(bitmapImageRep: bitmap),
              let appearance = NSAppearance(named: name) else {
            throw XCTSkip("AppKit bitmap context unavailable")
        }

        let cg = bitmapContext.cgContext
        cg.saveGState()
        cg.translateBy(x: 0, y: height)
        cg.scaleBy(x: 1, y: -1)
        let flipped = NSGraphicsContext(cgContext: cg, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = flipped
        appearance.performAsCurrentDrawingAppearance {
            NSColor.textBackgroundColor.setFill()
            NSRect(x: 0, y: 0, width: width + 24, height: height).fill()
            let glyphs = layout.glyphRange(for: container)
            layout.drawBackground(forGlyphRange: glyphs, at: drawOrigin)
            layout.drawGlyphs(forGlyphRange: glyphs, at: drawOrigin)
        }
        NSGraphicsContext.restoreGraphicsState()
        cg.restoreGState()

        guard let rect = layout.imageRects[0] else {
            XCTFail("image renderer did not record a hit target")
            return Snapshot(bitmap: bitmap, imageRect: .zero, height: height)
        }
        return Snapshot(bitmap: bitmap, imageRect: rect, height: height)
    }

    /// An asymmetric source catches accidental vertical flips: red is the
    /// visual top half and blue is the visual bottom half.
    private func stripedImage(width: Int = 40, height: Int = 20) -> NSImage {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        for y in 0..<height {
            // NSBitmapImageRep indexes scanlines from the visual top.
            let color = y < height / 2
                ? NSColor(deviceRed: 1, green: 0, blue: 0, alpha: 1)
                : NSColor(deviceRed: 0, green: 0, blue: 1, alpha: 1)
            for x in 0..<width { rep.setColor(color, atX: x, y: y) }
        }
        let image = NSImage(size: NSSize(width: width, height: height))
        image.addRepresentation(rep)
        return image
    }
}
