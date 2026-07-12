import AppKit
import XCTest
import MarkdownEngine
@testable import MarkdownRender

@MainActor
final class SourceTreatmentRenderTests: XCTestCase {
    private func render(_ source: String) -> NSAttributedString {
        MarkdownRenderer(theme: Theme()).render(
            source: source,
            parsed: MarkdownParser().parse(source)
        )
    }

    func testRenderNeverMutatesSource() {
        let source = "---\ntitle: Test\n---\n\nPress <kbd>⌘K</kbd>.\n\n[ref]: /target\n"
        XCTAssertEqual(render(source).string, source)
    }

    func testSemanticHTMLProducesNativeTextAttributes() {
        let source = "<kbd>key</kbd> <u>under</u> <mark>bright</mark>"
        let attributed = render(source)
        let ns = source as NSString

        let key = ns.range(of: "key").location
        XCTAssertEqual((attributed.attribute(.font, at: key, effectiveRange: nil) as? NSFont)?.isFixedPitch,
                       true)
        let under = ns.range(of: "under").location
        XCTAssertNotNil(attributed.attribute(.underlineStyle, at: under, effectiveRange: nil))
        let bright = ns.range(of: "bright").location
        XCTAssertNotNil(attributed.attribute(.backgroundColor, at: bright, effectiveRange: nil))
    }

    func testMetadataCarriesOnePlaceholderAnchorAndCompactLineStyles() {
        let source = "---\ntitle: Test\nauthor: Vireo\n---\n\nBody\n"
        let attributed = render(source)

        XCTAssertEqual(attributed.attribute(.vireoSourceBlock, at: 0, effectiveRange: nil) as? String,
                       "Front matter · 2 fields")
        XCTAssertNotNil(attributed.attribute(.vireoMetadata, at: 5, effectiveRange: nil))
        XCTAssertNotNil(attributed.attribute(.vireoMarker, at: 5, effectiveRange: nil))
        let firstStyle = attributed.attribute(.paragraphStyle, at: 0, effectiveRange: nil)
            as? NSParagraphStyle
        XCTAssertEqual(firstStyle?.minimumLineHeight, 30)
        let hiddenStyle = attributed.attribute(.paragraphStyle, at: 8, effectiveRange: nil)
            as? NSParagraphStyle
        XCTAssertEqual(hiddenStyle?.maximumLineHeight ?? 1, 0.01, accuracy: 0.001)
    }

    func testManyMetadataLinesDoNotConsumeDocumentHeight() {
        let fields = (0..<80).map { "field\($0): value" }.joined(separator: "\n")
        let source = "---\n\(fields)\n---\n\nBody\n"
        let attributed = render(source)
        let storage = NSTextStorage(attributedString: attributed)
        let layout = MarkdownLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 600, height: 10_000))
        layout.addTextContainer(container)
        layout.ensureLayout(for: container)

        XCTAssertLessThan(layout.usedRect(for: container).height, 120,
                          "collapsed metadata should occupy one compact row")
    }

    func testUnsupportedInlineHTMLKeepsAReplacementAnchor() {
        let source = "before <span>inside</span> after<br>end"
        let attributed = render(source)
        let ns = source as NSString
        let span = ns.range(of: "<span>").location
        let br = ns.range(of: "<br>").location

        XCTAssertEqual(attributed.attribute(.vireoInlineHTML, at: span, effectiveRange: nil) as? String,
                       "html:span")
        XCTAssertEqual(attributed.attribute(.vireoInlineHTML, at: br, effectiveRange: nil) as? String,
                       "line-break")
        XCTAssertNotNil(attributed.attribute(.vireoMarker, at: span, effectiveRange: nil))
    }
}
