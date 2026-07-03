import XCTest
import MarkdownEngine
@testable import MarkdownEditor

final class ActiveFormatsTests: XCTestCase {
    private func parse(_ s: String) -> ParsedMarkdown { MarkdownParser().parse(s) }

    private func range(of needle: String, in s: String) -> NSRange {
        (s as NSString).range(of: needle)
    }

    func testBoldSelection() {
        let src = "some **bold** text"
        let f = ActiveFormats.at(range(of: "bold", in: src), in: parse(src))
        XCTAssertTrue(f.bold)
        XCTAssertFalse(f.italic)
    }

    func testCaretInsideBold() {
        let src = "some **bold** text"
        let mid = range(of: "bold", in: src).location + 2
        let f = ActiveFormats.at(NSRange(location: mid, length: 0), in: parse(src))
        XCTAssertTrue(f.bold)
    }

    func testPlainSelectionInactive() {
        let src = "some **bold** text"
        let f = ActiveFormats.at(range(of: "text", in: src), in: parse(src))
        XCTAssertEqual(f, ActiveFormats())
    }

    func testHeadingAndListAndQuote() {
        let src = "## Head\n\n- item\n\n> quoted\n"
        let parsed = parse(src)
        XCTAssertEqual(ActiveFormats.at(range(of: "Head", in: src), in: parsed).headingLevel, 2)
        XCTAssertTrue(ActiveFormats.at(range(of: "item", in: src), in: parsed).list)
        XCTAssertTrue(ActiveFormats.at(range(of: "quoted", in: src), in: parsed).quote)
    }

    func testLinkAndCode() {
        let src = "a [link](https://x.com) and `code`"
        let parsed = parse(src)
        XCTAssertTrue(ActiveFormats.at(range(of: "link", in: src), in: parsed).link)
        XCTAssertTrue(ActiveFormats.at(range(of: "code", in: src), in: parsed).code)
    }
}
