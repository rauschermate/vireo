import XCTest
@testable import MarkdownEngine

final class SourceTreatmentTests: XCTestCase {
    private let parser = MarkdownParser()

    func testFrontMatterBecomesOneMetadataBlock() {
        let source = "---\ntitle: Vireo\ntags: [swift, macOS]\n---\n\n# Document\n"
        let parsed = parser.parse(source)

        XCTAssertEqual(parsed.sourceBlocks.count, 1)
        guard let block = parsed.sourceBlocks.first else { return }
        XCTAssertEqual((source as NSString).substring(with: block.range),
                       "---\ntitle: Vireo\ntags: [swift, macOS]\n---\n")
        guard case .metadata(let label) = block.kind else {
            return XCTFail("front matter should be metadata")
        }
        XCTAssertEqual(label, "Front matter · 2 fields")
        XCTAssertEqual(parsed.toc.map(\.title), ["Document"])
        XCTAssertTrue(parsed.markerRanges.contains(block.range))
    }

    func testLocalSliceCannotInventFrontMatter() {
        let source = "---\nordinary content\n---\n"
        let parsed = parser.parse(source, recognizesFrontMatter: false)
        XCTAssertTrue(parsed.sourceBlocks.isEmpty)
    }

    func testReferenceDefinitionsAndContinuationTitleCollapseTogether() {
        let source = "See [the guide][guide].\n\n[guide]: https://example.com/guide\n  \"The guide\"\n[next]: /next\n\nTail\n"
        let parsed = parser.parse(source)

        XCTAssertEqual(parsed.sourceBlocks.count, 1)
        guard let block = parsed.sourceBlocks.first else { return }
        guard case .metadata(let label) = block.kind else {
            return XCTFail("references should be metadata")
        }
        XCTAssertEqual(label, "2 link references")
        XCTAssertEqual((source as NSString).substring(with: block.range),
                       "[guide]: https://example.com/guide\n  \"The guide\"\n[next]: /next\n")
        XCTAssertTrue(parsed.inlineRuns.contains { $0.link == "https://example.com/guide" })
    }

    func testIncompleteReferenceDefinitionStaysLiteral() {
        let parsed = parser.parse("[draft]:\n")
        XCTAssertTrue(parsed.sourceBlocks.isEmpty)
    }

    func testReferenceLikeLinesInsideLiteralBlocksStayContent() {
        let source = """
        ```text
        [fenced]: https://example.com/fenced
        ```

            [indented]: https://example.com/indented

        <section>
        [html]: https://example.com/html
        </section>
        """
        let parsed = parser.parse(source)

        XCTAssertFalse(parsed.sourceBlocks.contains {
            if case .metadata = $0.kind { return true }
            return false
        })
        XCTAssertTrue(parsed.sourceBlocks.contains {
            if case .unsupportedHTML(let label) = $0.kind {
                return label == "HTML section block · not rendered"
            }
            return false
        })
    }

    func testSafeInlineHTMLStylesContentAndHidesTags() {
        let source = "Press <kbd>⌘K</kbd>, <u>under</u>, <mark>bright</mark>."
        let parsed = parser.parse(source)
        let ns = source as NSString

        XCTAssertTrue(parsed.inlineRuns.contains {
            $0.code && ns.substring(with: $0.range) == "⌘K"
        })
        XCTAssertTrue(parsed.inlineRuns.contains {
            $0.underline && ns.substring(with: $0.range) == "under"
        })
        XCTAssertTrue(parsed.inlineRuns.contains {
            $0.highlight && ns.substring(with: $0.range) == "bright"
        })
        XCTAssertEqual(parsed.markerRanges.count, 6)
        XCTAssertTrue(parsed.inlineHTML.isEmpty)
    }

    func testMalformedInlineHTMLStyleDoesNotLeakAcrossBlocks() {
        let source = "<kbd>key\n\nplain paragraph\n"
        let parsed = parser.parse(source)
        let ns = source as NSString

        XCTAssertTrue(parsed.inlineRuns.contains {
            $0.code && ns.substring(with: $0.range) == "key"
        })
        XCTAssertFalse(parsed.inlineRuns.contains {
            $0.code && ns.substring(with: $0.range).contains("plain")
        })
    }

    func testInlineHTMLGetsIntentionalReplacementKinds() {
        let source = "first<br>second <span class=\"note\">word</span>"
        let parsed = parser.parse(source)

        XCTAssertEqual(parsed.inlineHTML.count, 2)
        XCTAssertTrue(parsed.inlineHTML.contains { $0.kind == .lineBreak })
        XCTAssertTrue(parsed.inlineHTML.contains { $0.kind == .unsupported(tag: "span") })
        XCTAssertEqual(parsed.markerRanges.count, 3)
    }

    func testHTMLBlocksAreExplicitlyUnsupportedAndCommentsAreMetadata() {
        let source = "<section>\nBrowser content\n</section>\n\n<!-- internal note -->\n"
        let parsed = parser.parse(source)

        XCTAssertEqual(parsed.sourceBlocks.count, 2)
        XCTAssertTrue(parsed.sourceBlocks.contains {
            if case .unsupportedHTML(let label) = $0.kind {
                return label == "HTML section block · not rendered"
            }
            return false
        })
        XCTAssertTrue(parsed.sourceBlocks.contains {
            if case .metadata(let label) = $0.kind { return label == "HTML comment" }
            return false
        })
    }
}
