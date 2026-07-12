import Foundation

/// Sorted, coalesced UTF-16 ranges with O(log n) point lookup. Besides making
/// arrow exclusions cheap, coalescing identical marker mutations materially
/// reduces attributed-string churn on delimiter-dense documents.
struct RangeSet {
    let ranges: [NSRange]

    init(_ input: [NSRange]) {
        let sorted = input.filter { $0.length > 0 }
            .sorted { lhs, rhs in
                lhs.location == rhs.location ? lhs.length < rhs.length
                    : lhs.location < rhs.location
            }
        var output: [NSRange] = []
        output.reserveCapacity(sorted.count)
        for range in sorted {
            guard let last = output.last else {
                output.append(range)
                continue
            }
            if range.location <= last.upperBound {
                output[output.count - 1] = NSRange(
                    location: last.location,
                    length: max(last.upperBound, range.upperBound) - last.location
                )
            } else {
                output.append(range)
            }
        }
        ranges = output
    }

    func contains(_ location: Int) -> Bool {
        var low = 0
        var high = ranges.count
        while low < high {
            let mid = (low + high) / 2
            if ranges[mid].upperBound <= location { low = mid + 1 }
            else { high = mid }
        }
        guard low < ranges.count else { return false }
        return NSLocationInRange(location, ranges[low])
    }
}
