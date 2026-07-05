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
        // Collapse chevron / `…` expander.
        if event.clickCount == 1, let anchor = collapseTarget(at: event) {
            controller?.toggleCollapse(anchor: anchor)
            return
        }
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
        snapCaretAfterListMarker() // clicks land inside hidden markers too
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

    // MARK: Insertion point

    /// Line fragments are 1.35× the font height with the extra leading on
    /// top, so the default full-fragment caret towers above the glyphs while
    /// hugging their bottom. Shrink it to the caret font's span, anchored to
    /// the fragment's bottom (where the text sits).
    /// Where the caret was last actually drawn (already corrected). Used to
    /// invalidate the old location when the caret moves off a relocated line.
    private var lastDrawnCaretRect: NSRect?

    public override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        let corrected = insertionRect(for: rect)
        lastDrawnCaretRect = corrected
        super.drawInsertionPoint(in: corrected, color: color, turnedOn: flag)
    }

    private func insertionRect(for rect: NSRect) -> NSRect {
        var r = rect

        // Directly after hidden marker glyphs (a fresh "3. " / "- [ ] " line)
        // AppKit anchors the caret to the last *real* glyph — the previous
        // line's newline. Recompute from the glyph at the caret instead — but
        // only when that glyph is already laid out, so this never *forces*
        // layout (it runs from setNeedsDisplay, which may pass
        // avoidAdditionalLayout). An unlaid caret isn't on screen anyway; it
        // relocates on the next draw once layout reaches it.
        let caret = selectedRange().location
        if let storage = textStorage, let lm = layoutManager,
           caret > 0, caret < storage.length,
           caret < lm.firstUnlaidCharacterIndex(),
           storage.attribute(.vireoMarker, at: caret - 1, effectiveRange: nil) != nil {
            let glyph = lm.glyphIndexForCharacter(at: caret)
            if glyph < lm.numberOfGlyphs {
                let lineRect = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                r = NSRect(x: lineRect.minX + lm.location(forGlyphAt: glyph).x + textContainerInset.width,
                           y: lineRect.minY + textContainerInset.height,
                           width: rect.width, height: lineRect.height)
            }
        }

        var font = typingAttributes[.font] as? NSFont
        if let storage = textStorage, storage.length > 0 {
            let idx = min(max(caret - 1, 0), storage.length - 1)
            if let f = storage.attribute(.font, at: idx, effectiveRange: nil) as? NSFont { font = f }
        }
        guard let font else { return r }
        let height = ceil(font.ascender - font.descender) + 2
        guard r.height > height else { return r }
        r.origin.y += r.height - height
        r.size.height = height
        return r
    }

    /// The system invalidates the caret's *uncorrected* rect on every blink.
    /// When we relocate the caret (onto another line), union in both its new
    /// corrected rect and the last place it was drawn — otherwise the old
    /// pixel is never erased and lingers as a ghost when the caret moves away.
    public override func setNeedsDisplay(_ invalidRect: NSRect, avoidAdditionalLayout flag: Bool) {
        var union = invalidRect
        if invalidRect.width <= 2, selectedRange().length == 0 {
            union = union.union(insertionRect(for: invalidRect))
            if let last = lastDrawnCaretRect { union = union.union(last) }
        }
        super.setNeedsDisplay(union, avoidAdditionalLayout: flag)
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

    // MARK: List collapse — hover chevrons and click targets

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self {
            removeTrackingArea(area)
        }
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseMoved, .mouseEnteredAndExited,
                                                 .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    public override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event) // sets the I-beam
        controller?.setHoveredListAnchor(collapsibleAnchorOnLine(at: event))
        // Arrow cursor over the clickable controls (fold chevron / `…` /
        // task checkboxes) — a subtle hint that they're clickable, not text.
        if collapseTarget(at: event) != nil || checkboxAnchor(at: event) != nil {
            NSCursor.arrow.set()
        }
    }

    public override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        controller?.setHoveredListAnchor(nil)
    }

    /// The collapsible list-item or heading anchor on the hovered line, if any.
    private func collapsibleAnchorOnLine(at event: NSEvent) -> Int? {
        guard let storage = textStorage, storage.length > 0,
              let lm = layoutManager, let container = textContainer,
              let controller else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        let inset = textContainerInset
        let local = NSPoint(x: point.x - inset.width, y: point.y - inset.height)
        let glyph = lm.glyphIndex(for: local, in: container)
        // Cursor must actually be over that line, not in empty space below.
        let lineRect = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        guard local.y >= lineRect.minY, local.y <= lineRect.maxY else { return nil }
        let charIndex = lm.characterIndexForGlyph(at: glyph)
        guard charIndex < storage.length else { return nil }
        let line = (storage.string as NSString).lineRange(for: NSRange(location: charIndex, length: 0))
        var anchor: Int?
        for key: NSAttributedString.Key in [.vireoBullet, .vireoCheckbox, .vireoHeading] {
            storage.enumerateAttribute(key, in: line) { value, range, stop in
                if value != nil, controller.isCollapsible(anchor: range.location) {
                    anchor = range.location
                    stop.pointee = true
                }
            }
            if anchor != nil { break }
        }
        return anchor
    }

    /// Chevron or `…` hit → the anchor to toggle. The recorded rects are in
    /// view coordinates (they include the draw origin / container inset).
    private func collapseTarget(at event: NSEvent) -> Int? {
        guard let lm = layoutManager as? MarkdownLayoutManager else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        for (anchor, rect) in lm.chevronRects where rect.contains(point) { return anchor }
        for (anchor, rect) in lm.dotsRects where rect.contains(point) { return anchor }
        return nil
    }

    // MARK: Caret vs hidden list markers

    /// A list item's leading marker (`- [ ] `, `1. `, …) is 2–8 invisible
    /// zero-width caret stops — arrows appeared stuck and clicks landed
    /// "nowhere". Snap the caret across the whole marker instead: forward to
    /// the item's first visible char, or (moving left) past it entirely.
    private func snapCaretAfterListMarker() {
        guard selectedRange().length == 0, let controller else { return }
        if let marker = controller.listMarkerRange(containing: selectedRange().location),
           selectedRange().location != marker.upperBound {
            setSelectedRange(NSRange(location: marker.upperBound, length: 0))
        }
    }

    public override func moveRight(_ sender: Any?) {
        super.moveRight(sender)
        snapCaretAfterListMarker()
    }

    public override func moveLeft(_ sender: Any?) {
        super.moveLeft(sender)
        guard selectedRange().length == 0, let controller else { return }
        if let marker = controller.listMarkerRange(containing: selectedRange().location) {
            setSelectedRange(NSRange(location: max(0, marker.location - 1), length: 0))
        }
    }

    public override func moveUp(_ sender: Any?) {
        super.moveUp(sender)
        snapCaretAfterListMarker()
    }

    public override func moveDown(_ sender: Any?) {
        super.moveDown(sender)
        snapCaretAfterListMarker()
    }

    // MARK: Enter — list continuation and hidden-marker hygiene

    public override func insertNewline(_ sender: Any?) {
        // Step past hidden closing markers *first* — otherwise a list item
        // ending in bold/link would get the continuation inserted between the
        // text and its closing `**`, splitting the construct.
        skipTrailingClosingMarkers()
        if handleListNewline() { return }
        super.insertNewline(sender)
    }

    /// Enter inside a list item continues the list (same bullet, unchecked box,
    /// incremented number). Enter on an *empty* item walks out one nesting level
    /// at a time (like Shift-Tab); once it's a top-level empty item, Enter
    /// removes the marker and exits the list. So repeatedly pressing Enter
    /// climbs out of a deep list and finally lands on a plain line.
    private func handleListNewline() -> Bool {
        guard selectedRange().length == 0, let storage = textStorage else { return false }
        let ns = storage.string as NSString
        let caret = selectedRange().location
        let line = ns.lineRange(for: NSRange(location: caret, length: 0))
        var lineText = ns.substring(with: line)
        if lineText.hasSuffix("\n") { lineText.removeLast() }
        guard let info = ListLine.parse(lineText) else { return false }
        guard caret >= line.location + info.markerEndOffset else { return false }

        if info.contentIsEmpty {
            // Nested empty item: outdent one level instead of exiting.
            if !info.indent.isEmpty {
                return adjustListIndent(outdent: true)
            }
            // Top-level empty item: clear the marker, leaving an empty line.
            let r = NSRange(location: line.location, length: (lineText as NSString).length)
            if shouldChangeText(in: r, replacementString: "") {
                storage.replaceCharacters(in: r, with: "")
                didChangeText()
                setSelectedRange(NSRange(location: line.location, length: 0))
            }
            return true
        }

        let insertion = "\n" + info.continuationPrefix
        let sel = NSRange(location: caret, length: 0)
        if shouldChangeText(in: sel, replacementString: insertion) {
            storage.replaceCharacters(in: sel, with: insertion)
            didChangeText()
            setSelectedRange(NSRange(location: caret + (insertion as NSString).length, length: 0))
        }
        return true
    }

    /// When the caret sits at the end of a construct's visible text, the
    /// hidden closing markers (`**`, `](url)`, …) come *after* it in the
    /// source. A newline inserted there would split the construct and dump raw
    /// markers onto the next line — step past them first.
    private func skipTrailingClosingMarkers() {
        guard selectedRange().length == 0, let storage = textStorage else { return }
        var i = selectedRange().location
        guard i > 0, i < storage.length else { return }
        let ns = storage.string as NSString
        // Only mid-line: at line start any following markers are *opening* ones.
        guard ns.character(at: i - 1) != 0x0A else { return }
        var moved = false
        while i < storage.length,
              ns.character(at: i) != 0x0A,
              storage.attribute(.vireoMarker, at: i, effectiveRange: nil) != nil {
            i += 1
            moved = true
        }
        if moved { setSelectedRange(NSRange(location: i, length: 0)) }
    }

    // MARK: Tab — list indent / outdent

    public override func insertTab(_ sender: Any?) {
        if adjustListIndent(outdent: false) { return }
        super.insertTab(sender)
    }

    public override func insertBacktab(_ sender: Any?) {
        if adjustListIndent(outdent: true) { return }
        super.insertBacktab(sender)
    }

    private static let indentUnit = "    " // 4 spaces nests reliably in GFM

    /// Indent/outdent every list-item line touched by the selection.
    private func adjustListIndent(outdent: Bool) -> Bool {
        guard let storage = textStorage else { return false }
        let ns = storage.string as NSString
        let sel = selectedRange()
        let lineSpan = ns.lineRange(for: sel)

        // Collect the list-item lines in the span.
        var listLines: [(range: NSRange, info: ListLine)] = []
        var pos = lineSpan.location
        while pos < max(lineSpan.upperBound, lineSpan.location + 1), pos < ns.length {
            let lr = ns.lineRange(for: NSRange(location: pos, length: 0))
            var text = ns.substring(with: lr)
            if text.hasSuffix("\n") { text.removeLast() }
            if let info = ListLine.parse(text) { listLines.append((lr, info)) }
            if lr.upperBound == pos { break }
            pos = lr.upperBound
        }
        guard !listLines.isEmpty else { return false }

        var caretShift = 0
        var edited = false
        for (lr, info) in listLines.reversed() {
            if outdent {
                var remove = 0
                while remove < Self.indentUnit.count, lr.location + remove < ns.length,
                      ns.character(at: lr.location + remove) == 0x20 { remove += 1 }
                if remove == 0, ns.character(at: lr.location) == 0x09 { remove = 1 }
                guard remove > 0 else { continue }
                let r = NSRange(location: lr.location, length: remove)
                if shouldChangeText(in: r, replacementString: "") {
                    storage.replaceCharacters(in: r, with: "")
                    edited = true
                    if lr.location <= sel.location { caretShift -= remove }
                }
            } else {
                // Indenting makes the line the first item of a (new) nested
                // list. A sublist directly under an item's text only parses
                // when it starts with 1 (CommonMark's can't-interrupt-a-
                // paragraph rule), so rewrite the ordered number to 1 —
                // the display renumbers from ordinals anyway.
                var replaceLen = 0
                var insert = Self.indentUnit
                if info.isOrdered {
                    let digitsLen = (info.marker as NSString).length - 1
                    let indentLen = (info.indent as NSString).length
                    replaceLen = indentLen + digitsLen
                    insert = Self.indentUnit + info.indent + "1"
                }
                let r = NSRange(location: lr.location, length: replaceLen)
                if shouldChangeText(in: r, replacementString: insert) {
                    storage.replaceCharacters(in: r, with: insert)
                    edited = true
                    if lr.location <= sel.location {
                        caretShift += (insert as NSString).length - replaceLen
                    }
                }
            }
        }
        // Swallow the Tab either way (⇧Tab on an unindented item is a no-op,
        // not a literal tab character) — but only report a change if one happened.
        guard edited else { return true }
        didChangeText()
        let caret = max(0, min(sel.location + caretShift, storage.length))
        let selLen = min(sel.length, storage.length - caret)
        setSelectedRange(NSRange(location: caret, length: selLen))
        return true
    }

    // NB: no didChangeText override — the Coordinator's textDidChange
    // notification already triggers the (synchronous) restyle; overriding here
    // too would restyle every keystroke twice.
}
