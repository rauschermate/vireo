import Foundation
import MarkdownEngine

struct ListGuideEntry: Equatable {
    let anchor: Int
    let subtree: NSRange
    let markerText: String?
    /// Anchor-through-subtree interval used for viewport queries.
    let queryRange: NSRange
}

/// Balanced interval tree for list guides. A long-lived parent may begin far
/// above the viewport while its subtree intersects it, so indexing anchors
/// alone is insufficient. Each node retains the intervals crossing its center
/// in both start and end order, making viewport lookup O(log n + k).
struct ListGuideIndex {
    private final class Node {
        let center: Int
        let byStart: [ListGuideEntry]
        let byEndDescending: [ListGuideEntry]
        let left: Node?
        let right: Node?

        init(_ entries: [ListGuideEntry]) {
            let midpoints = entries.map {
                $0.queryRange.location + $0.queryRange.length / 2
            }.sorted()
            center = midpoints[midpoints.count / 2]

            var leftEntries: [ListGuideEntry] = []
            var rightEntries: [ListGuideEntry] = []
            var crossing: [ListGuideEntry] = []
            for entry in entries {
                if entry.queryRange.upperBound <= center {
                    leftEntries.append(entry)
                } else if entry.queryRange.location > center {
                    rightEntries.append(entry)
                } else {
                    crossing.append(entry)
                }
            }
            byStart = crossing.sorted(by: Self.startsBefore)
            byEndDescending = crossing.sorted {
                if $0.queryRange.upperBound == $1.queryRange.upperBound {
                    return Self.startsBefore($0, $1)
                }
                return $0.queryRange.upperBound > $1.queryRange.upperBound
            }
            left = leftEntries.isEmpty ? nil : Node(leftEntries)
            right = rightEntries.isEmpty ? nil : Node(rightEntries)
        }

        func appendOverlaps(with window: NSRange, to result: inout [ListGuideEntry]) {
            if window.upperBound <= center {
                for entry in byStart {
                    guard entry.queryRange.location < window.upperBound else { break }
                    result.append(entry)
                }
                left?.appendOverlaps(with: window, to: &result)
            } else if window.location >= center {
                for entry in byEndDescending {
                    guard entry.queryRange.upperBound > window.location else { break }
                    result.append(entry)
                }
                right?.appendOverlaps(with: window, to: &result)
            } else {
                result.append(contentsOf: byStart)
                left?.appendOverlaps(with: window, to: &result)
                right?.appendOverlaps(with: window, to: &result)
            }
        }

        private static func startsBefore(_ lhs: ListGuideEntry,
                                         _ rhs: ListGuideEntry) -> Bool {
            if lhs.queryRange.location == rhs.queryRange.location {
                return lhs.queryRange.upperBound < rhs.queryRange.upperBound
            }
            return lhs.queryRange.location < rhs.queryRange.location
        }
    }

    private let root: Node?

    init(listMarkers: [ListMarker], tasks: [TaskMark]) {
        var values: [ListGuideEntry] = []
        values.reserveCapacity(listMarkers.count + tasks.count)
        for marker in listMarkers {
            guard let subtree = marker.subtreeRange else { continue }
            values.append(Self.entry(anchor: marker.anchor, subtree: subtree,
                                     markerText: marker.text))
        }
        for task in tasks {
            guard let subtree = task.subtreeRange else { continue }
            values.append(Self.entry(anchor: task.anchor, subtree: subtree,
                                     markerText: nil))
        }
        root = values.isEmpty ? nil : Node(values)
    }

    func overlapping(_ window: NSRange) -> [ListGuideEntry] {
        guard window.length > 0 else { return [] }
        var result: [ListGuideEntry] = []
        root?.appendOverlaps(with: window, to: &result)
        return result.sorted {
            if $0.queryRange.location == $1.queryRange.location {
                return $0.queryRange.upperBound < $1.queryRange.upperBound
            }
            return $0.queryRange.location < $1.queryRange.location
        }
    }

    private static func entry(anchor: Int, subtree: NSRange,
                              markerText: String?) -> ListGuideEntry {
        let start = min(anchor, subtree.location)
        return ListGuideEntry(anchor: anchor, subtree: subtree,
                              markerText: markerText,
                              queryRange: NSRange(location: start,
                                                  length: subtree.upperBound - start))
    }
}
