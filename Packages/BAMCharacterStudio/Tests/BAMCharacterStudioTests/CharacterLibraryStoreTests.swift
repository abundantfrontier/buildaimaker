import XCTest
@testable import BAMCharacterStudio

final class CharacterLibraryStoreTests: XCTestCase {
    private var tempRoot: URL!
    private var store: CharacterLibraryStore!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("bam-char-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        store = CharacterLibraryStore(libraryRoot: tempRoot)
    }

    override func tearDownWithError() throws {
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
    }

    func testSaveListLoadRoundTrip() throws {
        let draft = CharacterDraft(name: "Zorp", isComplete: false)
        try store.save(draft)
        let listed = try store.list()
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed[0].id, draft.id)
        XCTAssertEqual(listed[0].name, "Zorp")

        let loaded = try store.load(id: draft.id)
        XCTAssertEqual(loaded.name, "Zorp")
    }

    func testDeleteRemovesInProgressAndFinished() throws {
        let inProgress = CharacterDraft(name: "WIP", isComplete: false)
        let finished = CharacterDraft(name: "Done", isComplete: true)
        try store.save(inProgress)
        try store.save(finished)

        // Create asset dirs (voice previews etc.)
        let wipDir = try store.characterDirectory(id: inProgress.id)
        let doneDir = try store.characterDirectory(id: finished.id)
        try Data("preview".utf8).write(to: wipDir.appendingPathComponent("preview.wav"))
        try Data("preview".utf8).write(to: doneDir.appendingPathComponent("preview.wav"))

        XCTAssertEqual(try store.list().count, 2)

        try store.delete(id: inProgress.id)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: tempRoot.appendingPathComponent("characters/\(inProgress.id).json").path
            )
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: wipDir.path))
        XCTAssertEqual(try store.list().map(\.id), [finished.id])

        try store.delete(id: finished.id)
        XCTAssertTrue(try store.list().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: doneDir.path))
    }

    func testDeleteMissingIsNoOp() throws {
        XCTAssertNoThrow(try store.delete(id: UUID().uuidString))
    }

    func testDeleteRejectsPathEscapeId() {
        XCTAssertThrowsError(try store.delete(id: "../escape")) { error in
            // BAMError path escape
            XCTAssertTrue(String(describing: error).contains("PATH") || String(describing: error).contains("path") || String(describing: error).contains("Invalid"))
        }
    }
}
