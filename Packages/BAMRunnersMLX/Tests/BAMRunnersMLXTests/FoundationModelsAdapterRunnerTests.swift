import XCTest
import BAMCore
import BAMJobs
import BAMModels
@testable import BAMRunnersMLX

final class FoundationModelsAdapterRunnerTests: XCTestCase {
    func testToolkitProbeWithoutPath() {
        let probe = FoundationToolkitProbe.probe(
            config: FoundationToolkitConfig(toolkitRoot: nil)
        )
        XCTAssertFalse(probe.installed)
        XCTAssertTrue(probe.detail.contains("No toolkit"))
    }

    func testSignatureMismatchWarning() {
        let warn = FoundationAdapterService.signatureMismatchWarning(
            stored: "macos-26.0.1",
            current: "macos-27.0.0"
        )
        XCTAssertNotNil(warn)
        XCTAssertTrue(warn!.contains("MISMATCH") || warn!.contains("retrain") || warn!.contains("26") || warn!.contains("27"))

        let ok = FoundationAdapterService.signatureMismatchWarning(
            stored: "macos-26.0.1",
            current: "macos-26.0.5"
        )
        XCTAssertNil(ok, "Same major.minor should be compatible")
    }

    func testRunnerPrepareAndRunStub() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bam-fm-run-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let jobId = BAMID.generate()
        let jobDir = root.appendingPathComponent("jobs/\(jobId)", isDirectory: true)
        try FileManager.default.createDirectory(at: jobDir, withIntermediateDirectories: true)

        // Minimal mind JSONL
        let dataDir = jobDir.appendingPathComponent("data", isDirectory: true)
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        let jsonl = dataDir.appendingPathComponent("train.jsonl")
        let line = #"{"messages":[{"role":"user","content":"hi"},{"role":"assistant","content":"hello"}]}"# + "\n"
        try line.write(to: jsonl, atomically: true, encoding: .utf8)

        let paths = JobPaths(
            jobDir: jobDir.path,
            libraryRoot: root.path,
            datasetPath: jsonl.path,
            baseModelPath: nil,
            outputPath: jobDir.appendingPathComponent("artifacts").path,
            checkpointPath: jobDir.appendingPathComponent("checkpoints").path,
            cancelFlagPath: jobDir.appendingPathComponent("cancel.flag").path,
            logPath: jobDir.appendingPathComponent("logs/run.log").path
        )
        let spec = JobSpec.foundationAdapter(id: jobId, datasetVersionId: "dv1")

        let runner = FoundationModelsAdapterRunner(
            config: .testing,
            toolkitConfig: FoundationToolkitConfig(toolkitRoot: nil)
        )
        try await runner.prepare(job: spec, paths: paths)

        var gotResult = false
        var fake = false
        for try await event in runner.run(job: spec, paths: paths) {
            if case .result(let status, _, let message) = event {
                XCTAssertEqual(status, "succeeded")
                fake = message?.contains("fake=true") == true || message?.contains("stub") == true
                gotResult = true
            }
        }
        XCTAssertTrue(gotResult)
        XCTAssertTrue(fake)

        let listed = try FoundationAdapterService(libraryRoot: root).listInstalled()
        XCTAssertFalse(listed.isEmpty)
    }

    func testRunnerCapabilitiesIncludeFoundation() async throws {
        let runner = FoundationModelsAdapterRunner(config: .testing)
        let caps = try await runner.capabilities()
        XCTAssertTrue(caps.modalities.contains(.foundationAdapter))
        XCTAssertTrue(caps.modelFamilies.contains("apple-foundation"))
    }
}
