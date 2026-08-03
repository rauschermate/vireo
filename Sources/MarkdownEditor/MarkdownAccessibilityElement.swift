import AppKit

/// Stable virtual accessibility element for controls drawn by TextKit rather
/// than backed by NSViews. MarkdownTextView owns and reuses these while the
/// document is alive so VoiceOver focus does not jump on every layout pass.
final class MarkdownAccessibilityElement: NSAccessibilityElement {
    // AppKit dispatches accessibility actions on the UI thread, but the legacy
    // NSAccessibility protocol is not actor-annotated in the SDK.
    nonisolated(unsafe) var performPress: (() -> Bool)?

    override func accessibilityPerformPress() -> Bool {
        performPress?() ?? false
    }
}
