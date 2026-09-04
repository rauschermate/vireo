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

/// Typeface of the document text. Code always stays monospaced.
public enum EditorFontOption: String, CaseIterable, Identifiable, Sendable {
    case sans, mono
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .sans: return "Sans"
        case .mono: return "Mono"
        }
    }
}

/// What a file row in the sidebar shows: the document title (frontmatter or
/// leading H1, falling back to the file name) or always the file name.
public enum SidebarFileLabel: String, CaseIterable, Identifiable, Sendable {
    case title, filename
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .title: return "Document title"
        case .filename: return "File name"
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
        static let editorFont = "vireo.editorFont"
        static let sidebarVisible = "vireo.sidebar.visible"
        static let sidebarWidth = "vireo.sidebar.width"
        static let sidebarFileLabel = "vireo.sidebar.fileLabel"
        static let sidebarShowSearch = "vireo.sidebar.showSearch"
        static let sidebarShowRecents = "vireo.sidebar.showRecents"
        static let recentWorkspaces = "vireo.recentWorkspaces"
        static let lastWorkspace = "vireo.lastWorkspace"
        static let pinnedFiles = "vireo.sidebar.pinnedFiles"
    }

    nonisolated public static let defaultSidebarWidth: Double = 240

    /// Auto-save on by default (PRD §2).
    @Published public var autoSave: Bool = true {
        didSet { defaults.set(autoSave, forKey: Keys.autoSave) }
    }

    /// Follow the system appearance unless the user overrides it.
    @Published public var appearance: AppearanceOption = .system {
        didSet { defaults.set(appearance.rawValue, forKey: Keys.appearance) }
    }

    /// Dynamic out of the box: TOC opens only for long documents.
    @Published public var tocDefault: TOCDefaultOption = .dynamic {
        didSet { defaults.set(tocDefault.rawValue, forKey: Keys.tocDefault) }
    }

    @Published public var editorFont: EditorFontOption = .sans {
        didSet { defaults.set(editorFont.rawValue, forKey: Keys.editorFont) }
    }

    // MARK: Sidebar

    @Published public var sidebarVisible: Bool = true {
        didSet { defaults.set(sidebarVisible, forKey: Keys.sidebarVisible) }
    }

    @Published public var sidebarWidth: Double = Preferences.defaultSidebarWidth {
        didSet { defaults.set(sidebarWidth, forKey: Keys.sidebarWidth) }
    }

    @Published public var sidebarFileLabel: SidebarFileLabel = .title {
        didSet { defaults.set(sidebarFileLabel.rawValue, forKey: Keys.sidebarFileLabel) }
    }

    @Published public var sidebarShowSearch: Bool = true {
        didSet { defaults.set(sidebarShowSearch, forKey: Keys.sidebarShowSearch) }
    }

    @Published public var sidebarShowRecents: Bool = true {
        didSet { defaults.set(sidebarShowRecents, forKey: Keys.sidebarShowRecents) }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        autoSave = defaults.object(forKey: Keys.autoSave) as? Bool ?? true
        appearance = AppearanceOption(rawValue: defaults.string(forKey: Keys.appearance) ?? "") ?? .system
        tocDefault = TOCDefaultOption(rawValue: defaults.string(forKey: Keys.tocDefault) ?? "") ?? .dynamic
        editorFont = EditorFontOption(rawValue: defaults.string(forKey: Keys.editorFont) ?? "") ?? .sans
        sidebarVisible = defaults.object(forKey: Keys.sidebarVisible) as? Bool ?? true
        sidebarWidth = defaults.object(forKey: Keys.sidebarWidth) as? Double ?? Self.defaultSidebarWidth
        sidebarFileLabel = SidebarFileLabel(rawValue: defaults.string(forKey: Keys.sidebarFileLabel) ?? "") ?? .title
        sidebarShowSearch = defaults.object(forKey: Keys.sidebarShowSearch) as? Bool ?? true
        sidebarShowRecents = defaults.object(forKey: Keys.sidebarShowRecents) as? Bool ?? true
    }

    // MARK: Recent files

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

    // MARK: Workspaces

    /// Folders opened in the sidebar, newest first. Feeds the workspace
    /// switcher at the bottom of the sidebar.
    public var recentWorkspaces: [URL] {
        get { (defaults.array(forKey: Keys.recentWorkspaces) as? [String] ?? []).map { URL(fileURLWithPath: $0) } }
        set {
            let trimmed = Array(newValue.prefix(10))
            defaults.set(trimmed.map(\.path), forKey: Keys.recentWorkspaces)
        }
    }

    public func addRecentWorkspace(_ url: URL) {
        var list = recentWorkspaces.filter { $0.path != url.path }
        list.insert(url, at: 0)
        recentWorkspaces = list
    }

    public func removeRecentWorkspace(_ url: URL) {
        recentWorkspaces = recentWorkspaces.filter { $0.path != url.path }
    }

    /// The workspace open when the app last quit, restored on launch.
    public var lastWorkspace: URL? {
        get { defaults.string(forKey: Keys.lastWorkspace).map { URL(fileURLWithPath: $0) } }
        set { defaults.set(newValue?.path, forKey: Keys.lastWorkspace) }
    }

    // MARK: Pinned files (per workspace)

    public func pinnedFiles(for workspace: URL) -> [URL] {
        let table = defaults.dictionary(forKey: Keys.pinnedFiles) as? [String: [String]] ?? [:]
        return (table[workspace.path] ?? []).map { URL(fileURLWithPath: $0) }
    }

    public func setPinnedFiles(_ urls: [URL], for workspace: URL) {
        var table = defaults.dictionary(forKey: Keys.pinnedFiles) as? [String: [String]] ?? [:]
        if urls.isEmpty {
            table.removeValue(forKey: workspace.path)
        } else {
            table[workspace.path] = urls.map(\.path)
        }
        defaults.set(table, forKey: Keys.pinnedFiles)
    }
}
