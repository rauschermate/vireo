import XCTest
import Markdown
@testable import MarkdownEngine

final class ParserTests: XCTestCase {
    /// Remove marker ranges from the source to simulate what the user sees.
    private func visible(_ src: String) -> String {
        let parsed = MarkdownParser().parse(src)
        let ns = NSMutableString(string: src)
        for r in parsed.markerRanges.sorted(by: { $0.location > $1.location }) {
            ns.deleteCharacters(in: r)
        }
        return ns as String
    }

    func testHidesInlineMarkers() {
        XCTAssertEqual(visible("café **bold** x"), "café bold x")
        XCTAssertEqual(visible("a *it* b"), "a it b")
        XCTAssertEqual(visible("use `code` now"), "use code now")
        XCTAssertEqual(visible("~~gone~~ here"), "gone here")
    }

    func testHidesHeadingAndList() {
        XCTAssertEqual(visible("## Head"), "Head")
        XCTAssertEqual(visible("- item"), "item")
        XCTAssertEqual(visible("1. first"), "first")
    }

    func testHidesLink() {
        XCTAssertEqual(visible("see [Apple](https://apple.com) site"), "see Apple site")
    }

    func testHidesFencedCode() {
        let src = "```swift\nlet x = 1\n```\n"
        XCTAssertEqual(visible(src), "let x = 1\n")
    }

    func testHidesBlockQuote() {
        XCTAssertEqual(visible("> quoted"), "quoted")
    }

    func testTOC() {
        let src = "# Title\n\nbody\n\n## Section\n\n### Sub\n"
        let parsed = MarkdownParser().parse(src)
        XCTAssertEqual(parsed.toc.map(\.title), ["Title", "Section", "Sub"])
        XCTAssertEqual(parsed.toc.map(\.level), [1, 2, 3])
    }

    func testTaskList() {
        let src = "- [ ] todo\n- [x] done\n"
        let parsed = MarkdownParser().parse(src)
        XCTAssertEqual(parsed.tasks.count, 2)
        XCTAssertEqual(parsed.tasks.map(\.checked), [false, true])
        // task items don't also emit bullets
        XCTAssertTrue(parsed.listMarkers.isEmpty)
    }

    func testInlineRunsCarryStyle() {
        let parsed = MarkdownParser().parse("**bold** and *italic*")
        XCTAssertTrue(parsed.inlineRuns.contains { $0.bold })
        XCTAssertTrue(parsed.inlineRuns.contains { $0.italic })
    }

    func testImage() {
        let source = "![alt](pic.png)"
        let parsed = MarkdownParser().parse(source)
        XCTAssertEqual(parsed.images.count, 1)
        XCTAssertEqual(parsed.images.first?.source, "pic.png")
        XCTAssertEqual(visible(source), "", "the full image expression is rendering metadata")
        XCTAssertTrue(parsed.markerRanges.contains(NSRange(location: 0,
                                                            length: (source as NSString).length)))
    }
}

extension ParserTests {
    func testTableParsing() {
        let src = "| A | B |\n|---|---|\n| 1 | 2 |\n| 3 | 4 |\n"
        let parsed = MarkdownParser().parse(src)
        XCTAssertEqual(parsed.tables.count, 1)
        let t = parsed.tables[0]
        XCTAssertEqual(t.columnCount, 2)
        XCTAssertEqual(t.rows.count, 3)               // header + 2 body (separator excluded)
        XCTAssertTrue(t.rows[0].isHeader)
        XCTAssertFalse(t.rows[1].isHeader)
        XCTAssertEqual(t.rows[0].cells.map { (src as NSString).substring(with: $0.range) }, ["A", "B"])
        XCTAssertEqual(t.rows[1].cells.map { (src as NSString).substring(with: $0.range) }, ["1", "2"])
    }
}

extension ParserTests {
    func testBulletGlyphCyclesByDepth() {
        let src = "- one\n    - two\n        - three\n            - four\n"
        let parsed = MarkdownParser().parse(src)
        XCTAssertEqual(parsed.listMarkers.map(\.text), ["•", "◦", "▪", "•"])
        XCTAssertEqual(parsed.listMarkers.map(\.depth), [0, 1, 2, 3])
    }

    func testOrderedMarkersCycleByDepth() {
        let src = "1. one\n    1. two\n        1. three\n            1. four\n2. five\n"
        let parsed = MarkdownParser().parse(src)
        XCTAssertEqual(parsed.listMarkers.map(\.text), ["1.", "a.", "i.", "1.", "2."])
    }

    func testOrderedHelperFormats() {
        XCTAssertEqual(MarkdownParser.alpha(1), "a")
        XCTAssertEqual(MarkdownParser.alpha(26), "z")
        XCTAssertEqual(MarkdownParser.alpha(27), "aa")
        XCTAssertEqual(MarkdownParser.roman(4), "iv")
        XCTAssertEqual(MarkdownParser.roman(9), "ix")
        XCTAssertEqual(MarkdownParser.roman(14), "xiv")
    }

    func testSubtreeRanges() {
        let src = "- parent\n    - child one\n    - child two\n- leaf\n"
        let parsed = MarkdownParser().parse(src)
        let parent = parsed.listMarkers[0]
        XCTAssertNotNil(parent.subtreeRange)
        let sub = (src as NSString).substring(with: parent.subtreeRange!)
        XCTAssertTrue(sub.contains("child one") && sub.contains("child two"))
        XCTAssertNil(parsed.listMarkers[1].subtreeRange) // child one
        XCTAssertNil(parsed.listMarkers[3].subtreeRange) // leaf
    }

    func testEmptyListItemMarkerHidden() {
        // `- ` followed by newline: marker hidden, bullet anchored on the \n
        let src = "- item\n- \n- next\n"
        let parsed = MarkdownParser().parse(src)
        XCTAssertEqual(parsed.listMarkers.count, 3)
        XCTAssertEqual(visible(src), "item\n\nnext\n")
    }
}
