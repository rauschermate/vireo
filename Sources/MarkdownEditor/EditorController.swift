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
    private lazy var toolbar = FloatingToolbar(controller: self)
    /// Table whose source is revealed because the caret is inside it
    /// (identified by absolute anchor — stable across incremental edits).
    private var revealedTableAnchor: Int?

    public init() {
        imageLoader.onChange = { [weak self] in self?.restyle() }
    }

    /// Show/hide the floating format toolbar and reveal/re-hide table source
    /// as the selection moves.
    public func selectionChanged() {
        guard let tv = textView else { return }
        let sel = tv.selectedRange()

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

        guard sel.length > 0 else { toolbar.hide(); return }
        let rect = tv.firstRect(forCharacterRange: sel, actualRange: nil)
        toolbar.update(selectionRect: rect, hasSelection: true,
                       active: ActiveFormats.at(sel, in: parsed))
    }

    /// Hide the floating toolbar (scrolling detaches it from the selection).
    public func hideFloatingToolbar() {
        toolbar.hide()
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

    /// Edit path: incremental parse; re-apply attributes only over the dirty
    /// region (the whole document when the parser had to fall back).
    private func restyleAfterEdit() {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let update = incremental.update(storage.string)
        parsed = update.parsed
        onParsed?(parsed)
        applyStyles(dirty: update.dirtyRange)
    }

    /// Full restyle: theme, zoom, appearance or image loads changed, so every
    /// attribute must be recomputed even though the text didn't change.
    public func restyle() {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let update = incremental.update(storage.string)
        parsed = update.parsed
        onParsed?(parsed)
        applyStyles(dirty: nil)
    }

    /// Re-render and re-apply attributes over `dirty` (nil = whole document).
    /// Characters are never touched, so the selection and the on-disk source
    /// are preserved; bounding the range bounds TextKit's layout invalidation.
    private func applyStyles(dirty: NSRange?) {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let full = NSRange(location: 0, length: storage.length)
        let window = dirty.map { NSIntersectionRange($0, full) } ?? full

        if window.length > 0 {
            var renderer = MarkdownRenderer(theme: theme, baseURL: baseURL,
                                            imageLoader: imageLoader, isDark: tv.isDark)
            renderer.revealTableAnchor = revealedTableAnchor
            renderer.originOffset = window.location
            let sliceSource = (storage.string as NSString).substring(with: window)
            let sliceParsed = window == full ? parsed : parsed.slice(window)
            let rendered = renderer.render(source: sliceSource, parsed: sliceParsed)

            storage.beginEditing()
            rendered.enumerateAttributes(in: NSRange(location: 0, length: rendered.length)) { attrs, range, _ in
                storage.setAttributes(attrs, range: NSRange(location: range.location + window.location,
                                                            length: range.length))
            }
            storage.endEditing()
        }

        layoutManager?.markerColor = theme.secondaryColor
        layoutManager?.bulletFont = theme.bodyFont
        layoutManager?.tables = parsed.tables
        layoutManager?.tableRowHeight = theme.tableRowHeight
        layoutManager?.tableFont = theme.tableFont
        layoutManager?.tableHeaderFont = theme.tableHeaderFont
        tv.typingAttributes = [.font: theme.bodyFont, .foregroundColor: theme.textColor]
        tv.needsDisplay = true
    }

    /// Replace the whole document (external reload). Programmatic storage edits
    /// don't fire the text-view delegate, so we restyle explicitly.
    public func replaceEntireSource(_ s: String) {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let sel = tv.selectedRange()
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: s)
        incremental.reset() // wholesale replacement — diffing history is useless
        restyle()
        let caret = min(sel.location, (s as NSString).length)
        tv.setSelectedRange(NSRange(location: caret, length: 0))
    }

    // MARK: Navigation

    public func scroll(to location: Int) {
        guard let tv = textView, location <= (tv.textStorage?.length ?? 0) else { return }
        tv.scrollRangeToVisible(NSRange(location: location, length: 0))
        tv.setSelectedRange(NSRange(location: location, length: 0))
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

    public func insertLink() {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let sel = tv.selectedRange()
        let text = sel.length > 0 ? storage.attributedSubstring(from: sel).string : "link"
        let replacement = "[\(text)](https://)"
        if tv.shouldChangeText(in: sel, replacementString: replacement) {
            storage.replaceCharacters(in: sel, with: replacement)
            tv.didChangeText()
            // place caret inside the empty URL parens
            let caret = sel.location + (replacement as NSString).length - 1
            tv.setSelectedRange(NSRange(location: caret, length: 0))
        }
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
