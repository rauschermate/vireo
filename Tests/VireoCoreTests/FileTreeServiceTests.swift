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

    func testBuildTreeFiltersSortsFoldersFirstAndHidesNonMarkdownDirectories() throws {
        let root = try temporaryDirectory()
        try write("# Z", to: root.appendingPathComponent("zeta.md"))
        try write("# A", to: root.appendingPathComponent("Alpha.markdown"))
        try write("pixels", to: root.appendingPathComponent("image.png"))
        try write("hidden", to: root.appendingPathComponent(".hidden.md"))

        let docs = root.appendingPathComponent("Docs", isDirectory: true)
        let assets = root.appendingPathComponent("Assets", isDirectory: true)
        let empty = root.appendingPathComponent("Empty", isDirectory: true)
        for dir in [docs, assets, empty] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try write("# Guide", to: docs.appendingPathComponent("Guide.mdown"))
        try write("ignore", to: assets.appendingPathComponent("ignore.json"))

        let tree = try FileTreeService().buildTree(at: root)

        // Folders first, then files; a folder with only non-markdown files is
        // hidden, an empty folder tree still shows.
        XCTAssertEqual(tree.children?.map(\.name),
                       ["Docs", "Empty", "Alpha.markdown", "zeta.md"])
        XCTAssertEqual(tree.children?.first(where: { $0.name == "Docs" })?
            .children?.map(\.name), ["Guide.mdown"])
        XCTAssertNil(tree.children?.first(where: { $0.name == "Assets" }))
        XCTAssertNil(tree.children?.first(where: { $0.name == "Empty" })?.children)
    }

    func testBuildTreeReadsTitlesAndModificationDates() throws {
        let root = try temporaryDirectory()
        try write("# Morning Pages\n\nBody", to: root.appendingPathComponent("a.md"))
        try write("---\ntitle: \"Quoted Title\"\n---\n# Heading", to: root.appendingPathComponent("b.md"))
        try write("Just a paragraph\n# Late heading", to: root.appendingPathComponent("c.md"))

        let tree = try FileTreeService().buildTree(at: root)
        let byName = Dictionary(uniqueKeysWithValues: (tree.children ?? []).map { ($0.name, $0) })

        XCTAssertEqual(byName["a.md"]?.title, "Morning Pages")
        XCTAssertEqual(byName["b.md"]?.title, "Quoted Title")
        XCTAssertNil(byName["c.md"]?.title)
        XCTAssertEqual(byName["a.md"]?.stem, "a")
        XCTAssertGreaterThan(byName["a.md"]?.modifiedAt ?? .distantPast, Date(timeIntervalSince1970: 0))
        XCTAssertEqual(tree.allFiles.map(\.name), ["a.md", "b.md", "c.md"])
    }

    func testTitleCacheFollowsFileChanges() throws {
        let root = try temporaryDirectory()
        let file = root.appendingPathComponent("note.md")
        try write("# First", to: file)
        let service = FileTreeService()
        XCTAssertEqual(try service.buildTree(at: root).allFiles.first?.title, "First")

        // A rewrite with a different size invalidates the cached title.
        try write("# Second title", to: file)
        XCTAssertEqual(try service.buildTree(at: root).allFiles.first?.title, "Second title")
    }

    func testExtractTitleRules() {
        XCTAssertEqual(FileTreeService.extractTitle(from: "# Hello\n"), "Hello")
        XCTAssertEqual(FileTreeService.extractTitle(from: "\n\n  # Spaced  \n"), "Spaced")
        XCTAssertNil(FileTreeService.extractTitle(from: "text\n# Later"))
        XCTAssertNil(FileTreeService.extractTitle(from: "## Not an H1"))
        XCTAssertNil(FileTreeService.extractTitle(from: "#NoSpace"))
        XCTAssertEqual(FileTreeService.extractTitle(from: "---\ntitle: Plain\n---\nbody"), "Plain")
        XCTAssertEqual(FileTreeService.extractTitle(from: "---\ntitle: 'Single'\n---\n"), "Single")
        XCTAssertEqual(FileTreeService.extractTitle(from: "---\ndate: 2026\n---\n\n# After matter"), "After matter")
        XCTAssertNil(FileTreeService.extractTitle(from: "---\ntitle:\n---\nno heading"))
        XCTAssertEqual(FileTreeService.extractTitle(from: "---\r\ntitle: CRLF\r\n---\r\n"), "CRLF")
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
