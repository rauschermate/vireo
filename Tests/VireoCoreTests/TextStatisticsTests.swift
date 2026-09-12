import XCTest
@testable import VireoCore

final class TextStatisticsTests: XCTestCase {
    func testEmptyText() {
        XCTAssertEqual(TextStatistics.measure(""), TextStatistics(words: 0, characters: 0))
    }

    func testPlainWords() {
        XCTAssertEqual(TextStatistics.measure("Hello world"), TextStatistics(words: 2, characters: 11))
    }

    func testMarkdownPunctuationIsNotAWord() {
        let stats = TextStatistics.measure("# Title\n\n- **bold** item\n- second")
        XCTAssertEqual(stats.words, 4)
    }

    func testWhitespaceOnly() {
        XCTAssertEqual(TextStatistics.measure(" \n\t ").words, 0)
    }

    func testCountsUserPerceivedCharacters() {
        let stats = TextStatistics.measure("héllo 👨‍👩‍👧")
        XCTAssertEqual(stats.words, 1)
        XCTAssertEqual(stats.characters, 7)
    }

    func testContractionsAndNumbers() {
        XCTAssertEqual(TextStatistics.measure("don't stop at 3.14").words, 4)
    }
}
