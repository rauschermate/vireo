import Foundation
import Markdown

/// Converts swift-markdown `SourceLocation` (1-based line / UTF-8 byte column)
/// into UTF-16 offsets suitable for `NSRange` / `NSAttributedString`.
///
/// Built in a single O(n) pass over the UTF-8 bytes (no per-character String
/// allocation). Per-line start offsets are stored in both encodings; within a
/// line, ASCII-only lines convert in O(1) and multibyte lines by a short byte
/// walk — cmark's `SourceRange.upperBound` is *inclusive* of the last
/// character, and we return half-open `NSRange`s.
struct SourceMapping {
    private let utf8Bytes: [UInt8]
    /// Per-line starting offsets (index 0 == line 1), parallel arrays.
    private let lineStartUTF8: [Int]
    private let lineStartUTF16: [Int]
    /// Whether the line contains only ASCII (fast column conversion).
    private let lineIsASCII: [Bool]
    private let utf16Length: Int

    init(_ source: String) {
        let bytes = Array(source.utf8)
        var startsUTF8: [Int] = [0]
        var startsUTF16: [Int] = [0]
        var ascii: [Bool] = []
        var lineHasMultibyte = false
        var u16 = 0

        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            if b & 0x80 == 0 {
                // ASCII
                u16 += 1
                if b == 0x0A { // '\n'
                    ascii.append(!lineHasMultibyte)
                    lineHasMultibyte = false
                    startsUTF8.append(i + 1)
                    startsUTF16.append(u16)
                }
                i += 1
            } else {
                lineHasMultibyte = true
                // Lead byte determines sequence length; 4-byte sequences are
                // surrogate pairs (2 UTF-16 units), everything else is 1.
                let seqLen: Int
                if b >= 0xF0 { seqLen = 4; u16 += 2 }
                else if b >= 0xE0 { seqLen = 3; u16 += 1 }
                else { seqLen = 2; u16 += 1 }
                i += seqLen
            }
        }
        ascii.append(!lineHasMultibyte) // final line (no trailing newline)

        self.utf8Bytes = bytes
        self.lineStartUTF8 = startsUTF8
        self.lineStartUTF16 = startsUTF16
        self.lineIsASCII = ascii
        self.utf16Length = u16
    }

    /// UTF-16 offset for a 1-based (line, UTF-8 byte column) pair.
    private func utf16Offset(line: Int, column: Int) -> Int {
        guard line >= 1 else { return 0 }
        guard line <= lineStartUTF8.count else { return utf16Length }
        let lineIdx = line - 1
        let byteInLine = max(0, column - 1)

        if lineIsASCII.indices.contains(lineIdx), lineIsASCII[lineIdx] {
            return min(lineStartUTF16[lineIdx] + byteInLine, utf16Length)
        }

        // Multibyte line: walk its bytes, counting UTF-16 units.
        var u16 = lineStartUTF16[lineIdx]
        var i = lineStartUTF8[lineIdx]
        let target = min(lineStartUTF8[lineIdx] + byteInLine, utf8Bytes.count)
        while i < target {
            let b = utf8Bytes[i]
            if b & 0x80 == 0 { u16 += 1; i += 1 }
            else if b >= 0xF0 { u16 += 2; i += 4 }
            else if b >= 0xE0 { u16 += 1; i += 3 }
            else { u16 += 1; i += 2 }
        }
        return min(u16, utf16Length)
    }

    /// Convert a swift-markdown `SourceRange` (inclusive upper bound) to a
    /// half-open UTF-16 `NSRange`. Returns nil if the range is absent.
    func nsRange(_ range: SourceRange?) -> NSRange? {
        guard let range else { return nil }
        let start = utf16Offset(line: range.lowerBound.line, column: range.lowerBound.column)
        let end = utf16Offset(line: range.upperBound.line, column: range.upperBound.column)
        let lo = min(start, end)
        let hi = max(start, end)
        return NSRange(location: lo, length: hi - lo)
    }

    var totalUTF16Length: Int { utf16Length }
}
