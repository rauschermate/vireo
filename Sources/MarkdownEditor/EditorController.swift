import AppKit
import SwiftUI
import UniformTypeIdentifiers
import MarkdownEngine
import MarkdownRender

/// Owns the imperative bridge to one document's `NSTextView`: parsing, styling,
/// formatting commands, scrolling and zoom. The app holds one per open tab.
@MainActor
public final class EditorController: ObservableObject {
    weak var textView: MarkdownTextView?
    weak var layoutManager: MarkdownLayoutManager?
    public let imageLoader = ImageLoader()

    public var baseURL: URL?
    public var onSourceChange: ((String) -> Void)?
    public var onParsed: ((ParsedMarkdown) -> Void)?
    public var onOpenLink: ((String) -> Void)?

    @Published public var zoom: CGFloat = 1.0 { didSet { restyle() } }

    private let incremental = IncrementalParser()
    public private(set) var parsed = ParsedMarkdown()
    /// Shared source/visual boundary map. Every editor interaction uses this
    /// index rather than rediscovering marker ranges from text attributes.
    public private(set) var markerIndex = MarkerIndex.empty
    /// Semantic markers plus any delimiters retained while a formerly-valid
    /// construct is transiently incomplete in the active paragraph.
    private var presentationMarkerRanges: [NSRange] = []
    private var provisionalMarkerRanges: [NSRange]?
    private var expectedEditedSourceLength: Int?
    private var expectedEditedAnchor: Int?
    private var transientMarkerRanges: [NSRange] = []
    private var transientParagraphRange: NSRange?
    private lazy var toolbar = FloatingToolbar(controller: self)
    private lazy var linkPopover = LinkPopover()
    /// Table whose source is revealed because the caret is inside it
    /// (identified by absolute anchor — stable across incremental edits).
    private var revealedTableAnchor: Int?
    /// Collapsed list items (absolute anchors) and the hover target.
    private var collapsedAnchors: Set<Int> = []
    private var lastSourceLength = 0

    public init() {
        imageLoader.onChange = { [weak self] urls in self?.imagesDidLoad(urls) }
    }

    /// Give interaction code an identity source map immediately, before the
    /// first deferred parse/style pass. Without this bootstrap, a keystroke in
    /// the launch runloop would be clamped against `MarkerIndex.empty` and land
    /// at the beginning of a non-empty document.
    func bootstrapMarkerIndex(sourceLength: Int) {
        guard markerIndex.sourceLength != sourceLength else { return }
        markerIndex = MarkerIndex(ranges: presentationMarkerRanges,
                                  sourceLength: sourceLength)
    }

    /// Show/hide the floating format toolbar and reveal/re-hide table source
    /// as the selection moves.
    public func selectionChanged() {
        guard let tv = textView else { return }
        let sel = tv.selectedRange()

        // Incomplete syntax is retained only for the paragraph being actively
        // repaired. Moving away commits it as literal text rather than hiding
        // arbitrary punctuation indefinitely.
        if !transientMarkerRanges.isEmpty,
           let paragraph = transientParagraphRange,
           (sel.location < paragraph.location || sel.location >= paragraph.upperBound) {
            clearTransientMarkerPresentation(dirty: paragraph)
        }

        // Reveal the raw source of the table the caret sits in (if any) —
        // restyling only the affected table ranges, not the whole document.
        let anchor = parsed.tables.first { NSLocationInRange(sel.location, $0.range) }?.anchor
        if anchor != revealedTableAnchor {
            let previous = revealedTableAnchor
            revealedTableAnchor = anchor
            for a in [previous, anchor].compactMap({ $0 }) {
                if let range = parsed.tables.first(where: { $0.anchor == a })?.range {
                    applyStyles(dirty: range)
                }
            }
        }

        // Caret geometry on empty lines follows typingAttributes — keep them
        // in sync with wherever the caret just moved to.
        refreshTypingAttributes()

        guard sel.length > 0 else { toolbar.hide(); return }
        let rect = tv.firstRect(forCharacterRange: sel, actualRange: nil)
        toolbar.update(selectionRect: rect, hasSelection: true,
                       active: ActiveFormats.at(sel, in: parsed))
    }

    /// Hide the floating toolbar (scrolling detaches it from the selection).
    public func hideFloatingToolbar() {
        toolbar.hide()
    }

    /// Max width of the centered reading column (the text container plus its
    /// side inset). The find bar matches this so search aligns with the text.
    public var contentColumnMaxWidth: CGFloat { theme.contentMaxWidth + 48 }

    /// Minimum side gutter kept even on narrow windows.
    static let minContentSideInset: CGFloat = 24

    /// Keep the reading column centered at its max width (PRD: centered
    /// content column, ~640–800pt). Driven by frame-change notifications so it
    /// tracks live window resizes, not just SwiftUI updates.
    public func recenterContent() {
        guard let tv = textView, let scroll = tv.enclosingScrollView else { return }
        let available = scroll.contentSize.width
        guard available > 0 else { return }
        let column = min(available, contentColumnMaxWidth)
        let side = max(Self.minContentSideInset, (available - column) / 2)
        if abs(tv.textContainerInset.width - side) > 0.5 {
            tv.textContainerInset = NSSize(width: side, height: tv.textContainerInset.height)
            tv.needsDisplay = true
        }
    }

    /// Toggle the `[ ]` / `[x]` of the task whose checkbox is drawn at `anchor`
    /// (the first visible character of the item; the raw marker sits just
    /// before it in the hidden syntax).
    public func toggleTask(atAnchor anchor: Int) {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let ns = storage.string as NSString
        var i = anchor - 1
        let lower = max(0, anchor - 8)
        while i >= lower + 2 {
            if ns.character(at: i) == 0x5D { // ']'
                let mid = ns.character(at: i - 1)
                if ns.character(at: i - 2) == 0x5B, // '['
                   mid == 0x20 || mid == 0x78 || mid == 0x58 { // ' ', x, X
                    let r = NSRange(location: i - 1, length: 1)
                    let replacement = mid == 0x20 ? "x" : " "
                    if tv.shouldChangeText(in: r, replacementString: replacement) {
                        storage.replaceCharacters(in: r, with: replacement)
                        tv.didChangeText()
                    }
                    return
                }
            }
            i -= 1
        }
    }

    var theme: Theme { Theme(zoom: zoom) }

    // MARK: Styling

    /// Restyle after an edit. The incremental parser makes a keystroke ~1 ms
    /// on typical documents, so styling applies *synchronously* — no debounce,
    /// no flash of raw markdown. The one exception is IME composition: touching
    /// attributes mid-composition breaks marked text, so those restyles wait
    /// until the composition commits (the commit fires textDidChange again).
    public func scheduleRestyle() {
        guard let tv = textView, let storage = tv.textStorage else { return }
        onSourceChange?(storage.string)

        if tv.hasMarkedText() { return }
        restyleAfterEdit()
    }

    /// Capture marker presentation before an edit mutates the source. Existing
    /// delimiters that survive an edit can remain hidden even if the parser
    /// temporarily stops recognizing their now-incomplete construct.
    public func prepareForEdit(in range: NSRange, replacementString: String) {
        guard let storage = textView?.textStorage else { return }
        let sourceLength = storage.length
        let lower = min(max(0, range.location), sourceLength)
        let upper = min(max(lower, range.upperBound), sourceLength)
        let edit = NSRange(location: lower, length: upper - lower)
        let replacementLength = (replacementString as NSString).length
        let base = provisionalMarkerRanges ?? presentationMarkerRanges
        provisionalMarkerRanges = transformMarkerRanges(base, through: edit,
                                                         replacementLength: replacementLength)
        expectedEditedSourceLength = sourceLength - edit.length + replacementLength
        expectedEditedAnchor = edit.location + replacementLength
    }

    /// Edit path: incremental parse; re-apply attributes only over the dirty
    /// region (the whole document when the parser had to fall back).
    private func restyleAfterEdit() {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let update = incremental.update(storage.string)
        parsed = update.parsed
        updateMarkerPresentation(after: update, storage: storage)
        onParsed?(parsed)
        remapCollapsedAnchors(dirty: update.dirtyRange,
                              delta: storage.length - lastSourceLength)
        lastSourceLength = storage.length
        applyStyles(dirty: update.dirtyRange)
    }

    /// The fold subtree owned by `anchor` — list item, task or heading.
    private func subtree(forAnchor anchor: Int) -> NSRange? {
        (parsed.listMarkers.first { $0.anchor == anchor }?.subtreeRange)
            ?? (parsed.tasks.first { $0.anchor == anchor }?.subtreeRange)
            ?? (parsed.headings.first { $0.anchor == anchor }?.subtreeRange)
    }

    /// Keep collapse state attached to the right items across edits: anchors
    /// after the dirty window shift by the edit's delta; anchors inside it are
    /// re-validated against the fresh parse (dropped if the item vanished).
    private func remapCollapsedAnchors(dirty: NSRange?, delta: Int) {
        guard !collapsedAnchors.isEmpty else { return }
        let valid = Set(parsed.listMarkers.compactMap { $0.subtreeRange != nil ? $0.anchor : nil }
            + parsed.tasks.compactMap { $0.subtreeRange != nil ? $0.anchor : nil }
            + parsed.headings.compactMap { $0.subtreeRange != nil ? $0.anchor : nil })
        if let dirty {
            let oldDirtyEnd = dirty.location + dirty.length - delta
            collapsedAnchors = Set(collapsedAnchors.compactMap { a in
                if a < dirty.location { return a }
                if a >= oldDirtyEnd { return a + delta }
                return a // inside the edited window — keep only if still real
            }).intersection(valid)
        } else {
            collapsedAnchors = collapsedAnchors.intersection(valid)
        }
    }

    /// Toggle a list item's or heading's collapse state (chevron / `…` clicks).
    public func toggleCollapse(anchor: Int) {
        guard let tv = textView else { return }
        if collapsedAnchors.contains(anchor) {
            collapsedAnchors.remove(anchor)
        } else {
            collapsedAnchors.insert(anchor)
            // Rescue the caret if it's about to be hidden.
            if let subtree = subtree(forAnchor: anchor),
               NSIntersectionRange(tv.selectedRange(), subtree).length > 0
                || NSLocationInRange(tv.selectedRange().location, subtree) {
                tv.setSelectedRange(NSRange(location: max(0, subtree.location - 1), length: 0))
            }
        }
        applyStyles(dirty: nil)
    }

    public func isCollapsible(anchor: Int) -> Bool {
        subtree(forAnchor: anchor) != nil
    }

    /// Normalize an AppKit selection against every hidden Markdown marker.
    /// Direction determines which side owns a collapsed caret boundary.
    public func normalizedSelection(_ proposed: NSRange,
                                    previous: NSRange? = nil,
                                    affinity explicitAffinity: MarkerAffinity? = nil) -> NSRange {
        if proposed.length > 0 { return markerIndex.atomicSelection(proposed) }
        let affinity: MarkerAffinity
        if let explicitAffinity {
            affinity = explicitAffinity
        } else if let previous, proposed.location < previous.location {
            affinity = .upstream
        } else if let previous, proposed.location > previous.upperBound {
            affinity = .downstream
        } else {
            affinity = .nearest
        }
        return NSRange(location: markerIndex.caretPosition(proposed.location, affinity: affinity),
                       length: 0)
    }

    /// Hover target for the collapse chevron (set from mouse tracking).
    public func setHoveredListAnchor(_ anchor: Int?) {
        guard layoutManager?.hoveredAnchor != anchor else { return }
        layoutManager?.hoveredAnchor = anchor
        textView?.needsDisplay = true
    }

    /// Full restyle: theme, zoom or appearance changed, so every attribute must
    /// be recomputed even though the text didn't change.
    public func restyle() {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let update = incremental.update(storage.string)
        parsed = update.parsed
        // A theme/image restyle does not end an active repair transaction.
        if presentationMarkerRanges.isEmpty {
            presentationMarkerRanges = parsed.markerRanges
        }
        markerIndex = MarkerIndex(ranges: presentationMarkerRanges, sourceLength: storage.length)
        onParsed?(parsed)
        applyStyles(dirty: nil)
    }

    /// Re-render and re-apply attributes over `dirty` (nil = whole document).
    /// Characters are never touched, so the selection and the on-disk source
    /// are preserved; bounding the range bounds TextKit's layout invalidation.
    private func applyStyles(dirty: NSRange?) {
        applyStyles(windows: dirty.map { [$0] })
    }

    /// Image completions can touch disjoint paragraphs. Keep those windows
    /// separate so two images far apart never turn into a document-wide restyle.
    private func applyStyles(dirtyRanges: [NSRange]) {
        applyStyles(windows: dirtyRanges)
    }

    private func applyStyles(windows requestedWindows: [NSRange]?) {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let full = NSRange(location: 0, length: storage.length)
        let rawWindows = requestedWindows ?? [full]
        let expanded = rawWindows.map {
            expandOverCollapsedSubtrees(NSIntersectionRange($0, full),
                                        storage: storage)
        }.filter { $0.length > 0 }
        let windows = mergeStyleWindows(expanded)

        var presented = parsed
        presented.markerRanges = presentationMarkerRanges

        if !windows.isEmpty {
            storage.beginEditing()
            for window in windows {
                var renderer = MarkdownRenderer(theme: theme, baseURL: baseURL,
                                                imageLoader: imageLoader,
                                                isDark: tv.isDark)
                renderer.revealTableAnchor = revealedTableAnchor
                renderer.collapsedAnchors = collapsedAnchors
                renderer.originOffset = window.location
                let sliceSource = (storage.string as NSString).substring(with: window)
                let sliceParsed = window == full ? presented : presented.slice(window)
                let rendered = renderer.render(source: sliceSource, parsed: sliceParsed)

                rendered.enumerateAttributes(
                    in: NSRange(location: 0, length: rendered.length)
                ) { attrs, range, _ in
                    storage.setAttributes(
                        attrs,
                        range: NSRange(location: range.location + window.location,
                                       length: range.length)
                    )
                }
            }
            storage.endEditing()
        }

        layoutManager?.markerColor = theme.secondaryColor
        layoutManager?.bulletFont = theme.bodyFont
        layoutManager?.tables = parsed.tables
        layoutManager?.tableRowHeight = theme.tableRowHeight
        layoutManager?.tableFont = theme.tableFont
        layoutManager?.tableHeaderFont = theme.tableHeaderFont
        layoutManager?.imageMaxWidth = theme.contentMaxWidth
        layoutManager?.listMarkers = parsed.listMarkers
        layoutManager?.taskMarks = parsed.tasks
        layoutManager?.headingMarks = parsed.headings
        layoutManager?.collapsedAnchors = collapsedAnchors
        refreshTypingAttributes()
        tv.needsDisplay = true
    }

    private func mergeStyleWindows(_ ranges: [NSRange]) -> [NSRange] {
        let sorted = ranges.sorted { $0.location < $1.location }
        var merged: [NSRange] = []
        for range in sorted {
            guard let last = merged.last else {
                merged.append(range)
                continue
            }
            if range.location <= last.upperBound {
                merged[merged.count - 1] = NSUnionRange(last, range)
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    private func imagesDidLoad(_ urls: Set<URL>) {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let ranges = imageLoader.paragraphRanges(
            forLoadedURLs: urls, images: parsed.images,
            source: storage.string, baseURL: baseURL
        )
        guard !ranges.isEmpty else { return }
        let viewport = TextViewportAnchor.capture(in: tv)
        applyStyles(dirtyRanges: ranges)
        viewport?.restore(in: tv)
    }

    /// A restyle window must cover any collapsed fold it touches *entirely* —
    /// the renderer re-applies `.vireoCollapsed` from the anchor's subtree, so
    /// re-rendering only part of one (headings especially: their folds span
    /// many blocks) would leave that part visible. Grows the window to a fixed
    /// point, from the anchor's line start through the subtree's end.
    private func expandOverCollapsedSubtrees(_ window: NSRange, storage: NSTextStorage) -> NSRange {
        guard !collapsedAnchors.isEmpty, window.length < storage.length else { return window }
        let ns = storage.string as NSString
        var w = window
        var changed = true
        var iterations = 0
        while changed, iterations < 32 {
            changed = false
            iterations += 1
            for anchor in collapsedAnchors {
                guard let sub = subtree(forAnchor: anchor) else { continue }
                // The hidden region includes the newline before the subtree.
                let hide = NSRange(location: max(0, sub.location - 1),
                                   length: sub.length + min(1, sub.location))
                guard NSIntersectionRange(hide, w).length > 0, anchor < ns.length else { continue }
                let lineStart = ns.lineRange(for: NSRange(location: anchor, length: 0)).location
                let lo = min(w.location, lineStart)
                let hi = max(w.upperBound, hide.upperBound)
                if lo != w.location || hi != w.upperBound {
                    w = NSRange(location: lo, length: hi - lo)
                    changed = true
                }
            }
        }
        return NSIntersectionRange(w, NSRange(location: 0, length: storage.length))
    }

    /// Typing attributes drive the caret's geometry on empty lines (TextKit's
    /// "extra line fragment") — without the real paragraph style the caret sat
    /// compact and unindented after Enter, then jumped down/right once the
    /// first character brought the styled metrics in. Inherit font/paragraph
    /// from the character before the caret; strip decorations and our custom
    /// keys so hidden syntax and underlines don't leak into fresh typing.
    public func refreshTypingAttributes() {
        guard let tv = textView, let storage = tv.textStorage else { return }
        var font = theme.bodyFont
        var paragraph: NSParagraphStyle = {
            let p = NSMutableParagraphStyle()
            p.lineHeightMultiple = theme.lineHeightMultiple
            p.paragraphSpacing = theme.baseSize * 0.5
            return p
        }()

        let caret = tv.selectedRange().location
        if storage.length > 0 {
            let probe = min(max(caret - 1, 0), storage.length - 1)
            let attrs = storage.attributes(at: probe, effectiveRange: nil)
            if let f = attrs[.font] as? NSFont, !f.isFixedPitch { font = f }
            if let p = attrs[.paragraphStyle] as? NSParagraphStyle { paragraph = p }
        }
        tv.typingAttributes = [
            .font: font,
            .foregroundColor: theme.textColor,
            .paragraphStyle: paragraph,
        ]
    }

    /// Replace the whole document (external reload). Programmatic storage edits
    /// don't fire the text-view delegate, so we restyle explicitly.
    public func replaceEntireSource(_ s: String) {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let sel = tv.selectedRange()
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: s)
        incremental.reset() // wholesale replacement — diffing history is useless
        presentationMarkerRanges = []
        provisionalMarkerRanges = nil
        expectedEditedSourceLength = nil
        expectedEditedAnchor = nil
        transientMarkerRanges = []
        transientParagraphRange = nil
        restyle()
        let caret = min(sel.location, (s as NSString).length)
        tv.setSelectedRange(NSRange(location: caret, length: 0))
    }

    private func updateMarkerPresentation(after update: IncrementalUpdate,
                                          storage: NSTextStorage) {
        defer {
            provisionalMarkerRanges = nil
            expectedEditedSourceLength = nil
            expectedEditedAnchor = nil
        }

        guard let candidates = provisionalMarkerRanges,
              expectedEditedSourceLength == storage.length else {
            transientMarkerRanges = []
            transientParagraphRange = nil
            presentationMarkerRanges = parsed.markerRanges
            markerIndex = MarkerIndex(ranges: presentationMarkerRanges,
                                      sourceLength: storage.length)
            return
        }

        let ns = storage.string as NSString
        let anchor = min(expectedEditedAnchor ?? update.dirtyRange?.location ?? 0, storage.length)
        let paragraph = ns.paragraphRange(for: NSRange(location: anchor, length: 0))
        let semantic = MarkerIndex(ranges: parsed.markerRanges, sourceLength: storage.length)
        transientMarkerRanges = candidates.filter { candidate in
            guard NSIntersectionRange(candidate, paragraph).length > 0 else { return false }
            return !semantic.ranges.contains { semanticRange in
                semanticRange.location <= candidate.location
                    && semanticRange.upperBound >= candidate.upperBound
            }
        }
        transientParagraphRange = transientMarkerRanges.isEmpty ? nil : paragraph
        presentationMarkerRanges = MarkerIndex(
            ranges: parsed.markerRanges + transientMarkerRanges,
            sourceLength: storage.length
        ).ranges
        markerIndex = MarkerIndex(ranges: presentationMarkerRanges,
                                  sourceLength: storage.length)
    }

    private func clearTransientMarkerPresentation(dirty: NSRange) {
        transientMarkerRanges = []
        transientParagraphRange = nil
        presentationMarkerRanges = parsed.markerRanges
        if let storage = textView?.textStorage {
            markerIndex = MarkerIndex(ranges: presentationMarkerRanges,
                                      sourceLength: storage.length)
        }
        applyStyles(dirty: dirty)
    }

    private func transformMarkerRanges(_ ranges: [NSRange], through edit: NSRange,
                                       replacementLength: Int) -> [NSRange] {
        let delta = replacementLength - edit.length
        var result: [NSRange] = []
        result.reserveCapacity(ranges.count + 2)
        for marker in ranges {
            if marker.upperBound <= edit.location {
                result.append(marker)
            } else if marker.location >= edit.upperBound {
                result.append(NSRange(location: marker.location + delta, length: marker.length))
            } else {
                let leftEnd = min(marker.upperBound, edit.location)
                if leftEnd > marker.location {
                    result.append(NSRange(location: marker.location,
                                          length: leftEnd - marker.location))
                }
                let rightStart = max(marker.location, edit.upperBound)
                if marker.upperBound > rightStart {
                    let shiftedStart = rightStart + delta
                    result.append(NSRange(location: shiftedStart,
                                          length: marker.upperBound - rightStart))
                }
            }
        }
        let newLength = max(0, (textView?.textStorage?.length ?? 0) + delta)
        return MarkerIndex(ranges: result, sourceLength: newLength).ranges
    }

    // MARK: Navigation

    /// Web-style smooth scroll to a character position (TOC clicks, anchors).
    /// Expands any folds hiding the target first — scrolling to a ~zero-height
    /// hidden line would land nowhere visible.
    public func scroll(to location: Int) {
        guard let tv = textView, let storage = tv.textStorage,
              location <= storage.length else { return }
        expandFolds(containing: location)
        tv.setSelectedRange(NSRange(location: location, length: 0))

        guard let scroll = tv.enclosingScrollView,
              let lm = tv.layoutManager, let container = tv.textContainer else {
            tv.scrollRangeToVisible(NSRange(location: location, length: 0))
            return
        }
        // Force layout up to the target so its rect is meaningful.
        let charRange = NSRange(location: min(location, max(0, storage.length - 1)), length: 1)
        let glyphRange = lm.glyphRange(forCharacterRange: charRange, actualCharacterRange: nil)
        lm.ensureLayout(forGlyphRange: glyphRange)
        let rect = lm.boundingRect(forGlyphRange: glyphRange, in: container)

        var targetY = rect.minY + tv.textContainerInset.height - 28 // breathing room above
        let maxY = max(0, tv.frame.height - scroll.contentSize.height)
        targetY = max(0, min(targetY, maxY))

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.35
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            ctx.allowsImplicitAnimation = true
            scroll.contentView.animator().setBoundsOrigin(
                NSPoint(x: scroll.contentView.bounds.origin.x, y: targetY))
        }, completionHandler: { [weak scroll] in
            MainActor.assumeIsolated {
                if let scroll { scroll.reflectScrolledClipView(scroll.contentView) }
            }
        })
    }

    /// Expand every collapsed item/heading whose fold hides `location`
    /// (all levels of nesting at once).
    private func expandFolds(containing location: Int) {
        guard !collapsedAnchors.isEmpty else { return }
        let hiding = collapsedAnchors.filter { anchor in
            guard let sub = subtree(forAnchor: anchor) else { return false }
            return NSLocationInRange(location, sub)
        }
        guard !hiding.isEmpty else { return }
        collapsedAnchors.subtract(hiding)
        applyStyles(dirty: nil)
    }

    public func performFind() {
        guard let tv = textView else { return }
        tv.window?.makeFirstResponder(tv)
        // performTextFinderAction reads the sender's tag to pick the action.
        let item = NSMenuItem()
        item.tag = Int(NSTextFinder.Action.showFindInterface.rawValue)
        tv.performTextFinderAction(item)
    }

    // MARK: Formatting (v1: wrap/insert; source stays canonical)
    // All caret math uses NSString/UTF-16 lengths to match NSRange semantics
    // (String.count is Characters and misplaces the caret around emoji).

    public func toggleBold() { wrapSelection("**", "**") }
    public func toggleItalic() { wrapSelection("*", "*") }
    public func toggleStrikethrough() { wrapSelection("~~", "~~") }
    public func toggleInlineCode() { wrapSelection("`", "`") }
    public func toggleQuote() { prefixLine("> ") }
    public func toggleBulletList() { prefixLine("- ") }

    /// Set the line's heading level; applying the current level toggles back
    /// to body text, and a different level replaces the existing one.
    public func makeHeading(_ level: Int) {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let sel = tv.selectedRange()
        let ns = storage.string as NSString
        let line = ns.lineRange(for: NSRange(location: sel.location, length: 0))
        let lineText = ns.substring(with: line) as NSString
        let target = String(repeating: "#", count: level) + " "

        var existingLen = 0
        while existingLen < min(6, lineText.length), lineText.character(at: existingLen) == 0x23 {
            existingLen += 1
        }
        if existingLen > 0, existingLen < lineText.length, lineText.character(at: existingLen) == 0x20 {
            existingLen += 1
        } else {
            existingLen = 0
        }

        let existing = lineText.substring(to: existingLen)
        let replacement = existing == target ? "" : target
        let r = NSRange(location: line.location, length: existingLen)
        if tv.shouldChangeText(in: r, replacementString: replacement) {
            storage.replaceCharacters(in: r, with: replacement)
            tv.didChangeText()
            let delta = (replacement as NSString).length - existingLen
            tv.setSelectedRange(NSRange(location: max(line.location, sel.location + delta),
                                        length: sel.length))
        }
    }

    private struct LinkEditSession {
        var replacementRange: NSRange
        var labelSource: String?
        var initialLabel: String
        var originalSelection: NSRange
        var canRemove: Bool
    }

    public func insertLink() {
        guard let tv = textView, let storage = tv.textStorage, tv.window != nil else { return }
        let selection = tv.selectedRange()
        let existing = link(at: selection)
        let session: LinkEditSession
        let anchorRange: NSRange
        let destination: String

        if let existing {
            session = LinkEditSession(
                replacementRange: existing.range,
                labelSource: (storage.string as NSString).substring(with: existing.labelRange),
                initialLabel: existing.label,
                originalSelection: selection,
                canRemove: true)
            anchorRange = existing.labelRange
            destination = existing.destination
        } else {
            let selectedSource = selection.length > 0
                ? (storage.string as NSString).substring(with: selection) : nil
            let label = selection.length > 0 ? visibleText(in: selection, source: storage.string) : "link"
            session = LinkEditSession(replacementRange: selection,
                                      labelSource: selectedSource.flatMap {
                                          linkLabelSourceIsSafe($0) ? $0 : nil
                                      },
                                      initialLabel: label,
                                      originalSelection: selection,
                                      canRemove: false)
            anchorRange = selection
            destination = ""
        }

        toolbar.hide()
        let rect = popoverAnchor(for: anchorRange, in: tv)
        linkPopover.show(label: session.initialLabel, destination: destination,
                         canRemove: session.canRemove, relativeTo: rect, of: tv) { [weak self, weak tv] action in
            guard let self, let tv else { return }
            var restoreFocus = true
            switch action {
            case .save(let label, let destination):
                _ = self.replaceLink(in: session.replacementRange, label: label,
                                     destination: destination,
                                     preservedLabelSource: session.labelSource,
                                     preservedLabel: session.initialLabel)
            case .remove:
                if let labelSource = session.labelSource {
                    self.removeLink(in: session.replacementRange, keeping: labelSource)
                }
            case .cancel:
                let length = tv.textStorage?.length ?? 0
                let location = min(session.originalSelection.location, length)
                let selected = NSRange(location: location,
                                       length: min(session.originalSelection.length, length - location))
                tv.setSelectedRange(selected)
            case .dismiss:
                // A click outside the transient popover owns the next focus and
                // selection; do not steal either back from the clicked control.
                restoreFocus = false
            }
            if restoreFocus {
                DispatchQueue.main.async { tv.window?.makeFirstResponder(tv) }
            }
        }
    }

    @discardableResult
    func replaceLink(in range: NSRange, label: String, destination rawDestination: String,
                     preservedLabelSource: String? = nil, preservedLabel: String? = nil) -> Bool {
        guard let tv = textView, let storage = tv.textStorage,
              range.upperBound <= storage.length,
              let destination = try? LinkDestination.normalize(rawDestination) else { return false }
        let labelSource: String
        if label == preservedLabel, let preservedLabelSource {
            labelSource = preservedLabelSource
        } else {
            labelSource = label.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "]", with: "\\]")
        }
        let escapedDestination = destination.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "(", with: "\\(")
            .replacingOccurrences(of: ")", with: "\\)")
        let replacement = "[\(labelSource)](\(escapedDestination))"
        guard tv.shouldChangeText(in: range, replacementString: replacement) else { return false }
        storage.replaceCharacters(in: range, with: replacement)
        tv.didChangeText()
        tv.setSelectedRange(NSRange(location: range.location + 1,
                                    length: (labelSource as NSString).length))
        return true
    }

    func removeLink(in range: NSRange, keeping labelSource: String) {
        guard let tv = textView, let storage = tv.textStorage,
              range.upperBound <= storage.length,
              tv.shouldChangeText(in: range, replacementString: labelSource) else { return }
        storage.replaceCharacters(in: range, with: labelSource)
        tv.didChangeText()
        tv.setSelectedRange(NSRange(location: range.location,
                                    length: (labelSource as NSString).length))
    }

    private func link(at selection: NSRange) -> LinkRun? {
        if selection.length > 0 {
            return parsed.links.first { NSIntersectionRange($0.labelRange, selection).length > 0
                || NSIntersectionRange($0.range, selection).length == selection.length }
        }
        let location = selection.location
        return parsed.links.first {
            location >= $0.labelRange.location && location <= $0.labelRange.upperBound
        } ?? parsed.links.first { NSLocationInRange(location, $0.range) }
    }

    private func visibleText(in range: NSRange, source: String) -> String {
        let visible = NSMutableString(string: (source as NSString).substring(with: range))
        let intersections = parsed.markerRanges.map { NSIntersectionRange($0, range) }
            .filter { $0.length > 0 }
            .sorted { $0.location > $1.location }
        for intersection in intersections {
            visible.deleteCharacters(in: NSRange(location: intersection.location - range.location,
                                                  length: intersection.length))
        }
        return visible as String
    }

    /// An unescaped closing bracket would terminate the new link label. Keep
    /// valid nested emphasis/code source intact, but flatten unsafe selections
    /// through the escaped plain-label path.
    private func linkLabelSourceIsSafe(_ source: String) -> Bool {
        var precedingBackslashes = 0
        for character in source {
            if character == "\\" {
                precedingBackslashes += 1
                continue
            }
            if character == "]", precedingBackslashes.isMultiple(of: 2) { return false }
            precedingBackslashes = 0
        }
        return true
    }

    private func popoverAnchor(for range: NSRange, in textView: NSTextView) -> NSRect {
        let screenRect = textView.firstRect(forCharacterRange: range, actualRange: nil)
        guard let window = textView.window else { return textView.visibleRect }
        let windowRect = window.convertFromScreen(screenRect)
        let viewRect = textView.convert(windowRect, from: nil)
        return viewRect.isEmpty ? NSRect(x: viewRect.minX, y: viewRect.minY, width: 1, height: 20)
                                : viewRect
    }

    // MARK: Insert menu (tables, code blocks, images, …)

    public func insertTable(columns: Int = 2, rows: Int = 2) {
        let header = "| " + (1...columns).map { "Column \($0)" }.joined(separator: " | ") + " |"
        let separator = "|" + Array(repeating: " --- |", count: columns).joined()
        let body = Array(repeating: "|" + Array(repeating: "     |", count: columns).joined(),
                         count: rows).joined(separator: "\n")
        insertBlockSnippet("\(header)\n\(separator)\n\(body)")
    }

    public func insertCodeBlock() {
        // caret lands on the empty line inside the fences
        insertBlockSnippet("```\n\n```", caretOffsetInSnippet: 4)
    }

    public func insertHorizontalRule() {
        insertBlockSnippet("---")
    }

    public func insertTaskItem() {
        insertBlockSnippet("- [ ] ")
    }

    /// Pick an image file and insert it, preferring a path relative to the
    /// document's folder so the file stays portable.
    public func insertImageFromPanel() {
        guard let tv = textView, let window = tv.window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                let path = self.relativePath(for: url)
                self.insertBlockSnippet("![\(url.deletingPathExtension().lastPathComponent)](\(path))")
            }
        }
    }

    /// Edit the rendered image without exposing its hidden Markdown expression.
    /// The same surface is available by double-click and from the context menu.
    public func editImage(atAnchor anchor: Int) {
        guard let tv = textView, let window = tv.window,
              let image = parsed.images.first(where: { $0.anchor == anchor }) else { return }

        let altField = NSTextField(string: image.alt)
        altField.placeholderString = "Describe the image"
        altField.setAccessibilityLabel("Alt text")
        let sourceField = NSTextField(string: image.source)
        sourceField.placeholderString = "Path or URL"
        sourceField.setAccessibilityLabel("Image source")

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Alt text"), altField],
            [NSTextField(labelWithString: "Source"), sourceField],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).width = 320
        grid.rowSpacing = 8
        grid.columnSpacing = 10

        let alert = NSAlert()
        alert.messageText = "Edit Image"
        alert.informativeText = "Update the description or image path."
        alert.accessoryView = grid
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Remove Image")
        alert.buttons.last?.hasDestructiveAction = true
        alert.window.initialFirstResponder = altField

        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard let self else { return }
                if response == .alertFirstButtonReturn {
                    let source = sourceField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !source.isEmpty else {
                        NSSound.beep()
                        return
                    }
                    self.replaceImage(atAnchor: anchor, alt: altField.stringValue, source: source)
                } else if response == .alertThirdButtonReturn {
                    self.removeImage(atAnchor: anchor)
                }
            }
        }
    }

    public func removeImage(atAnchor anchor: Int) {
        replaceImageSource(atAnchor: anchor, replacement: "")
    }

    func replaceImage(atAnchor anchor: Int, alt: String, source: String) {
        let escapedAlt = alt.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "]", with: "\\]")
        let escapedSource = source.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "(", with: "\\(")
            .replacingOccurrences(of: ")", with: "\\)")
        replaceImageSource(atAnchor: anchor,
                           replacement: "![\(escapedAlt)](\(escapedSource))")
    }

    private func replaceImageSource(atAnchor anchor: Int, replacement: String) {
        guard let tv = textView, let storage = tv.textStorage,
              let image = parsed.images.first(where: { $0.anchor == anchor }) else { return }
        guard tv.shouldChangeText(in: image.range, replacementString: replacement) else { return }
        storage.replaceCharacters(in: image.range, with: replacement)
        tv.didChangeText()
        let caret = min(image.range.location + (replacement as NSString).length, storage.length)
        tv.setSelectedRange(NSRange(location: caret, length: 0))
    }

    private func relativePath(for url: URL) -> String {
        guard let base = baseURL?.standardizedFileURL else { return url.path }
        let target = url.standardizedFileURL
        if target.path.hasPrefix(base.path + "/") {
            return String(target.path.dropFirst(base.path.count + 1))
        }
        return target.path
    }

    /// Insert a block-level snippet after the caret's line, separated by blank
    /// lines so it parses as its own block, and place the caret usefully.
    public func insertBlockSnippet(_ snippet: String, caretOffsetInSnippet: Int? = nil) {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let ns = storage.string as NSString
        let sel = tv.selectedRange()
        let line = ns.lineRange(for: NSRange(location: sel.location, length: 0))
        let lineText = ns.substring(with: line)
        let lineIsBlank = lineText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        var insertLoc: Int
        var text: String
        if lineIsBlank {
            insertLoc = line.location
            text = snippet + "\n"
        } else {
            insertLoc = line.upperBound
            if !lineText.hasSuffix("\n") { text = "\n\n" + snippet + "\n" }
            else { text = "\n" + snippet + "\n" }
        }

        let r = NSRange(location: insertLoc, length: 0)
        if tv.shouldChangeText(in: r, replacementString: text) {
            storage.replaceCharacters(in: r, with: text)
            tv.didChangeText()
            let prefixLen = (text as NSString).length - (snippet as NSString).length
                - (text.hasSuffix("\n") ? 1 : 0)
            let caret: Int
            if let offset = caretOffsetInSnippet {
                caret = insertLoc + prefixLen + offset
            } else {
                caret = insertLoc + (text as NSString).length
            }
            tv.setSelectedRange(NSRange(location: min(caret, storage.length), length: 0))
            tv.scrollRangeToVisible(tv.selectedRange())
        }
    }

    /// Wrap the selection in markers — or, if it's already wrapped (markers
    /// adjacent to the selection or included in it), remove them (toggle off).
    private func wrapSelection(_ prefix: String, _ suffix: String) {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let sel = tv.selectedRange()
        let ns = storage.string as NSString
        let pLen = (prefix as NSString).length
        let sLen = (suffix as NSString).length

        // Toggle off: markers immediately surround the selection.
        if sel.location >= pLen, sel.upperBound + sLen <= ns.length,
           ns.substring(with: NSRange(location: sel.location - pLen, length: pLen)) == prefix,
           ns.substring(with: NSRange(location: sel.upperBound, length: sLen)) == suffix {
            let outer = NSRange(location: sel.location - pLen, length: sel.length + pLen + sLen)
            let inner = ns.substring(with: sel)
            if tv.shouldChangeText(in: outer, replacementString: inner) {
                storage.replaceCharacters(in: outer, with: inner)
                tv.didChangeText()
                tv.setSelectedRange(NSRange(location: outer.location,
                                            length: (inner as NSString).length))
            }
            return
        }

        // Toggle off: the selection itself includes the markers.
        let selected = ns.substring(with: sel)
        if sel.length >= pLen + sLen, selected.hasPrefix(prefix), selected.hasSuffix(suffix) {
            let inner = String(selected.dropFirst(prefix.count).dropLast(suffix.count))
            if tv.shouldChangeText(in: sel, replacementString: inner) {
                storage.replaceCharacters(in: sel, with: inner)
                tv.didChangeText()
                tv.setSelectedRange(NSRange(location: sel.location,
                                            length: (inner as NSString).length))
            }
            return
        }

        // Wrap.
        let replacement = prefix + selected + suffix
        if tv.shouldChangeText(in: sel, replacementString: replacement) {
            storage.replaceCharacters(in: sel, with: replacement)
            tv.didChangeText()
            tv.setSelectedRange(NSRange(location: sel.location + pLen,
                                        length: (selected as NSString).length))
        }
    }

    /// Prefix the current line — or remove the prefix if it's already there.
    private func prefixLine(_ prefix: String) {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let sel = tv.selectedRange()
        let ns = storage.string as NSString
        let line = ns.lineRange(for: NSRange(location: sel.location, length: 0))
        let pLen = (prefix as NSString).length

        // Toggle off.
        if line.length >= pLen,
           ns.substring(with: NSRange(location: line.location, length: pLen)) == prefix {
            let r = NSRange(location: line.location, length: pLen)
            if tv.shouldChangeText(in: r, replacementString: "") {
                storage.replaceCharacters(in: r, with: "")
                tv.didChangeText()
                tv.setSelectedRange(NSRange(location: max(line.location, sel.location - pLen),
                                            length: sel.length))
            }
            return
        }

        let insertRange = NSRange(location: line.location, length: 0)
        if tv.shouldChangeText(in: insertRange, replacementString: prefix) {
            storage.replaceCharacters(in: insertRange, with: prefix)
            tv.didChangeText()
            tv.setSelectedRange(NSRange(location: sel.location + pLen, length: sel.length))
        }
    }
}
