import AppKit
import XCTest
import MarkdownEngine
@testable import MarkdownRender

/// cmark extends a list item's range through the blank lines after it. The
/// blanks after the *last* item must not keep the list paragraph style —
/// otherwise the caret parks at the list indent right after Enter exits the
/// list. Blanks between loose-list siblings keep the compact list style.
@MainActor
final class ListTrailingBlankTests: XCTestCase {
    private func indent(_ rendered: NSAttributedString, at location: Int) -> CGFloat {
        let style = rendered.attribute(.paragraphStyle, at: location,
                                       effectiveRange: nil) as? NSParagraphStyle
        return style?.firstLineHeadIndent ?? -1
    }

    func testBlankLinesAfterTheLastItemDropTheListIndent() throws {
        let source = "- [ ] a\n    - [ ] b\n\ntail\n"
        let parsed = MarkdownParser().parse(source)
        let rendered = MarkdownRenderer(theme: Theme()).render(source: source,
                                                               parsed: parsed)
        let ns = source as NSString
        let blank = ns.range(of: "b\n\n").upperBound - 1
        let tail = ns.range(of: "tail").location
        XCTAssertEqual(indent(rendered, at: blank), indent(rendered, at: tail),
                       "the blank after the list belongs to the text below")
        XCTAssertGreaterThan(indent(rendered, at: ns.range(of: "- [ ] b").location),
                             indent(rendered, at: tail))
    }

    func testTrimNeverReachesTheItemsOwnContent() throws {
        let source = "- alpha\n\n- beta\n\ntail\n"
        let parsed = MarkdownParser().parse(source)
        let rendered = MarkdownRenderer(theme: Theme()).render(source: source,
                                                               parsed: parsed)
        let ns = source as NSString
        let tail = indent(rendered, at: ns.range(of: "tail").location)
        for item in ["alpha", "beta"] {
            XCTAssertGreaterThan(indent(rendered, at: ns.range(of: item).location),
                                 tail, "\(item) keeps its list indent")
        }
    }
}
