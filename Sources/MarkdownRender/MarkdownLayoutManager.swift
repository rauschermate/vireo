import AppKit

/// TextKit-1 layout manager that realises the hidden-syntax look:
///  • syntax-marker glyphs (`.vireoMarker`) are turned into null glyphs — present
///    in the backing store, zero-width and invisible on screen;
///  • list bullets / numbers, task checkboxes and inline images (which are *not*
///    literal glyphs in the source) are drawn on top.
///
/// The backing text storage is never mutated, so `textStorage.string` stays
/// byte-identical to the markdown on disk.
///
/// Not `@MainActor`-annotated: `NSLayoutManager`/its delegate protocol are not
/// actor-isolated in the SDK, and all layout/drawing happens on the main thread
/// at runtime.
public final class MarkdownLayoutManager: NSLayoutManager, NSLayoutManagerDelegate {
    public var markerColor: NSColor = .secondaryLabelColor
    public var bulletFont: NSFont = .systemFont(ofSize: 16)
    public var imageProvider: ((String) -> NSImage?)?

    public override init() {
        super.init()
        self.delegate = self
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        self.delegate = self
    }

    // MARK: Hide markers by emitting null glyphs

    public func layoutManager(_ layoutManager: NSLayoutManager,
                              shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
                              properties props: UnsafePointer<NSLayoutManager.GlyphProperty>,
                              characterIndexes charIndexes: UnsafePointer<Int>,
                              font: NSFont,
                              forGlyphRange glyphRange: NSRange) -> Int {
        guard let storage = textStorage else { return 0 }
        let count = glyphRange.length
        var newProps = [NSLayoutManager.GlyphProperty](repeating: [], count: count)
        var changed = false
        for i in 0..<count {
            let charIndex = charIndexes[i]
            if charIndex < storage.length,
               storage.attribute(.vireoMarker, at: charIndex, effectiveRange: nil) != nil {
                newProps[i] = .null
                changed = true
            } else {
                newProps[i] = props[i]
            }
        }
        guard changed else { return 0 }
        newProps.withUnsafeBufferPointer { buf in
            self.setGlyphs(glyphs, properties: buf.baseAddress!,
                           characterIndexes: charIndexes, font: font, forGlyphRange: glyphRange)
        }
        return count
    }

    // MARK: Draw bullets / checkboxes / images

    public override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage else { return }
        let charRange = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)

        storage.enumerateAttribute(.vireoBullet, in: charRange) { value, range, _ in
            guard let s = value as? String else { return }
            drawLeftMarker(s, atCharIndex: range.location, origin: origin, color: markerColor)
        }
        storage.enumerateAttribute(.vireoCheckbox, in: charRange) { value, range, _ in
            guard let n = value as? NSNumber else { return }
            drawLeftMarker(n.boolValue ? "☑" : "☐", atCharIndex: range.location,
                           origin: origin, color: n.boolValue ? .controlAccentColor : markerColor)
        }
        storage.enumerateAttribute(.vireoImage, in: charRange) { value, range, _ in
            guard let src = value as? String, let img = imageProvider?(src) else { return }
            drawImage(img, atCharIndex: range.location, origin: origin)
        }
    }

    private func lineFragment(forChar charIndex: Int) -> NSRect? {
        guard charIndex < numberOfGlyphs || charIndex == 0 else { return nil }
        let glyph = glyphIndexForCharacter(at: charIndex)
        guard glyph < numberOfGlyphs else { return nil }
        return lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
    }

    private func drawLeftMarker(_ s: String, atCharIndex charIndex: Int, origin: NSPoint, color: NSColor) {
        guard charIndex < numberOfGlyphs else { return }
        let glyph = glyphIndexForCharacter(at: charIndex)
        guard glyph < numberOfGlyphs else { return }
        let lineRect = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let glyphLoc = location(forGlyphAt: glyph)
        let attrs: [NSAttributedString.Key: Any] = [.font: bulletFont, .foregroundColor: color]
        let size = (s as NSString).size(withAttributes: attrs)
        let x = origin.x + lineRect.minX + glyphLoc.x - size.width - 5
        let y = origin.y + lineRect.minY + (lineRect.height - size.height) / 2
        (s as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: attrs)
    }

    private func drawImage(_ img: NSImage, atCharIndex charIndex: Int, origin: NSPoint) {
        guard charIndex < numberOfGlyphs, let container = textContainers.first else { return }
        let glyph = glyphIndexForCharacter(at: charIndex)
        guard glyph < numberOfGlyphs else { return }
        let lineRect = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let maxW = container.size.width - container.lineFragmentPadding * 2
        guard img.size.width > 0 else { return }
        let scale = min(1, maxW / img.size.width)
        let w = img.size.width * scale
        let h = img.size.height * scale
        let rect = NSRect(x: origin.x + lineRect.minX + 12,
                          y: origin.y + lineRect.minY + 4,
                          width: w, height: h)
        img.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
    }
}
