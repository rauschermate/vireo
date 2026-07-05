import XCTest
@testable import MarkdownEngine

/// A marker-only line just created by Tab/Enter isn't a list item to cmark
/// (an empty item can't interrupt a paragraph) — the parser synthesizes the
/// item it is about to become so the drawn marker appears immediately.
final class DanglingItemTests: XCTestCase {
    private func markers(_ src: String) -> [(depth: Int, text: String)] {
        MarkdownParser().parse(src).listMarkers.map { ($0.depth, $0.text) }
    }

    func testTabIndentedEmptyOrderedItemGetsDepthStyledMarker() {
        let m = markers("1. asd\n    1. asf\n    2. asd\n        1. \n")
        XCTAssertEqual(m.map(\.text), ["1.", "a.", "b.", "i."])
        XCTAssertEqual(m.last?.depth, 2)
    }

    func testTabIndentedEmptyBulletDoesNotBecomeSetextHeading() {
        let src = "- asd\n    - \n"
        let parsed = MarkdownParser().parse(src)
        XCTAssertEqual(parsed.listMarkers.map(\.text), ["•", "◦"])
        XCTAssertTrue(parsed.toc.isEmpty, "bare `- ` must not parse as a setext underline")
    }

    func testEmptyTaskItemAfterParagraphDrawsCheckbox() {
        let parsed = MarkdownParser().parse("- [ ] asd\n    - [ ] \n")
        XCTAssertEqual(parsed.tasks.count, 2)
        XCTAssertEqual(parsed.tasks.last?.checked, false)
    }

    func testRealSetextHeadingStillParses() {
        let parsed = MarkdownParser().parse("Title\n---\n")
        XCTAssertEqual(parsed.toc.count, 1)
        XCTAssertTrue(parsed.listMarkers.isEmpty)
    }

    func testMarkerLineWithContentIsNotSynthesized() {
        // `1. x` interrupts fine and parses for real — no double markers.
        let m = markers("1. asd\n    1. asf\n    2. asd\n        1. x\n")
        XCTAssertEqual(m.map(\.text), ["1.", "a.", "b.", "i."])
    }
}
