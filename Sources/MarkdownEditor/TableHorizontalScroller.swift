import AppKit
import MarkdownRender

/// One lightweight native scroller per visible overflowing table. The table
/// remains TextKit-drawn; this control only exposes and manipulates its offset.
@MainActor
final class TableHorizontalScroller: NSScroller {
    let tableAnchor: Int
    var onRequestOffset: ((CGFloat) -> Void)?

    private var currentOffset: CGFloat = 0
    private var maxOffset: CGFloat = 0
    private var viewportWidth: CGFloat = 0

    init(tableAnchor: Int) {
        self.tableAnchor = tableAnchor
        super.init(frame: .zero)
        scrollerStyle = .overlay
        controlSize = .small
        target = self
        action = #selector(valueChanged(_:))
        setAccessibilityLabel("Scroll table horizontally")
        toolTip = "Scroll table horizontally"
    }

    required init?(coder: NSCoder) { nil }

    func update(geometry: TableScrollGeometry, frame: NSRect) {
        currentOffset = geometry.offset
        maxOffset = geometry.maxOffset
        viewportWidth = geometry.viewportRect.width
        self.frame = frame
        knobProportion = geometry.contentWidth > 0
            ? min(1, geometry.viewportRect.width / geometry.contentWidth)
            : 1
        doubleValue = maxOffset > 0 ? Double(currentOffset / maxOffset) : 0
        isHidden = !geometry.isOverflowing
    }

    @objc private func valueChanged(_ sender: NSScroller) {
        let line = min(48, max(24, viewportWidth * 0.1))
        let page = max(line, viewportWidth * 0.8)
        let proposed: CGFloat
        switch hitPart {
        case .decrementLine: proposed = currentOffset - line
        case .incrementLine: proposed = currentOffset + line
        case .decrementPage: proposed = currentOffset - page
        case .incrementPage: proposed = currentOffset + page
        case .knob, .knobSlot:
            proposed = CGFloat(doubleValue) * maxOffset
        default:
            return
        }
        onRequestOffset?(min(max(0, proposed), maxOffset))
    }
}
