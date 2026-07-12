import XCTest
@testable import MarkdownEngine

final class ParsedMarkdownSliceTests: XCTestCase {
    func testIndexedSliceMatchesReferenceFilterAcrossDocument() {
        let source = (0..<240).map { index in
            "## Heading \(index)\n\nParagraph **\(index)** with *style* and [link](https://example.com/\(index)).\n\n- [ ] task \(index)\n\n"
        }.joined()
        let parsed = MarkdownParser().parse(source)
        let ns = source as NSString

        for index in stride(from: 0, to: 240, by: 7) {
            let paragraph = ns.range(of: "Paragraph **\(index)**")
            let window = ns.paragraphRange(for: paragraph)
            XCTAssertEqual(parsed.slice(window), referenceSlice(parsed, window: window),
                           "slice diverged around paragraph \(index)")
            let insideFormatting = NSRange(location: paragraph.location + 12, length: 1)
            XCTAssertEqual(parsed.slice(insideFormatting),
                           referenceSlice(parsed, window: insideFormatting),
                           "slice diverged inside inline formatting \(index)")
        }
    }

    /// Straight filtering implementation retained only as a correctness oracle
    /// for the indexed production path.
    private func referenceSlice(_ value: ParsedMarkdown, window: NSRange) -> ParsedMarkdown {
        let delta = -window.location
        func hits(_ range: NSRange) -> Bool {
            NSIntersectionRange(range, window).length > 0
                || (range.length == 0 && NSLocationInRange(range.location, window))
        }
        func shift(_ range: NSRange) -> NSRange {
            NSRange(location: range.location + delta, length: range.length)
        }

        var output = ParsedMarkdown()
        output.markerRanges = value.markerRanges.filter(hits).map(shift)
        output.inlineRuns = value.inlineRuns.filter { hits($0.range) }.map {
            var run = $0; run.range = shift(run.range); return run
        }
        output.blockRuns = value.blockRuns.filter { hits($0.range) }.map {
            var run = $0; run.range = shift(run.range); return run
        }
        output.images = value.images.filter { hits($0.range) }.map {
            var run = $0; run.range = shift(run.range); run.anchor += delta; return run
        }
        output.links = value.links.filter { hits($0.range) }.map {
            var run = $0
            run.range = shift(run.range)
            run.labelRange = shift(run.labelRange)
            return run
        }
        output.tasks = value.tasks.filter { NSLocationInRange($0.anchor, window) }.map {
            var mark = $0
            mark.anchor += delta
            if let subtree = mark.subtreeRange { mark.subtreeRange = shift(subtree) }
            return mark
        }
        output.listMarkers = value.listMarkers.filter {
            NSLocationInRange($0.anchor, window)
        }.map {
            var mark = $0
            mark.anchor += delta
            if let subtree = mark.subtreeRange { mark.subtreeRange = shift(subtree) }
            return mark
        }
        output.tables = value.tables.filter { hits($0.range) }.map { table in
            var table = table
            table.range = shift(table.range)
            table.anchor += delta
            if let separator = table.separatorRange { table.separatorRange = shift(separator) }
            table.rows = table.rows.map { row in
                var row = row
                row.cells = row.cells.map { cell in
                    var cell = cell; cell.range = shift(cell.range); return cell
                }
                return row
            }
            return table
        }
        output.toc = value.toc.filter { NSLocationInRange($0.location, window) }.map {
            var entry = $0; entry.location += delta; return entry
        }
        output.headings = value.headings.filter {
            NSLocationInRange($0.anchor, window)
        }.map {
            var heading = $0
            heading.anchor += delta
            if let subtree = heading.subtreeRange { heading.subtreeRange = shift(subtree) }
            return heading
        }
        return output
    }
}
