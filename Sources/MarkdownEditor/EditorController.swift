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

    public init() {
        imageLoader.onChange = { [weak self] in self?.restyle() }
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

        let renderer = MarkdownRenderer(theme: theme, baseURL: baseURL,
                                        imageLoader: imageLoader, isDark: tv.isDark)
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
        textView?.performFindPanelAction(nil)
    }

    // MARK: Formatting (v1: wrap/insert; source stays canonical)

    public func toggleBold() { wrapSelection("**", "**") }
    public func toggleItalic() { wrapSelection("*", "*") }
    public func toggleStrikethrough() { wrapSelection("~~", "~~") }
    public func toggleInlineCode() { wrapSelection("`", "`") }
    public func makeHeading(_ level: Int) { prefixLine(String(repeating: "#", count: level) + " ") }
    public func toggleQuote() { prefixLine("> ") }
    public func toggleBulletList() { prefixLine("- ") }

    public func insertLink() {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let sel = tv.selectedRange()
        let text = sel.length > 0 ? storage.attributedSubstring(from: sel).string : "link"
        let replacement = "[\(text)](https://)"
        if tv.shouldChangeText(in: sel, replacementString: replacement) {
            storage.replaceCharacters(in: sel, with: replacement)
            tv.didChangeText()
            // place caret inside the empty URL parens
            let caret = sel.location + replacement.count - 1
            tv.setSelectedRange(NSRange(location: caret, length: 0))
        }
    }

    private func wrapSelection(_ prefix: String, _ suffix: String) {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let sel = tv.selectedRange()
        let inner = storage.attributedSubstring(from: sel).string
        let replacement = prefix + inner + suffix
        if tv.shouldChangeText(in: sel, replacementString: replacement) {
            storage.replaceCharacters(in: sel, with: replacement)
            tv.didChangeText()
            let caret = sel.location + prefix.count
            tv.setSelectedRange(NSRange(location: caret, length: inner.isEmpty ? 0 : inner.count))
        }
    }

    private func prefixLine(_ prefix: String) {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let sel = tv.selectedRange()
        let ns = storage.string as NSString
        let lineStart = ns.lineRange(for: NSRange(location: sel.location, length: 0)).location
        let insertRange = NSRange(location: lineStart, length: 0)
        if tv.shouldChangeText(in: insertRange, replacementString: prefix) {
            storage.replaceCharacters(in: insertRange, with: prefix)
            tv.didChangeText()
            tv.setSelectedRange(NSRange(location: sel.location + prefix.count, length: sel.length))
        }
    }
}
