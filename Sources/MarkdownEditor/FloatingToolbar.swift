import AppKit

/// A small formatting toolbar that floats near the current text selection
/// (PRD §2). Rendered on a translucent material panel in the spirit of the
/// Liquid Glass chrome (eng-design §8.0). Buttons drive the same
/// `EditorController` commands as the menu and keyboard shortcuts.
@MainActor
final class FloatingToolbar {
    private var panel: NSPanel?
    private weak var controller: EditorController?

    init(controller: EditorController) {
        self.controller = controller
    }

    private struct Item { let symbol: String; let help: String; let action: (EditorController) -> Void }

    private let items: [Item] = [
        Item(symbol: "bold", help: "Bold") { $0.toggleBold() },
        Item(symbol: "italic", help: "Italic") { $0.toggleItalic() },
        Item(symbol: "strikethrough", help: "Strikethrough") { $0.toggleStrikethrough() },
        Item(symbol: "chevron.left.forwardslash.chevron.right", help: "Inline Code") { $0.toggleInlineCode() },
        Item(symbol: "textformat.size.larger", help: "Heading") { $0.makeHeading(2) },
        Item(symbol: "list.bullet", help: "List") { $0.toggleBulletList() },
        Item(symbol: "text.quote", help: "Quote") { $0.toggleQuote() },
        Item(symbol: "link", help: "Link") { $0.insertLink() },
    ]

    /// Show above the given selection rect (screen coordinates), or hide if empty.
    func update(selectionRect: NSRect?, hasSelection: Bool) {
        guard hasSelection, let rect = selectionRect else { hide(); return }
        let panel = panel ?? makePanel()
        self.panel = panel
        let size = panel.frame.size
        let x = rect.midX - size.width / 2
        let y = rect.maxY + 8
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        if !panel.isVisible { panel.orderFront(nil) }
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 6, bottom: 4, right: 6)
        for item in items {
            let button = NSButton()
            button.image = NSImage(systemSymbolName: item.symbol, accessibilityDescription: item.help)
            button.bezelStyle = .accessoryBarAction
            button.isBordered = false
            button.toolTip = item.help
            button.setButtonType(.momentaryChange)
            button.target = self
            button.action = #selector(buttonTapped(_:))
            button.tag = items.firstIndex { $0.help == item.help } ?? 0
            button.contentTintColor = .labelColor
            stack.addArrangedSubview(button)
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
        panel.hidesOnDeactivate = false
        return panel
    }

    @objc private func buttonTapped(_ sender: NSButton) {
        guard let controller, items.indices.contains(sender.tag) else { return }
        items[sender.tag].action(controller)
    }
}
