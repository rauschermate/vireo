import Foundation
import Markdown

/// Converts swift-markdown `SourceLocation` (1-based line / byte-column) into
/// UTF-16 offsets suitable for `NSRange` / `NSAttributedString`.
///
/// cmark reports columns as 1-based **UTF-8 byte** offsets within a line, and
/// its `SourceRange.upperBound` is *inclusive* of the last character. We map to
/// UTF-16 offsets and return half-open `NSRange`s.
struct SourceMapping {
    private let utf16Length: Int
    /// Per-line starting UTF-8 byte offset (index 0 == line 1).
    private let lineStartUTF8: [Int]
    /// Character boundaries: parallel cumulative UTF-8 and UTF-16 counts.
    private let boundaryUTF8: [Int]
    private let boundaryUTF16: [Int]

    init(_ source: String) {
        var lineStarts: [Int] = [0]
        var b8: [Int] = [0]
        var b16: [Int] = [0]
        var u8 = 0
        var u16 = 0
        for ch in source {
            u8 += String(ch).utf8.count
            u16 += String(ch).utf16.count
            b8.append(u8)
            b16.append(u16)
            if ch == "\n" {
                lineStarts.append(u8)
            }
        }
        self.lineStartUTF8 = lineStarts
        self.boundaryUTF8 = b8
        self.boundaryUTF16 = b16
        self.utf16Length = u16
    }

    /// UTF-8 byte offset for a 1-based (line, column) pair.
    private func byteOffset(line: Int, column: Int) -> Int {
        guard line >= 1, line <= lineStartUTF8.count else {
            return line < 1 ? 0 : (boundaryUTF8.last ?? 0)
        }
        return lineStartUTF8[line - 1] + max(0, column - 1)
    }

    /// Nearest character-boundary UTF-16 offset for a UTF-8 byte offset.
    private func utf16(forByte byte: Int) -> Int {
        // binary search boundaryUTF8 for the largest value <= byte
        var lo = 0
        var hi = boundaryUTF8.count - 1
        if byte <= 0 { return 0 }
        if byte >= boundaryUTF8[hi] { return boundaryUTF16[hi] }
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if boundaryUTF8[mid] <= byte { lo = mid } else { hi = mid - 1 }
        }
        return boundaryUTF16[lo]
    }

    /// Convert a swift-markdown `SourceRange` (inclusive upper bound) to a
    /// half-open UTF-16 `NSRange`. Returns nil if the range is absent.
    func nsRange(_ range: SourceRange?) -> NSRange? {
        guard let range else { return nil }
        let startByte = byteOffset(line: range.lowerBound.line, column: range.lowerBound.column)
        // upperBound is inclusive of the final character's start column, so it
        // points at the last character; we extend to the end of that character.
        let endByte = byteOffset(line: range.upperBound.line, column: range.upperBound.column)
        let start = utf16(forByte: startByte)
        let end = utf16(forByte: endByte)
        let lo = min(start, end)
        let hi = max(start, end)
        return NSRange(location: lo, length: max(0, hi - lo))
    }

    var totalUTF16Length: Int { utf16Length }
}
