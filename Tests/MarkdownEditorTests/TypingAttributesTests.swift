import XCTest
import AppKit
@testable import MarkdownEditor

/// Regression tests for the caret jump on fresh lines: the caret's geometry on
/// an empty line comes from typingAttributes, so they must carry the *styled*
/// paragraph (line-height multiple, list indent) — not bare font+color.
@MainActor
final class TypingAttributesTests: XCTestCase {
    private func makeEditor(_ source: String) -> (EditorController, MarkdownTextView) {
        let controller = EditorController()
        let (scroll, textView) = MarkdownSourceView.makeTextStack(source: source, controller: controller)
        scroll.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        controller.restyle()
        return (controller, textView)
    }

    func testParagraphStyleCarriedAfterEnterAtDocumentEnd() {
        let (controller, tv) = makeEditor("A paragraph of text.")
        tv.setSelectedRange(NSRange(location: tv.textStorage!.length, length: 0))
        tv.insertNewline(nil)
        controller.refreshTypingAttributes()

        let style = tv.typingAttributes[.paragraphStyle] as? NSParagraphStyle
        XCTAssertNotNil(style, "typing attributes must include a paragraph style")
        XCTAssertGreaterThan(style!.lineHeightMultiple, 1.0,
                             "empty-line caret must use the styled line height, not the default")
    }

    func testListIndentCarriedOntoContinuationLine() {
        let (controller, tv) = makeEditor("- item one")
        tv.setSelectedRange(NSRange(location: tv.textStorage!.length, length: 0))
        tv.insertNewline(nil) // list continuation inserts "\n- " (hidden)
        controller.refreshTypingAttributes()

        let style = tv.typingAttributes[.paragraphStyle] as? NSParagraphStyle
        XCTAssertNotNil(style)
        XCTAssertGreaterThan(style!.firstLineHeadIndent, 0,
                             "caret on a fresh list item must sit at the list indent")
    }

    func testCodeFontDoesNotLeakIntoTyping() {
        let (controller, tv) = makeEditor("some `code`")
        tv.setSelectedRange(NSRange(location: tv.textStorage!.length, length: 0))
        controller.refreshTypingAttributes()
        let font = tv.typingAttributes[.font] as? NSFont
        XCTAssertEqual(font?.isFixedPitch, false,
                       "monospace must not leak into fresh typing after a code span")
    }
}
