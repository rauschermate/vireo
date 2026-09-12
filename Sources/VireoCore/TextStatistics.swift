import Foundation

/// Word and character counts of a document's source text.
public struct TextStatistics: Equatable, Sendable {
    public let words: Int
    public let characters: Int

    public init(words: Int, characters: Int) {
        self.words = words
        self.characters = characters
    }

    /// Words follow the system's word-break rules, so markdown punctuation
    /// such as `#`, `*`, and `-` never counts. Characters are user-perceived
    /// characters of the raw source, syntax included.
    public static func measure(_ text: String) -> TextStatistics {
        var words = 0
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex,
                                 options: [.byWords, .substringNotRequired]) { _, _, _, _ in
            words += 1
        }
        return TextStatistics(words: words, characters: text.count)
    }
}
