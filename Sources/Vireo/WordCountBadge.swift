import SwiftUI
import VireoCore

/// The word and character count that floats in the document's bottom-right
/// corner while the preference is on.
struct WordCountBadge: View {
    let statistics: TextStatistics

    var body: some View {
        Text(label)
            .font(.system(size: 11))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor).opacity(0.88))
            )
            .allowsHitTesting(false)
            .accessibilityLabel(label)
    }

    private var label: String {
        let words = statistics.words == 1 ? "word" : "words"
        let characters = statistics.characters == 1 ? "character" : "characters"
        return "\(statistics.words.formatted()) \(words) · \(statistics.characters.formatted()) \(characters)"
    }
}
