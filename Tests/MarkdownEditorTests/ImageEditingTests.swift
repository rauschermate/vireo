import XCTest
import AppKit
import MarkdownRender
@testable import MarkdownEditor

@MainActor
final class ImageEditingTests: XCTestCase {
    private func makeEditor(_ source: String) -> (EditorController, MarkdownTextView) {
        let controller = EditorController()
        let (_, textView) = MarkdownSourceView.makeTextStack(source: source, controller: controller)
        controller.restyle()
        return (controller, textView)
    }

    func testRenderedImageCanBeEditedWithoutRevealingSource() {
        let (controller, textView) = makeEditor("![Old](old.png)")
        controller.replaceImage(atAnchor: 0, alt: "New] label", source: "new (2).png")

        XCTAssertEqual(textView.string, #"![New\] label](new \(2\).png)"#)
    }

    func testRenderedImageCanBeRemoved() {
        let (controller, textView) = makeEditor("before\n\n![Diagram](diagram.png)\n\nafter")
        let anchor = controller.parsed.images[0].anchor
        controller.removeImage(atAnchor: anchor)

        XCTAssertEqual(textView.string, "before\n\n\n\nafter")
    }

    func testSelectedImageCanBeDeletedWithoutExposingItsSource() {
        let (controller, textView) = makeEditor("before\n\n![Diagram](diagram.png)\n\nafter")
        let anchor = controller.parsed.images[0].anchor

        textView.selectImage(atAnchor: anchor)

        XCTAssertEqual(textView.selectedImageAnchor, anchor)
        XCTAssertEqual((textView.layoutManager as? MarkdownLayoutManager)?.selectedImageAnchor,
                       anchor)

        textView.deleteBackward(nil)

        XCTAssertEqual(textView.string, "before\n\n\n\nafter")
        XCTAssertNil(textView.selectedImageAnchor)
        XCTAssertNil((textView.layoutManager as? MarkdownLayoutManager)?.selectedImageAnchor)
    }

    func testEditorSurfaceDrawsImageUpright() throws {
        let controller = EditorController()
        let (scroll, textView) = MarkdownSourceView.makeTextStack(
            source: "![Orientation](orientation.png)", controller: controller)
        scroll.frame = NSRect(x: 0, y: 0, width: 240, height: 120)
        textView.frame = NSRect(x: 0, y: 0, width: 240, height: 120)
        controller.restyle()

        guard let layout = textView.layoutManager as? MarkdownLayoutManager,
              let container = textView.textContainer else {
            return XCTFail("editor TextKit stack unavailable")
        }
        let sourceImage = stripedImage()
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("vireo-orientation-\(UUID().uuidString).png")
        guard let sourceRep = sourceImage.representations.first as? NSBitmapImageRep,
              let png = sourceRep.representation(using: .png, properties: [:]) else {
            return XCTFail("test image could not be encoded")
        }
        try png.write(to: sourceURL)
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let loader = ImageLoader()
        guard let loadedImage = loader.image(forSource: sourceURL.path, baseURL: nil) else {
            return XCTFail("test image could not be loaded")
        }
        layout.imageProvider = { _ in loadedImage }
        layout.ensureLayout(for: container)

        guard let bitmap = textView.bitmapImageRepForCachingDisplay(in: textView.bounds) else {
            throw XCTSkip("AppKit view snapshot unavailable")
        }
        textView.cacheDisplay(in: textView.bounds, to: bitmap)

        guard let rect = layout.imageRects[0] else {
            return XCTFail("image renderer did not record a hit target")
        }
        let scaleX = CGFloat(bitmap.pixelsWide) / textView.bounds.width
        let scaleY = CGFloat(bitmap.pixelsHigh) / textView.bounds.height
        let x = Int(rect.midX * scaleX)
        let top = bitmap.colorAt(x: x, y: Int((rect.minY + rect.height * 0.25) * scaleY))?
            .usingColorSpace(.deviceRGB)
        let bottom = bitmap.colorAt(x: x, y: Int((rect.minY + rect.height * 0.75) * scaleY))?
            .usingColorSpace(.deviceRGB)
        XCTAssertGreaterThan(top?.redComponent ?? 0, top?.blueComponent ?? 1,
                             "the red source stripe must stay at the visual top")
        XCTAssertGreaterThan(bottom?.blueComponent ?? 0, bottom?.redComponent ?? 1,
                             "the blue source stripe must stay at the visual bottom")
    }

    private func stripedImage() -> NSImage {
        let width = 40
        let height = 20
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        let red = NSColor(deviceRed: 1, green: 0, blue: 0, alpha: 1)
        let blue = NSColor(deviceRed: 0, green: 0, blue: 1, alpha: 1)
        for y in 0..<height {
            let color = y < height / 2 ? red : blue
            for x in 0..<width { rep.setColor(color, atX: x, y: y) }
        }
        let image = NSImage(size: NSSize(width: width, height: height))
        image.addRepresentation(rep)
        return image
    }
}
