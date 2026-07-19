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

    func testScanDiscoversAdapterOnlyLayout() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("bam-scan-adapter-\(UUID().uuidString)", isDirectory: true)
        let modelDir = tmp.appendingPathComponent("adapter-only", isDirectory: true)
        try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        try Data("{}".utf8).write(to: modelDir.appendingPathComponent("adapter_config.json"))

        let scanner = LocalModelScanner(modelsBaseURL: tmp)
        let results = try scanner.scan()
        XCTAssertEqual(results.count, 1)
        let hit = try XCTUnwrap(results.first)
        XCTAssertEqual(hit.directoryName, "adapter-only")
        XCTAssertFalse(hit.hasConfigJSON)
        XCTAssertTrue(hit.hasAdapterConfigJSON)
        XCTAssertEqual(hit.displayName, "adapter-only")
        XCTAssertNil(hit.modelType)
    }

    func testScanSkipsInvalidPathComponents() throws {
        // validatedPathComponent rejects "", ".", "..", separators — pin that filter.
        XCTAssertNil(LibraryPaths.validatedPathComponent(""))
        XCTAssertNil(LibraryPaths.validatedPathComponent("."))
        XCTAssertNil(LibraryPaths.validatedPathComponent(".."))
        XCTAssertNil(LibraryPaths.validatedPathComponent("a/b"))
        XCTAssertNil(LibraryPaths.validatedPathComponent("a\\b"))
        XCTAssertNil(LibraryPaths.validatedPathComponent("a\0b"))
        XCTAssertEqual(LibraryPaths.validatedPathComponent("ok-model"), "ok-model")

        // On-disk: create a real model next to a "." name cannot be created as child
        // (FS treats "." as self). Use a symlink-named escape instead is covered elsewhere.
        // Create a valid peer and ensure only it is returned.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("bam-scan-names-\(UUID().uuidString)", isDirectory: true)
        let good = tmp.appendingPathComponent("good-model", isDirectory: true)
        try FileManager.default.createDirectory(at: good, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let scanner = LocalModelScanner(modelsBaseURL: tmp)
        let results = try scanner.scan()
        XCTAssertEqual(results.map(\.directoryName), ["good-model"])
    }

    func testScanSkipsSymlinkEscapingModelsBase() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("bam-scan-symlink-\(UUID().uuidString)", isDirectory: true)
        let modelsBase = root.appendingPathComponent("models-base", isDirectory: true)
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        let inside = modelsBase.appendingPathComponent("local-ok", isDirectory: true)

        try fm.createDirectory(at: modelsBase, withIntermediateDirectories: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try fm.createDirectory(at: inside, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        try Data("{\"model_type\":\"outside\"}".utf8)
            .write(to: outside.appendingPathComponent("config.json"))
        try Data("{\"model_type\":\"inside\"}".utf8)
            .write(to: inside.appendingPathComponent("config.json"))

        let escapeLink = modelsBase.appendingPathComponent("escape-link", isDirectory: false)
        try fm.createSymbolicLink(at: escapeLink, withDestinationURL: outside)

        let scanner = LocalModelScanner(modelsBaseURL: modelsBase)
        let results = try scanner.scan()

        // Outside symlink must be omitted; only the in-base directory remains.
        XCTAssertEqual(results.map(\.directoryName), ["local-ok"])
        XCTAssertEqual(results.first?.modelType, "inside")
        XCTAssertFalse(results.contains { $0.directoryName == "escape-link" })
    }

    func testIsPathUnderBase() {
        let base = URL(fileURLWithPath: "/tmp/models/base", isDirectory: true)
        let child = URL(fileURLWithPath: "/tmp/models/base/abc", isDirectory: true)
        let sibling = URL(fileURLWithPath: "/tmp/models/base-evil", isDirectory: true)
        let outside = URL(fileURLWithPath: "/tmp/other", isDirectory: true)

        XCTAssertTrue(LocalModelScanner.isPath(child, under: base))
        XCTAssertTrue(LocalModelScanner.isPath(base, under: base))
        XCTAssertFalse(LocalModelScanner.isPath(sibling, under: base))
        XCTAssertFalse(LocalModelScanner.isPath(outside, under: base))
    }

    func testDefaultScannerUsesLibraryPathsModelsBase() {
        let scanner = LocalModelScanner()
        XCTAssertEqual(scanner.modelsBaseURL.path, LibraryPaths.modelsBase.path)
    }
}
