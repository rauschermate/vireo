import AppKit
import MarkdownEngine

/// Adapter used by the native macOS Find bar. NSTextView's built-in finder sees
/// its raw backing string; this client exposes the syntax-free visual string and
/// maps every result or replacement back to canonical Markdown source ranges.
@MainActor
final class VisibleTextFinderClient: NSObject, @preconcurrency NSTextFinderClient {
    weak var textView: MarkdownTextView?

    init(textView: MarkdownTextView) {
        self.textView = textView
    }

    private var index: MarkerIndex { textView?.controller?.markerIndex ?? .empty }
    private var source: NSString { (textView?.textStorage?.string ?? "") as NSString }

    var string: String { index.visibleString(in: source) }

    var firstSelectedRange: NSRange {
        guard let textView else { return NSRange(location: 0, length: 0) }
        return index.visibleRange(forSourceRange: textView.selectedRange())
    }

    var selectedRanges: [NSValue] {
        get {
            guard let textView else { return [NSValue(range: NSRange(location: 0, length: 0))] }
            return textView.selectedRanges.map { value in
                NSValue(range: index.visibleRange(forSourceRange: value.rangeValue))
            }
        }
        set {
            guard let textView, !newValue.isEmpty else { return }
            let mapped = newValue.map { NSValue(range: index.sourceRange(forVisibleRange: $0.rangeValue)) }
            textView.setSelectedRanges(mapped, affinity: .downstream, stillSelecting: false)
        }
    }

    func scrollRangeToVisible(_ range: NSRange) {
        textView?.scrollRangeToVisible(index.sourceRange(forVisibleRange: range))
    }

    func shouldReplaceCharacters(inRanges ranges: [NSValue], with strings: [String]) -> Bool {
        guard let textView, ranges.count == strings.count else { return false }
        return textView.isEditable
    }

    func replaceCharacters(in range: NSRange, with string: String) {
        guard let textView, let storage = textView.textStorage else { return }
        let sourceRange = index.sourceRange(forVisibleRange: range)
        // Use NSTextView's edit path so Replace participates in the document's
        // persistent undo manager and emits exactly one change notification.
        textView.insertText(string, replacementRange: sourceRange)
        let caret = sourceRange.location + (string as NSString).length
        textView.setSelectedRange(NSRange(location: min(caret, storage.length), length: 0))
    }

    func contentView(at index: Int, effectiveCharacterRange outRange: NSRangePointer) -> NSView {
        outRange.pointee = NSRange(location: 0, length: self.index.visibleLength)
        return textView ?? NSView()
    }

    func rects(forCharacterRange range: NSRange) -> [NSValue]? {
        guard let textView else { return nil }
        let sourceRange = index.sourceRange(forVisibleRange: range)
        let screenRect = textView.firstRect(forCharacterRange: sourceRange, actualRange: nil)
        guard !screenRect.isEmpty else { return nil }
        let windowRect = textView.window?.convertFromScreen(screenRect) ?? screenRect
        return [NSValue(rect: textView.convert(windowRect, from: nil))]
    }

    /// The system draws the yellow find indicator above the content view. It
    /// needs the matched glyphs redrawn into that overlay; falling back to the
    /// whole text view leaves an opaque rectangle that covers the word.
    func drawCharacters(in range: NSRange, forContentView view: NSView) {
        guard let textView, view === textView,
              let layoutManager = textView.layoutManager else { return }
        let sourceRange = index.sourceRange(forVisibleRange: range)
        let glyphRange = layoutManager.glyphRange(forCharacterRange: sourceRange,
                                                  actualCharacterRange: nil)
        guard glyphRange.length > 0 else { return }
        layoutManager.drawGlyphs(forGlyphRange: glyphRange,
                                 at: textView.textContainerOrigin)
    }

    var visibleCharacterRanges: [NSValue] {
        [NSValue(range: NSRange(location: 0, length: index.visibleLength))]
    }
}
