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

    // MARK: Enter — list continuation and hidden-marker hygiene

    public override func insertNewline(_ sender: Any?) {
        if handleListNewline() { return }
        skipTrailingClosingMarkers()
        super.insertNewline(sender)
    }

    /// Enter inside a list item continues the list (same bullet, unchecked box,
    /// incremented number); Enter on an *empty* item removes its marker and
    /// exits the list.
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
            // Exit the list: clear the marker, leaving an empty line.
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
        var listLines: [NSRange] = []
        var pos = lineSpan.location
        while pos < max(lineSpan.upperBound, lineSpan.location + 1), pos < ns.length {
            let lr = ns.lineRange(for: NSRange(location: pos, length: 0))
            var text = ns.substring(with: lr)
            if text.hasSuffix("\n") { text.removeLast() }
            if ListLine.parse(text) != nil { listLines.append(lr) }
            if lr.upperBound == pos { break }
            pos = lr.upperBound
        }
        guard !listLines.isEmpty else { return false }

        var caretShift = 0
        for lr in listLines.reversed() {
            if outdent {
                var remove = 0
                while remove < Self.indentUnit.count, lr.location + remove < ns.length,
                      ns.character(at: lr.location + remove) == 0x20 { remove += 1 }
                if remove == 0, ns.character(at: lr.location) == 0x09 { remove = 1 }
                guard remove > 0 else { continue }
                let r = NSRange(location: lr.location, length: remove)
                if shouldChangeText(in: r, replacementString: "") {
                    storage.replaceCharacters(in: r, with: "")
                    if lr.location <= sel.location { caretShift -= remove }
                }
            } else {
                let r = NSRange(location: lr.location, length: 0)
                if shouldChangeText(in: r, replacementString: Self.indentUnit) {
                    storage.replaceCharacters(in: r, with: Self.indentUnit)
                    if lr.location <= sel.location { caretShift += Self.indentUnit.count }
                }
            }
        }
        didChangeText()
        let caret = max(0, min(sel.location + caretShift, storage.length))
        setSelectedRange(NSRange(location: caret, length: sel.length))
        return true
    }

    // NB: no didChangeText override — the Coordinator's textDidChange
    // notification already triggers the (synchronous) restyle; overriding here
    // too would restyle every keystroke twice.
}
