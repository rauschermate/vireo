import Foundation

/// Thin typed wrapper over UserDefaults for the handful of v1 preferences.
@MainActor
public final class Preferences: ObservableObject {
    public static let shared = Preferences()
    private let defaults = UserDefaults.standard

    private enum Keys {
        static let autoSave = "vireo.autoSave"
        static let recentFiles = "vireo.recentFiles"
    }

    /// Auto-save on by default (PRD §2).
    @Published public var autoSave: Bool = true {
        didSet { defaults.set(autoSave, forKey: Keys.autoSave) }
    }

    public init() {
        autoSave = defaults.object(forKey: Keys.autoSave) as? Bool ?? true
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
