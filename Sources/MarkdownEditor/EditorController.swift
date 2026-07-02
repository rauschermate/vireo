import AppKit
import SwiftUI
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

    private let parser = MarkdownParser()
    private var restyleWork: DispatchWorkItem?
    public private(set) var parsed = ParsedMarkdown()
    private lazy var toolbar = FloatingToolbar(controller: self)
    /// Table whose source is revealed because the caret is inside it.
    private var revealedTableIndex: Int?

    public init() {
        imageLoader.onChange = { [weak self] in self?.restyle() }
    }

    /// Show/hide the floating format toolbar and reveal/re-hide table source
    /// as the selection moves.
    public func selectionChanged() {
        guard let tv = textView else { return }
        let sel = tv.selectedRange()

        // Reveal the raw source of the table the caret sits in (if any).
        let idx = parsed.tables.firstIndex { NSLocationInRange(sel.location, $0.range) }
        if idx != revealedTableIndex {
            revealedTableIndex = idx
            restyle()
        }

        guard sel.length > 0 else { toolbar.hide(); return }
        let rect = tv.firstRect(forCharacterRange: sel, actualRange: nil)
        toolbar.update(selectionRect: rect, hasSelection: true)
    }

    var theme: Theme { Theme(zoom: zoom) }

    // MARK: Styling

    /// Debounced re-parse + re-style after edits.
    public func scheduleRestyle() {
        if let tv = textView, let storage = tv.textStorage {
            onSourceChange?(storage.string)
        }
        restyleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.restyle() }
        restyleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    /// Re-parse the source and re-apply all attributes in place. Characters are
    /// never touched, so the selection and the on-disk source are preserved.
    public func restyle() {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let source = storage.string
        let parsed = parser.parse(source)
        self.parsed = parsed
        onParsed?(parsed)

        var renderer = MarkdownRenderer(theme: theme, baseURL: baseURL,
                                        imageLoader: imageLoader, isDark: tv.isDark)
        renderer.revealTableIndex = revealedTableIndex
        let rendered = renderer.render(source: source, parsed: parsed)
        let full = NSRange(location: 0, length: storage.length)

        storage.beginEditing()
        storage.setAttributes(nil, range: full)
        rendered.enumerateAttributes(in: NSRange(location: 0, length: rendered.length)) { attrs, range, _ in
            storage.setAttributes(attrs, range: range)
        }
        storage.endEditing()

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
