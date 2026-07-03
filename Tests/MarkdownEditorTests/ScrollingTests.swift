import XCTest
@testable import MarkdownEditor

/// Regression test for the "cannot scroll" bug: NSTextView.maxSize defaults to
/// the initial frame, silently capping growth — the document view must be able
/// to grow far beyond the viewport for scrolling to exist at all.
@MainActor
final class ScrollingTests: XCTestCase {
    func testTextViewGrowsBeyondViewport() {
        let source = Array(repeating: "A paragraph of body text.\n\n", count: 300).joined()
        let controller = EditorController()
        let (scroll, textView) = MarkdownSourceView.makeTextStack(source: source, controller: controller)
        scroll.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        textView.frame.size.width = 800

        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        textView.sizeToFit()

        XCTAssertGreaterThan(textView.frame.height, 5000,
                             "document view must grow past the viewport or scrolling is impossible")
        XCTAssertGreaterThanOrEqual(textView.maxSize.height, CGFloat.greatestFiniteMagnitude)
    }

    func testContentColumnCenteredWithMaxWidth() {
        let controller = EditorController()
        let (scroll, textView) = MarkdownSourceView.makeTextStack(source: "hello", controller: controller)

        // Wide window: column caps at contentMaxWidth (+padding), centered.
        scroll.frame = NSRect(x: 0, y: 0, width: 1400, height: 600)
        controller.recenterContent()
        let available = scroll.contentSize.width
        let column = controller.theme.contentMaxWidth + 48
        let expected = (available - column) / 2
        XCTAssertEqual(textView.textContainerInset.width, expected, accuracy: 1.0,
                       "column must be centered at max width in a wide window")

        // Narrow window: falls back to the minimum margin.
        scroll.frame = NSRect(x: 0, y: 0, width: 600, height: 600)
        controller.recenterContent()
        XCTAssertEqual(textView.textContainerInset.width, 24, accuracy: 1.0,
                       "narrow windows keep the minimum margin")
    }
}
