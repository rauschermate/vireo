import Foundation
import XCTest
@testable import VireoCore

final class FileTreeServiceTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for url in temporaryDirectories {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryDirectories = []
    }

    func testBuildTreeFiltersSortsAndOmitsEmptyDirectories() throws {
        let root = try temporaryDirectory()
        try write("# Z", to: root.appendingPathComponent("zeta.md"))
        try write("# A", to: root.appendingPathComponent("Alpha.markdown"))
        try write("pixels", to: root.appendingPathComponent("image.png"))
        try write("hidden", to: root.appendingPathComponent(".hidden.md"))

        let docs = root.appendingPathComponent("Docs", isDirectory: true)
        let empty = root.appendingPathComponent("Empty", isDirectory: true)
        try FileManager.default.createDirectory(at: docs,
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: empty,
                                                withIntermediateDirectories: true)
        try write("# Guide", to: docs.appendingPathComponent("Guide.mdown"))
        try write("ignore", to: empty.appendingPathComponent("ignore.json"))

        let tree = try FileTreeService().buildTree(at: root)

        XCTAssertEqual(tree.children?.map(\.name),
                       ["Alpha.markdown", "Docs", "zeta.md"])
        XCTAssertEqual(tree.children?.first(where: { $0.name == "Docs" })?
            .children?.map(\.name), ["Guide.mdown"])
        XCTAssertNil(tree.children?.first(where: { $0.name == "Empty" }))
    }

    func testBuildTreeSkipsDirectorySymlinks() throws {
        let root = try temporaryDirectory()
        let docs = root.appendingPathComponent("Docs", isDirectory: true)
        try FileManager.default.createDirectory(at: docs,
                                                withIntermediateDirectories: true)
        try write("# Safe", to: docs.appendingPathComponent("Safe.md"))
        try FileManager.default.createSymbolicLink(
            at: docs.appendingPathComponent("Loop"),
            withDestinationURL: root
        )

        let tree = try FileTreeService().buildTree(at: root)
        let docsNode = try XCTUnwrap(tree.children?.first)

        XCTAssertEqual(docsNode.children?.map(\.name), ["Safe.md"])
    }

    func testBuildTreeHonorsTaskCancellation() async throws {
        let root = try temporaryDirectory()
        try write("# Note", to: root.appendingPathComponent("Note.md"))
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        let task = Task.detached {
            for await _ in stream { break }
            return try FileTreeService().buildTree(at: root)
        }
        task.cancel()
        continuation.yield(())
        continuation.finish()

        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
            // Expected: cancellation is checked before any directory work.
        }
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("VireoFileTreeTests-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: url,
                                                withIntermediateDirectories: true)
        temporaryDirectories.append(url)
        return url
    }

    private func write(_ value: String, to url: URL) throws {
        try Data(value.utf8).write(to: url)
    }
}
