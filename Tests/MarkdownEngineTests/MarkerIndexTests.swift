import XCTest
@testable import MarkdownEngine

final class MarkerIndexTests: XCTestCase {
    private let source = "A **bold** and [link](https://example.com)." as NSString

    private var index: MarkerIndex {
        MarkerIndex(ranges: [
            NSRange(location: 2, length: 2),
            NSRange(location: 8, length: 2),
            NSRange(location: 15, length: 1),
            NSRange(location: 20, length: 22),
        ], sourceLength: source.length)
    }

    func testNormalizesClampsAndMergesMarkers() {
        let value = MarkerIndex(ranges: [
            NSRange(location: 4, length: 3),
            NSRange(location: 1, length: 3),
            NSRange(location: 7, length: 2),
            NSRange(location: 20, length: 4),
        ], sourceLength: 22)
        XCTAssertEqual(value.ranges, [NSRange(location: 1, length: 8),
                                      NSRange(location: 20, length: 2)])
    }

    func testDirectionalCaretCrossesWholeMarker() {
        XCTAssertEqual(index.caretPosition(2, affinity: .downstream), 4)
        XCTAssertEqual(index.caretPosition(3, affinity: .downstream), 4)
        XCTAssertEqual(index.caretPosition(4, affinity: .upstream), 2)
        XCTAssertEqual(index.caretPosition(3, affinity: .upstream), 2)
        XCTAssertEqual(index.caretPosition(3, affinity: .nearest), 4)
        XCTAssertEqual(index.caretPosition(4, affinity: .nearest), 4)
    }

    func testSelectionExpandsPartialMarkersAtomically() {
        XCTAssertEqual(index.atomicSelection(NSRange(location: 3, length: 6)),
                       NSRange(location: 2, length: 8))
        XCTAssertEqual(index.atomicSelection(NSRange(location: 4, length: 4)),
                       NSRange(location: 4, length: 4))
    }

    func testDeletingAllVisibleFormattingContentIncludesDelimiters() {
        XCTAssertEqual(index.balancedDeletionRange(NSRange(location: 4, length: 4)),
                       NSRange(location: 2, length: 8))
        XCTAssertEqual(index.balancedDeletionRange(NSRange(location: 16, length: 4)),
                       NSRange(location: 15, length: 27))
    }

    func testVisibleAndSourceOffsetsRoundTripWithAffinity() {
        XCTAssertEqual(index.visibleOffset(forSourceOffset: 2), 2)
        XCTAssertEqual(index.visibleOffset(forSourceOffset: 3), 2)
        XCTAssertEqual(index.visibleOffset(forSourceOffset: 4), 2)
        XCTAssertEqual(index.sourceOffset(forVisibleOffset: 2, affinity: .upstream), 2)
        XCTAssertEqual(index.sourceOffset(forVisibleOffset: 2, affinity: .downstream), 4)

        for visible in 0...index.visibleLength {
            let sourceOffset = index.sourceOffset(forVisibleOffset: visible, affinity: .downstream)
            XCTAssertEqual(index.visibleOffset(forSourceOffset: sourceOffset), visible)
        }
    }

    func testVisibleStringOmitsAllSyntax() {
        XCTAssertEqual(index.visibleString(in: source), "A bold and link.")
        XCTAssertEqual(index.visibleString(in: NSRange(location: 2, length: 8), source: source), "bold")
    }

    func testVisibleCharacterDeletionSkipsMarkersAndKeepsGraphemesWhole() {
        let emojiSource = "**A👩🏽‍💻**" as NSString
        let value = MarkerIndex(ranges: [NSRange(location: 0, length: 2),
                                         NSRange(location: emojiSource.length - 2, length: 2)],
                                sourceLength: emojiSource.length)

        let emoji = value.nextVisibleCharacter(after: 3, in: emojiSource)
        XCTAssertEqual(emoji.map { emojiSource.substring(with: $0) }, "👩🏽‍💻")
        XCTAssertEqual(value.previousVisibleCharacter(before: emojiSource.length, in: emojiSource), emoji)
        XCTAssertEqual(value.nextVisibleCharacter(after: 0, in: emojiSource),
                       NSRange(location: 2, length: 1))
    }

    func testEmptyIndexIsIdentity() {
        let value = MarkerIndex(ranges: [], sourceLength: 4)
        XCTAssertEqual(value.visibleLength, 4)
        XCTAssertEqual(value.caretPosition(2, affinity: .downstream), 2)
        XCTAssertEqual(value.visibleString(in: "test" as NSString), "test")
    }
}
