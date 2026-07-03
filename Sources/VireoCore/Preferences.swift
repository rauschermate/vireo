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

/// Thin typed wrapper over UserDefaults for the handful of v1 preferences.
@MainActor
public final class Preferences: ObservableObject {
    public static let shared = Preferences()
    private let defaults = UserDefaults.standard

    private enum Keys {
        static let autoSave = "vireo.autoSave"
        static let recentFiles = "vireo.recentFiles"
        static let appearance = "vireo.appearance"
    }

    /// Auto-save on by default (PRD §2).
    @Published public var autoSave: Bool = true {
        didSet { defaults.set(autoSave, forKey: Keys.autoSave) }
    }

    /// Follow the system appearance unless the user overrides it.
    @Published public var appearance: AppearanceOption = .system {
        didSet { defaults.set(appearance.rawValue, forKey: Keys.appearance) }
    }

    public init() {
        autoSave = defaults.object(forKey: Keys.autoSave) as? Bool ?? true
        appearance = AppearanceOption(rawValue: defaults.string(forKey: Keys.appearance) ?? "") ?? .system
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
