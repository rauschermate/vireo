import Foundation

/// App-wide appearance: follow the OS (default) or force light/dark.
public enum AppearanceOption: String, CaseIterable, Identifiable, Sendable {
    case system, light, dark
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}

/// Whether the table of contents starts open: always, never, or only for
/// long documents (dynamic).
public enum TOCDefaultOption: String, CaseIterable, Identifiable, Sendable {
    case on, off, dynamic
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .on: return "On"
        case .off: return "Off"
        case .dynamic: return "Dynamic"
        }
    }
}

/// Thin typed wrapper over UserDefaults for the handful of v1 preferences.
@MainActor
public final class Preferences: ObservableObject {
    public static let shared = Preferences()
    private let defaults: UserDefaults

    private enum Keys {
        static let autoSave = "vireo.autoSave"
        static let recentFiles = "vireo.recentFiles"
        static let appearance = "vireo.appearance"
        static let tocDefault = "vireo.tocDefault"
        static let revealSyntax = "vireo.revealSyntaxNearCaret"
    }

    /// Auto-save on by default (PRD §2).
    @Published public var autoSave: Bool = true {
        didSet { defaults.set(autoSave, forKey: Keys.autoSave) }
    }

    /// Prototype: the block that holds the caret shows its raw Markdown
    /// syntax, dimmed; every other block renders clean. Off by default.
    @Published public var revealSyntax: Bool = false {
        didSet { defaults.set(revealSyntax, forKey: Keys.revealSyntax) }
    }

    /// Follow the system appearance unless the user overrides it.
    @Published public var appearance: AppearanceOption = .system {
        didSet { defaults.set(appearance.rawValue, forKey: Keys.appearance) }
    }

    /// Dynamic out of the box: TOC opens only for long documents.
    @Published public var tocDefault: TOCDefaultOption = .dynamic {
        didSet { defaults.set(tocDefault.rawValue, forKey: Keys.tocDefault) }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        autoSave = defaults.object(forKey: Keys.autoSave) as? Bool ?? true
        appearance = AppearanceOption(rawValue: defaults.string(forKey: Keys.appearance) ?? "") ?? .system
        tocDefault = TOCDefaultOption(rawValue: defaults.string(forKey: Keys.tocDefault) ?? "") ?? .dynamic
        revealSyntax = defaults.object(forKey: Keys.revealSyntax) as? Bool ?? false
    }

    public var recentFiles: [URL] {
        get { (defaults.array(forKey: Keys.recentFiles) as? [String] ?? []).compactMap { URL(string: $0) } }
        set {
            let trimmed = Array(newValue.prefix(10))
            defaults.set(trimmed.map(\.absoluteString), forKey: Keys.recentFiles)
        }
    }

    public func addRecent(_ url: URL) {
        var list = recentFiles.filter { $0 != url }
        list.insert(url, at: 0)
        recentFiles = list
    }
}
