import XCTest
@testable import BAMDatasets
import BAMModels

final class MindDatasetUpsertTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bam-mind-upsert-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func sampleJSONL() -> String {
        let row: [String: Any] = [
            "messages": [
                ["role": "user", "content": "Hi"],
                ["role": "assistant", "content": "Hello from Robby."],
            ],
        ]
        let data = try! JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
        return String(data: data, encoding: .utf8)! + "\n"
    }

    func testMergeByStableIdDoesNotDuplicate() throws {
        let service = try DatasetLibraryService.openInMemoryForTesting(libraryRoot: root)
        let jsonl = sampleJSONL()
        let first = try service.upsertMindJSONL(
            jsonl: jsonl,
            name: "Robby mind",
            existingDatasetId: nil,
            policy: .mergeByStableId
        )
        XCTAssertTrue(first.created)

        let second = try service.upsertMindJSONL(
            jsonl: jsonl,
            name: "Robby mind",
            existingDatasetId: first.datasetId,
            policy: .mergeByStableId
        )
        XCTAssertEqual(second.datasetId, first.datasetId)
        XCTAssertTrue(second.unchanged)
        XCTAssertFalse(second.created)

        let all = try service.listDatasets()
        XCTAssertEqual(all.count, 1)
    }

    func testAlwaysCreateMakesNewRows() throws {
        let service = try DatasetLibraryService.openInMemoryForTesting(libraryRoot: root)
        let jsonl = sampleJSONL()
        let a = try service.upsertMindJSONL(
            jsonl: jsonl,
            name: "Robby mind",
            existingDatasetId: nil,
            policy: .alwaysCreate
        )
        let b = try service.upsertMindJSONL(
            jsonl: jsonl,
            name: "Robby mind",
            existingDatasetId: a.datasetId,
            policy: .alwaysCreate
        )
        XCTAssertNotEqual(a.datasetId, b.datasetId)
        XCTAssertEqual(try service.listDatasets().count, 2)
    }

    func testReplaceUpdatesVersion() throws {
        let service = try DatasetLibraryService.openInMemoryForTesting(libraryRoot: root)
        let first = try service.upsertMindJSONL(
            jsonl: sampleJSONL(),
            name: "Robby mind",
            existingDatasetId: nil,
            policy: .mergeByStableId
        )
        let row: [String: Any] = [
            "messages": [
                ["role": "user", "content": "Who are you?"],
                ["role": "assistant", "content": "I am Robby."],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
        let jsonl2 = String(data: data, encoding: .utf8)! + "\n"
        let second = try service.upsertMindJSONL(
            jsonl: jsonl2,
            name: "Robby mind",
            existingDatasetId: first.datasetId,
            policy: .replaceExisting
        )
        XCTAssertEqual(second.datasetId, first.datasetId)
        XCTAssertFalse(second.unchanged)
        XCTAssertNotEqual(second.versionId, first.versionId)
        let versions = try service.store.versions(datasetId: first.datasetId)
        XCTAssertEqual(versions.count, 2)
    }
}
