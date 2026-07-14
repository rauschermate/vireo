import AppKit

enum LinkDestinationError: LocalizedError, Equatable {
    case empty
    case invalidCharacters
    case invalidURL

    var errorDescription: String? {
        switch self {
        case .empty: return "Enter a destination."
        case .invalidCharacters: return "The destination contains unsupported characters."
        case .invalidURL: return "Enter a complete URL, email address, anchor, or file path."
        }
    }
}

/// Validation and conservative normalization shared by the popover and tests.
enum LinkDestination {
    static func normalize(_ raw: String) throws -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw LinkDestinationError.empty }
        guard !value.unicodeScalars.contains(where: {
            CharacterSet.controlCharacters.contains($0) || $0 == "\t"
        }) else { throw LinkDestinationError.invalidCharacters }

        value = value.replacingOccurrences(of: " ", with: "%20")

        if matches(value, #"^[^@/\s]+@[^@/\s]+\.[^@/\s]+$"#) {
            return "mailto:\(value)"
        }

        let looksLikeFile = matches(value.lowercased(),
                                    #"^[^/?#]+\.(md|markdown|txt|html?|pdf|png|jpe?g|gif|webp|svg)$"#)
        if value.lowercased().hasPrefix("www.")
            || (!looksLikeFile
                && matches(value, #"^[A-Za-z0-9](?:[A-Za-z0-9-]*\.)+[A-Za-z]{2,}(?::[0-9]+)?(?:[/?#].*)?$"#)) {
            value = "https://\(value)"
        }

        if let colon = value.firstIndex(of: ":"),
           matches(String(value[..<colon]), #"^[A-Za-z][A-Za-z0-9+.-]*$"#) {
            guard let components = URLComponents(string: value),
                  let rawScheme = components.scheme else { throw LinkDestinationError.invalidURL }
            let scheme = rawScheme.lowercased()
            if scheme == "http" || scheme == "https" {
                guard components.host?.isEmpty == false else { throw LinkDestinationError.invalidURL }
            } else if scheme == "mailto" {
                guard !components.path.isEmpty else { throw LinkDestinationError.invalidURL }
            } else {
                guard value.index(after: colon) < value.endIndex else {
                    throw LinkDestinationError.invalidURL
                }
            }
        } else if value.contains(":") || value.lowercased().hasPrefix("http//")
                    || value.lowercased().hasPrefix("https//") {
            // A colon before any path separator is almost certainly an intended
            // but malformed scheme; do not silently save it as a relative path.
            throw LinkDestinationError.invalidURL
        }

        return value
    }

    private static func matches(_ value: String, _ pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }
}

@MainActor
final class LinkPopover: NSObject, NSPopoverDelegate, NSTextFieldDelegate {
    enum Action {
        case save(label: String, destination: String)
        case remove
        case cancel
        case dismiss
    }

    private let popover = NSPopover()
    private let labelField = NSTextField()
    private let destinationField = NSTextField()
    private let statusLabel = NSTextField(labelWithString: " ")
    private let saveButton = NSButton(title: "Apply", target: nil, action: nil)
    private let removeButton = NSButton(title: "Remove Link", target: nil, action: nil)
    private var completion: ((Action) -> Void)?

    override init() {
        super.init()
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = makeContentViewController()
    }

    func show(label: String, destination: String, canRemove: Bool,
              relativeTo rect: NSRect, of view: NSView,
              completion: @escaping (Action) -> Void) {
        if popover.isShown { finish(.cancel, close: true) }
        self.completion = completion
        labelField.stringValue = label
        destinationField.stringValue = destination
        removeButton.isHidden = !canRemove
        updateValidation()
        popover.show(relativeTo: rect, of: view, preferredEdge: .maxY)

        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.destinationField.window else { return }
            window.makeFirstResponder(self.destinationField)
            self.destinationField.selectText(nil)
        }
    }

    func popoverDidClose(_ notification: Notification) {
        finish(.dismiss, close: false)
    }

    func controlTextDidChange(_ obj: Notification) {
        updateValidation()
    }

    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            cancel()
            return true
        }
        return false
    }

    private func makeContentViewController() -> NSViewController {
        labelField.placeholderString = "Link text"
        labelField.setAccessibilityLabel("Link text")
        labelField.delegate = self
        labelField.target = self
        labelField.action = #selector(save)

        destinationField.placeholderString = "https://example.com"
        destinationField.setAccessibilityLabel("Link destination")
        destinationField.delegate = self
        destinationField.target = self
        destinationField.action = #selector(save)

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 2
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        saveButton.target = self
        saveButton.action = #selector(save)
        saveButton.keyEquivalent = "\r"
        saveButton.bezelStyle = .rounded

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.bezelStyle = .rounded

        removeButton.target = self
        removeButton.action = #selector(remove)
        removeButton.bezelStyle = .accessoryBarAction
        removeButton.isBordered = false
        removeButton.contentTintColor = .systemRed

        let actions = NSStackView(views: [removeButton, NSView(), cancelButton, saveButton])
        actions.orientation = .horizontal
        actions.spacing = 8

        let stack = NSStackView(views: [fieldLabel("Text"), labelField,
                                        fieldLabel("Destination"), destinationField,
                                        statusLabel, actions])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.setCustomSpacing(10, after: labelField)
        stack.setCustomSpacing(12, after: statusLabel)
        for view in [labelField, destinationField, statusLabel, actions] {
            view.widthAnchor.constraint(equalToConstant: 312).isActive = true
        }

        let root = NSView()
        root.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),
        ])

        let controller = NSViewController()
        controller.view = root
        controller.preferredContentSize = NSSize(width: 340, height: 204)
        return controller
    }

    private func fieldLabel(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func updateValidation() {
        let label = labelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty, !label.contains("\n") else {
            statusLabel.stringValue = "Enter link text on one line."
            statusLabel.textColor = .systemRed
            saveButton.isEnabled = false
            return
        }
        do {
            let normalized = try LinkDestination.normalize(destinationField.stringValue)
            let entered = destinationField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            statusLabel.stringValue = normalized == entered ? " " : "Will use \(normalized)"
            statusLabel.textColor = .secondaryLabelColor
            saveButton.isEnabled = true
        } catch {
            statusLabel.stringValue = (error as? LocalizedError)?.errorDescription ?? "Invalid destination."
            statusLabel.textColor = .systemRed
            saveButton.isEnabled = false
        }
    }

    @objc private func save() {
        guard saveButton.isEnabled,
              let destination = try? LinkDestination.normalize(destinationField.stringValue) else { return }
        finish(.save(label: labelField.stringValue, destination: destination), close: true)
    }

    @objc private func remove() { finish(.remove, close: true) }
    @objc private func cancel() { finish(.cancel, close: true) }

    private func finish(_ action: Action, close: Bool) {
        guard let completion else { return }
        self.completion = nil
        if close, popover.isShown { popover.performClose(nil) }
        completion(action)
    }
}
