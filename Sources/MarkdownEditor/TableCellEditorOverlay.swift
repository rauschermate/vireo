import AppKit
import MarkdownEngine
import MarkdownRender

enum TableCellNavigation {
    case finish
    case next
    case previous
    case down
}

enum TableEditAction: Int {
    case insertRowAbove = 1
    case insertRowBelow
    case deleteRow
    case insertColumnLeft
    case insertColumnRight
    case deleteColumn
    case alignLeft
    case alignCenter
    case alignRight
    case deleteTable
}

struct TableMenuState {
    var rowCount: Int
    var columnCount: Int
    var alignment: TableAlignment
}

/// A single native field mounted directly over the active drawn table cell.
/// Only one exists at a time, keeping a large document light while preserving
/// familiar spreadsheet keyboard behavior.
@MainActor
final class TableCellEditorOverlay: NSView, NSTextFieldDelegate {
    let cellID: TableCellID
    let originalText: String
    private let field = NSTextField()
    private let menuButton = NSButton()
    private let menuState: TableMenuState
    private var isFinishing = false

    var onCommit: ((String, TableCellNavigation) -> Void)?
    var onCancel: (() -> Void)?
    var onAction: ((String, TableEditAction) -> Void)?
    var currentText: String { field.stringValue }

    override var isFlipped: Bool { true }

    init(geometry: TableCellGeometry, text: String, state: TableMenuState,
         theme: Theme) {
        cellID = geometry.id
        originalText = text
        menuState = state
        super.init(frame: geometry.rect.insetBy(dx: 1, dy: 0))

        wantsLayer = true
        layer?.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.98).cgColor
        layer?.borderColor = NSColor.controlAccentColor.cgColor
        layer?.borderWidth = 2
        layer?.cornerRadius = 4

        field.stringValue = text
        field.placeholderString = "Empty cell"
        field.font = geometry.isHeader ? theme.tableHeaderFont : theme.tableFont
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.lineBreakMode = .byTruncatingTail
        field.usesSingleLineMode = true
        field.delegate = self
        field.setAccessibilityLabel(geometry.isHeader
            ? "Header, column \(geometry.id.column + 1)"
            : "Row \(geometry.id.row + 1), column \(geometry.id.column + 1)")
        switch geometry.alignment {
        case .center: field.alignment = .center
        case .right: field.alignment = .right
        default: field.alignment = .left
        }
        addSubview(field)

        menuButton.image = NSImage(systemSymbolName: "ellipsis.circle",
                                   accessibilityDescription: "Table cell actions")
        menuButton.isBordered = false
        menuButton.imagePosition = .imageOnly
        menuButton.contentTintColor = .secondaryLabelColor
        menuButton.refusesFirstResponder = true
        menuButton.target = self
        menuButton.action = #selector(showActions(_:))
        menuButton.toolTip = "Table cell actions"
        addSubview(menuButton)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        let buttonWidth: CGFloat = 40
        field.frame = NSRect(x: 8, y: 2,
                             width: max(20, bounds.width - buttonWidth - 10),
                             height: max(20, bounds.height - 4))
        menuButton.frame = NSRect(x: bounds.width - buttonWidth, y: 0,
                                  width: buttonWidth, height: bounds.height)
    }

    func update(geometry: TableCellGeometry) {
        frame = geometry.rect.insetBy(dx: 1, dy: 0)
        needsLayout = true
    }

    func beginEditing(selectAll: Bool) {
        guard let window else { return }
        window.makeFirstResponder(field)
        if selectAll {
            field.selectText(nil)
        } else if let editor = field.currentEditor() {
            editor.selectedRange = NSRange(location: (field.stringValue as NSString).length,
                                           length: 0)
        }
    }

    func insertText(_ text: String) {
        if let editor = field.currentEditor() {
            editor.insertText(text)
        } else {
            field.stringValue += text
        }
    }

    func finishWithoutCallback() {
        isFinishing = true
        field.abortEditing()
        removeFromSuperview()
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard !isFinishing else { return }
        isFinishing = true
        onCommit?(field.stringValue, .finish)
    }

    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy commandSelector: Selector) -> Bool {
        let navigation: TableCellNavigation?
        switch commandSelector {
        case #selector(NSResponder.insertTab(_:)): navigation = .next
        case #selector(NSResponder.insertBacktab(_:)): navigation = .previous
        case #selector(NSResponder.insertNewline(_:)): navigation = .down
        case #selector(NSResponder.cancelOperation(_:)):
            isFinishing = true
            onCancel?()
            return true
        default: navigation = nil
        }
        guard let navigation else { return false }
        isFinishing = true
        onCommit?(field.stringValue, navigation)
        return true
    }

    @objc private func showActions(_ sender: NSButton) {
        let menu = NSMenu(title: "Table")
        add("Add Row Above", .insertRowAbove, to: menu)
        add("Add Row Below", .insertRowBelow, to: menu)
        let deleteRow = add("Delete Row", .deleteRow, to: menu)
        deleteRow.isEnabled = cellID.row > 0
        menu.addItem(.separator())
        add("Add Column Left", .insertColumnLeft, to: menu)
        add("Add Column Right", .insertColumnRight, to: menu)
        let deleteColumn = add("Delete Column", .deleteColumn, to: menu)
        deleteColumn.isEnabled = menuState.columnCount > 1
        menu.addItem(.separator())

        let alignment = NSMenu(title: "Alignment")
        for (title, action, value) in [
            ("Align Left", TableEditAction.alignLeft, TableAlignment.left),
            ("Align Center", .alignCenter, .center),
            ("Align Right", .alignRight, .right),
        ] {
            let item = add(title, action, to: alignment)
            item.state = menuState.alignment == value ? .on : .off
        }
        let alignmentItem = NSMenuItem(title: "Alignment", action: nil, keyEquivalent: "")
        alignmentItem.submenu = alignment
        menu.addItem(alignmentItem)
        menu.addItem(.separator())
        let deleteTable = add("Delete Table", .deleteTable, to: menu)
        deleteTable.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
        menu.popUp(positioning: nil,
                   at: NSPoint(x: sender.bounds.midX, y: sender.bounds.maxY + 2),
                   in: sender)
    }

    @discardableResult
    private func add(_ title: String, _ action: TableEditAction,
                     to menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(runAction(_:)), keyEquivalent: "")
        item.target = self
        item.tag = action.rawValue
        menu.addItem(item)
        return item
    }

    @objc private func runAction(_ sender: NSMenuItem) {
        guard let action = TableEditAction(rawValue: sender.tag) else { return }
        isFinishing = true
        onAction?(field.stringValue, action)
    }
}
