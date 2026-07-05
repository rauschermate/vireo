import XCTest
@testable import MarkdownEngine

final class SetextListMarkerTests: XCTestCase {
    func testIndentedEmptyBulletRendersNested() {
        let src = "- bullet one\n    - \n- bullet two\n"
        let p = MarkdownParser().parse(src)
        XCTAssertFalse(p.blockRuns.contains { if case .heading = $0.kind { return true }; return false },
                       "no heading run")
        // three bullets: two depth-0, one depth-1 (the indented empty one)
        XCTAssertEqual(p.listMarkers.map(\.depth).sorted(), [0, 0, 1])
    }
    func testRealHeadingsStillHeadings() {
        for src in ["## Real ATX\n\nbody\n", "Setext title\n===\n\nbody\n", "Setext two\n---\n\nbody\n"] {
            let p = MarkdownParser().parse(src)
            XCTAssertTrue(p.blockRuns.contains { if case .heading = $0.kind { return true }; return false },
                          "expected heading for: \(src.prefix(20))")
        }
    }
    func testEnterBulletUnderTextNotHeading() {
        // text + Enter makes `- ` — must be a bullet, not a setext heading
        let p = MarkdownParser().parse("some text\n- \n")
        XCTAssertFalse(p.blockRuns.contains { if case .heading = $0.kind { return true }; return false })
    }
}
