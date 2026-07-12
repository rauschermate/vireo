import AppKit
import XCTest
import MarkdownEngine
@testable import MarkdownRender

final class VisibleDecorationScalingTests: XCTestCase {
    func testListGuideIndexFindsOffscreenAncestorWithoutUnrelatedEntries() {
        let markers = [
            ListMarker(anchor: 5, text: "•", depth: 0,
                       subtreeRange: NSRange(location: 20, length: 980)),
            ListMarker(anchor: 500, text: "◦", depth: 1,
                       subtreeRange: NSRange(location: 520, length: 90)),
            ListMarker(anchor: 1_200, text: "•", depth: 0,
                       subtreeRange: NSRange(location: 1_220, length: 80)),
        ]
        let index = ListGuideIndex(listMarkers: markers, tasks: [])

        XCTAssertEqual(index.overlapping(NSRange(location: 550, length: 20)).map(\.anchor),
                       [5, 500])
        XCTAssertEqual(index.overlapping(NSRange(location: 1_250, length: 10)).map(\.anchor),
                       [1_200])
    }
}

@MainActor
final class LayoutScalingTests: XCTestCase {
    private struct Harness {
        let source: String
        let parsed: ParsedMarkdown
        let storage: NSTextStorage
        let layout: MarkdownLayoutManager
        let container: NSTextContainer
    }

    private func harness(_ source: String, width: CGFloat = 640) -> Harness {
        let parsed = MarkdownParser().parse(source)
        let rendered = MarkdownRenderer(theme: Theme()).render(source: source, parsed: parsed)
        let storage = NSTextStorage(attributedString: rendered)
        let layout = MarkdownLayoutManager()
        let theme = Theme()
        layout.tables = parsed.tables
        layout.tableRowHeight = theme.tableRowHeight
        layout.tableFont = theme.tableFont
        layout.tableHeaderFont = theme.tableHeaderFont
        layout.listMarkers = parsed.listMarkers
        layout.taskMarks = parsed.tasks
        layout.headingMarks = parsed.headings
        storage.addLayoutManager(layout)
        let container = NSTextContainer(
            size: NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        )
        layout.addTextContainer(container)
        return Harness(source: source, parsed: parsed, storage: storage,
                       layout: layout, container: container)
    }

    private func draw(_ harness: Harness, glyphRange: NSRange? = nil) {
        let canvas = NSImage(size: NSSize(width: 760, height: 900))
        canvas.lockFocus()
        let range = glyphRange ?? harness.layout.glyphRange(for: harness.container)
        harness.layout.drawGlyphs(forGlyphRange: range, at: .zero)
        canvas.unlockFocus()
    }

    func testDrawingVisibleNestedListDoesNotLayOutWholeSubtree() {
        let children = (0..<5_000).map { "    - child \($0)\n" }.joined()
        let value = harness("- parent\n" + children)
        let initial = NSRange(location: 0, length: min(2_000, value.storage.length))
        value.layout.ensureLayout(forCharacterRange: initial)
        let visible = value.layout.glyphRange(
            forBoundingRect: NSRect(x: 0, y: 0, width: 640, height: 800),
            in: value.container
        )

        draw(value, glyphRange: visible)

        XCTAssertLessThan(value.layout.firstUnlaidCharacterIndex(), value.storage.length / 2,
                          "painting one viewport must not lay out the complete list subtree")
    }

    func testTableMeasurementsAreCachedAndInvalidatedBySourceAndWidth() {
        let source = "| Name | Role |\n| --- | --- |\n| Ada | Engineer |\n"
        let value = harness(source)
        value.layout.ensureLayout(for: value.container)
        draw(value)
        draw(value)
        XCTAssertEqual(value.layout.tableRenderCacheBuildCount, 1)

        let cell = (value.storage.string as NSString).range(of: "Ada")
        value.storage.replaceCharacters(in: cell, with: "Eve")
        value.layout.ensureLayout(for: value.container)
        draw(value)
        XCTAssertEqual(value.layout.tableRenderCacheBuildCount, 2,
                       "a character edit must invalidate prepared cell content")

        value.container.size = NSSize(width: 420, height: CGFloat.greatestFiniteMagnitude)
        value.layout.invalidateLayout(forCharacterRange: NSRange(location: 0,
                                                                  length: value.storage.length),
                                      actualCharacterRange: nil)
        value.layout.ensureLayout(for: value.container)
        draw(value)
        XCTAssertEqual(value.layout.tableRenderCacheBuildCount, 3,
                       "column measurements must rebuild for a new container width")
    }

    func testManyColumnTableNeverExceedsReadingColumn() {
        let columns = (1...12).map { "Column \($0)" }
        let header = "| " + columns.joined(separator: " | ") + " |"
        let separator = "|" + Array(repeating: " --- |", count: columns.count).joined()
        let row = "| " + columns.map { "Value \($0)" }.joined(separator: " | ") + " |"
        let value = harness("\(header)\n\(separator)\n\(row)\n", width: 600)
        value.layout.ensureLayout(for: value.container)
        draw(value)

        guard let rect = value.layout.tableRects[value.parsed.tables[0].anchor] else {
            return XCTFail("table geometry missing")
        }
        XCTAssertLessThanOrEqual(rect.width, 600.5)
        XCTAssertEqual(value.layout.tableCellGeometries.count, 24)
    }
}
