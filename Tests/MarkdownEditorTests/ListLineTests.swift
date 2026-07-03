import XCTest
@testable import MarkdownEditor

final class ListLineTests: XCTestCase {
    func testBullet() {
        let l = ListLine.parse("- item")
        XCTAssertEqual(l?.marker, "-")
        XCTAssertEqual(l?.isOrdered, false)
        XCTAssertEqual(l?.contentIsEmpty, false)
        XCTAssertEqual(l?.markerEndOffset, 2)
        XCTAssertEqual(l?.continuationPrefix, "- ")
    }

    func testStarAndPlusBullets() {
        XCTAssertEqual(ListLine.parse("* x")?.continuationPrefix, "* ")
        XCTAssertEqual(ListLine.parse("+ x")?.continuationPrefix, "+ ")
    }

    func testIndentedBullet() {
        let l = ListLine.parse("    - nested")
        XCTAssertEqual(l?.indent, "    ")
        XCTAssertEqual(l?.markerEndOffset, 6)
        XCTAssertEqual(l?.continuationPrefix, "    - ")
    }

    func testOrdered() {
        let l = ListLine.parse("3. third")
        XCTAssertEqual(l?.isOrdered, true)
        XCTAssertEqual(l?.marker, "3.")
        XCTAssertEqual(l?.continuationPrefix, "4. ")
    }

    func testOrderedParen() {
        XCTAssertEqual(ListLine.parse("7) x")?.continuationPrefix, "8) ")
    }

    func testTask() {
        let l = ListLine.parse("- [ ] todo")
        XCTAssertEqual(l?.isTask, true)
        XCTAssertEqual(l?.taskChecked, false)
        XCTAssertEqual(l?.markerEndOffset, 6)
        XCTAssertEqual(l?.continuationPrefix, "- [ ] ")
    }

    func testCheckedTaskContinuesUnchecked() {
        let l = ListLine.parse("- [x] done")
        XCTAssertEqual(l?.taskChecked, true)
        XCTAssertEqual(l?.continuationPrefix, "- [ ] ")
    }

    func testEmptyItem() {
        XCTAssertEqual(ListLine.parse("- ")?.contentIsEmpty, true)
        XCTAssertEqual(ListLine.parse("-")?.contentIsEmpty, true) // bare marker at EOL
        XCTAssertEqual(ListLine.parse("- [ ] ")?.contentIsEmpty, true)
        XCTAssertEqual(ListLine.parse("2. ")?.contentIsEmpty, true)
    }

    func testNonListLines() {
        XCTAssertNil(ListLine.parse("plain text"))
        XCTAssertNil(ListLine.parse("-not a list"))
        XCTAssertNil(ListLine.parse("1x. not ordered"))
        XCTAssertNil(ListLine.parse(""))
        XCTAssertNil(ListLine.parse("  "))
    }

    func testBracketContentIsNotATaskBox() {
        // `- [link](url)` is a bullet whose content starts with a link, not a task.
        let l = ListLine.parse("- [link](url)")
        XCTAssertEqual(l?.isTask, false)
        XCTAssertEqual(l?.markerEndOffset, 2)
    }
}
