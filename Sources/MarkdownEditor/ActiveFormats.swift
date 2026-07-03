import Foundation
import MarkdownEngine

/// Which formats apply at the current selection — drives the floating
/// toolbar's active-button states. Pure logic, unit-testable.
public struct ActiveFormats: Equatable {
    public var bold = false
    public var italic = false
    public var strikethrough = false
    public var code = false
    public var link = false
    public var headingLevel: Int?
    public var list = false
    public var quote = false

    public init() {}

    /// Formats at `selection` within `parsed`. For a caret (empty selection),
    /// probes the character *before* it — matching how typing continues the
    /// format to the caret's left.
    public static func at(_ selection: NSRange, in parsed: ParsedMarkdown) -> ActiveFormats {
        var f = ActiveFormats()
        let probe: NSRange = selection.length > 0
            ? selection
            : NSRange(location: max(0, selection.location - 1), length: selection.location > 0 ? 1 : 0)

        for run in parsed.inlineRuns where NSIntersectionRange(run.range, probe).length > 0 {
            f.bold = f.bold || run.bold
            f.italic = f.italic || run.italic
            f.strikethrough = f.strikethrough || run.strikethrough
            f.code = f.code || run.code
            f.link = f.link || run.link != nil
        }
        for block in parsed.blockRuns where NSLocationInRange(selection.location, block.range) {
            switch block.kind {
            case .heading(let level): f.headingLevel = level
            case .listItem: f.list = true
            case .blockQuote: f.quote = true
            case .codeBlock: f.code = true
            default: break
            }
        }
        return f
    }
}
