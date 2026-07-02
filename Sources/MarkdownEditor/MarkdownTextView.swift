import AppKit
import MarkdownRender

/// NSTextView specialised for the hidden-syntax markdown surface. It keeps the
/// markdown *source* as its backing store and defers all styling to the
/// `EditorController`. Clicks on link text follow the link (reader behaviour).
public final class MarkdownTextView: NSTextView {
    weak var controller: EditorController?

    var isDark: Bool {
        effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    public override func mouseDown(with event: NSEvent) {
        // Click on a drawn task checkbox toggles it.
        if event.clickCount == 1, let anchor = checkboxAnchor(at: event) {
            controller?.toggleTask(atAnchor: anchor)
            return
        }
        // ⌘-click follows links (editor convention); a plain click must still
        // place the caret so link text stays editable.
        if event.clickCount == 1,
           event.modifierFlags.contains(.command),
           let link = linkDestination(at: event) {
            controller?.onOpenLink?(link)
            return
        }
        super.mouseDown(with: event)
    }

    /// If the click lands on a drawn checkbox (left of a task item's first
    /// character), return that item's anchor index.
    private func checkboxAnchor(at event: NSEvent) -> Int? {
        guard let storage = textStorage, storage.length > 0,
              let lm = layoutManager, let container = textContainer else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        let inset = textContainerInset
        let local = NSPoint(x: point.x - inset.width, y: point.y - inset.height)
        let glyph = lm.glyphIndex(for: local, in: container)
        let charIndex = lm.characterIndexForGlyph(at: glyph)
        guard charIndex < storage.length else { return nil }

        let line = (storage.string as NSString).lineRange(for: NSRange(location: charIndex, length: 0))
        var anchor: Int?
        storage.enumerateAttribute(.vireoCheckbox, in: line) { value, range, stop in
            if value != nil { anchor = range.location; stop.pointee = true }
        }
        guard let anchor, anchor < lm.numberOfGlyphs else { return nil }

        let aGlyph = lm.glyphIndexForCharacter(at: anchor)
        let lineRect = lm.lineFragmentRect(forGlyphAt: aGlyph, effectiveRange: nil)
        let ax = lineRect.minX + lm.location(forGlyphAt: aGlyph).x
        // The box is drawn just left of the anchor glyph.
        guard local.x < ax, local.x > ax - 30,
              local.y >= lineRect.minY, local.y <= lineRect.maxY else { return nil }
        return anchor
    }

    private func linkDestination(at event: NSEvent) -> String? {
        guard let storage = textStorage, storage.length > 0 else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        let inset = textContainerInset
        let local = NSPoint(x: point.x - inset.width, y: point.y - inset.height)
        guard let lm = layoutManager, let container = textContainer else { return nil }
        let glyph = lm.glyphIndex(for: local, in: container)
        let charIndex = lm.characterIndexForGlyph(at: glyph)
        guard charIndex < storage.length else { return nil }
        return storage.attribute(.vireoLink, at: charIndex, effectiveRange: nil) as? String
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        controller?.restyle()
    }

    // Formatting keyboard shortcuts (⌘B / ⌘I).
    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           let chars = event.charactersIgnoringModifiers {
            switch chars {
            case "b": controller?.toggleBold(); return true
            case "i": controller?.toggleItalic(); return true
            case "k": controller?.insertLink(); return true
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    public override func didChangeText() {
        super.didChangeText()
        controller?.scheduleRestyle()
    }
}
