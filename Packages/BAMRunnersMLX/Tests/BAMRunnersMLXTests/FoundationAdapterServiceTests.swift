import XCTest
import BAMCore
import BAMModels
@testable import BAMRunnersMLX

final class FoundationAdapterServiceTests: XCTestCase {
    func testPublishStubCreatesLibraryLayout() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bam-fm-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let service = FoundationAdapterService(libraryRoot: root)
        let result = try service.publishStub(
            displayName: "Test Stub",
            characterName: "Unit-7",
            datasetId: "ds-1"
        )

        XCTAssertTrue(result.isFake)
        XCTAssertEqual(result.record.kind, .foundationAdapter)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.packageURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.metadataURL.path))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: result.directoryURL.appendingPathComponent("model_card.md").path
            )
        )

        let listed = try service.listInstalled()
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed[0].displayName, "Test Stub")
        XCTAssertTrue(listed[0].isFake)
        XCTAssertEqual(listed[0].characterName, "Unit-7")
    }

    func testImportFMAdapterCopiesPackage() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bam-fm-imp-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let src = root.appendingPathComponent("incoming.fmadapter")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("REAL_ISH_PACKAGE\n".utf8).write(to: src)

        let service = FoundationAdapterService(libraryRoot: root.appendingPathComponent("lib"))
        let result = try service.importFMAdapter(
            sourceURL: src,
            displayName: "Imported Adapter"
        )

        XCTAssertFalse(result.isFake)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.packageURL.path))
        let body = try String(contentsOf: result.packageURL, encoding: .utf8)
        XCTAssertTrue(body.contains("REAL_ISH_PACKAGE"))

        let listed = try service.listInstalled()
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed[0].source, .importPackage)
    }

    func testExportDatasetForToolkitSplitsRows() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bam-fm-exp-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        var lines: [String] = []
        for i in 0..<10 {
            lines.append(
                #"{"messages":[{"role":"user","content":"u\#(i)"},{"role":"assistant","content":"a\#(i)"}]}"#
            )
        }
        let source = root.appendingPathComponent("mind.jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: source, atomically: true, encoding: .utf8)

        let out = root.appendingPathComponent("export", isDirectory: true)
        let service = FoundationAdapterService(libraryRoot: root)
        let result = try service.exportDatasetForToolkit(sourceJSONLURL: source, outputDirectory: out)

        XCTAssertEqual(result.trainRowCount + result.evalRowCount, 10)
        XCTAssertGreaterThan(result.trainRowCount, 0)
        XCTAssertGreaterThan(result.evalRowCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.readmeURL.path))
        let readme = try String(contentsOf: result.readmeURL, encoding: .utf8)
        XCTAssertTrue(readme.contains("Adapter Training Toolkit"))
    }

    func testTrainBackendTitles() {
        XCTAssertEqual(TrainBackend.openMlxLora.title, "Open MLX LoRA")
        XCTAssertEqual(TrainBackend.appleFoundationAdapter.title, "Apple Foundation Adapter")
        XCTAssertEqual(ArtifactKind.foundationAdapter.rawValue, "foundation_adapter")
    }
}
