import AppKit
import XCTest
@testable import MarkdownRender

@MainActor
final class TextViewportAnchorTests: XCTestCase {
    func testRestoreKeepsVisibleTextFixedWhenEarlierParagraphGrows() throws {
        let source = (0..<120).map { "Line \($0) has readable content." }
            .joined(separator: "\n")
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = 1.3
        let storage = NSTextStorage(
            string: source,
            attributes: [.font: NSFont.systemFont(ofSize: 16),
                         .paragraphStyle: paragraph]
        )
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(
            size: NSSize(width: 360, height: CGFloat.greatestFiniteMagnitude)
        )
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 360, height: 0),
                                  textContainer: container)
        textView.isVerticallyResizable = true
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.textContainerInset = NSSize(width: 12, height: 12)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 360, height: 180))
        scroll.hasVerticalScroller = true
        scroll.documentView = textView
        sizeDocument(textView, layout: layout, container: container)

        scroll.contentView.setBoundsOrigin(NSPoint(x: 0, y: 700))
        scroll.reflectScrolledClipView(scroll.contentView)
        let before = try visiblePosition(in: textView)
        let anchor = try XCTUnwrap(TextViewportAnchor.capture(in: textView))

        let tall = paragraph.mutableCopy() as! NSMutableParagraphStyle
        tall.minimumLineHeight = 280
        tall.maximumLineHeight = 280
        let firstParagraph = (source as NSString).paragraphRange(
            for: NSRange(location: 0, length: 0)
        )
        storage.addAttribute(.paragraphStyle, value: tall, range: firstParagraph)
        sizeDocument(textView, layout: layout, container: container)
        anchor.restore(in: textView)

        let after = try visiblePosition(in: textView)
        XCTAssertEqual(after.character, before.character)
        XCTAssertEqual(after.lineOffset, before.lineOffset, accuracy: 0.5)
    }

    private func sizeDocument(_ textView: NSTextView, layout: NSLayoutManager,
                              container: NSTextContainer) {
        layout.ensureLayout(for: container)
        textView.frame.size.height = ceil(layout.usedRect(for: container).height)
            + textView.textContainerInset.height * 2
    }

    private func visiblePosition(in textView: NSTextView) throws
        -> (character: Int, lineOffset: CGFloat) {
        let scroll = try XCTUnwrap(textView.enclosingScrollView)
        let layout = try XCTUnwrap(textView.layoutManager)
        let container = try XCTUnwrap(textView.textContainer)
        let top = scroll.contentView.bounds.minY
        let origin = textView.textContainerOrigin
        let glyph = min(layout.glyphIndex(
            for: NSPoint(x: container.lineFragmentPadding + 1,
                         y: max(0, top - origin.y + 1)),
            in: container
        ), layout.numberOfGlyphs - 1)
        let line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        return (layout.characterIndexForGlyph(at: glyph),
                origin.y + line.minY - top)
    }
}
