import XCTest
@testable import VireoCore

final class DocumentWriterTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vireo-writer-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory,
                                                withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    func testWritesAgainstExpectedRevision() throws {
        let url = temporaryDirectory.appendingPathComponent("note.md")
        try FileService.save("before", to: url)
        let initial = try FileService.loadSnapshot(url)
        let writer = DocumentWriter(label: "writer-success-\(UUID().uuidString)")

        let result = writer.writeSynchronously(source: "after", to: url,
                                               expected: initial.revision)

        guard case .success(let revision) = result else {
            return XCTFail("expected success, got \(result)")
        }
        XCTAssertEqual(try FileService.load(url), "after")
        XCTAssertEqual(revision, try FileService.loadSnapshot(url).revision)
    }

    func testExternalChangeIsReturnedWithoutBeingOverwritten() throws {
        let url = temporaryDirectory.appendingPathComponent("note.md")
        try FileService.save("initial", to: url)
        let initial = try FileService.loadSnapshot(url)
        try FileService.save("external", to: url)
        let writer = DocumentWriter(label: "writer-conflict-\(UUID().uuidString)")

        let result = writer.writeSynchronously(source: "local", to: url,
                                               expected: initial.revision)

        guard case .conflict(let disk) = result else {
            return XCTFail("expected conflict, got \(result)")
        }
        XCTAssertEqual(disk.source, "external")
        XCTAssertEqual(try FileService.load(url), "external")
    }

    func testWriteFailureIsAResult() {
        struct ExpectedFailure: LocalizedError {
            var errorDescription: String? { "Disk is full" }
        }
        let snapshot = FileSnapshot(source: "before",
                                    revision: FileService.revision(of: Data("before".utf8)))
        let writer = DocumentWriter(label: "writer-failure-\(UUID().uuidString)",
                                    io: DocumentWriterIO(read: { _ in snapshot },
                                                         write: { _, _ in throw ExpectedFailure() }))

        let result = writer.writeSynchronously(source: "after",
                                               to: URL(fileURLWithPath: "/note.md"),
                                               expected: snapshot.revision)

        XCTAssertEqual(result, .failure("Disk is full"))
    }
}
