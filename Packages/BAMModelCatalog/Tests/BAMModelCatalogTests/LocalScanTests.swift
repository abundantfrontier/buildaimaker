import XCTest
import BAMCore
import BAMModels
@testable import BAMModelCatalog

final class LocalScanTests: XCTestCase {
    func testScanEmptyDirectoryReturnsEmpty() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("bam-scan-empty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let scanner = LocalModelScanner(modelsBaseURL: tmp)
        let results = try scanner.scan()
        XCTAssertTrue(results.isEmpty)
    }

    func testScanMissingDirectoryReturnsEmpty() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("bam-scan-missing-\(UUID().uuidString)", isDirectory: true)
        // Do not create — scanner should treat missing root as empty.
        let scanner = LocalModelScanner(modelsBaseURL: missing)
        let results = try scanner.scan()
        XCTAssertTrue(results.isEmpty)
    }

    func testScanDiscoversConfigLayout() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("bam-scan-cfg-\(UUID().uuidString)", isDirectory: true)
        let modelDir = tmp.appendingPathComponent("model-a", isDirectory: true)
        try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let config: [String: Any] = [
            "model_type": "qwen2",
            "license": "Apache-2.0",
        ]
        let configData = try JSONSerialization.data(withJSONObject: config)
        try configData.write(to: modelDir.appendingPathComponent("config.json"))

        // Loose file should be ignored.
        try Data("skip".utf8).write(to: tmp.appendingPathComponent("readme.txt"))

        let scanner = LocalModelScanner(modelsBaseURL: tmp)
        let results = try scanner.scan()
        XCTAssertEqual(results.count, 1)
        let hit = try XCTUnwrap(results.first)
        XCTAssertEqual(hit.directoryName, "model-a")
        XCTAssertTrue(hit.hasConfigJSON)
        XCTAssertFalse(hit.hasAdapterConfigJSON)
        XCTAssertEqual(hit.modelType, "qwen2")
        XCTAssertEqual(hit.license, "Apache-2.0")
        XCTAssertEqual(hit.displayName, "qwen2")

        let record = hit.asModelRecord(id: DomainFixtures.baseModelId, sourceKey: "test/key")
        XCTAssertEqual(record.id, DomainFixtures.baseModelId)
        XCTAssertEqual(record.kind, .base)
        XCTAssertEqual(record.sourceKey, "test/key")
        XCTAssertEqual(record.localPath, hit.localPath)
        XCTAssertEqual(record.license, "Apache-2.0")
    }

    func testDefaultScannerUsesLibraryPathsModelsBase() {
        let scanner = LocalModelScanner()
        XCTAssertEqual(scanner.modelsBaseURL.path, LibraryPaths.modelsBase.path)
    }
}
