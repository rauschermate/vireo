import XCTest
@testable import MarkdownEngine

/// The parser and the editor share one marker scanner. These tests pin the
/// rules the three old hand-written copies disagreed on.
final class ListMarkerScannerTests: XCTestCase {
    private func scan(_ line: String) -> ListMarkerScan? {
        let ns = line as NSString
        return ListMarkerScanner.scan(ns, in: NSRange(location: 0, length: ns.length))
    }

    // MARK: Whitespace after the marker

    func testTabAfterMarkerCountsAsWhitespace() {
        let s = scan("-\tx")
        XCTAssertNotNil(s)
        XCTAssertEqual(s?.contentStart, 2, "the tab belongs to the marker prefix")
        XCTAssertEqual(s?.hasWhitespaceAfterMarker, true)
    }

    func testSpaceAndTabRunIsConsumedWhole() {
        XCTAssertEqual(scan("- \t x")?.contentStart, 4)
    }

    func testMarkerWithNoWhitespaceIsNotAList() {
        XCTAssertNil(scan("-x"))
        XCTAssertNil(scan("1.x"))
    }

    func testMarkerAtLineEndScansButReportsNoWhitespace() {
        let s = scan("-")
        XCTAssertNotNil(s, "an empty item Tab just created still scans")
        XCTAssertEqual(s?.hasWhitespaceAfterMarker, false)
        XCTAssertEqual(s?.isMarkerOnly, true)
    }

    // MARK: Ordered markers

    func testNineDigitOrdinalScans() {
        guard case .ordered(let ordinal, let delimiter)? = scan("123456789. x")?.kind else {
            return XCTFail("expected an ordered marker")
        }
        XCTAssertEqual(ordinal, 123456789)
        XCTAssertEqual(delimiter, ".")
    }

    func testTenDigitOrdinalIsNotAMarker() {
        // CommonMark caps the ordinal at nine digits; cmark parses the tenth
        // as a paragraph, so the scanner must agree.
        XCTAssertNil(scan("1234567890. x"))
    }

    func testOrderedDelimiterIsRequired() {
        XCTAssertNil(scan("12 x"))
        XCTAssertEqual(scan("12) x")?.isOrdered, true)
    }

    // MARK: Task boxes

    func testTaskBoxAfterOrderedMarker() {
        // swift-markdown reports a checkbox on ordered items, so the scanner
        // must not restrict the box to bullets.
        let s = scan("1. [x] done")
        XCTAssertEqual(s?.taskChecked, true)
        XCTAssertEqual(s?.isOrdered, true)
        XCTAssertEqual(s?.contentStart, 7)
    }

    func testTaskBoxNeedsWhitespaceOrLineEndAfterIt() {
        XCTAssertNil(scan("- [x]y")?.taskChecked, "GFM needs a space after the box")
        XCTAssertEqual(scan("- [x]")?.taskChecked, true, "the line end is enough")
        XCTAssertEqual(scan("- [x] y")?.taskChecked, true)
    }

    func testTaskBoxAcceptsUpperAndLowerX() {
        XCTAssertEqual(scan("- [X] a")?.taskChecked, true)
        XCTAssertEqual(scan("- [ ] a")?.taskChecked, false)
        XCTAssertNil(scan("- [?] a")?.taskChecked)
    }

    // MARK: Shape

    func testIndentAndOffsets() {
        let s = scan("    - [ ] body")
        XCTAssertEqual(s?.markerStart, 4)
        XCTAssertEqual(s?.markerEnd, 5)
        XCTAssertEqual(s?.contentStart, 10)
    }

    func testScanStopsAtTheFirstNewline() {
        let ns = "- \nnext" as NSString
        let s = ListMarkerScanner.scan(ns, in: NSRange(location: 0, length: ns.length))
        XCTAssertEqual(s?.lineEnd, 2)
        XCTAssertEqual(s?.isMarkerOnly, true, "content on the next line does not count")
    }

    func testNonMarkers() {
        XCTAssertNil(scan("plain text"))
        XCTAssertNil(scan(""))
        XCTAssertNil(scan("   "))
    }

    // MARK: Through the parser

    func testEmptyItemHidesATabAfterTheMarker() {
        // The old empty-item scanner took spaces but not tabs, so `-⇥` hid the
        // dash and left the tab on screen next to the drawn bullet.
        let tab = MarkdownParser().parse("- a\n-\u{09}\n")
        let space = MarkdownParser().parse("- a\n- \n")
        XCTAssertEqual(tab.markerRanges.last?.length, 2)
        XCTAssertEqual(tab.markerRanges.last?.length, space.markerRanges.last?.length)
    }
}
