import XCTest
@testable import BAMDatasets
import BAMModels

final class MindDatasetDedupeTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bam-dedupe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func jsonl(_ n: Int) -> String {
        let row: [String: Any] = [
            "messages": [
                ["role": "user", "content": "u\(n)"],
                ["role": "assistant", "content": "a\(n)"],
            ],
        ]
        let data = try! JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
        return String(data: data, encoding: .utf8)! + "\n"
    }

    func testDedupeRemovesOrphansKeepsReferenced() throws {
        let service = try DatasetLibraryService.openInMemoryForTesting(libraryRoot: root)
        // Three identical-name minds via alwaysCreate.
        let a = try service.upsertMindJSONL(
            jsonl: jsonl(1), name: "Robby mind", existingDatasetId: nil, policy: .alwaysCreate
        )
        let b = try service.upsertMindJSONL(
            jsonl: jsonl(1), name: "Robby mind", existingDatasetId: nil, policy: .alwaysCreate
        )
        let c = try service.upsertMindJSONL(
            jsonl: jsonl(2), name: "Robby mind", existingDatasetId: nil, policy: .alwaysCreate
        )
        XCTAssertEqual(try service.listDatasets().count, 3)

        // Character points at `a`.
        let dry = try service.dedupeMindDatasets(
            referencedDatasetIds: [a.datasetId],
            dryRun: true
        )
        XCTAssertTrue(dry.dryRun)
        XCTAssertTrue(dry.kept.contains(a.datasetId))
        XCTAssertEqual(try service.listDatasets().count, 3)

        let live = try service.dedupeMindDatasets(
            referencedDatasetIds: [a.datasetId],
            dryRun: false
        )
        XCTAssertFalse(live.dryRun)
        XCTAssertTrue(live.kept.contains(a.datasetId))
        XCTAssertTrue(live.deleted.contains(b.datasetId) || live.deleted.contains(c.datasetId))
        let remaining = try service.listDatasets()
        XCTAssertTrue(remaining.contains(where: { $0.id == a.datasetId }))
        XCTAssertLessThan(remaining.count, 3)
    }
}
