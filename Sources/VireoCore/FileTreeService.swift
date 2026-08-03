import Foundation

/// A markdown file or directory in the file sidebar.
public struct FileNode: Identifiable, Hashable, Sendable {
    public let id: URL
    public var url: URL { id }
    public let name: String
    public let isDirectory: Bool
    public let children: [FileNode]?

    public init(id: URL, name: String, isDirectory: Bool,
                children: [FileNode]?) {
        self.id = id
        self.name = name
        self.isDirectory = isDirectory
        self.children = children
    }
}

/// Builds the markdown-only sidebar tree without touching UI state. The work is
/// synchronous by design so callers can run it in a cancellable detached task.
public struct FileTreeService: Sendable {
    public init() {}

    public func buildTree(at url: URL) throws -> FileNode {
        try Task.checkCancellation()
        // Preserve the URL the user opened for selection identity while using
        // resolved paths only for cycle detection below.
        let root = url.standardizedFileURL
        var visited: Set<URL> = []
        return try buildDirectory(at: root, visited: &visited, isRoot: true)
    }

    private func buildDirectory(at url: URL, visited: inout Set<URL>,
                                isRoot: Bool = false) throws -> FileNode {
        try Task.checkCancellation()
        let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
        guard visited.insert(canonical).inserted else {
            return directoryNode(for: url, children: [])
        }

        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
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
            return directoryNode(for: url, children: [])
        }

        var children: [FileNode] = []
        for child in contents.sorted(by: Self.sortURLs) {
            try Task.checkCancellation()
            guard let values = try? child.resourceValues(forKeys: keys),
                  values.isSymbolicLink != true else { continue }
            if values.isDirectory == true {
                let node = try buildDirectory(at: child, visited: &visited)
                if !(node.children?.isEmpty ?? true) { children.append(node) }
            } else if FileService.isMarkdown(child) {
                children.append(FileNode(id: child.standardizedFileURL,
                                         name: child.lastPathComponent,
                                         isDirectory: false, children: nil))
            }
        }
        return directoryNode(for: url, children: children)
    }

    private func directoryNode(for url: URL, children: [FileNode]) -> FileNode {
        let name = url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
        return FileNode(id: url.standardizedFileURL, name: name,
                        isDirectory: true,
                        children: children.isEmpty ? nil : children)
    }

    private static func sortURLs(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent) == .orderedAscending
    }
}
