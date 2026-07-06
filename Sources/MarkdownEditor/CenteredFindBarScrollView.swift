import AppKit

/// Scroll view that aligns the AppKit find bar with the centered reading column:
/// the bar's background spans the full pane width (as a normal find bar does),
/// but the search field + controls are centered to the content column and the
/// field's left edge sits flush with the body text.
///
/// The find bar's private view tree is:
/// ```
/// NSTextFinderBarView (findBarView, full width)
///   NSBannerView (sizes to hug its content)
///     …background views…
///     NSStackView  ← the controls row (search field, nav, Done)
/// ```
/// `NSScrollView.tile()` lays this out; we re-run after it to (1) stretch the
/// banner + its background layers to the full pane width and (2) inset the
/// control `NSStackView`s to the reading column via their `edgeInsets` — the
/// arranged controls are constraint-pinned to the banner, so setting their
/// frames doesn't survive Auto Layout, but `edgeInsets` is honoured by the
/// stack's own layout. `tile()` fires on every resize and when the bar is
/// shown/hidden, so the alignment holds.
final class CenteredFindBarScrollView: NSScrollView {
    /// The reading column's max width (`EditorController.contentColumnMaxWidth`).
    var columnMaxWidth: () -> CGFloat = { .greatestFiniteMagnitude }
    /// The minimum side gutter, matched to the text container's inset.
    var minSideInset: CGFloat = 24
    /// The text container's `lineFragmentPadding` — the field is shifted in by
    /// this so its text lines up with the body glyphs, not the container edge.
    var textLeadingPadding: CGFloat = 8

    override func tile() {
        super.tile()
        guard isFindBarVisible, let bar = findBarView else { return }
        let available = bounds.width
        let column = min(available, columnMaxWidth())
        let side = max(minSideInset, (available - column) / 2)
        let contentWidth = available - side * 2
        guard contentWidth > 0 else { return }

        _ = contentWidth
        // AppKit sizes the banner (background + controls) to hug its content.
        // Stretch the banner and its background layers to the full pane width so
        // the find bar reads as a normal edge-to-edge bar…
        if let banner = bar.subviews.first {
            setFullWidth(banner, available)
            for sub in banner.subviews where !(sub is NSStackView) {
                setFullWidth(sub, available)
            }
        }

        // …then inset the control rows to the reading column via the stack's own
        // `edgeInsets` (its arranged views are constraint-pinned to the banner,
        // so setting frames doesn't survive — edgeInsets is respected by the
        // stack's layout). The extra `textLeadingPadding` on the left lands the
        // search field's text flush with the body glyphs.
        for row in controlRows(in: bar) {
            let want = NSEdgeInsets(top: row.edgeInsets.top,
                                    left: side + textLeadingPadding,
                                    bottom: row.edgeInsets.bottom,
                                    right: side)
            if abs(row.edgeInsets.left - want.left) > 0.5 || abs(row.edgeInsets.right - want.right) > 0.5 {
                row.edgeInsets = want
            }
        }
    }

    /// Stretch a view to span `[0, width)` horizontally, preserving y/height.
    private func setFullWidth(_ v: NSView, _ width: CGFloat) {
        if abs(v.frame.origin.x) > 0.5 || abs(v.frame.size.width - width) > 0.5 {
            var f = v.frame
            f.origin.x = 0
            f.size.width = width
            v.frame = f
        }
    }

    /// Visible control rows (search row; replace row when shown) inside the banner.
    private func controlRows(in bar: NSView) -> [NSStackView] {
        var out: [NSStackView] = []
        func walk(_ v: NSView) {
            for s in v.subviews {
                if let stack = s as? NSStackView, !stack.isHidden { out.append(stack) }
                else { walk(s) }
            }
        }
        walk(bar)
        return out
    }

}
