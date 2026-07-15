import AppKit

/// A logical first-visible text line plus its visual offset from the viewport.
/// Restoring it after paragraph metrics change prevents async images above the
/// viewport from making the document jump under the reader.
@MainActor
public struct TextViewportAnchor {
    private let characterIndex: Int
    private let lineOffset: CGFloat

    public static func capture(in textView: NSTextView) -> TextViewportAnchor? {
        guard let scrollView = textView.enclosingScrollView,
              let layout = textView.layoutManager,
              let container = textView.textContainer,
              layout.numberOfGlyphs > 0 else { return nil }
        let visibleTop = scrollView.contentView.bounds.minY
        let containerOrigin = textView.textContainerOrigin
        let point = NSPoint(
            x: container.lineFragmentPadding + 1,
            y: max(0, visibleTop - containerOrigin.y + 1)
        )
        let glyph = min(layout.glyphIndex(for: point, in: container),
                        layout.numberOfGlyphs - 1)
        let character = layout.characterIndexForGlyph(at: glyph)
        let line = layout.lineFragmentRect(forGlyphAt: glyph,
                                           effectiveRange: nil)
        return TextViewportAnchor(characterIndex: character,
                                  lineOffset: containerOrigin.y + line.minY - visibleTop)
    }

    public func restore(in textView: NSTextView) {
        guard let scrollView = textView.enclosingScrollView,
              let storage = textView.textStorage,
              let layout = textView.layoutManager,
              textView.textContainer != nil,
              storage.length > 0 else { return }
        let character = min(characterIndex, storage.length - 1)
        let glyphs = layout.glyphRange(
            forCharacterRange: NSRange(location: character, length: 1),
            actualCharacterRange: nil
        )
        guard glyphs.length > 0 else { return }
        layout.ensureLayout(forGlyphRange: glyphs)
        let line = layout.lineFragmentRect(forGlyphAt: glyphs.location,
                                           effectiveRange: nil)
        let clipView = scrollView.contentView
        let targetY = textView.textContainerOrigin.y + line.minY - lineOffset
        let proposed = NSRect(x: clipView.bounds.minX, y: targetY,
                              width: clipView.bounds.width,
                              height: clipView.bounds.height)
        clipView.setBoundsOrigin(clipView.constrainBoundsRect(proposed).origin)
        scrollView.reflectScrolledClipView(clipView)
    }
}
