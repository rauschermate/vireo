import AppKit
import MarkdownEngine

/// Turns a source string + its `ParsedMarkdown` into styled attributed text
/// while preserving the source characters exactly. Syntax delimiters are
/// tagged for the layout manager to hide; drawn controls and media receive
/// semantic anchor attributes.
@MainActor
public struct MarkdownRenderer {
    public var theme: Theme
    public var baseURL: URL?
    public weak var imageLoader: ImageLoader?
    public var isDark: Bool
    /// When rendering a slice, its absolute document start. Position-carrying
    /// attributes such as table anchors remain in document coordinates.
    public var originOffset: Int = 0
    /// Extra height beneath the final table row for the editor's local scroller.
    /// Quick Look and snapshots retain the default zero value.
    public var tableScrollerGutter: CGFloat = 0
    /// List items whose subtrees are hidden, expressed as absolute anchors.
    public var collapsedAnchors: Set<Int> = []

    /// Huge fenced blocks retain coherent code presentation but skip the regex
    /// token pass so a structural edit cannot synchronously color megabytes.
    public static let syntaxHighlightingUTF16Limit = 262_144

    public init(theme: Theme, baseURL: URL? = nil,
                imageLoader: ImageLoader? = nil, isDark: Bool = false) {
        self.theme = theme
        self.baseURL = baseURL
        self.imageLoader = imageLoader
        self.isDark = isDark
    }

    public func render(source: String,
                       parsed: ParsedMarkdown) -> NSAttributedString {
        let signpost = VireoPerformanceTrace.begin("Attributed Render")
        defer { VireoPerformanceTrace.end("Attributed Render", signpost) }
        let plan = RenderPlan(source: source, parsed: parsed, theme: theme,
                              baseURL: baseURL, imageLoader: imageLoader,
                              isDark: isDark,
                              tableScrollerGutter: tableScrollerGutter,
                              originOffset: originOffset,
                              collapsedAnchors: collapsedAnchors)
        return plan.materialize(source: source)
    }

    /// Apply the same plan directly to live text storage. `source` and `parsed`
    /// may describe a local slice; `targetOffset` locates it in the target.
    /// This avoids building an intermediate attributed string and enumerating
    /// its attributes back into storage on every editor restyle.
    public func apply(source: String, parsed: ParsedMarkdown,
                      to text: NSMutableAttributedString,
                      at targetOffset: Int = 0) {
        let signpost = VireoPerformanceTrace.begin("Style Application")
        defer { VireoPerformanceTrace.end("Style Application", signpost) }
        let sourceLength = (source as NSString).length
        guard sourceLength > 0, targetOffset >= 0,
              targetOffset + sourceLength <= text.length else { return }
        let plan = RenderPlan(source: source, parsed: parsed, theme: theme,
                              baseURL: baseURL, imageLoader: imageLoader,
                              isDark: isDark,
                              tableScrollerGutter: tableScrollerGutter,
                              originOffset: originOffset,
                              collapsedAnchors: collapsedAnchors)
        plan.apply(to: text, at: targetOffset)
    }
}
