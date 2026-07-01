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
        let parsed = MarkdownParser().parse("![alt](pic.png)")
        XCTAssertEqual(parsed.images.count, 1)
        XCTAssertEqual(parsed.images.first?.source, "pic.png")
    }
}
