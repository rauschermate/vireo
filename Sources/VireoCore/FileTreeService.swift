import Foundation

/// A markdown file or directory in the file sidebar.
public struct FileNode: Identifiable, Hashable, Sendable {
    public let id: URL
    public var url: URL { id }
    public let name: String
    public let isDirectory: Bool
    public let children: [FileNode]?
    /// Document title: YAML frontmatter `title:` or a leading `# H1`. Nil for
    /// directories and for files without one.
    public let title: String?
    public let modifiedAt: Date

    public init(id: URL, name: String, isDirectory: Bool,
                children: [FileNode]?, title: String? = nil,
                modifiedAt: Date = .distantPast) {
        self.id = id
        self.name = name
        self.isDirectory = isDirectory
        self.children = children
        self.title = title
        self.modifiedAt = modifiedAt
    }

    /// The file name without its extension.
    public var stem: String { (name as NSString).deletingPathExtension }

    /// Every markdown file below this node, depth first.
    public var allFiles: [FileNode] {
        var out: [FileNode] = []
        collectFiles(into: &out)
        return out
    }

    private func collectFiles(into out: inout [FileNode]) {
        for child in children ?? [] {
            if child.isDirectory { child.collectFiles(into: &out) } else { out.append(child) }
        }
    }

    /// The node for `url` below this node, if it is in the tree.
    public func node(for url: URL) -> FileNode? {
        if self.url == url { return self }
        for child in children ?? [] {
            if let found = child.node(for: url) { return found }
        }
        return nil
    }
}

/// What a directory holds, transitively. Mirrors the sidebar rule: folders
/// with markdown show, empty folder trees show, folders with only other files
/// stay hidden.
enum DirectoryContent {
    case empty, other, markdown
}

/// Builds the markdown-only sidebar tree without touching UI state. The work is
/// synchronous by design so callers can run it in a cancellable detached task.
///
/// Titles come from the first 4 KiB of each file and are cached by
/// modification date and size, so a rebuild after one save re-reads one file.
public final class FileTreeService: @unchecked Sendable {
    private struct CachedTitle {
        var modifiedAt: Date
        var size: Int
        var title: String?
    }

    private let lock = NSLock()
    private var titleCache: [URL: CachedTitle] = [:]

    public init() {}

    public func buildTree(at url: URL) throws -> FileNode {
        try Task.checkCancellation()
        // Preserve the URL the user opened for selection identity while using
        // resolved paths only for cycle detection below.
        let root = url.standardizedFileURL
        var visited: Set<URL> = []
        let built = try buildDirectory(at: root, visited: &visited, isRoot: true)
        prune(keeping: Set(built.node.allFiles.map(\.url)))
        return built.node
    }

    private func buildDirectory(at url: URL, visited: inout Set<URL>,
                                isRoot: Bool = false) throws -> (node: FileNode, content: DirectoryContent) {
        try Task.checkCancellation()
        let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
        guard visited.insert(canonical).inserted else {
            return (directoryNode(for: url, children: []), .empty)
        }

        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey,
                                         .contentModificationDateKey, .fileSizeKey]
        let contents: [URL]
        do {
            contents = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles]
            )
        } catch {
            if error is CancellationError { throw error }
            if isRoot { throw error }
            return (directoryNode(for: url, children: []), .empty)
        }

        var directories: [FileNode] = []
        var files: [FileNode] = []
        var content = DirectoryContent.empty
        for child in contents {
            try Task.checkCancellation()
            guard let values = try? child.resourceValues(forKeys: keys),
                  values.isSymbolicLink != true else { continue }
            if values.isDirectory == true {
                let built = try buildDirectory(at: child, visited: &visited)
                switch built.content {
                case .markdown:
                    content = .markdown
                    directories.append(built.node)
                case .empty:
                    directories.append(built.node)
                case .other:
                    if content == .empty { content = .other }
                }
            } else if FileService.isMarkdown(child) {
                content = .markdown
                let modified = values.contentModificationDate ?? .distantPast
                let size = values.fileSize ?? 0
                files.append(FileNode(id: child.standardizedFileURL,
                                      name: child.lastPathComponent,
                                      isDirectory: false, children: nil,
                                      title: title(of: child, modifiedAt: modified, size: size),
                                      modifiedAt: modified))
            } else if content == .empty {
                content = .other
            }
        }
        directories.sort(by: Self.sortNodes)
        files.sort(by: Self.sortNodes)
        let node = directoryNode(for: url, children: directories + files,
                                 modifiedAt: (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                                    .contentModificationDate ?? .distantPast)
        return (node, content)
    }

    private func directoryNode(for url: URL, children: [FileNode],
                               modifiedAt: Date = .distantPast) -> FileNode {
        let name = url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
        return FileNode(id: url.standardizedFileURL, name: name,
                        isDirectory: true,
                        children: children.isEmpty ? nil : children,
                        modifiedAt: modifiedAt)
    }

    /// Finder order: case-insensitive, numbers compare numerically.
    private static func sortNodes(_ lhs: FileNode, _ rhs: FileNode) -> Bool {
        lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }

    // MARK: Titles

    private func title(of url: URL, modifiedAt: Date, size: Int) -> String? {
        lock.lock()
        let cached = titleCache[url]
        lock.unlock()
        if let cached, cached.modifiedAt == modifiedAt, cached.size == size {
            return cached.title
        }
        let title = Self.readTitle(of: url)
        lock.lock()
        titleCache[url] = CachedTitle(modifiedAt: modifiedAt, size: size, title: title)
        lock.unlock()
        return title
    }

    private func prune(keeping live: Set<URL>) {
        lock.lock()
        titleCache = titleCache.filter { live.contains($0.key) }
        lock.unlock()
    }

    /// Read the head of the file and derive its title.
    public static func readTitle(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4096), !data.isEmpty else { return nil }
        return extractTitle(from: String(decoding: data, as: UTF8.self))
    }

    /// YAML frontmatter `title:` wins; otherwise the first non-blank line must
    /// be an H1. A document that starts with anything else has no title.
    public static func extractTitle(from raw: String) -> String? {
        // "\r\n" is a single Character in Swift; normalise so every line
        // operation below can assume "\n".
        let text = raw.replacingOccurrences(of: "\r\n", with: "\n")
        var body = Substring(text)
        if text.hasPrefix("---\n") {
            let afterOpen = text.dropFirst(4)
            if let close = afterOpen.range(of: "\n---\n") {
                let yaml = afterOpen[afterOpen.startIndex..<close.lowerBound]
                for line in yaml.split(separator: "\n", omittingEmptySubsequences: false) {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    guard trimmed.hasPrefix("title:") else { continue }
                    var value = trimmed.dropFirst("title:".count)
                        .trimmingCharacters(in: .whitespaces)
                    if value.count >= 2,
                       let first = value.first, let last = value.last,
                       (first == "\"" && last == "\"") || (first == "'" && last == "'") {
                        value = String(value.dropFirst().dropLast())
                    }
                    if !value.isEmpty { return value }
                }
                body = afterOpen[close.upperBound...]
            }
        }
        return leadingH1(in: body)
    }

    private static func leadingH1(in text: Substring) -> String? {
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            guard trimmed.hasPrefix("# ") else { return nil }
            let heading = trimmed.dropFirst(2).trimmingCharacters(in: .whitespaces)
            return heading.isEmpty ? nil : heading
        }
        return nil
    }
}
