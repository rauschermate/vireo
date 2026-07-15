import Foundation
import CryptoKit

/// Content identity used for optimistic file writes. Comparing a stable digest
/// catches external replacements even when inode or modification-date metadata
/// is coarse or rewritten by a file provider.
public struct FileRevision: Sendable, Equatable {
    public var byteCount: Int
    public var digest: [UInt8]

    public init(byteCount: Int, digest: [UInt8]) {
        self.byteCount = byteCount
        self.digest = digest
    }
}

public struct FileSnapshot: Sendable, Equatable {
    public var source: String
    public var revision: FileRevision

    public init(source: String, revision: FileRevision) {
        self.source = source
        self.revision = revision
    }
}

/// Atomic load/save of markdown files. The string written is exactly what the
/// editor holds — the source is never transformed on the way to disk.
public enum FileService {
    public static func load(_ url: URL) throws -> String {
        try loadSnapshot(url).source
    }

    public static func loadSnapshot(_ url: URL) throws -> FileSnapshot {
        let data = try Data(contentsOf: url)
        return FileSnapshot(source: String(decoding: data, as: UTF8.self),
                            revision: revision(of: data))
    }

    /// Atomic write (temp + rename) so a crash mid-write can't truncate the file.
    public static func save(_ text: String, to url: URL) throws {
        let data = Data(text.utf8)
        try data.write(to: url, options: [.atomic])
    }

    public static func revision(of data: Data) -> FileRevision {
        FileRevision(byteCount: data.count, digest: Array(SHA256.hash(data: data)))
    }

    public static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "text"]

    public static func isMarkdown(_ url: URL) -> Bool {
        markdownExtensions.contains(url.pathExtension.lowercased())
    }
}
