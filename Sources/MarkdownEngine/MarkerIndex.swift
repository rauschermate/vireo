import Foundation

/// Which source-side edge owns a visual position where hidden Markdown syntax
/// collapses to zero width.
public enum MarkerAffinity: Sendable {
    case upstream
    case downstream
    case nearest
}

/// An immutable, indexed view of the source ranges hidden by the renderer.
///
/// TextKit still stores the untouched Markdown source, so every hidden marker
/// contributes several source positions to one visual position. This type is
/// the single authority for crossing those boundaries. It deliberately lives
/// in MarkdownEngine so editing, find, copy, hit testing and accessibility all
/// share exactly the same mapping without depending on AppKit attributes.
public struct MarkerIndex: Sendable, Equatable {
    public let sourceLength: Int
    public let ranges: [NSRange]

    private let hiddenPrefix: [Int]
    private let visibleStarts: [Int]

    public init(ranges rawRanges: [NSRange], sourceLength: Int) {
        self.sourceLength = max(0, sourceLength)

        let limit = max(0, sourceLength)
        let clamped = rawRanges.compactMap { range -> NSRange? in
            guard range.location != NSNotFound, range.length > 0 else { return nil }
            let lower = min(max(0, range.location), limit)
            let upper = min(max(lower, range.upperBound), limit)
            guard upper > lower else { return nil }
            return NSRange(location: lower, length: upper - lower)
        }.sorted {
            $0.location == $1.location ? $0.upperBound < $1.upperBound : $0.location < $1.location
        }

        var normalized: [NSRange] = []
        normalized.reserveCapacity(clamped.count)
        for range in clamped {
            if let last = normalized.last, range.location <= last.upperBound {
                normalized[normalized.count - 1] = NSRange(
                    location: last.location,
                    length: max(last.upperBound, range.upperBound) - last.location
                )
            } else {
                normalized.append(range)
            }
        }
        ranges = normalized

        var prefix: [Int] = [0]
        var starts: [Int] = []
        prefix.reserveCapacity(normalized.count + 1)
        starts.reserveCapacity(normalized.count)
        for range in normalized {
            starts.append(range.location - prefix[prefix.count - 1])
            prefix.append(prefix[prefix.count - 1] + range.length)
        }
        hiddenPrefix = prefix
        visibleStarts = starts
    }

    public static let empty = MarkerIndex(ranges: [], sourceLength: 0)

    public var visibleLength: Int { sourceLength - hiddenPrefix.last! }

    /// The marker whose source interior contains `position`. Boundary ownership
    /// follows `affinity`; this is useful for directional movement.
    public func marker(containing position: Int, affinity: MarkerAffinity = .nearest) -> NSRange? {
        guard !ranges.isEmpty else { return nil }
        let p = min(max(0, position), sourceLength)
        let insertion = firstRangeStarting(atOrAfter: p)

        if insertion < ranges.count, ranges[insertion].location == p,
           affinity == .downstream {
            return ranges[insertion]
        }
        if insertion > 0 {
            let previous = ranges[insertion - 1]
            switch affinity {
            case .upstream where p > previous.location && p <= previous.upperBound:
                return previous
            case .nearest where p > previous.location && p < previous.upperBound:
                return previous
            case .downstream where p >= previous.location && p < previous.upperBound:
                return previous
            default:
                break
            }
        }
        return nil
    }

    /// Canonical source offset for a caret at a visually collapsed boundary.
    public func caretPosition(_ position: Int, affinity: MarkerAffinity) -> Int {
        let p = min(max(0, position), sourceLength)
        guard let range = marker(containing: p, affinity: affinity) else { return p }
        switch affinity {
        case .upstream:
            return range.location
        case .downstream:
            return range.upperBound
        case .nearest:
            return p - range.location < range.upperBound - p ? range.location : range.upperBound
        }
    }

    /// Expand a selection so it never owns only part of an invisible marker.
    public func atomicSelection(_ proposed: NSRange) -> NSRange {
        let clamped = clampedRange(proposed)
        guard clamped.length > 0, !ranges.isEmpty else { return clamped }
        var lower = clamped.location
        var upper = clamped.upperBound

        var index = max(0, firstRangeStarting(atOrAfter: lower) - 1)
        while index < ranges.count {
            let marker = ranges[index]
            if marker.location >= upper { break }
            if marker.upperBound > lower {
                lower = min(lower, marker.location)
                upper = max(upper, marker.upperBound)
            }
            index += 1
        }
        return NSRange(location: lower, length: upper - lower)
    }

    /// When all visible content inside a formatting construct is deleted,
    /// include its immediately surrounding hidden delimiters as one transaction.
    /// Repeating handles nested constructs such as bold text inside a link.
    public func balancedDeletionRange(_ proposed: NSRange) -> NSRange {
        var result = atomicSelection(proposed)
        guard result.length > 0 else { return result }

        while true {
            guard let leading = marker(endingAt: result.location),
                  let trailing = marker(startingAt: result.upperBound) else { break }
            result = NSRange(location: leading.location,
                             length: trailing.upperBound - leading.location)
        }
        return result
    }

    /// Source range of the composed visible character immediately before a
    /// caret. Hidden markers are crossed atomically.
    public func previousVisibleCharacter(before position: Int, in source: NSString) -> NSRange? {
        var cursor = caretPosition(position, affinity: .upstream)
        while cursor > 0 {
            if let marker = marker(containing: cursor, affinity: .upstream) {
                cursor = marker.location
                continue
            }
            let range = source.rangeOfComposedCharacterSequence(at: cursor - 1)
            if let marker = marker(containing: range.location, affinity: .downstream) {
                cursor = marker.location
                continue
            }
            return range
        }
        return nil
    }

    /// Source range of the composed visible character immediately after a
    /// caret. Hidden markers are crossed atomically.
    public func nextVisibleCharacter(after position: Int, in source: NSString) -> NSRange? {
        var cursor = caretPosition(position, affinity: .downstream)
        while cursor < min(source.length, sourceLength) {
            if let marker = marker(containing: cursor, affinity: .downstream) {
                cursor = marker.upperBound
                continue
            }
            let range = source.rangeOfComposedCharacterSequence(at: cursor)
            if let marker = marker(containing: range.location, affinity: .downstream) {
                cursor = marker.upperBound
                continue
            }
            return range
        }
        return nil
    }

    /// Visual UTF-16 offset corresponding to a canonical source offset.
    public func visibleOffset(forSourceOffset sourceOffset: Int) -> Int {
        let p = min(max(0, sourceOffset), sourceLength)
        guard !ranges.isEmpty else { return p }
        let insertion = firstRangeStarting(atOrAfter: p)
        var hidden = hiddenPrefix[insertion]
        if insertion > 0 {
            let previous = ranges[insertion - 1]
            if p < previous.upperBound {
                hidden -= previous.upperBound - p
            }
        }
        return p - hidden
    }

    /// Canonical source offset corresponding to a visual UTF-16 offset.
    public func sourceOffset(forVisibleOffset visibleOffset: Int,
                             affinity: MarkerAffinity = .downstream) -> Int {
        let v = min(max(0, visibleOffset), visibleLength)
        guard !ranges.isEmpty else { return v }

        let firstGreater = firstVisibleStart(greaterThan: v)
        if firstGreater > 0, visibleStarts[firstGreater - 1] == v {
            let range = ranges[firstGreater - 1]
            return affinity == .upstream ? range.location : range.upperBound
        }
        return min(sourceLength, v + hiddenPrefix[firstGreater])
    }

    public func visibleRange(forSourceRange range: NSRange) -> NSRange {
        let r = clampedRange(range)
        let lower = visibleOffset(forSourceOffset: r.location)
        let upper = visibleOffset(forSourceOffset: r.upperBound)
        return NSRange(location: lower, length: max(0, upper - lower))
    }

    public func sourceRange(forVisibleRange range: NSRange,
                            startAffinity: MarkerAffinity = .downstream,
                            endAffinity: MarkerAffinity = .upstream) -> NSRange {
        let lower = sourceOffset(forVisibleOffset: range.location, affinity: startAffinity)
        let upper = sourceOffset(forVisibleOffset: range.upperBound, affinity: endAffinity)
        return NSRange(location: lower, length: max(0, upper - lower))
    }

    /// The text a user can actually see inside `sourceRange`.
    public func visibleString(in sourceRange: NSRange, source: NSString) -> String {
        let selected = clampedRange(NSIntersectionRange(
            sourceRange,
            NSRange(location: 0, length: min(source.length, sourceLength))
        ))
        guard selected.length > 0 else { return "" }
        let output = NSMutableString(string: source.substring(with: selected))

        var index = firstRangeStarting(atOrAfter: selected.upperBound)
        while index > 0 {
            index -= 1
            let intersection = NSIntersectionRange(ranges[index], selected)
            if intersection.length > 0 {
                output.deleteCharacters(in: NSRange(location: intersection.location - selected.location,
                                                     length: intersection.length))
            }
            if ranges[index].upperBound <= selected.location { break }
        }
        return output as String
    }

    public func visibleString(in source: NSString) -> String {
        visibleString(in: NSRange(location: 0, length: min(source.length, sourceLength)), source: source)
    }

    private func clampedRange(_ range: NSRange) -> NSRange {
        guard range.location != NSNotFound else { return NSRange(location: sourceLength, length: 0) }
        let lower = min(max(0, range.location), sourceLength)
        let upper = min(max(lower, range.upperBound), sourceLength)
        return NSRange(location: lower, length: upper - lower)
    }

    private func marker(startingAt location: Int) -> NSRange? {
        let index = firstRangeStarting(atOrAfter: location)
        guard index < ranges.count, ranges[index].location == location else { return nil }
        return ranges[index]
    }

    private func marker(endingAt location: Int) -> NSRange? {
        let index = firstRangeStarting(atOrAfter: location)
        guard index > 0, ranges[index - 1].upperBound == location else { return nil }
        return ranges[index - 1]
    }

    private func firstRangeStarting(atOrAfter location: Int) -> Int {
        var lower = 0
        var upper = ranges.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if ranges[middle].location < location { lower = middle + 1 }
            else { upper = middle }
        }
        return lower
    }

    private func firstVisibleStart(greaterThan location: Int) -> Int {
        var lower = 0
        var upper = visibleStarts.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if visibleStarts[middle] <= location { lower = middle + 1 }
            else { upper = middle }
        }
        return lower
    }
}
