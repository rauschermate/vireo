import Foundation

public struct DocumentWriterIO: Sendable {
    public var read: @Sendable (URL) throws -> FileSnapshot
    public var write: @Sendable (String, URL) throws -> Void

    public init(read: @escaping @Sendable (URL) throws -> FileSnapshot,
                write: @escaping @Sendable (String, URL) throws -> Void) {
        self.read = read
        self.write = write
    }

    public static let live = DocumentWriterIO(
        read: { try FileService.loadSnapshot($0) },
        write: { try FileService.save($0, to: $1) })
}

public enum DocumentWriteResult: Sendable, Equatable {
    case success(FileRevision)
    case conflict(FileSnapshot)
    case failure(String)
}

public enum DocumentReadResult: Sendable, Equatable {
    case success(FileSnapshot)
    case failure(String)
}

/// A single serial I/O lane for document reads and writes. Callers pass the
/// revision they last observed; the writer refuses to overwrite a different
/// disk version and returns that snapshot for reconciliation.
public final class DocumentWriter: @unchecked Sendable {
    public static let shared = DocumentWriter()

    private let queue: DispatchQueue
    private let io: DocumentWriterIO

    public init(label: String = "com.materauscher.vireo.document-writer",
                io: DocumentWriterIO = .live) {
        self.queue = DispatchQueue(label: label, qos: .utility)
        self.io = io
    }

    public func write(source: String, to url: URL, expected: FileRevision?,
                      completion: @escaping @Sendable (DocumentWriteResult) -> Void) {
        queue.async { [self] in completion(performWrite(source: source, to: url, expected: expected)) }
    }

    public func writeSynchronously(source: String, to url: URL,
                                   expected: FileRevision?) -> DocumentWriteResult {
        queue.sync { performWrite(source: source, to: url, expected: expected) }
    }

    public func read(_ url: URL,
                     completion: @escaping @Sendable (DocumentReadResult) -> Void) {
        queue.async { [self] in
            do { completion(.success(try io.read(url))) }
            catch { completion(.failure(error.localizedDescription)) }
        }
    }

    private func performWrite(source: String, to url: URL,
                              expected: FileRevision?) -> DocumentWriteResult {
        do {
            if let expected {
                let current = try io.read(url)
                guard current.revision == expected else { return .conflict(current) }
            }
            try io.write(source, url)
            let saved = try io.read(url)
            guard saved.source == source else { return .conflict(saved) }
            return .success(saved.revision)
        } catch {
            return .failure(error.localizedDescription)
        }
    }
}
