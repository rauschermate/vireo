import XCTest
import VireoCore
@testable import Vireo

@MainActor
final class DocumentModelTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUp() async throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vireo-document-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory,
                                                withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    func testAutosaveFailureIsDurableVisibleAndDirty() async throws {
        let url = try makeFile("before")
        let preferences = makePreferences(autoSave: true)
        let writer = failingWriter(message: "Disk is full")
        let document = try DocumentModel(url: url, preferences: preferences, writer: writer,
                                         autosaveDelay: 0.01, watchesExternalChanges: false)
        let surfaced = expectation(description: "save failure surfaced")
        document.onSaveFailure = { message in
            XCTAssertEqual(message, "Disk is full")
            surfaced.fulfill()
        }

        document.handleEdit("local edit")
        await fulfillment(of: [surfaced], timeout: 1)

        XCTAssertTrue(document.isDirty)
        XCTAssertEqual(document.saveState, .failed("Disk is full"))
        XCTAssertEqual(try FileService.load(url), "before")
    }

    func testEnablingAutosaveFlushesExistingDirtyEdits() async throws {
        let url = try makeFile("before")
        let preferences = makePreferences(autoSave: false)
        let document = try DocumentModel(url: url, preferences: preferences,
                                         writer: writer(), autosaveDelay: 0.01,
                                         watchesExternalChanges: false)
        document.handleEdit("after")
        XCTAssertEqual(document.saveState, .unsaved)
        XCTAssertEqual(try FileService.load(url), "before")

        preferences.autoSave = true
        await waitUntil { document.saveState == .saved && !document.isDirty }

        XCTAssertEqual(try FileService.load(url), "after")
    }

    func testDisablingAutosaveCancelsPendingWrite() async throws {
        let url = try makeFile("before")
        let preferences = makePreferences(autoSave: true)
        let document = try DocumentModel(url: url, preferences: preferences,
                                         writer: writer(), autosaveDelay: 0.2,
                                         watchesExternalChanges: false)

        document.handleEdit("after")
        preferences.autoSave = false
        try? await Task.sleep(for: .milliseconds(350))

        XCTAssertEqual(try FileService.load(url), "before")
        XCTAssertTrue(document.isDirty)
        XCTAssertEqual(document.saveState, .unsaved)
    }

    func testNewestGenerationWinsWhenEditingDuringAWrite() async throws {
        let url = try makeFile("before")
        let preferences = makePreferences(autoSave: true)
        let io = DocumentWriterIO(
            read: { try FileService.loadSnapshot($0) },
            write: { source, url in
                Thread.sleep(forTimeInterval: 0.05)
                try FileService.save(source, to: url)
            })
        let document = try DocumentModel(
            url: url, preferences: preferences,
            writer: DocumentWriter(label: "generation-\(UUID().uuidString)", io: io),
            autosaveDelay: 0, watchesExternalChanges: false)

        document.handleEdit("generation one")
        document.saveNow()
        document.handleEdit("generation two")

        await waitUntil(timeout: 2) { document.saveState == .saved && !document.isDirty }
        XCTAssertEqual(try FileService.load(url), "generation two")
    }

    func testExternalChangeIsNotOverwrittenAndCanBeReloaded() async throws {
        let url = try makeFile("initial")
        let preferences = makePreferences(autoSave: false)
        let document = try DocumentModel(url: url, preferences: preferences,
                                         writer: writer(), watchesExternalChanges: false)
        let conflictFound = expectation(description: "external conflict")
        document.onSaveConflict = { _ in conflictFound.fulfill() }
        document.handleEdit("local")
        try FileService.save("external", to: url)

        document.saveNow()
        await fulfillment(of: [conflictFound], timeout: 1)

        XCTAssertEqual(try FileService.load(url), "external")
        XCTAssertTrue(document.isDirty)
        XCTAssertNotNil(document.pendingConflict)
        document.resolveConflict(.reloadDisk)
        XCTAssertEqual(document.source, "external")
        XCTAssertFalse(document.isDirty)
        XCTAssertEqual(document.saveState, .saved)
    }

    func testSynchronousCloseSaveFailureCannotClearDirtyState() throws {
        let url = try makeFile("before")
        let preferences = makePreferences(autoSave: true)
        let document = try DocumentModel(url: url, preferences: preferences,
                                         writer: failingWriter(message: "Permission denied"),
                                         watchesExternalChanges: false)
        document.handleEdit("after")

        let result = document.saveSynchronously(notifyFailure: false)

        XCTAssertEqual(result, .failure("Permission denied"))
        XCTAssertTrue(document.isDirty)
        XCTAssertEqual(document.saveState, .failed("Permission denied"))
        XCTAssertEqual(try FileService.load(url), "before")
    }

    func testSynchronousCloseFlushesNewestGenerationBehindInFlightWrite() throws {
        let url = try makeFile("before")
        let preferences = makePreferences(autoSave: true)
        let io = DocumentWriterIO(
            read: { try FileService.loadSnapshot($0) },
            write: { source, url in
                Thread.sleep(forTimeInterval: 0.05)
                try FileService.save(source, to: url)
            })
        let document = try DocumentModel(
            url: url, preferences: preferences,
            writer: DocumentWriter(label: "close-generation-\(UUID().uuidString)", io: io),
            watchesExternalChanges: false)
        document.handleEdit("first")
        document.saveNow()
        document.handleEdit("newest")

        let result = document.saveSynchronously(notifyFailure: false)

        guard case .success = result else { return XCTFail("expected save, got \(result)") }
        XCTAssertEqual(try FileService.load(url), "newest")
        XCTAssertFalse(document.isDirty)
        XCTAssertEqual(document.saveState, .saved)
    }

    func testExplicitKeepMineRetriesAgainstObservedExternalRevision() throws {
        let url = try makeFile("initial")
        let preferences = makePreferences(autoSave: false)
        let document = try DocumentModel(url: url, preferences: preferences,
                                         writer: writer(), watchesExternalChanges: false)
        document.handleEdit("local")
        try FileService.save("external", to: url)

        let first = document.saveSynchronously(notifyFailure: false)
        guard case .conflict(let disk) = first else {
            return XCTFail("expected conflict, got \(first)")
        }
        let conflict = DocumentConflict(url: url, disk: disk)
        document.acceptConflictForSynchronousOverwrite(conflict)
        let retry = document.saveSynchronously(notifyFailure: false)

        guard case .success = retry else { return XCTFail("expected retry success, got \(retry)") }
        XCTAssertEqual(try FileService.load(url), "local")
        XCTAssertFalse(document.isDirty)
    }

    private func makeFile(_ source: String) throws -> URL {
        let url = temporaryDirectory.appendingPathComponent("note-\(UUID().uuidString).md")
        try FileService.save(source, to: url)
        return url
    }

    private func makePreferences(autoSave: Bool) -> Preferences {
        let name = "vireo-document-preferences-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let preferences = Preferences(defaults: defaults)
        preferences.autoSave = autoSave
        return preferences
    }

    private func writer() -> DocumentWriter {
        DocumentWriter(label: "document-test-\(UUID().uuidString)")
    }

    private func failingWriter(message: String) -> DocumentWriter {
        struct Failure: LocalizedError {
            var message: String
            var errorDescription: String? { message }
        }
        return DocumentWriter(
            label: "document-failure-\(UUID().uuidString)",
            io: DocumentWriterIO(read: { try FileService.loadSnapshot($0) },
                                 write: { _, _ in throw Failure(message: message) }))
    }

    private func waitUntil(timeout: TimeInterval = 1,
                           _ condition: @escaping @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("condition not met before timeout")
    }
}
