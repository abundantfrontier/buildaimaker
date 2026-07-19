import BAMCore
import BAMJobs
import BAMModels
import BAMRunners
import XCTest

@testable import BAMRunnersMLX

final class DryRunTests: XCTestCase {
    private var libraryRoot: URL!

    override func setUpWithError() throws {
        libraryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("bam-dry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: libraryRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: libraryRoot)
    }

    func testMaterializeOnlyDryRunService() async throws {
        let source = try writeFixtureJSONL()
        let modelDir = try writeFixtureModel()

        let service = DryRunService(
            libraryRoot: libraryRoot,
            supervisorConfig: .testing,
            invokeWorker: false,
            availableUnifiedGBOverride: 32
        )

        let result = try await service.validateAndDryRun(
            sourceJSONLURL: source,
            baseModelPath: modelDir,
            baseModelId: DomainFixtures.baseModelId,
            baseModelSourceKey: "buildaimaker/tiny-qwen-mlx-fixture",
            datasetVersionId: DomainFixtures.datasetVersionId
        )

        XCTAssertFalse(result.didTrain)
        XCTAssertEqual(result.workerExecutablePath, "(materialize-only)")
        try JobMaterializer.assertLayoutExists(
            jobDir: URL(fileURLWithPath: result.materialize.paths.jobDir, isDirectory: true)
        )
    }

    func testHardwareGateBlocksDryRun() async {
        let source: URL
        let modelDir: URL
        do {
            source = try writeFixtureJSONL()
            modelDir = try writeFixtureModel()
        } catch {
            XCTFail("fixture setup failed: \(error)")
            return
        }

        let service = DryRunService(
            libraryRoot: libraryRoot,
            invokeWorker: false,
            availableUnifiedGBOverride: 8
        )

        do {
            _ = try await service.validateAndDryRun(
                sourceJSONLURL: source,
                baseModelPath: modelDir,
                baseModelId: "m",
                baseModelSourceKey: "k",
                datasetVersionId: "v"
            )
            XCTFail("expected preflight refuse")
        } catch let error as BAMError {
            XCTAssertEqual(error.code, .preflightMemory)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testPrepareOnlyWithEchoWorker() async throws {
        let exe: URL
        do {
            exe = try resolveEchoWorker()
        } catch {
            throw XCTSkip("bam-echo-worker not built — run swift build first")
        }

        let source = try writeFixtureJSONL()
        let modelDir = try writeFixtureModel()

        var config = ProcessSupervisorConfig.testing
        config.extraEnvironment = [
            "BAM_ECHO_MODE": "happy",
            "BAM_ECHO_STEPS": "1",
            "BAM_ECHO_STEP_MS": "10",
        ]

        let client = MLXWorkerClient(
            executableURL: exe,
            config: config
        )

        let request = LLMMaterializeRequest(
            libraryRoot: libraryRoot,
            sourceJSONLURL: source,
            baseModelPath: modelDir,
            baseModelId: DomainFixtures.baseModelId,
            baseModelSourceKey: "echo/model",
            datasetVersionId: DomainFixtures.datasetVersionId
        )

        let result = try await client.dryRun(request: request)
        XCTAssertFalse(result.didTrain)
        XCTAssertEqual(result.capabilities?.modalities.contains(.llm), true)
        XCTAssertNotNil(result.workerId)
        try JobMaterializer.assertLayoutExists(
            jobDir: URL(fileURLWithPath: result.materialize.paths.jobDir, isDirectory: true)
        )

        // Issue 1: dry-run must not leave cancel.flag (would mark job cancelled).
        XCTAssertFalse(
            CancelFlag.exists(at: result.materialize.paths.cancelFlagPath),
            "dry-run teardown must not write cancel.flag"
        )

        // Issue 4: observational prepare-only proof — no train side-effect artifacts.
        let fm = FileManager.default
        let checkpointDir = URL(fileURLWithPath: result.materialize.paths.checkpointPath, isDirectory: true)
        let artifactsDir = URL(fileURLWithPath: result.materialize.paths.outputPath, isDirectory: true)
        let checkpointChildren =
            (try? fm.contentsOfDirectory(atPath: checkpointDir.path)) ?? []
        let artifactChildren =
            (try? fm.contentsOfDirectory(atPath: artifactsDir.path)) ?? []
        XCTAssertTrue(
            checkpointChildren.isEmpty,
            "prepare-only dry-run must not write checkpoints; got \(checkpointChildren)"
        )
        XCTAssertTrue(
            artifactChildren.isEmpty,
            "prepare-only dry-run must not write train artifacts; got \(artifactChildren)"
        )
        // No adapter-style outputs under job dir.
        let jobDir = URL(fileURLWithPath: result.materialize.paths.jobDir, isDirectory: true)
        let jobListing = try fm.contentsOfDirectory(atPath: jobDir.path)
        XCTAssertFalse(jobListing.contains("adapter_config.json"))
        XCTAssertFalse(jobListing.contains { $0.hasSuffix(".safetensors") })
    }

    // MARK: - Helpers

    private func writeFixtureJSONL() throws -> URL {
        let url = libraryRoot.appendingPathComponent("source.jsonl")
        let body = """
            {"messages":[{"role":"user","content":"hi"},{"role":"assistant","content":"yo"}]}
            """
        try Data(body.utf8).write(to: url)
        return url
    }

    private func writeFixtureModel() throws -> URL {
        let dir = libraryRoot
            .appendingPathComponent("models/base/tiny", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: dir.appendingPathComponent("config.json"))
        return dir
    }

    private func resolveEchoWorker() throws -> URL {
        let env = ProcessInfo.processInfo.environment
        if let override = env["BAM_ECHO_WORKER_PATH"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        var dir = cwd
        for _ in 0 ..< 10 {
            for config in ["debug", "release"] {
                let candidates = [
                    dir.appendingPathComponent(".build/\(config)/bam-echo-worker"),
                    dir.appendingPathComponent(".build/arm64-apple-macosx/\(config)/bam-echo-worker"),
                    dir.appendingPathComponent(".build/x86_64-apple-macosx/\(config)/bam-echo-worker"),
                ]
                for c in candidates where FileManager.default.isExecutableFile(atPath: c.path) {
                    return c
                }
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        throw XCTSkip("bam-echo-worker binary not found")
    }
}
