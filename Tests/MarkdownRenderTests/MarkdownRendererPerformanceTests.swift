import AppKit
import XCTest
import MarkdownEngine
@testable import MarkdownRender

@MainActor
final class MarkdownRendererPerformanceTests: XCTestCase {
    private let fixture = """
    # Heading

    A paragraph with **bold**, *italic*, `code`, ~~strike~~, a [link](https://example.com), and prose -> arrow.

    > A **quoted** line.

    - item one
    - [ ] task

    | A | B |
    |---|---|
    | 1 | 2 |

    ```swift
    let value = 42 // highlighted
    ```
    """

    func testDirectOffsetApplicationMatchesStandaloneRenderAndPreservesOutside() {
        let parsed = MarkdownParser().parse(fixture)
        let prefix = "prefix\n"
        let suffix = "\nsuffix"
        var renderer = MarkdownRenderer(theme: Theme())
        renderer.originOffset = (prefix as NSString).length
        let standalone = renderer.render(source: fixture, parsed: parsed)
        let target = NSMutableAttributedString(
            string: prefix + fixture + suffix,
            attributes: [.foregroundColor: NSColor.systemPink]
        )

        renderer.apply(source: fixture, parsed: parsed, to: target,
                       at: (prefix as NSString).length)

        let renderedRange = NSRange(location: (prefix as NSString).length,
                                    length: (fixture as NSString).length)
        let offsetResult = target.attributedSubstring(from: renderedRange)
        if !offsetResult.isEqual(to: standalone) {
            for index in 0..<standalone.length {
                let lhs = standalone.attributes(at: index, effectiveRange: nil)
                let rhs = offsetResult.attributes(at: index, effectiveRange: nil)
                if !NSDictionary(dictionary: lhs).isEqual(to: rhs) {
                    XCTFail("attributes differ at \(index): \(lhs) != \(rhs)")
                    break
                }
            }
        }
        XCTAssertTrue((target.attribute(.foregroundColor, at: 0,
                                        effectiveRange: nil) as? NSColor)?.isEqual(NSColor.systemPink) == true)
        XCTAssertTrue((target.attribute(.foregroundColor, at: target.length - 1,
                                        effectiveRange: nil) as? NSColor)?.isEqual(NSColor.systemPink) == true)
        XCTAssertEqual(target.string, prefix + fixture + suffix)
    }

    func testArrowLookupUsesSourceRangesInsteadOfAttributedRunQueries() {
        let source = """
        prose -> yes and [link](https://example.com/a->b)

        `code -> no`

        | Value |
        |---|
        | table -> no |

        ```swift
        let arrow = "->"
        ```
        """
        let attributed = MarkdownRenderer(theme: Theme()).render(
            source: source, parsed: MarkdownParser().parse(source)
        )
        let ns = source as NSString
        let prose = ns.range(of: "->").location
        let url = ns.range(of: "a->b").location + 1
        let inlineCode = ns.range(of: "code ->").location + ("code " as NSString).length
        let table = ns.range(of: "table ->").location + ("table " as NSString).length
        let fenced = ns.range(of: "\"->\"").location + 1

        XCTAssertNotNil(attributed.attribute(.vireoArrow, at: prose, effectiveRange: nil))
        XCTAssertNil(attributed.attribute(.vireoArrow, at: url, effectiveRange: nil))
        XCTAssertNil(attributed.attribute(.vireoArrow, at: inlineCode, effectiveRange: nil))
        XCTAssertNil(attributed.attribute(.vireoArrow, at: table, effectiveRange: nil))
        XCTAssertNil(attributed.attribute(.vireoArrow, at: fenced, effectiveRange: nil))
    }

    func testLargeCodeBlockDegradesToUnTokenizedCodeStyle() {
        let repeated = String(repeating: "let value = 42 // line\n",
                              count: MarkdownRenderer.syntaxHighlightingUTF16Limit / 20)
        let source = "```swift\n" + repeated + "```\n"
        XCTAssertGreaterThan((source as NSString).length,
                             MarkdownRenderer.syntaxHighlightingUTF16Limit)
        let theme = Theme()
        let attributed = MarkdownRenderer(theme: theme).render(
            source: source, parsed: MarkdownParser().parse(source)
        )
        let keyword = (source as NSString).range(of: "let").location
        let color = attributed.attribute(.foregroundColor, at: keyword,
                                         effectiveRange: nil) as? NSColor
        let font = attributed.attribute(.font, at: keyword, effectiveRange: nil) as? NSFont

        XCTAssertFalse(color?.isEqual(NSColor.systemBlue) == true)
        XCTAssertEqual(font?.isFixedPitch, true)
    }

    func testSmallCodeBlockStillReceivesTokenColors() {
        let source = "```swift\nlet value = 42\n```\n"
        let theme = Theme()
        let attributed = MarkdownRenderer(theme: theme).render(
            source: source, parsed: MarkdownParser().parse(source)
        )
        let keyword = (source as NSString).range(of: "let").location
        let color = attributed.attribute(.foregroundColor, at: keyword,
                                         effectiveRange: nil) as? NSColor

        XCTAssertTrue(color?.isEqual(NSColor.systemBlue) == true)
    }
}
