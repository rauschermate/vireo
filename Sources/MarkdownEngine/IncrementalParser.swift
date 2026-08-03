import Foundation

/// One AppKit-approved source replacement, expressed in UTF-16 coordinates of
/// the source *before* the edit. Supplying this lets the incremental parser skip
/// allocating and diffing the entire document after every keystroke.
public struct SourceEdit: Sendable, Equatable {
    public let oldRange: NSRange
    public let replacement: String
    public let oldSourceLength: Int

    public init(oldRange: NSRange, replacement: String, oldSourceLength: Int) {
        self.oldRange = oldRange
        self.replacement = replacement
        self.oldSourceLength = oldSourceLength
    }
}

public enum IncrementalStrategy: Sendable, Equatable {
    case full
    case exactEdit
    case sourceDiff
    case unchanged
}

public struct IncrementalUpdate {
    public let parsed: ParsedMarkdown
    /// UTF-16 range in the *new* source whose styling changed; nil = restyle all.
    public let dirtyRange: NSRange?
    /// How the changed source window was found. Exposed for diagnostics and
    /// deterministic pipeline tests, not as a user-facing performance promise.
    public let strategy: IncrementalStrategy
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
    private var lastSource = ""
    private var lastParsed: ParsedMarkdown?

    /// Below this size a full parse is already ~instant; skip the machinery.
    public var minIncrementalLength = 16_384

    public init() {}

    /// Forget history (external reload, document swap).
    public func reset() {
        lastSource = ""
        lastParsed = nil
    }

    public func update(_ source: String) -> IncrementalUpdate {
        update(source, edit: nil)
    }

    public func update(_ source: String, edit: SourceEdit?) -> IncrementalUpdate {
        let new = source as NSString
        defer { lastSource = source }

        guard let old = lastParsed, !lastSource.isEmpty, new.length >= minIncrementalLength else {
            return full(source)
        }
        let oldText = lastSource as NSString
        if let edit,
           edit.oldSourceLength == oldText.length,
           edit.oldRange.location >= 0,
           edit.oldRange.upperBound <= oldText.length,
           oldText.substring(with: edit.oldRange) == edit.replacement,
           lastSource == source {
            return IncrementalUpdate(parsed: old,
                                     dirtyRange: NSRange(location: 0, length: 0),
                                     strategy: .unchanged)
        }

        // 1. Prefer the exact range NSTextView already approved. If no single
        //    reliable edit is available (IME/multi-line transformations/undo),
        //    retain the safe full-source diff fallback.
        let p: Int
        let oldChangedEnd: Int
        let newChangedEnd: Int
        let strategy: IncrementalStrategy
        if let exact = exactWindow(for: edit, old: oldText, new: new) {
            p = exact.start
            oldChangedEnd = exact.oldEnd
            newChangedEnd = exact.newEnd
            strategy = .exactEdit
        } else {
            var prefix = 0
            let maxPrefix = min(oldText.length, new.length)
            while prefix < maxPrefix,
                  oldText.character(at: prefix) == new.character(at: prefix) { prefix += 1 }
            var suffix = 0
            let maxSuffix = maxPrefix - prefix
            while suffix < maxSuffix,
                  oldText.character(at: oldText.length - 1 - suffix)
                    == new.character(at: new.length - 1 - suffix) { suffix += 1 }
            p = prefix
            oldChangedEnd = oldText.length - suffix
            newChangedEnd = new.length - suffix
            strategy = .sourceDiff
        }
        let delta = new.length - oldText.length
        if p == oldChangedEnd, p == newChangedEnd {
            // no textual change
            return IncrementalUpdate(parsed: old,
                                     dirtyRange: NSRange(location: 0, length: 0),
                                     strategy: .unchanged)
        }

        // 2. Expand to blank-line regions (with one extra region of margin for
        //    lazy continuation), then pull in any previous blocks the window
        //    touches (code blocks span blank lines), to a fixed point.
        var newStart = regionStart(new, before: min(p, newChangedEnd))
        newStart = regionStart(new, before: max(0, newStart - 1))
        var newEnd = regionEnd(new, after: newChangedEnd)
        newEnd = regionEnd(new, after: min(new.length, newEnd + 1))

        var iterations = 0
        while iterations < 32 {
            iterations += 1
            var oldStart = newStart               // in the common prefix
            var oldEnd = newEnd - delta            // in the common suffix
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
        guard oldStart >= 0, oldEnd <= oldText.length, oldStart <= p, oldEnd >= oldChangedEnd,
              newStart >= 0, newEnd <= new.length, newStart <= newEnd else {
            return full(source)
        }
        // Whole document anyway → full parse is simpler and equally fast.
        if newStart == 0 && newEnd == new.length { return full(source) }

        // 3. Non-local constructs in either slice force a full parse:
        //    unbalanced fences, or link reference definitions.
        let newSlice = new.substring(with: NSRange(location: newStart, length: newEnd - newStart))
        let oldSlice = oldText.substring(with: NSRange(location: oldStart, length: oldEnd - oldStart))
        guard fenceLineCount(newSlice) % 2 == 0, fenceLineCount(oldSlice) % 2 == 0,
              !hasLinkReferenceDefinition(newSlice), !hasLinkReferenceDefinition(oldSlice) else {
            return full(source)
        }

        // 4. Parse the slice locally and splice into the previous result.
        // A slice that begins at a thematic break in the middle of the file
        // must not be mistaken for document front matter.
        let local = parser.parse(newSlice, recognizesFrontMatter: newStart == 0)
        var spliced = splice(old: old, local: local,
                             oldStart: oldStart, oldEnd: oldEnd,
                             newStart: newStart, delta: delta)
        // Heading fold ranges are non-local (they end at the next same-or-
        // higher heading, possibly far outside the slice) — recompute them
        // over the full document from the spliced TOC.
        spliced.headings = MarkdownParser.computeHeadingMarks(source: new, toc: spliced.toc)
        lastParsed = spliced
        return IncrementalUpdate(parsed: spliced,
                                 dirtyRange: NSRange(location: newStart, length: newEnd - newStart),
                                 strategy: strategy)
    }

    private func full(_ source: String) -> IncrementalUpdate {
        let parsed = parser.parse(source)
        lastParsed = parsed
        return IncrementalUpdate(parsed: parsed, dirtyRange: nil, strategy: .full)
    }

    // MARK: Region boundaries (blank-line separated, scanning UTF-16 units)

    private func regionStart(_ text: NSString, before pos: Int) -> Int {
        var i = min(pos, text.length) - 1
        while i > 0 {
            if text.character(at: i) == 0x0A,
               text.character(at: i - 1) == 0x0A { return i + 1 }
            i -= 1
        }
        return 0
    }

    /// Consume consecutive blank lines (`[ \t]*\n`) starting at `pos`.
    private func extendPastBlankLines(_ text: NSString, from pos: Int) -> Int {
        var i = pos
        while i < text.length {
            var j = i
            while j < text.length,
                  text.character(at: j) == 0x20 || text.character(at: j) == 0x09 { j += 1 }
            guard j < text.length, text.character(at: j) == 0x0A else { break }
            i = j + 1
        }
        return i
    }

    private func regionEnd(_ text: NSString, after pos: Int) -> Int {
        var i = max(pos, 0)
        while i + 1 < text.length {
            if text.character(at: i) == 0x0A,
               text.character(at: i + 1) == 0x0A { return i + 1 }
            i += 1
        }
        return text.length
    }

    private func exactWindow(for edit: SourceEdit?, old: NSString,
                             new: NSString) -> (start: Int, oldEnd: Int, newEnd: Int)? {
        guard let edit,
              edit.oldSourceLength == old.length,
              edit.oldRange.location >= 0,
              edit.oldRange.upperBound <= old.length else { return nil }
        let replacement = edit.replacement as NSString
        guard old.length - edit.oldRange.length + replacement.length == new.length,
              edit.oldRange.location + replacement.length <= new.length,
              new.substring(with: NSRange(location: edit.oldRange.location,
                                          length: replacement.length)) == edit.replacement else {
            return nil
        }
        // Validate a bounded amount of unchanged context on both sides. This
        // catches stale/mis-composed edit records without turning the fast path
        // back into a document-wide prefix/suffix scan.
        let prefixLength = min(32, edit.oldRange.location)
        if prefixLength > 0 {
            let prefix = NSRange(location: edit.oldRange.location - prefixLength,
                                 length: prefixLength)
            guard old.substring(with: prefix) == new.substring(with: prefix) else { return nil }
        }
        let suffixLength = min(32, old.length - edit.oldRange.upperBound)
        if suffixLength > 0 {
            let oldSuffix = NSRange(location: edit.oldRange.upperBound, length: suffixLength)
            let newSuffix = NSRange(location: edit.oldRange.location + replacement.length,
                                    length: suffixLength)
            guard old.substring(with: oldSuffix) == new.substring(with: newSuffix) else { return nil }
        }
        return (edit.oldRange.location, edit.oldRange.upperBound,
                edit.oldRange.location + replacement.length)
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
        func shiftLink(_ link: LinkRun, _ d: Int) -> LinkRun {
            var x = link
            x.range = shift(x.range, d)
            x.labelRange = shift(x.labelRange, d)
            return x
        }
        out.links =
            old.links.filter { keep($0.range) }
            + local.links.map { shiftLink($0, newStart) }
            + old.links.filter { keepAfter($0.range) }.map { shiftLink($0, delta) }
        func shiftSourceBlock(_ block: SourceBlockRun, _ d: Int) -> SourceBlockRun {
            var x = block
            x.range = shift(x.range, d)
            x.anchor += d
            return x
        }
        out.sourceBlocks =
            old.sourceBlocks.filter { keep($0.range) }
            + local.sourceBlocks.map { shiftSourceBlock($0, newStart) }
            + old.sourceBlocks.filter { keepAfter($0.range) }.map { shiftSourceBlock($0, delta) }
        func shiftInlineHTML(_ run: InlineHTMLRun, _ d: Int) -> InlineHTMLRun {
            var x = run
            x.range = shift(x.range, d)
            x.anchor += d
            return x
        }
        out.inlineHTML =
            old.inlineHTML.filter { keep($0.range) }
            + local.inlineHTML.map { shiftInlineHTML($0, newStart) }
            + old.inlineHTML.filter { keepAfter($0.range) }.map { shiftInlineHTML($0, delta) }
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
