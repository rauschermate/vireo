import AppKit
import XCTest
import MarkdownEngine
@testable import MarkdownRender

@MainActor
final class BlockDecorationTests: XCTestCase {
    private let source = """
    ```swift
    let value = 42
    print(value)
    ```

    > A calm quotation
    > on two lines.

    ---

    Use `inline code` here.
    """

    func testRendererUsesBlockMetadataNotCharacterBackgrounds() throws {
        let parsed = MarkdownParser().parse(source)
        let rendered = MarkdownRenderer(theme: Theme()).render(source: source,
                                                                 parsed: parsed)
        let code = try XCTUnwrap(parsed.blockRuns.first {
            if case .codeBlock = $0.kind { return true }
            return false
        })
        let quote = try XCTUnwrap(parsed.blockRuns.first {
            if case .blockQuote = $0.kind { return true }
            return false
        })
        let rule = try XCTUnwrap(parsed.blockRuns.first {
            if case .thematicBreak = $0.kind { return true }
            return false
        })

        XCTAssertNotNil(rendered.attribute(.vireoCodeBlock,
                                           at: code.range.location,
                                           effectiveRange: nil))
        rendered.enumerateAttribute(.backgroundColor, in: code.range) {
            value, _, _ in XCTAssertNil(value)
        }
        XCTAssertNotNil(rendered.attribute(.vireoBlockQuote,
                                           at: quote.range.location,
                                           effectiveRange: nil))
        for index in rule.range.location..<rule.range.upperBound
        where (source as NSString).character(at: index) != 0x0A {
            XCTAssertNotNil(rendered.attribute(.vireoMarker, at: index,
                                               effectiveRange: nil))
        }
        XCTAssertNotNil(rendered.attribute(.vireoThematicBreak,
                                           at: rule.range.location,
                                           effectiveRange: nil))

        let inline = (source as NSString).range(of: "inline code")
        XCTAssertNotNil(rendered.attribute(.backgroundColor,
                                           at: inline.location,
                                           effectiveRange: nil),
                        "inline code should retain its compact character background")
        let firstFence = (source as NSString).lineRange(
            for: NSRange(location: code.range.location, length: 0)
        )
        let fenceStyle = rendered.attribute(.paragraphStyle,
                                            at: firstFence.location,
                                            effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(fenceStyle?.maximumLineHeight, 8)
        let closingFence = (source as NSString).lineRange(
            for: (source as NSString).range(of: "```", options: .backwards)
        )
        let closingFenceStyle = rendered.attribute(.paragraphStyle,
                                                   at: closingFence.location,
                                                   effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(closingFenceStyle?.maximumLineHeight, 8)
    }

    func testBlockSurfacesDrawContinuouslyInLightAndDarkAppearances() throws {
        for appearanceName: NSAppearance.Name in [.aqua, .darkAqua] {
            let snapshot = try drawSnapshot(appearanceName)
            let code = try XCTUnwrap(snapshot.layout.codeBlockRects.values.first)
            let quote = try XCTUnwrap(snapshot.layout.quoteBarRects.values.first)
            let rule = try XCTUnwrap(snapshot.layout.thematicRuleRects.values.first)

            XCTAssertGreaterThan(code.width, 350)
            XCTAssertGreaterThan(code.height, 40)
            XCTAssertEqual(quote.width, 3)
            XCTAssertGreaterThan(quote.height, 20)
            XCTAssertGreaterThan(rule.width, 350)

            let firstCodeLine = lineFragment(containing: "let value", in: snapshot.layout)
            let lastCodeLine = lineFragment(containing: "print(value)", in: snapshot.layout)
            let topPadding = firstCodeLine.minY - code.minY
            let bottomPadding = code.maxY - lastCodeLine.maxY
            let firstGlyph = visualGlyphRect(containing: "let value", in: snapshot)
            let lastGlyph = visualGlyphRect(containing: "print(value)", in: snapshot)
            let topVisualPadding = firstGlyph.minY - code.minY
            let bottomVisualPadding = code.maxY - lastGlyph.maxY
            XCTAssertGreaterThanOrEqual(topPadding, 5)
            XCTAssertGreaterThanOrEqual(bottomPadding, 5)
            XCTAssertLessThanOrEqual(abs(topPadding - bottomPadding), 4)
            XCTAssertGreaterThanOrEqual(topVisualPadding, 6)
            XCTAssertGreaterThanOrEqual(bottomVisualPadding, 6)
            XCTAssertLessThanOrEqual(abs(topVisualPadding - bottomVisualPadding), 4)

            let page = try color(snapshot.bitmap, x: 2, y: code.midY)
            let codeSurface = try color(snapshot.bitmap, x: code.maxX - 12,
                                        y: code.midY)
            let quoteBar = try color(snapshot.bitmap, x: quote.midX,
                                     y: quote.midY)
            let rulePixel = try color(snapshot.bitmap, x: rule.midX,
                                      y: rule.midY)
            XCTAssertGreaterThan(distance(page, codeSurface), 0.02)
            XCTAssertGreaterThan(distance(page, quoteBar), 0.02)
            XCTAssertGreaterThan(distance(page, rulePixel), 0.02)
        }
    }

    private func drawSnapshot(_ appearanceName: NSAppearance.Name) throws
        -> (bitmap: NSBitmapImageRep, layout: MarkdownLayoutManager,
            storage: NSTextStorage) {
        let parsed = MarkdownParser().parse(source)
        let rendered = MarkdownRenderer(theme: Theme()).render(source: source,
                                                                 parsed: parsed)
        let storage = NSTextStorage(attributedString: rendered)
        let layout = MarkdownLayoutManager()
        storage.addLayoutManager(layout)
        let width: CGFloat = 440
        let container = NSTextContainer(size: NSSize(width: width, height: 2_000))
        container.lineFragmentPadding = 8
        layout.addTextContainer(container)
        layout.ensureLayout(for: container)
        let height = ceil(layout.usedRect(for: container).height + 20)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(width), pixelsHigh: Int(height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ))
        let bitmapContext = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
        let cg = bitmapContext.cgContext
        cg.saveGState()
        cg.translateBy(x: 0, y: height)
        cg.scaleBy(x: 1, y: -1)
        let flipped = NSGraphicsContext(cgContext: cg, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = flipped
        appearance.performAsCurrentDrawingAppearance {
            NSColor.textBackgroundColor.setFill()
            NSRect(x: 0, y: 0, width: width, height: height).fill()
            let glyphs = layout.glyphRange(for: container)
            layout.drawBackground(forGlyphRange: glyphs, at: .zero)
            layout.drawGlyphs(forGlyphRange: glyphs, at: .zero)
        }
        NSGraphicsContext.restoreGraphicsState()
        cg.restoreGState()
        return (bitmap, layout, storage)
    }

    private func color(_ bitmap: NSBitmapImageRep, x: CGFloat,
                       y: CGFloat) throws -> NSColor {
        try XCTUnwrap(bitmap.colorAt(x: Int(x), y: Int(y))?
            .usingColorSpace(.deviceRGB))
    }

    private func lineFragment(containing text: String,
                              in layout: MarkdownLayoutManager) -> NSRect {
        let character = (source as NSString).range(of: text).location
        let glyph = layout.glyphIndexForCharacter(at: character)
        return layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
    }

    private func visualGlyphRect(
        containing text: String,
        in snapshot: (bitmap: NSBitmapImageRep, layout: MarkdownLayoutManager,
                      storage: NSTextStorage)
    ) -> NSRect {
        let character = (source as NSString).range(of: text).location
        let glyph = snapshot.layout.glyphIndexForCharacter(at: character)
        let line = snapshot.layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let location = snapshot.layout.location(forGlyphAt: glyph)
        let font = snapshot.storage.attribute(.font, at: character,
                                              effectiveRange: nil) as! NSFont
        let baseline = line.minY + location.y
        return NSRect(x: line.minX + location.x,
                      y: baseline - font.ascender,
                      width: 1,
                      height: font.ascender - font.descender)
    }

    private func distance(_ lhs: NSColor, _ rhs: NSColor) -> CGFloat {
        abs(lhs.redComponent - rhs.redComponent)
            + abs(lhs.greenComponent - rhs.greenComponent)
            + abs(lhs.blueComponent - rhs.blueComponent)
    }
}
