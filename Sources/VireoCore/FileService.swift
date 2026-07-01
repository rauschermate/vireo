import Foundation

/// Atomic load/save of markdown files. The string written is exactly what the
/// editor holds — the source is never transformed on the way to disk.
public enum FileService {
    public static func load(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return String(decoding: data, as: UTF8.self)
    }

    /// Atomic write (temp + rename) so a crash mid-write can't truncate the file.
    public static func save(_ text: String, to url: URL) throws {
        let data = Data(text.utf8)
        try data.write(to: url, options: [.atomic])
    }

    public static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "text"]

    public static func isMarkdown(_ url: URL) -> Bool {
        markdownExtensions.contains(url.pathExtension.lowercased())
    }
}
