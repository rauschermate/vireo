import AppKit

/// A small formatting toolbar that floats near the current text selection
/// (PRD §2). Rendered on a translucent material panel in the spirit of the
/// Liquid Glass chrome (eng-design §8.0). Buttons drive the same
/// `EditorController` commands as the menu and keyboard shortcuts.
@MainActor
final class FloatingToolbar {
    enum Context {
        case document
        case tableCell
    }

    private var panel: NSPanel?
    private weak var controller: EditorController?
    private var context: Context?
    private(set) var isPresented = false
    var presentedContext: Context? { context }

    init(controller: EditorController) {
        self.controller = controller
    }

    private struct Item {
        var symbol: String?           // SF Symbol…
        var title: String?            // …or a short text label (H1/H2/H3)
        var help: String
        var separatorAfter = false
        var isActive: (ActiveFormats) -> Bool = { _ in false }
        var action: (EditorController) -> Void
    }

    private var activeItems: [Item] = []

    private func items(for context: Context) -> [Item] {
        let inline = [
            Item(symbol: "bold", help: "Bold",
                 isActive: { $0.bold }) { $0.toggleBold() },
            Item(symbol: "italic", help: "Italic",
                 isActive: { $0.italic }) { $0.toggleItalic() },
            Item(symbol: "strikethrough", help: "Strikethrough",
                 isActive: { $0.strikethrough }) { $0.toggleStrikethrough() },
            Item(symbol: "chevron.left.forwardslash.chevron.right",
                 help: "Inline Code", isActive: { $0.code }) {
                $0.toggleInlineCode()
            },
        ]
        guard context == .document else { return inline }
        return [
            Item(title: "H1", help: "Heading 1",
                 isActive: { $0.headingLevel == 1 }) { $0.makeHeading(1) },
            Item(title: "H2", help: "Heading 2",
                 isActive: { $0.headingLevel == 2 }) { $0.makeHeading(2) },
            Item(title: "H3", help: "Heading 3", separatorAfter: true,
                 isActive: { $0.headingLevel == 3 }) { $0.makeHeading(3) },
        ] + inline.enumerated().map { index, item in
            var item = item
            if index == inline.count - 1 { item.separatorAfter = true }
            return item
        } + [
            Item(symbol: "list.bullet", help: "List",
                 isActive: { $0.list }) { $0.toggleBulletList() },
            Item(symbol: "text.quote", help: "Quote",
                 isActive: { $0.quote }) { $0.toggleQuote() },
            Item(symbol: "link", help: "Link",
                 isActive: { $0.link }) { $0.insertLink() },
        ]
    }

    private var buttons: [NSButton] = []

    private let buttonSize: CGFloat = 30
    private let symbolConfig = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)

    /// Show above the given selection rect (screen coordinates), or hide if empty.
    func update(selectionRect: NSRect?, hasSelection: Bool,
                active: ActiveFormats = ActiveFormats(),
                context: Context = .document) {
        guard hasSelection, let rect = selectionRect else { hide(); return }
        if self.context != context {
            panel?.orderOut(nil)
            panel = nil
            buttons.removeAll(keepingCapacity: true)
            activeItems = items(for: context)
            self.context = context
        }
        let panel = panel ?? makePanel()
        self.panel = panel
        applyActiveStates(active)
        let size = panel.frame.size
        let x = rect.midX - size.width / 2
        let y = rect.maxY + 8
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        if !panel.isVisible { panel.orderFront(nil) }
        isPresented = true
    }

    private func applyActiveStates(_ active: ActiveFormats) {
        for button in buttons {
            guard activeItems.indices.contains(button.tag) else { continue }
            let item = activeItems[button.tag]
            let isOn = item.isActive(active)
            button.contentTintColor = isOn ? .controlAccentColor : .labelColor
            if let title = item.title {
                button.attributedTitle = NSAttributedString(
                    string: title,
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                        .foregroundColor: isOn ? NSColor.controlAccentColor : NSColor.labelColor,
                    ])
            }
        }
    }

    func hide() {
        panel?.orderOut(nil)
        isPresented = false
    }

    private func makePanel() -> NSPanel {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 3
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        for (index, item) in activeItems.enumerated() {
            let button = NSButton()
            if let symbol = item.symbol {
                button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: item.help)?
                    .withSymbolConfiguration(symbolConfig)
            } else if let title = item.title {
                button.title = title
                button.font = .systemFont(ofSize: 13, weight: .semibold)
            }
            button.bezelStyle = .accessoryBarAction
            button.isBordered = false
            button.toolTip = item.help
            button.setButtonType(.momentaryChange)
            button.target = self
            button.action = #selector(buttonTapped(_:))
            button.tag = index
            button.contentTintColor = .labelColor
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: buttonSize).isActive = true
            button.heightAnchor.constraint(equalToConstant: buttonSize).isActive = true
            stack.addArrangedSubview(button)
            buttons.append(button)

            if item.separatorAfter {
                let line = NSBox()
                line.boxType = .separator
                line.translatesAutoresizingMaskIntoConstraints = false
                line.heightAnchor.constraint(equalToConstant: buttonSize - 12).isActive = true
                stack.addArrangedSubview(line)
            }
        }
        stack.layoutSubtreeIfNeeded()
        let size = stack.fittingSize

        // Liquid Glass on macOS 26+ (eng-design §8.0); material fallback below.
        let effect: NSView
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: NSRect(origin: .zero, size: size))
            glass.cornerRadius = 9
            stack.frame = glass.bounds
            glass.contentView = stack
            effect = glass
        } else {
            let visual = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
            visual.material = .hudWindow
            visual.blendingMode = .behindWindow
            visual.state = .active
            visual.wantsLayer = true
            visual.layer?.cornerRadius = 9
            visual.layer?.masksToBounds = true
            stack.frame = visual.bounds
            stack.autoresizingMask = [.width, .height]
            visual.addSubview(stack)
            effect = visual
        }

        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.nonactivatingPanel, .borderless],
                            backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.contentView = effect
        // Float above Vireo only — hide when the app deactivates (AppKit
        // restores it on reactivation while the selection persists).
        panel.hidesOnDeactivate = true
        return panel
    }

    @objc private func buttonTapped(_ sender: NSButton) {
        guard let controller, activeItems.indices.contains(sender.tag) else { return }
        activeItems[sender.tag].action(controller)
    }
}
