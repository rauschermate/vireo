import XCTest
@testable import MarkdownEngine

/// The incremental parser's contract: its spliced output must be *identical*
/// to a full re-parse of the new source, for any edit.
final class IncrementalParserTests: XCTestCase {
    private let base = """
    # Title

    Intro paragraph with **bold**, *italic*, `code` and a [link](https://x.com).

    ## Section One

    - item one
    - item two
        - nested item

    ```swift
    let x = 1

    let y = 2 // fence contains a blank line
    ```

    > A quote with émojis 😀 and café.

    | A | B |
    |---|---|
    | 1 | 2 |

    - [ ] todo item
    - [x] done item

    ## Section Two

    Closing paragraph. Text ~~struck~~ here.
    """

    private func makeParser() -> IncrementalParser {
        let p = IncrementalParser()
        p.minIncrementalLength = 0 // exercise the incremental path on small docs
        return p
    }

    /// Apply `edit` to `base`, run the incremental path, and assert exact
    /// equality with a full parse. Returns the update for extra assertions.
    @discardableResult
    private func assertEquivalent(_ edited: String, base: String? = nil,
                                  file: StaticString = #filePath, line: UInt = #line) -> IncrementalUpdate {
        let parser = makeParser()
        _ = parser.update(base ?? self.base)     // establish history
        let update = parser.update(edited)
        let reference = MarkdownParser().parse(edited)
        XCTAssertEqual(update.parsed, reference,
                       "incremental result diverged from full parse", file: file, line: line)
        return update
    }

    // MARK: localized edits stay incremental

    func testTypeInMiddleParagraph() {
        let edited = base.replacingOccurrences(of: "Intro paragraph", with: "Intro paragraphX")
        let update = assertEquivalent(edited)
        XCTAssertNotNil(update.dirtyRange, "a paragraph edit should stay incremental")
        XCTAssertLessThan(update.dirtyRange!.length, (base as NSString).length / 2,
                          "dirty range should be a fraction of the document")
    }

    func testDeleteWord() {
        assertEquivalent(base.replacingOccurrences(of: "**bold**, ", with: ""))
    }

    func testEditInsideCodeBlockSpanningBlankLine() {
        let edited = base.replacingOccurrences(of: "let y = 2", with: "let y = 42")
        let update = assertEquivalent(edited)
        XCTAssertNotNil(update.dirtyRange)
    }

    func testEditTableCell() {
        assertEquivalent(base.replacingOccurrences(of: "| 1 | 2 |", with: "| 10 | 2 |"))
    }

    func testToggleTask() {
        assertEquivalent(base.replacingOccurrences(of: "- [ ] todo", with: "- [x] todo"))
    }

    func testMultibyteInsert() {
        assertEquivalent(base.replacingOccurrences(of: "émojis 😀", with: "émojis 😀🎉"))
    }

    func testAddHeadingUpdatesTOC() {
        let edited = base.replacingOccurrences(of: "Closing paragraph.",
                                               with: "### New Sub\n\nClosing paragraph.")
        let update = assertEquivalent(edited)
        XCTAssertTrue(update.parsed.toc.contains { $0.title == "New Sub" })
    }

    // MARK: structural edits fall back to a full parse (and stay correct)

    func testOpeningFenceFallsBack() {
        let edited = base.replacingOccurrences(of: "Closing paragraph.",
                                               with: "```\nClosing paragraph.")
        let update = assertEquivalent(edited)
        XCTAssertNil(update.dirtyRange, "an unbalanced fence must force a full restyle")
    }

    func testLinkReferenceDefinitionFallsBack() {
        let edited = base + "\n\n[ref]: https://example.com\n"
        let update = assertEquivalent(edited)
        XCTAssertNil(update.dirtyRange)
    }

    // MARK: fuzz — random edits never diverge

    func testFuzzedEditsMatchFullParse() {
        var seed: UInt64 = 0x5EED
        func rand(_ bound: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int(seed >> 33) % max(1, bound)
        }
        let snippets = ["x", "**b**", "\n", "\n\n## H\n\n", "`c`", "😀", "- item\n", "> q\n", "```", "~~s~~"]

        let parser = makeParser()
        var current = base
        _ = parser.update(current)
        let reference = MarkdownParser()

        for i in 0..<200 {
            var chars = Array(current.utf16)
            if rand(2) == 0, chars.count > 10 {
                // delete a small random chunk (snap to scalar boundaries via round-trip)
                let start = rand(chars.count - 5)
                let len = 1 + rand(4)
                chars.removeSubrange(start..<min(start + len, chars.count))
            } else {
                let insert = Array(snippets[rand(snippets.count)].utf16)
                chars.insert(contentsOf: insert, at: rand(chars.count + 1))
            }
            guard let candidate = String(utf16CodeUnitsRepairingIllFormed: chars) else { continue }
            current = candidate
            let update = parser.update(current)
            let expected = reference.parse(current)
            XCTAssertEqual(update.parsed, expected, "fuzz iteration \(i) diverged")
            if update.parsed != expected { break }
        }
    }
}

private extension String {
    /// Build from UTF-16 units, repairing any surrogates the fuzzer cut in half.
    init?(utf16CodeUnitsRepairingIllFormed units: [UInt16]) {
        self.init(decoding: units, as: UTF16.self)
    }
}
