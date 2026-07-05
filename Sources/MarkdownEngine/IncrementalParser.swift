import Foundation

public struct IncrementalUpdate {
    public let parsed: ParsedMarkdown
    /// UTF-16 range in the *new* source whose styling changed; nil = restyle all.
    public let dirtyRange: NSRange?
}

/// Incremental re-parse (eng-design §5): diff the edit against the previous
/// source, expand it to safe block boundaries, re-parse only that slice with
/// cmark, and splice the result into the previous parse. Falls back to a full
/// parse whenever the edit could have non-local effects (fence toggles, link
/// reference definitions, expansion reaching the whole document).
///
/// Invariant (enforced by tests): the spliced result is identical to a full
/// re-parse of the new source.
public final class IncrementalParser {
    private let parser = MarkdownParser()
    private var lastSource: [UInt16] = []
    private var lastParsed: ParsedMarkdown?

    /// Below this size a full parse is already ~instant; skip the machinery.
    public var minIncrementalLength = 16_384

    public init() {}

    /// Forget history (external reload, document swap).
    public func reset() {
        lastSource = []
        lastParsed = nil
    }

    public func update(_ source: String) -> IncrementalUpdate {
        let new = Array(source.utf16)
        defer { lastSource = new }

        guard let old = lastParsed, !lastSource.isEmpty, new.count >= minIncrementalLength else {
            return full(source)
        }
        let old16 = lastSource

        // 1. Common prefix/suffix → changed window.
        var p = 0
        let maxP = min(old16.count, new.count)
        while p < maxP, old16[p] == new[p] { p += 1 }
        var s = 0
        let maxS = maxP - p
        while s < maxS, old16[old16.count - 1 - s] == new[new.count - 1 - s] { s += 1 }
        let delta = new.count - old16.count
        let oldChangedEnd = old16.count - s
        let newChangedEnd = new.count - s
        if p == oldChangedEnd, p == newChangedEnd {
            // no textual change
            return IncrementalUpdate(parsed: old, dirtyRange: NSRange(location: 0, length: 0))
        }

        // 2. Expand to blank-line regions (with one extra region of margin for
        //    lazy continuation), then pull in any previous blocks the window
        //    touches (code blocks span blank lines), to a fixed point.
        var newStart = regionStart(new, before: min(p, newChangedEnd))
        newStart = regionStart(new, before: max(0, newStart - 1))
        var newEnd = regionEnd(new, after: newChangedEnd)
        newEnd = regionEnd(new, after: min(new.count, newEnd + 1))

        var iterations = 0
        while iterations < 32 {
            iterations += 1
            var oldStart = newStart               // in the common prefix
            var oldEnd = newEnd - delta           // in the common suffix
            var grew = false
            for run in old.blockRuns {
                guard run.range.location < oldEnd, run.range.upperBound > oldStart else { continue }
                if run.range.location < oldStart { oldStart = run.range.location; grew = true }
                if run.range.upperBound > oldEnd { oldEnd = run.range.upperBound; grew = true }
            }
            if !grew { break }
            // Boundary sanity: expansion must stay inside common prefix/suffix.
            guard oldStart <= p, oldEnd >= oldChangedEnd else { return full(source) }
            newStart = regionStart(new, before: oldStart)
            newEnd = regionEnd(new, after: oldEnd + delta)
        }
        guard iterations < 32 else { return full(source) }

        // Include the trailing blank line(s) in the slice: cmark reports a
        // block's range differently at end-of-input than when a blank line
        // follows, so the slice's last block needs the same context as the
        // full document gives it.
        newEnd = extendPastBlankLines(new, from: newEnd)

        let oldStart = newStart
        let oldEnd = newEnd - delta
        guard oldStart >= 0, oldEnd <= old16.count, oldStart <= p, oldEnd >= oldChangedEnd,
              newStart >= 0, newEnd <= new.count, newStart <= newEnd else {
            return full(source)
        }
        // Whole document anyway → full parse is simpler and equally fast.
        if newStart == 0 && newEnd == new.count { return full(source) }

        // 3. Non-local constructs in either slice force a full parse:
        //    unbalanced fences, or link reference definitions.
        let newSlice = String(utf16CodeUnits: Array(new[newStart..<newEnd]), count: newEnd - newStart)
        let oldSlice = String(utf16CodeUnits: Array(old16[oldStart..<oldEnd]), count: oldEnd - oldStart)
        guard fenceLineCount(newSlice) % 2 == 0, fenceLineCount(oldSlice) % 2 == 0,
              !hasLinkReferenceDefinition(newSlice), !hasLinkReferenceDefinition(oldSlice) else {
            return full(source)
        }

        // 4. Parse the slice locally and splice into the previous result.
        let local = parser.parse(newSlice)
        var spliced = splice(old: old, local: local,
                             oldStart: oldStart, oldEnd: oldEnd,
                             newStart: newStart, delta: delta)
        // Heading fold ranges are non-local (they end at the next same-or-
        // higher heading, possibly far outside the slice) — recompute them
        // over the full document from the spliced TOC.
        spliced.headings = MarkdownParser.computeHeadingMarks(source: source as NSString,
                                                              toc: spliced.toc)
        lastParsed = spliced
        return IncrementalUpdate(parsed: spliced,
                                 dirtyRange: NSRange(location: newStart, length: newEnd - newStart))
    }

    private func full(_ source: String) -> IncrementalUpdate {
        let parsed = parser.parse(source)
        lastParsed = parsed
        return IncrementalUpdate(parsed: parsed, dirtyRange: nil)
    }

    // MARK: Region boundaries (blank-line separated, scanning UTF-16 units)

    private func regionStart(_ text: [UInt16], before pos: Int) -> Int {
        var i = min(pos, text.count) - 1
        while i > 0 {
            if text[i] == 0x0A, text[i - 1] == 0x0A { return i + 1 }
            i -= 1
        }
        return 0
    }

    /// Consume consecutive blank lines (`[ \t]*\n`) starting at `pos`.
    private func extendPastBlankLines(_ text: [UInt16], from pos: Int) -> Int {
        var i = pos
        while i < text.count {
            var j = i
            while j < text.count, text[j] == 0x20 || text[j] == 0x09 { j += 1 }
            guard j < text.count, text[j] == 0x0A else { break }
            i = j + 1
        }
        return i
    }

    private func regionEnd(_ text: [UInt16], after pos: Int) -> Int {
        var i = max(pos, 0)
        while i + 1 < text.count {
            if text[i] == 0x0A, text[i + 1] == 0x0A { return i + 1 }
            i += 1
        }
        return text.count
    }

    // MARK: Non-local construct detection

    /// Count of lines that open/close a fenced code block (``` or ~~~ after ≤3 spaces).
    private func fenceLineCount(_ slice: String) -> Int {
        var count = 0
        slice.enumerateLines { line, _ in
            var spaces = 0
            var idx = line.startIndex
            while idx < line.endIndex, line[idx] == " ", spaces < 4 { spaces += 1; idx = line.index(after: idx) }
            guard spaces < 4, idx < line.endIndex else { return }
            let c = line[idx]
            guard c == "`" || c == "~" else { return }
            var runLen = 0
            var j = idx
            while j < line.endIndex, line[j] == c { runLen += 1; j = line.index(after: j) }
            if runLen >= 3 { count += 1 }
        }
        return count
    }

    /// `[label]: destination` lines change link resolution document-wide.
    private func hasLinkReferenceDefinition(_ slice: String) -> Bool {
        var found = false
        slice.enumerateLines { line, stop in
            let trimmed = line.drop { $0 == " " }
            if trimmed.first == "[", trimmed.contains("]:") {
                found = true
                stop = true
            }
        }
        return found
    }

    // MARK: Splicing

    private func splice(old: ParsedMarkdown, local: ParsedMarkdown,
                        oldStart: Int, oldEnd: Int, newStart: Int, delta: Int) -> ParsedMarkdown {
        func keep(_ r: NSRange) -> Bool { r.upperBound <= oldStart }
        func keepAfter(_ r: NSRange) -> Bool { r.location >= oldEnd }
        func shift(_ r: NSRange, _ d: Int) -> NSRange { NSRange(location: r.location + d, length: r.length) }

        var out = ParsedMarkdown()
        out.markerRanges =
            old.markerRanges.filter(keep)
            + local.markerRanges.map { shift($0, newStart) }
            + old.markerRanges.filter(keepAfter).map { shift($0, delta) }
        out.inlineRuns =
            old.inlineRuns.filter { keep($0.range) }
            + local.inlineRuns.map { var x = $0; x.range = shift(x.range, newStart); return x }
            + old.inlineRuns.filter { keepAfter($0.range) }.map { var x = $0; x.range = shift(x.range, delta); return x }
        out.blockRuns =
            old.blockRuns.filter { keep($0.range) }
            + local.blockRuns.map { var x = $0; x.range = shift(x.range, newStart); return x }
            + old.blockRuns.filter { keepAfter($0.range) }.map { var x = $0; x.range = shift(x.range, delta); return x }
        out.images =
            old.images.filter { keep($0.range) }
            + local.images.map { var x = $0; x.range = shift(x.range, newStart); x.anchor += newStart; return x }
            + old.images.filter { keepAfter($0.range) }.map { var x = $0; x.range = shift(x.range, delta); x.anchor += delta; return x }
        func shiftTask(_ t: TaskMark, _ d: Int) -> TaskMark {
            var x = t
            x.anchor += d
            if let s = x.subtreeRange { x.subtreeRange = shift(s, d) }
            return x
        }
        func shiftMarker(_ m: ListMarker, _ d: Int) -> ListMarker {
            var x = m
            x.anchor += d
            if let s = x.subtreeRange { x.subtreeRange = shift(s, d) }
            return x
        }
        out.tasks =
            old.tasks.filter { $0.anchor < oldStart }
            + local.tasks.map { shiftTask($0, newStart) }
            + old.tasks.filter { $0.anchor >= oldEnd }.map { shiftTask($0, delta) }
        out.listMarkers =
            old.listMarkers.filter { $0.anchor < oldStart }
            + local.listMarkers.map { shiftMarker($0, newStart) }
            + old.listMarkers.filter { $0.anchor >= oldEnd }.map { shiftMarker($0, delta) }
        func shiftTable(_ t: TableInfo, _ d: Int) -> TableInfo {
            var x = t
            x.range = shift(x.range, d)
            x.anchor += d
            if let sep = x.separatorRange { x.separatorRange = shift(sep, d) }
            x.rows = x.rows.map { row in
                var r = row
                r.cells = r.cells.map { var c = $0; c.range = shift(c.range, d); return c }
                return r
            }
            return x
        }
        out.tables =
            old.tables.filter { keep($0.range) }
            + local.tables.map { shiftTable($0, newStart) }
            + old.tables.filter { keepAfter($0.range) }.map { shiftTable($0, delta) }
        out.toc =
            old.toc.filter { $0.location < oldStart }
            + local.toc.map { var x = $0; x.location += newStart; return x }
            + old.toc.filter { $0.location >= oldEnd }.map { var x = $0; x.location += delta; return x }
        return out
    }
}
