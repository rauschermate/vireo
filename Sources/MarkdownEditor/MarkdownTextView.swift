import AppKit
import MarkdownEngine
import MarkdownRender

/// NSTextView specialised for the hidden-syntax markdown surface. It keeps the
/// markdown *source* as its backing store and defers all styling to the
/// `EditorController`. Clicks on link text follow the link (reader behaviour).
public final class MarkdownTextView: NSTextView {
    weak var controller: EditorController?
    private let persistentUndoManager = UndoManager()
    private var syntaxFreeFinder: NSTextFinder?
    private var syntaxFreeFinderClient: VisibleTextFinderClient?
    private var representedImageAnchor: Int?
    private(set) var selectedImageAnchor: Int?
    private var markdownAccessibilityElements: [String: MarkdownAccessibilityElement] = [:]
    private var cachedAccessibilityIndex = MarkerIndex.empty
    private var cachedAccessibilityBase = MarkerIndex.empty
    private var cachedAccessibilityAdditionalRanges: [NSRange] = []

    public override var undoManager: UndoManager? { persistentUndoManager }

    var isDark: Bool {
        effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    public override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        super.draw(dirtyRect)
        NSGraphicsContext.restoreGraphicsState()
        // Heading disclosures sit in the leading margin, outside TextKit's
        // glyph clip. Paint them at the view level so hover and collapsed
        // states remain visible while still using the layout manager's shared
        // list/heading disclosure renderer.
        (layoutManager as? MarkdownLayoutManager)?
            .drawHeadingDisclosureOverlays(in: dirtyRect)
        controller?.tableGeometryDidChange()
    }

    public override func mouseDown(with event: NSEvent) {
        // A rendered image behaves like a native selectable object: one click
        // gives it focus without exposing or placing the caret inside its
        // hidden Markdown expression.
        if event.clickCount == 1 {
            if let anchor = imageAnchor(at: event) {
                selectImage(atAnchor: anchor)
                window?.makeFirstResponder(self)
                return
            }
            selectImage(atAnchor: nil)
        }
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
        // Tables remain rendered during editing. A click enters the drawn cell
        // through one lightweight native overlay instead of exposing raw pipes.
        if event.clickCount <= 2,
           let layout = layoutManager as? MarkdownLayoutManager {
            let point = convert(event.locationInWindow, from: nil)
            let origin = textContainerOrigin
            let containerPoint = NSPoint(x: point.x - origin.x,
                                         y: point.y - origin.y)
            if let cell = layout.tableCell(at: containerPoint) {
                controller?.beginTableCellEditing(cell, selectAll: event.clickCount == 1)
                return
            }
        }
        // ⌘-click follows links (editor convention); a plain click must still
        // place the caret so link text stays editable.
        if event.clickCount == 1,
           event.modifierFlags.contains(.command),
           let link = linkDestination(at: event) {
            controller?.onOpenLink?(link)
            return
        }
        // Rendered images keep their Markdown source hidden. Double-clicking
        // opens a native editor so changing the alt text/source never requires
        // manipulating invisible delimiters.
        if event.clickCount == 2, let anchor = imageAnchor(at: event) {
            selectImage(atAnchor: anchor)
            controller?.editImage(atAnchor: anchor)
            return
        }
        super.mouseDown(with: event)
        normalizeSelection(affinity: .nearest) // clicks can land in null glyphs
    }

    public override func menu(for event: NSEvent) -> NSMenu? {
        guard let anchor = imageAnchor(at: event) else { return super.menu(for: event) }
        selectImage(atAnchor: anchor)
        window?.makeFirstResponder(self)
        representedImageAnchor = anchor
        let menu = NSMenu(title: "Image")
        let edit = NSMenuItem(title: "Edit Image…", action: #selector(editRepresentedImage),
                              keyEquivalent: "")
        edit.target = self
        menu.addItem(edit)
        menu.addItem(.separator())
        let remove = NSMenuItem(title: "Remove Image", action: #selector(removeRepresentedImage),
                                keyEquivalent: "")
        remove.target = self
        menu.addItem(remove)
        return menu
    }

    @objc private func editRepresentedImage() {
        guard let anchor = representedImageAnchor else { return }
        controller?.editImage(atAnchor: anchor)
    }

    @objc private func removeRepresentedImage() {
        guard let anchor = representedImageAnchor else { return }
        selectImage(atAnchor: nil)
        controller?.removeImage(atAnchor: anchor)
    }

    /// Keep rendered-image selection separate from AppKit's text selection.
    /// The layout manager owns the border because it also owns image drawing.
    func selectImage(atAnchor anchor: Int?) {
        let validAnchor = anchor.flatMap { candidate -> Int? in
            guard let storage = textStorage, candidate >= 0, candidate < storage.length,
                  storage.attribute(.vireoImage, at: candidate, effectiveRange: nil) != nil else {
                return nil
            }
            return candidate
        }
        guard selectedImageAnchor != validAnchor else { return }
        selectedImageAnchor = validAnchor
        (layoutManager as? MarkdownLayoutManager)?.selectedImageAnchor = validAnchor
        if let validAnchor,
           let image = controller?.parsed.images.first(where: { $0.anchor == validAnchor }) {
            // Collapse any prior text selection at a safe visible boundary.
            // The insertion point stays hidden while the image is selected.
            setSelectedRange(NSRange(location: min(image.range.upperBound,
                                                    textStorage?.length ?? 0),
                                     length: 0))
        }
        needsDisplay = true
    }

    @discardableResult
    private func removeSelectedImage() -> Bool {
        guard let anchor = selectedImageAnchor, let controller else { return false }
        selectImage(atAnchor: nil)
        controller.removeImage(atAnchor: anchor)
        return true
    }

    public override func keyDown(with event: NSEvent) {
        // Delete/Forward Delete are dispatched to the overrides above. Any
        // other keyboard action returns focus to the text caret; Escape simply
        // clears the object selection.
        if selectedImageAnchor != nil {
            if event.keyCode == 53 {
                selectImage(atAnchor: nil)
                return
            }
            if event.keyCode != 51, event.keyCode != 117 {
                selectImage(atAnchor: nil)
            }
        }
        super.keyDown(with: event)
    }

    public override func scrollWheel(with event: NSEvent) {
        let shifted = event.modifierFlags.contains(.shift)
        let horizontal = event.scrollingDeltaX
        let raw = abs(horizontal) > 0.1 ? horizontal
            : (shifted ? event.scrollingDeltaY : 0)
        let hasHorizontalIntent = abs(horizontal) >= abs(event.scrollingDeltaY) || shifted
        if hasHorizontalIntent, abs(raw) > 0.1 {
            var delta = event.isDirectionInvertedFromDevice ? raw : -raw
            if !event.hasPreciseScrollingDeltas { delta *= 32 }
            let point = convert(event.locationInWindow, from: nil)
            let origin = textContainerOrigin
            let containerPoint = NSPoint(x: point.x - origin.x,
                                         y: point.y - origin.y)
            if controller?.scrollTableHorizontally(atContainerPoint: containerPoint,
                                                   delta: delta) == true {
                return
            }
        }
        super.scrollWheel(with: event)
    }

    public override func didChangeText() {
        selectImage(atAnchor: nil)
        super.didChangeText()
    }

    /// If the click lands on a drawn checkbox (left of a task item's first
    /// character), return that item's anchor index.
    private func checkboxAnchor(at event: NSEvent) -> Int? {
        guard let lm = layoutManager as? MarkdownLayoutManager else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        return nearestAnchor(at: point, in: lm.checkboxRects)
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
        guard selectedImageAnchor == nil,
              controller?.isTableInteractionActive != true else { return }
        let corrected = insertionRect(for: rect)
        lastDrawnCaretRect = corrected
        super.drawInsertionPoint(in: corrected, color: color, turnedOn: flag)
    }

    /// Return the visually correct caret rectangle for the current source
    /// selection. Internal so marker-boundary geometry stays regression-tested.
    func insertionRect(for rect: NSRect) -> NSRect {
        var r = rect
        let caret = selectedRange().location

        // A hidden marker collapses multiple source offsets onto one visual
        // boundary. TextKit's default caret rect can then borrow the null
        // glyph's geometry, appearing low or at the end of the line. Anchor it
        // to the next visible glyph (or the previous glyph at document end)
        // and derive its vertical position from that line's actual baseline.
        if let boundary = markerBoundaryInsertionRect(caret: caret, width: rect.width) {
            return boundary
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

    private func markerBoundaryInsertionRect(caret: Int, width: CGFloat) -> NSRect? {
        guard let storage = textStorage, let lm = layoutManager,
              let container = textContainer, let controller,
              controller.markerIndex.sourceLength == storage.length else { return nil }

        let index = controller.markerIndex
        let visual = index.visibleOffset(forSourceOffset: caret)
        let upstream = index.sourceOffset(forVisibleOffset: visual, affinity: .upstream)
        let downstream = index.sourceOffset(forVisibleOffset: visual, affinity: .downstream)
        guard upstream != downstream else { return nil }

        let source = storage.string as NSString
        let next = index.nextVisibleCharacter(after: downstream, in: source)
        let previous = index.previousVisibleCharacter(before: upstream, in: source)
        guard let anchorRange = next ?? previous,
              anchorRange.location < lm.firstUnlaidCharacterIndex() else { return nil }

        let glyphRange = lm.glyphRange(forCharacterRange: anchorRange,
                                       actualCharacterRange: nil)
        guard glyphRange.length > 0 else { return nil }
        let glyph = next == nil ? glyphRange.upperBound - 1 : glyphRange.location
        guard glyph < lm.numberOfGlyphs else { return nil }

        let lineRect = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let glyphLocation = lm.location(forGlyphAt: glyph)
        let origin = textContainerOrigin
        let x: CGFloat
        if next != nil {
            x = origin.x + lineRect.minX + glyphLocation.x
        } else {
            x = origin.x + lm.boundingRect(forGlyphRange: glyphRange, in: container).maxX
        }

        let fontIndex = min(anchorRange.location, max(0, storage.length - 1))
        let font = (storage.attribute(.font, at: fontIndex,
                                      effectiveRange: nil) as? NSFont)
            ?? (typingAttributes[.font] as? NSFont)
            ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let height = ceil(font.ascender - font.descender) + 2
        let baseline = origin.y + lineRect.minY + glyphLocation.y
        return NSRect(x: x, y: baseline - font.ascender - 1,
                      width: max(1, width), height: height)
    }

    /// The system invalidates the caret's *uncorrected* rect on every blink.
    /// When we relocate the caret (onto another line), union in both its new
    /// corrected rect and the last place it was drawn — otherwise the old
    /// pixel is never erased and lingers as a ghost when the caret moves away.
    public override func setNeedsDisplay(_ invalidRect: NSRect, avoidAdditionalLayout flag: Bool) {
        // AppKit invalidates several NSTextView properties while the document
        // view still has a zero-sized pre-mount frame. Asking TextKit to map
        // that rect to glyphs eagerly fills every layout hole in a large
        // document. There is no visible viewport to update yet, so preserve
        // the invalidation while explicitly deferring layout until mounting
        // gives the view real bounds.
        guard bounds.width > 0, bounds.height > 0 else {
            super.setNeedsDisplay(invalidRect, avoidAdditionalLayout: true)
            return
        }

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

    /// Keep AppKit's standard Find bar, but point it at the syntax-free string
    /// supplied by VisibleTextFinderClient rather than NSTextView's raw source.
    public override func performTextFinderAction(_ sender: Any?) {
        let action = NSTextFinder.Action(rawValue: (sender as? NSMenuItem)?.tag ?? 0)
        guard let action else { return }
        if syntaxFreeFinder == nil {
            let finder = NSTextFinder()
            let client = VisibleTextFinderClient(textView: self)
            finder.client = client
            finder.isIncrementalSearchingEnabled = true
            finder.incrementalSearchingShouldDimContentView = true
            syntaxFreeFinder = finder
            syntaxFreeFinderClient = client
        }
        syntaxFreeFinder?.findBarContainer = enclosingScrollView
        syntaxFreeFinder?.performAction(action)
    }

    public override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(performTextFinderAction(_:)),
           let action = NSTextFinder.Action(rawValue: item.tag) {
            return syntaxFreeFinder?.validateAction(action) ?? true
        }
        return super.validateUserInterfaceItem(item)
    }

    public override func shouldChangeText(in affectedCharRange: NSRange,
                                          replacementString: String?) -> Bool {
        syntaxFreeFinder?.noteClientStringWillChange()
        let allowed = super.shouldChangeText(in: affectedCharRange,
                                             replacementString: replacementString)
        if allowed, let storage = textStorage {
            let replacement = replacementString ?? ""
            controller?.prepareForEdit(in: affectedCharRange,
                                       replacementString: replacement)
            controller?.recordPendingEdit(range: affectedCharRange,
                                          replacement: replacement,
                                          oldSourceLength: storage.length)
        }
        return allowed
    }

    // MARK: List collapse — hover chevrons and click targets

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        // NSTextView's window does not request mouse-moved events by default.
        // Tracking areas alone are therefore insufficient in the live app:
        // synthetic tests can call mouseMoved directly while an actual hover
        // never reaches us. Disclosure affordances depend on continuous hover
        // updates, so opt the containing editor window into those events.
        window?.acceptsMouseMovedEvents = true
    }

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
        if collapseTarget(at: event) != nil || checkboxAnchor(at: event) != nil
            || imageAnchor(at: event) != nil {
            NSCursor.arrow.set()
        }
    }

    public override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        controller?.setHoveredListAnchor(nil)
    }

    /// The collapsible list-item or heading anchor on the hovered line, if any.
    private func collapsibleAnchorOnLine(at event: NSEvent) -> Int? {
        let point = convert(event.locationInWindow, from: nil)
        if let layout = layoutManager as? MarkdownLayoutManager,
           let anchor = nearestCandidate(at: point,
                                         in: layout.collapseHoverRects)?.anchor {
            return anchor
        }
        guard let storage = textStorage, storage.length > 0,
              let lm = layoutManager, let container = textContainer,
              let controller else { return nil }
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
        return [nearestCandidate(at: point, in: lm.chevronRects),
                nearestCandidate(at: point, in: lm.dotsRects)]
            .compactMap { $0 }
            .min { $0.distance < $1.distance }?.anchor
    }

    private func nearestAnchor(at point: NSPoint,
                               in rects: [Int: NSRect]) -> Int? {
        nearestCandidate(at: point, in: rects)?.anchor
    }

    private func nearestCandidate(at point: NSPoint,
                                  in rects: [Int: NSRect])
        -> (anchor: Int, distance: CGFloat)? {
        rects.compactMap { anchor, rect -> (Int, CGFloat)? in
            guard rect.contains(point) else { return nil }
            return (anchor, hypot(rect.midX - point.x, rect.midY - point.y))
        }.min { $0.1 < $1.1 }
    }

    private func imageAnchor(at event: NSEvent) -> Int? {
        guard let lm = layoutManager as? MarkdownLayoutManager,
              let storage = textStorage else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        let origin = textContainerOrigin
        let containerPoint = NSPoint(x: point.x - origin.x, y: point.y - origin.y)
        for (anchor, rect) in lm.imageRects {
            let hitRect = NSRect(x: rect.midX - max(44, rect.width) / 2,
                                 y: rect.midY - max(44, rect.height) / 2,
                                 width: max(44, rect.width),
                                 height: max(44, rect.height))
            guard hitRect.contains(containerPoint) else { continue }
            guard anchor < storage.length,
                  storage.attribute(.vireoImage, at: anchor, effectiveRange: nil) != nil else {
                continue
            }
            return anchor
        }
        return nil
    }

    // MARK: Source / visual boundaries

    /// Apply the controller's one marker-boundary policy after a native AppKit
    /// movement. We keep AppKit's word, bidi, line and vertical navigation, then
    /// canonicalize only if it landed in invisible syntax.
    @discardableResult
    private func normalizeSelection(affinity: MarkerAffinity) -> NSRange {
        guard let controller else { return selectedRange() }
        let current = selectedRange()
        let normalized = controller.normalizedSelection(current, affinity: affinity)
        if current != normalized { setSelectedRange(normalized) }
        return normalized
    }

    private func move(_ affinity: MarkerAffinity, _ operation: () -> Void) {
        operation()
        normalizeSelection(affinity: affinity)
    }

    /// TextKit can treat a zero-width delimiter glyph as a line-edge stop when
    /// an unmodified arrow starts exactly on that collapsed boundary. Move the
    /// one adjacent visible grapheme ourselves only at that boundary; all
    /// other positions stay on AppKit's native bidi-aware movement path.
    @discardableResult
    private func moveAcrossCollapsedMarker(_ affinity: MarkerAffinity) -> Bool {
        guard selectedRange().length == 0, let storage = textStorage, let controller else {
            return false
        }
        let index = controller.markerIndex
        let caret = selectedRange().location
        let visible = index.visibleOffset(forSourceOffset: caret)
        guard index.sourceOffset(forVisibleOffset: visible, affinity: .upstream)
                != index.sourceOffset(forVisibleOffset: visible, affinity: .downstream) else {
            return false
        }

        let source = storage.string as NSString
        let target: Int?
        switch affinity {
        case .upstream:
            target = index.previousVisibleCharacter(before: caret, in: source)?.location
        case .downstream:
            target = index.nextVisibleCharacter(after: caret, in: source)?.upperBound
        case .nearest:
            target = nil
        }
        guard let target else { return false }
        let proposed = NSRange(location: target, length: 0)
        setSelectedRange(controller.normalizedSelection(proposed, affinity: affinity))
        scrollRangeToVisible(selectedRange())
        return true
    }

    public override func moveRight(_ sender: Any?) {
        if !moveAcrossCollapsedMarker(.downstream) {
            move(.downstream) { super.moveRight(sender) }
        }
        activateTableCellAtCaret()
    }

    public override func moveForward(_ sender: Any?) {
        if !moveAcrossCollapsedMarker(.downstream) {
            move(.downstream) { super.moveForward(sender) }
        }
        activateTableCellAtCaret()
    }

    public override func moveLeft(_ sender: Any?) {
        if !moveAcrossCollapsedMarker(.upstream) {
            move(.upstream) { super.moveLeft(sender) }
        }
        activateTableCellAtCaret()
    }

    public override func moveBackward(_ sender: Any?) {
        if !moveAcrossCollapsedMarker(.upstream) {
            move(.upstream) { super.moveBackward(sender) }
        }
        activateTableCellAtCaret()
    }

    private func moveAndActivate(_ affinity: MarkerAffinity, _ operation: () -> Void) {
        move(affinity, operation)
        activateTableCellAtCaret()
    }

    public override func moveWordRight(_ sender: Any?) { moveAndActivate(.downstream) { super.moveWordRight(sender) } }
    public override func moveWordForward(_ sender: Any?) { moveAndActivate(.downstream) { super.moveWordForward(sender) } }
    public override func moveWordLeft(_ sender: Any?) { moveAndActivate(.upstream) { super.moveWordLeft(sender) } }
    public override func moveWordBackward(_ sender: Any?) { moveAndActivate(.upstream) { super.moveWordBackward(sender) } }
    public override func moveToEndOfLine(_ sender: Any?) { moveAndActivate(.upstream) { super.moveToEndOfLine(sender) } }
    public override func moveToRightEndOfLine(_ sender: Any?) { moveAndActivate(.upstream) { super.moveToRightEndOfLine(sender) } }
    public override func moveToBeginningOfLine(_ sender: Any?) { moveAndActivate(.downstream) { super.moveToBeginningOfLine(sender) } }
    public override func moveToLeftEndOfLine(_ sender: Any?) { moveAndActivate(.downstream) { super.moveToLeftEndOfLine(sender) } }
    public override func moveToEndOfParagraph(_ sender: Any?) { moveAndActivate(.upstream) { super.moveToEndOfParagraph(sender) } }
    public override func moveToBeginningOfParagraph(_ sender: Any?) { moveAndActivate(.downstream) { super.moveToBeginningOfParagraph(sender) } }
    public override func moveUp(_ sender: Any?) { moveAndActivate(.nearest) { super.moveUp(sender) } }
    public override func moveDown(_ sender: Any?) { moveAndActivate(.nearest) { super.moveDown(sender) } }

    private func activateTableCellAtCaret() {
        guard selectedRange().length == 0 else { return }
        controller?.beginTableCellEditing(atSourceLocation: selectedRange().location)
    }

    public override func moveRightAndModifySelection(_ sender: Any?) { move(.downstream) { super.moveRightAndModifySelection(sender) } }
    public override func moveForwardAndModifySelection(_ sender: Any?) { move(.downstream) { super.moveForwardAndModifySelection(sender) } }
    public override func moveLeftAndModifySelection(_ sender: Any?) { move(.upstream) { super.moveLeftAndModifySelection(sender) } }
    public override func moveBackwardAndModifySelection(_ sender: Any?) { move(.upstream) { super.moveBackwardAndModifySelection(sender) } }
    public override func moveWordRightAndModifySelection(_ sender: Any?) { move(.downstream) { super.moveWordRightAndModifySelection(sender) } }
    public override func moveWordForwardAndModifySelection(_ sender: Any?) { move(.downstream) { super.moveWordForwardAndModifySelection(sender) } }
    public override func moveWordLeftAndModifySelection(_ sender: Any?) { move(.upstream) { super.moveWordLeftAndModifySelection(sender) } }
    public override func moveWordBackwardAndModifySelection(_ sender: Any?) { move(.upstream) { super.moveWordBackwardAndModifySelection(sender) } }
    public override func moveToEndOfLineAndModifySelection(_ sender: Any?) { move(.upstream) { super.moveToEndOfLineAndModifySelection(sender) } }
    public override func moveToRightEndOfLineAndModifySelection(_ sender: Any?) { move(.upstream) { super.moveToRightEndOfLineAndModifySelection(sender) } }
    public override func moveToBeginningOfLineAndModifySelection(_ sender: Any?) { move(.downstream) { super.moveToBeginningOfLineAndModifySelection(sender) } }
    public override func moveToLeftEndOfLineAndModifySelection(_ sender: Any?) { move(.downstream) { super.moveToLeftEndOfLineAndModifySelection(sender) } }
    public override func moveToEndOfParagraphAndModifySelection(_ sender: Any?) { move(.upstream) { super.moveToEndOfParagraphAndModifySelection(sender) } }
    public override func moveToBeginningOfParagraphAndModifySelection(_ sender: Any?) { move(.downstream) { super.moveToBeginningOfParagraphAndModifySelection(sender) } }
    public override func moveUpAndModifySelection(_ sender: Any?) { move(.nearest) { super.moveUpAndModifySelection(sender) } }
    public override func moveDownAndModifySelection(_ sender: Any?) { move(.nearest) { super.moveDownAndModifySelection(sender) } }

    public override func insertText(_ string: Any, replacementRange: NSRange) {
        if replacementRange.location == NSNotFound, !hasMarkedText(),
           controller?.beginTableCellEditing(atSourceLocation: selectedRange().location,
                                             selectAll: selectedRange().length > 0) == true {
            let plain = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
            controller?.insertTextIntoActiveTableCell(plain)
            return
        }
        // A vertical arrow, service or accessibility action may have left the
        // insertion point inside a hidden marker. Canonicalize before editing.
        if replacementRange.location == NSNotFound, !hasMarkedText() {
            normalizeSelection(affinity: .downstream)
            super.insertText(string, replacementRange: replacementRange)
        } else if let controller, !hasMarkedText() {
            let normalized = controller.normalizedSelection(replacementRange,
                                                            affinity: .downstream)
            super.insertText(string, replacementRange: normalized)
        } else {
            super.insertText(string, replacementRange: replacementRange)
        }
    }

    // MARK: Atomic deletion and pasteboard

    public override func deleteBackward(_ sender: Any?) {
        if removeSelectedImage() { return }
        if deleteSelectedVisibleText() { return }
        guard let storage = textStorage, let controller,
              let character = controller.markerIndex.previousVisibleCharacter(
                before: selectedRange().location, in: storage.string as NSString) else {
            super.deleteBackward(sender)
            return
        }
        deleteVisibleRange(character)
    }

    public override func deleteForward(_ sender: Any?) {
        if removeSelectedImage() { return }
        if deleteSelectedVisibleText() { return }
        guard let storage = textStorage, let controller,
              let character = controller.markerIndex.nextVisibleCharacter(
                after: selectedRange().location, in: storage.string as NSString) else {
            super.deleteForward(sender)
            return
        }
        deleteVisibleRange(character)
    }

    public override func deleteBackwardByDecomposingPreviousCharacter(_ sender: Any?) {
        // A Markdown boundary is more important than decomposing one scalar of
        // a grapheme: never leave half a delimiter or half an emoji behind.
        deleteBackward(sender)
    }

    public override func deleteWordBackward(_ sender: Any?) {
        if deleteSelectedVisibleText() { return }
        super.moveWordBackwardAndModifySelection(sender)
        normalizeSelection(affinity: .upstream)
        _ = deleteSelectedVisibleText()
    }

    public override func deleteWordForward(_ sender: Any?) {
        if deleteSelectedVisibleText() { return }
        super.moveWordForwardAndModifySelection(sender)
        normalizeSelection(affinity: .downstream)
        _ = deleteSelectedVisibleText()
    }

    public override func deleteToBeginningOfLine(_ sender: Any?) {
        if deleteSelectedVisibleText() { return }
        super.moveToBeginningOfLineAndModifySelection(sender)
        normalizeSelection(affinity: .downstream)
        _ = deleteSelectedVisibleText()
    }

    public override func deleteToEndOfLine(_ sender: Any?) {
        if deleteSelectedVisibleText() { return }
        super.moveToEndOfLineAndModifySelection(sender)
        normalizeSelection(affinity: .upstream)
        _ = deleteSelectedVisibleText()
    }

    public override func deleteToBeginningOfParagraph(_ sender: Any?) {
        if deleteSelectedVisibleText() { return }
        super.moveToBeginningOfParagraphAndModifySelection(sender)
        normalizeSelection(affinity: .downstream)
        _ = deleteSelectedVisibleText()
    }

    public override func deleteToEndOfParagraph(_ sender: Any?) {
        if deleteSelectedVisibleText() { return }
        super.moveToEndOfParagraphAndModifySelection(sender)
        normalizeSelection(affinity: .upstream)
        _ = deleteSelectedVisibleText()
    }

    @discardableResult
    private func deleteSelectedVisibleText() -> Bool {
        let selection = selectedRange()
        guard selection.length > 0 else { return false }
        deleteVisibleRange(selection)
        return true
    }

    private func deleteVisibleRange(_ range: NSRange) {
        guard let storage = textStorage, let controller else { return }
        let deletion = controller.markerIndex.balancedDeletionRange(range)
        guard deletion.length > 0 else { return }
        // NSTextView owns undo registration. Going through its editing path
        // keeps atomic syntax deletion indistinguishable from native typing.
        super.insertText("", replacementRange: deletion)
        setSelectedRange(NSRange(location: min(deletion.location, storage.length), length: 0))
    }

    public override func copy(_ sender: Any?) {
        guard let storage = textStorage, let controller, selectedRange().length > 0 else {
            super.copy(sender)
            return
        }
        let selection = controller.markerIndex.atomicSelection(selectedRange())
        let visible = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: selection))
        for marker in controller.markerIndex.ranges.reversed() {
            let intersection = NSIntersectionRange(marker, selection)
            guard intersection.length > 0 else { continue }
            visible.deleteCharacters(in: NSRange(location: intersection.location - selection.location,
                                                 length: intersection.length))
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(visible.string, forType: .string)
        if let rtf = try? visible.data(from: NSRange(location: 0, length: visible.length),
                                       documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) {
            pasteboard.setData(rtf, forType: .rtf)
        }
    }

    public override func cut(_ sender: Any?) {
        guard selectedRange().length > 0 else { return }
        copy(sender)
        _ = deleteSelectedVisibleText()
    }

    // MARK: Enter — list continuation and hidden-marker hygiene

    public override func insertNewline(_ sender: Any?) {
        if controller?.routeTableNavigation(
            .down, fromSourceLocation: selectedRange().location
        ) == true { return }
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
            // Top-level empty item: exit the list. Replace the marker with a
            // newline so the item's line becomes a blank separator and the
            // caret drops onto a fresh line below it. Just clearing the marker
            // would leave the caret directly under the item, where typed text
            // is a *lazy continuation* and keeps rendering inside the list.
            let r = NSRange(location: line.location, length: (lineText as NSString).length)
            if shouldChangeText(in: r, replacementString: "\n") {
                storage.replaceCharacters(in: r, with: "\n")
                didChangeText()
                setSelectedRange(NSRange(location: line.location + 1, length: 0))
            }
            return true
        }

        let insertion = "\n" + info.continuationPrefix
        let sel = NSRange(location: caret, length: 0)
        if shouldChangeText(in: sel, replacementString: insertion) {
            storage.replaceCharacters(in: sel, with: insertion)
            let newCaret = caret + (insertion as NSString).length
            // A new item in the middle of an ordered list duplicates the
            // numbers below it — count the following siblings on from the
            // inserted one so the source stays sequential.
            if info.isOrdered {
                renumberOrderedSiblings(afterLineAt: newCaret)
            }
            didChangeText()
            setSelectedRange(NSRange(location: newCaret, length: 0))
        }
        return true
    }

    /// Apply `ListLine`'s renumber edits bottom-up so earlier ranges stay
    /// valid while later digit runs change width (9 → 10).
    private func renumberOrderedSiblings(afterLineAt location: Int) {
        guard let storage = textStorage else { return }
        let edits = ListLine.orderedSiblingRenumberEdits(
            in: storage.string as NSString, afterLineAt: location)
        for edit in edits.reversed() {
            if shouldChangeText(in: edit.range, replacementString: edit.replacement) {
                storage.replaceCharacters(in: edit.range, with: edit.replacement)
            }
        }
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
        if controller?.routeTableNavigation(
            .next, fromSourceLocation: selectedRange().location
        ) == true { return }
        if adjustListIndent(outdent: false) { return }
        super.insertTab(sender)
    }

    public override func insertBacktab(_ sender: Any?) {
        if controller?.routeTableNavigation(
            .previous, fromSourceLocation: selectedRange().location
        ) == true { return }
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

    // MARK: Accessibility's visual text model

    /// Tables are rendered as semantic accessibility children below, so their
    /// transparent pipes/separator rows must not also leak through the text
    /// area's backing-source representation. Folded descendants similarly
    /// stay out of the text value until the user expands their parent.
    private func accessibilityTextIndex() -> MarkerIndex? {
        guard let storage = textStorage, let controller else { return nil }
        let tableRanges = controller.parsed.tables.map(\.range)
        let collapsed = (controller.parsed.listMarkers.map {
            ($0.anchor, $0.subtreeRange)
        } + controller.parsed.tasks.map {
            ($0.anchor, $0.subtreeRange)
        } + controller.parsed.headings.map {
            ($0.anchor, $0.subtreeRange)
        }).compactMap { anchor, subtree -> NSRange? in
            guard (layoutManager as? MarkdownLayoutManager)?
                .collapsedAnchors.contains(anchor) == true,
                  var subtree else { return nil }
            if subtree.location > 0 {
                subtree = NSRange(location: subtree.location - 1,
                                  length: subtree.length + 1)
            }
            return subtree
        }
        let additionalRanges = (tableRanges + collapsed).sorted {
            $0.location == $1.location ? $0.length < $1.length
                                       : $0.location < $1.location
        }
        if cachedAccessibilityBase != controller.markerIndex
            || cachedAccessibilityAdditionalRanges != additionalRanges {
            cachedAccessibilityBase = controller.markerIndex
            cachedAccessibilityAdditionalRanges = additionalRanges
            cachedAccessibilityIndex = MarkerIndex(
                ranges: controller.markerIndex.ranges + additionalRanges,
                sourceLength: storage.length
            )
        }
        return cachedAccessibilityIndex
    }

    /// NSTextView normally exposes its backing string to VoiceOver. For Vireo,
    /// that is an implementation detail: accessibility must describe the same
    /// syntax-free document sighted users read and edit.
    public override func accessibilityValue() -> String? {
        guard let storage = textStorage, let index = accessibilityTextIndex() else {
            return super.accessibilityValue()
        }
        return index.visibleString(in: storage.string as NSString)
    }

    public override func accessibilityNumberOfCharacters() -> Int {
        accessibilityTextIndex()?.visibleLength ?? super.accessibilityNumberOfCharacters()
    }

    public override func accessibilitySelectedText() -> String? {
        guard let storage = textStorage, let index = accessibilityTextIndex() else {
            return super.accessibilitySelectedText()
        }
        return index.visibleString(in: selectedRange(), source: storage.string as NSString)
    }

    public override func accessibilitySelectedTextRange() -> NSRange {
        guard let index = accessibilityTextIndex() else {
            return super.accessibilitySelectedTextRange()
        }
        return index.visibleRange(forSourceRange: selectedRange())
    }

    public override func setAccessibilitySelectedTextRange(_ range: NSRange) {
        guard let index = accessibilityTextIndex() else {
            super.setAccessibilitySelectedTextRange(range)
            return
        }
        setSelectedRange(index.sourceRange(forVisibleRange: range))
    }

    public override func accessibilitySelectedTextRanges() -> [NSValue]? {
        guard let index = accessibilityTextIndex() else {
            return super.accessibilitySelectedTextRanges()
        }
        return selectedRanges.map {
            NSValue(range: index.visibleRange(forSourceRange: $0.rangeValue))
        }
    }

    public override func setAccessibilitySelectedTextRanges(_ ranges: [NSValue]?) {
        guard let index = accessibilityTextIndex(), let ranges, !ranges.isEmpty else {
            super.setAccessibilitySelectedTextRanges(ranges)
            return
        }
        setSelectedRanges(ranges.map {
            NSValue(range: index.sourceRange(forVisibleRange: $0.rangeValue))
        }, affinity: .downstream, stillSelecting: false)
    }

    public override func accessibilityVisibleCharacterRange() -> NSRange {
        guard let index = accessibilityTextIndex() else {
            return super.accessibilityVisibleCharacterRange()
        }
        return index.visibleRange(
            forSourceRange: super.accessibilityVisibleCharacterRange()
        )
    }

    public override func accessibilityString(for range: NSRange) -> String? {
        guard let storage = textStorage, let index = accessibilityTextIndex() else {
            return super.accessibilityString(for: range)
        }
        let visible = index.visibleString(in: storage.string as NSString) as NSString
        let lower = min(max(0, range.location), visible.length)
        let upper = min(max(lower, range.upperBound), visible.length)
        return visible.substring(with: NSRange(location: lower, length: upper - lower))
    }

    public override func accessibilityAttributedString(for range: NSRange) -> NSAttributedString? {
        guard let storage = textStorage, let index = accessibilityTextIndex() else {
            return super.accessibilityAttributedString(for: range)
        }
        let sourceRange = index.sourceRange(forVisibleRange: range)
        let result = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: sourceRange))
        for marker in index.ranges.reversed() {
            let intersection = NSIntersectionRange(marker, sourceRange)
            if intersection.length > 0 {
                result.deleteCharacters(in: NSRange(location: intersection.location - sourceRange.location,
                                                    length: intersection.length))
            }
        }
        return result
    }

    public override func accessibilityRange(for index: Int) -> NSRange {
        guard let storage = textStorage, let textIndex = accessibilityTextIndex() else {
            return super.accessibilityRange(for: index)
        }
        let visible = textIndex.visibleString(in: storage.string as NSString) as NSString
        guard index >= 0, index < visible.length else {
            return NSRange(location: min(max(0, index), visible.length), length: 0)
        }
        return visible.rangeOfComposedCharacterSequence(at: index)
    }

    public override func accessibilityRange(for point: NSPoint) -> NSRange {
        guard let index = accessibilityTextIndex() else {
            return super.accessibilityRange(for: point)
        }
        return index.visibleRange(
            forSourceRange: super.accessibilityRange(for: point)
        )
    }

    public override func accessibilityFrame(for range: NSRange) -> NSRect {
        guard let index = accessibilityTextIndex() else {
            return super.accessibilityFrame(for: range)
        }
        return super.accessibilityFrame(
            for: index.sourceRange(forVisibleRange: range)
        )
    }

    public override func accessibilityStyleRange(for index: Int) -> NSRange {
        guard let textIndex = accessibilityTextIndex() else {
            return super.accessibilityStyleRange(for: index)
        }
        let sourceIndex = textIndex.sourceOffset(forVisibleOffset: index,
                                                 affinity: .downstream)
        return textIndex.visibleRange(
            forSourceRange: super.accessibilityStyleRange(for: sourceIndex)
        )
    }

    // MARK: Accessibility for custom-drawn controls

    public override func accessibilityChildren() -> [Any]? {
        var children = super.accessibilityChildren() ?? []
        guard let controller, let storage = textStorage,
              let layout = layoutManager as? MarkdownLayoutManager else {
            return children
        }
        var usedIDs: Set<String> = []
        var ordered: [(location: Int, element: MarkdownAccessibilityElement)] = []

        func element(id: String, role: NSAccessibility.Role, label: String?,
                     frame: NSRect, parent: Any? = nil, value: Any? = nil,
                     help: String? = nil,
                     press: (() -> Bool)? = nil) -> MarkdownAccessibilityElement {
            let item = markdownAccessibilityElements[id]
                ?? MarkdownAccessibilityElement()
            markdownAccessibilityElements[id] = item
            usedIDs.insert(id)
            item.setAccessibilityIdentifier(id)
            item.setAccessibilityRole(role)
            item.setAccessibilityLabel(label)
            item.setAccessibilityFrame(frame)
            item.setAccessibilityParent(parent ?? self)
            item.setAccessibilityValue(value)
            item.setAccessibilityHelp(help)
            item.setAccessibilityEnabled(true)
            item.setAccessibilityChildren(nil)
            item.performPress = press
            return item
        }

        let source = storage.string as NSString
        let baseIndex = controller.markerIndex

        for task in controller.parsed.tasks {
            guard let rect = layout.checkboxRects[task.anchor] else { continue }
            let label = accessibilityLineLabel(at: task.anchor, source: source,
                                               index: baseIndex)
            let item = element(
                id: "markdown-task-\(task.anchor)", role: .checkBox,
                label: label.isEmpty ? "Task" : label,
                frame: accessibilityScreenFrame(for: rect),
                value: NSNumber(value: task.checked),
                help: task.checked ? "Checked. Press to uncheck."
                                   : "Not checked. Press to check.",
                press: { [weak controller] in
                    controller?.toggleTask(atAnchor: task.anchor)
                    return controller != nil
                }
            )
            ordered.append((task.anchor, item))
        }

        let folds: [(anchor: Int, label: String)] =
            controller.parsed.listMarkers.compactMap { marker in
                marker.subtreeRange == nil ? nil
                    : (marker.anchor, accessibilityLineLabel(
                        at: marker.anchor, source: source, index: baseIndex))
            }
            + controller.parsed.tasks.compactMap { task in
                task.subtreeRange == nil ? nil
                    : (task.anchor, accessibilityLineLabel(
                        at: task.anchor, source: source, index: baseIndex))
            }
            + controller.parsed.headings.compactMap { heading in
                heading.subtreeRange == nil ? nil
                    : (heading.anchor, accessibilityLineLabel(
                        at: heading.anchor, source: source, index: baseIndex))
            }
        for fold in folds {
            guard let rect = layout.chevronRects[fold.anchor] else { continue }
            let collapsed = layout.collapsedAnchors.contains(fold.anchor)
            let verb = collapsed ? "Expand" : "Collapse"
            let item = element(
                id: "markdown-fold-\(fold.anchor)", role: .disclosureTriangle,
                label: fold.label.isEmpty ? "\(verb) section"
                                          : "\(verb) \(fold.label)",
                frame: accessibilityScreenFrame(for: rect),
                value: NSNumber(value: !collapsed),
                help: "Press to \(verb.lowercased()) this section.",
                press: { [weak controller] in
                    controller?.toggleCollapse(anchor: fold.anchor)
                    return controller != nil
                }
            )
            ordered.append((fold.anchor, item))
        }

        for image in controller.parsed.images {
            guard let rect = layout.imageRects[image.anchor] else { continue }
            let alt = image.alt.trimmingCharacters(in: .whitespacesAndNewlines)
            let item = element(
                id: "markdown-image-\(image.anchor)", role: .image,
                label: alt.isEmpty ? "Image" : alt,
                frame: accessibilityScreenFrame(forContainerRect: rect),
                help: "Image source: \(image.source). Press to edit.",
                press: { [weak controller] in
                    controller?.editImage(atAnchor: image.anchor)
                    return controller != nil
                }
            )
            ordered.append((image.anchor, item))
        }

        for block in controller.parsed.sourceBlocks {
            guard let rect = layout.sourceBlockRects[block.anchor] else { continue }
            let label: String
            switch block.kind {
            case .metadata(let value), .unsupportedHTML(let value):
                label = value
            }
            let item = element(
                id: "markdown-source-block-\(block.anchor)", role: .staticText,
                label: nil, frame: accessibilityScreenFrame(forContainerRect: rect),
                value: label
            )
            ordered.append((block.anchor, item))
        }

        let visibleSource = super.accessibilityVisibleCharacterRange()
        for link in controller.parsed.links where visibleSource.length == 0
            || NSIntersectionRange(link.range, visibleSource).length > 0 {
            let frame = super.accessibilityFrame(for: link.labelRange)
            guard !frame.isEmpty else { continue }
            let item = element(
                id: "markdown-link-\(link.range.location)", role: .link,
                label: link.label.isEmpty ? link.destination : link.label,
                frame: frame, value: link.destination,
                help: "Opens \(link.destination).",
                press: { [weak controller] in
                    guard let open = controller?.onOpenLink else { return false }
                    open(link.destination)
                    return true
                }
            )
            ordered.append((link.range.location, item))
        }

        for table in controller.parsed.tables.sorted(by: { $0.anchor < $1.anchor }) {
            guard let tableRect = layout.tableRects[table.anchor] else { continue }
            let tableElement = element(
                id: "markdown-table-\(table.anchor)", role: .table,
                label: "Table, \(table.rows.count) rows, \(table.columnCount) columns",
                frame: accessibilityScreenFrame(forContainerRect: tableRect)
            )
            var rowElements: [MarkdownAccessibilityElement] = []
            for rowIndex in table.rows.indices {
                let geometries = layout.tableCellGeometries.values
                    .filter { $0.id.tableAnchor == table.anchor && $0.id.row == rowIndex }
                    .sorted { $0.id.column < $1.id.column }
                guard !geometries.isEmpty else { continue }
                let rowRect = geometries.dropFirst().reduce(geometries[0].rect) {
                    NSUnionRect($0, $1.rect)
                }
                let rowElement = element(
                    id: "markdown-table-\(table.anchor)-row-\(rowIndex)",
                    role: .row,
                    label: rowIndex == 0 ? "Header row" : "Row \(rowIndex)",
                    frame: accessibilityScreenFrame(forContainerRect: rowRect),
                    parent: tableElement
                )
                var cells: [MarkdownAccessibilityElement] = []
                for geometry in geometries {
                    guard table.rows.indices.contains(geometry.id.row),
                          let cell = table.rows[geometry.id.row].cells.first(where: {
                              $0.column == geometry.id.column
                          }) else { continue }
                    let cellValue = baseIndex.visibleString(in: cell.range, source: source)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let cellLabel = geometry.isHeader
                        ? "Column \(geometry.id.column + 1) header"
                        : "Row \(geometry.id.row), column \(geometry.id.column + 1)"
                    let cellElement = element(
                        id: "markdown-table-\(table.anchor)-cell-\(geometry.id.row)-\(geometry.id.column)",
                        role: .cell, label: cellLabel,
                        frame: accessibilityScreenFrame(forContainerRect: geometry.rect),
                        parent: rowElement, value: cellValue,
                        help: "Press to edit this table cell.",
                        press: { [weak controller] in
                            controller?.beginTableCellEditing(geometry)
                            return controller != nil
                        }
                    )
                    cells.append(cellElement)
                }
                rowElement.setAccessibilityChildren(cells)
                rowElements.append(rowElement)
            }
            tableElement.setAccessibilityChildren(rowElements)
            ordered.append((table.anchor, tableElement))
        }

        markdownAccessibilityElements = markdownAccessibilityElements.filter {
            usedIDs.contains($0.key)
        }
        children.append(contentsOf: ordered.sorted { lhs, rhs in
            if lhs.location == rhs.location {
                return (lhs.element.accessibilityIdentifier() ?? "")
                    < (rhs.element.accessibilityIdentifier() ?? "")
            }
            return lhs.location < rhs.location
        }.map(\.element))
        return children
    }

    private func accessibilityLineLabel(at anchor: Int, source: NSString,
                                        index: MarkerIndex) -> String {
        guard anchor <= source.length else { return "" }
        let location = min(anchor, max(0, source.length - 1))
        let line = source.lineRange(for: NSRange(location: location, length: 0))
        return index.visibleString(in: line, source: source)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func accessibilityScreenFrame(for viewRect: NSRect) -> NSRect {
        guard let window else { return viewRect }
        return window.convertToScreen(convert(viewRect, to: nil))
    }

    private func accessibilityScreenFrame(forContainerRect rect: NSRect) -> NSRect {
        accessibilityScreenFrame(for: rect.offsetBy(dx: textContainerOrigin.x,
                                                     dy: textContainerOrigin.y))
    }

    func notifyAccessibilityLayoutChanged() {
        NSAccessibility.post(element: self, notification: .layoutChanged)
    }

    // NB: no didChangeText override — the Coordinator's textDidChange
    // notification already triggers the (synchronous) restyle; overriding here
    // too would restyle every keystroke twice.
}
