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
    private let theme: Theme
    private let baseFont: NSFont
    private var markdownText: String
    private var isFinishing = false
    private var hasBegunEditing = false
    private var isActivatingEditor = false
    private weak var observedEditor: NSTextView?

    var onCommit: ((String, TableCellNavigation) -> Void)?
    var onCancel: (() -> Void)?
    var onAction: ((String, TableEditAction) -> Void)?
    var onSelectionChange: ((NSRect?, Bool, ActiveFormats) -> Void)?
    var currentText: String { field.stringValue }
    var currentMarkdown: String {
        syncMarkdownWithVisibleText()
        return markdownText
    }

    override var isFlipped: Bool { true }

    init(geometry: TableCellGeometry, markdown: String, state: TableMenuState,
         theme: Theme) {
        let text = EditableMarkdownTable.visibleText(fromMarkdown: markdown)
        cellID = geometry.id
        originalText = text
        menuState = state
        self.theme = theme
        baseFont = geometry.isHeader ? theme.tableHeaderFont : theme.tableFont
        markdownText = markdown
        super.init(frame: geometry.rect.insetBy(dx: 1, dy: 0))

        wantsLayer = true
        layer?.borderWidth = 2
        layer?.cornerRadius = 4

        field.stringValue = text
        field.placeholderString = "Empty cell"
        field.font = baseFont
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
        updateAppearanceColors()
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

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateAppearanceColors()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearanceColors()
    }

    private func updateAppearanceColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.textBackgroundColor
                .withAlphaComponent(0.98).cgColor
            layer?.borderColor = NSColor.controlAccentColor.cgColor
            menuButton.contentTintColor = NSColor.secondaryLabelColor
            refreshFieldPresentation()
        }
    }

    func update(geometry: TableCellGeometry) {
        frame = geometry.rect.insetBy(dx: 1, dy: 0)
        needsLayout = true
    }

    func beginEditing(selectAll: Bool) {
        // A table click arrives while NSTextView is still processing its own
        // mouse-down. Moving the field editor synchronously can be undone by
        // that event, producing an immediate end-editing callback. Activate on
        // the next run-loop turn, after the text view has finished tracking.
        requestEditorActivation(selectAll: selectAll, attempt: 0)
    }

    private func requestEditorActivation(selectAll: Bool, attempt: Int) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let window, superview != nil, !isFinishing else { return }
            isActivatingEditor = true
            let accepted = window.makeFirstResponder(field)
            if accepted, let editor = field.currentEditor() as? NSTextView {
                hasBegunEditing = true
                let length = (field.stringValue as NSString).length
                let selection = selectAll
                    ? NSRange(location: 0, length: length)
                    : NSRange(location: length, length: 0)
                beginObservingSelection(in: editor)
                refreshFieldPresentation(in: editor, preserving: selection)
                publishSelection(from: editor)
            } else {
                hasBegunEditing = false
            }
            isActivatingEditor = false
            if !hasBegunEditing, attempt < 2 {
                requestEditorActivation(selectAll: selectAll, attempt: attempt + 1)
            }
        }
    }

    private func syncMarkdownWithVisibleText() {
        markdownText = EditableMarkdownTable.updating(
            markdown: markdownText, toVisibleText: field.stringValue
        )
    }

    private func refreshFieldPresentation(in editor: NSTextView? = nil,
                                          preserving explicitSelection: NSRange? = nil) {
        syncMarkdownWithVisibleText()
        let visible = field.stringValue
        let full = NSRange(location: 0, length: (visible as NSString).length)
        let presentation = NSMutableAttributedString(
            string: visible,
            attributes: [.font: baseFont, .foregroundColor: NSColor.labelColor]
        )
        let parsed = MarkdownParser().parse(markdownText)
        for run in parsed.inlineRuns {
            let visibleRun = NSIntersectionRange(
                EditableMarkdownTable.visibleRange(forSourceRange: run.range,
                                                   in: markdownText),
                full
            )
            guard visibleRun.length > 0 else { continue }
            if run.code {
                presentation.addAttributes([
                    .font: theme.codeFont,
                    .foregroundColor: theme.codeColor,
                    .backgroundColor: theme.codeBackground,
                ], range: visibleRun)
            } else if run.bold || run.italic {
                var font = baseFont
                if run.bold {
                    font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
                }
                if run.italic {
                    font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
                }
                presentation.addAttribute(.font, value: font, range: visibleRun)
            }
            if run.strikethrough {
                presentation.addAttribute(
                    .strikethroughStyle,
                    value: NSUnderlineStyle.single.rawValue,
                    range: visibleRun
                )
            }
            if run.link != nil {
                presentation.addAttributes([
                    .foregroundColor: NSColor.linkColor,
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                ], range: visibleRun)
            }
        }

        if let editor = editor ?? (field.currentEditor() as? NSTextView) {
            let selection = clampedSelection(
                explicitSelection ?? editor.selectedRange, length: full.length
            )
            editor.textStorage?.setAttributedString(presentation)
            editor.selectedRange = selection
        } else {
            field.attributedStringValue = presentation
        }
    }

    private func clampedSelection(_ selection: NSRange, length: Int) -> NSRange {
        guard selection.location != NSNotFound else {
            return NSRange(location: length, length: 0)
        }
        let lower = min(max(0, selection.location), length)
        let upper = min(max(lower, selection.upperBound), length)
        return NSRange(location: lower, length: upper - lower)
    }

    private func beginObservingSelection(in editor: NSTextView) {
        guard observedEditor !== editor else { return }
        endObservingSelection()
        observedEditor = editor
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(fieldEditorSelectionDidChange(_:)),
            name: NSTextView.didChangeSelectionNotification,
            object: editor
        )
    }

    private func endObservingSelection() {
        if let observedEditor {
            NotificationCenter.default.removeObserver(
                self,
                name: NSTextView.didChangeSelectionNotification,
                object: observedEditor
            )
        }
        observedEditor = nil
        onSelectionChange?(nil, false, ActiveFormats())
    }

    @objc private func fieldEditorSelectionDidChange(_ notification: Notification) {
        guard !isFinishing,
              let editor = notification.object as? NSTextView,
              editor === observedEditor else { return }
        publishSelection(from: editor)
    }

    private func publishSelection(from editor: NSTextView) {
        let selection = editor.selectedRange
        guard selection.length > 0 else {
            onSelectionChange?(nil, false, ActiveFormats())
            return
        }
        syncMarkdownWithVisibleText()
        let rect = editor.firstRect(forCharacterRange: selection, actualRange: nil)
        let active = EditableMarkdownTable.activeFormats(
            in: markdownText, visibleRange: selection
        )
        onSelectionChange?(rect, true, active)
    }

    func toggleInlineFormat(_ format: TableInlineFormat) {
        guard let editor = field.currentEditor() as? NSTextView else { return }
        let selection = editor.selectedRange
        guard selection.length > 0 else { return }
        syncMarkdownWithVisibleText()
        markdownText = EditableMarkdownTable.toggling(
            format, in: markdownText, visibleRange: selection
        )
        refreshFieldPresentation(in: editor, preserving: selection)
        publishSelection(from: editor)
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
        endObservingSelection()
        field.abortEditing()
        removeFromSuperview()
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard hasBegunEditing, !isActivatingEditor, !isFinishing else { return }
        isFinishing = true
        endObservingSelection()
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
            endObservingSelection()
            onCancel?()
            return true
        default: navigation = nil
        }
        guard let navigation else { return false }
        isFinishing = true
        endObservingSelection()
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
        endObservingSelection()
        onAction?(field.stringValue, action)
    }
}
