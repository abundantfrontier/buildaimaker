import BAMCore
import BAMJobs
import BAMModels
import BAMRunners
import XCTest

@testable import BAMRunnersMLX

final class LoRATrainTests: XCTestCase {
    private var libraryRoot: URL!

    override func setUpWithError() throws {
        libraryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("bam-lora-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: libraryRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: libraryRoot)
    }

    func testModelCardRendersHoldOutAndSamples() {
        let card = ModelCardContent(
            title: "LoRA Adapter",
            baseModelSourceKey: "buildaimaker/tiny-qwen-mlx-fixture",
            method: "lora",
            jobId: "job-1",
            adapterArtifactId: "art-1",
            holdOutLoss: 1.25,
            trainLoss: 0.9,
            sampleGenerations: ModelCardContent.stubSamples(),
            hyperparametersSummary: "rank=16",
            fakeTrain: true
        )
        let md = card.renderMarkdown()
        XCTAssertTrue(md.contains("Hold-out validation loss"))
        XCTAssertTrue(md.contains("1.250000"))
        XCTAssertTrue(md.contains("Sample generations"))
        XCTAssertTrue(md.contains("Hello!"))
        XCTAssertTrue(md.contains("fake"))
    }

    func testAdapterArtifactWriterPublishesUnderModelsAdapters() throws {
        let paths = try makeMaterializedPaths()
        let spec = JobSpec.llm(
            id: paths.jobId,
            baseModelId: DomainFixtures.baseModelId,
            baseModelSourceKey: "buildaimaker/tiny-qwen-mlx-fixture",
            datasetVersionId: DomainFixtures.datasetVersionId,
            hyperparameters: LLMHyperparameters(epochs: 1, batchSize: 1)
        )

        let writer = AdapterArtifactWriter()
        let jobAdapter = try writer.ensureJobAdapterStub(
            paths: paths.paths,
            spec: spec,
            holdOutLoss: 1.1,
            trainLoss: 0.7,
            fakeTrain: true
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: jobAdapter.appendingPathComponent("adapter_config.json").path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: jobAdapter.appendingPathComponent("model_card.md").path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: jobAdapter.appendingPathComponent("metrics.json").path
            )
        )

        let artifactId = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
        let published = try writer.publishToLibrary(
            paths: paths.paths,
            spec: spec,
            artifactId: artifactId,
            holdOutLoss: 1.1,
            trainLoss: 0.7,
            fakeTrain: true
        )

        XCTAssertEqual(published.artifactId, artifactId)
        XCTAssertTrue(published.adapterDirectory.path.contains("models/adapters"))
        XCTAssertTrue(published.adapterDirectory.path.hasSuffix(artifactId))
        XCTAssertEqual(published.record.kind, .loraAdapter)
        XCTAssertEqual(published.record.jobId, spec.id)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: published.modelCardURL.path)
        )
        let cardText = try String(contentsOf: published.modelCardURL, encoding: .utf8)
        XCTAssertTrue(cardText.contains("Hold-out"))
        XCTAssertTrue(cardText.contains(artifactId))
    }

    func testE2ETrainWithLLMWorkerFakeMode() async throws {
        let exe: URL
        do {
            exe = try resolveLLMWorker()
        } catch {
            throw XCTSkip("bam-llm-worker not built — run swift build first")
        }

        let source = try writeFixtureJSONL()
        let modelDir = try writeFixtureModel()

        var config = ProcessSupervisorConfig.testing
        config.helloDeadline = 10
        config.heartbeatTimeout = 5
        config.extraEnvironment = [
            "BAM_LORA_FAKE": "1",
            RuntimePaths.EnvironmentKey.skipInterpreterCheck: "1",
        ]
        if let pins = RuntimePaths.resolvePinsRoot() {
            config.extraEnvironment[RuntimePaths.EnvironmentKey.pythonPinsRoot] = pins.path
        }

        let service = LoRATrainService(
            libraryRoot: libraryRoot,
            supervisorConfig: config,
            availableUnifiedGBOverride: 32,
            forceFakeTrain: true
        )

        let result = try await service.train(
            sourceJSONLURL: source,
            baseModelPath: modelDir,
            baseModelId: DomainFixtures.baseModelId,
            baseModelSourceKey: "buildaimaker/tiny-qwen-mlx-fixture",
            datasetVersionId: DomainFixtures.datasetVersionId,
            hyperparameters: LLMHyperparameters(epochs: 1, batchSize: 1),
            workerURL: exe
        )

        XCTAssertEqual(result.status, "succeeded")
        XCTAssertTrue(result.didTrain)
        XCTAssertTrue(result.fakeTrain)
        XCTAssertNotNil(result.publish)
        XCTAssertNotNil(result.holdOutLoss)

        let publish = try XCTUnwrap(result.publish)
        XCTAssertTrue(publish.adapterDirectory.path.contains("/models/adapters/"))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: publish.adapterDirectory.appendingPathComponent("adapter_config.json").path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: publish.adapterDirectory.appendingPathComponent("model_card.md").path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: publish.adapterDirectory.appendingPathComponent("adapters.safetensors").path
            )
        )

        // Job-local adapter also present.
        let jobAdapter = AdapterArtifactWriter.jobAdapterDirectory(
            paths: result.materialize.paths
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: jobAdapter.path))

        // Progress events observed.
        let hasProgress = result.events.contains { if case .progress = $0 { return true }; return false }
        XCTAssertTrue(hasProgress)
    }

    func testE2ETrainWithEchoWorkerStillPublishesAdapter() async throws {
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
            "BAM_ECHO_STEPS": "2",
            "BAM_ECHO_STEP_MS": "10",
        ]

        let service = LoRATrainService(
            libraryRoot: libraryRoot,
            supervisorConfig: config,
            availableUnifiedGBOverride: 32,
            forceFakeTrain: true
        )

        let result = try await service.train(
            sourceJSONLURL: source,
            baseModelPath: modelDir,
            baseModelId: DomainFixtures.baseModelId,
            baseModelSourceKey: "echo/model",
            datasetVersionId: DomainFixtures.datasetVersionId,
            workerURL: exe
        )

        XCTAssertEqual(result.status, "succeeded")
        XCTAssertNotNil(result.publish)
        let card = try String(
            contentsOf: try XCTUnwrap(result.publish).modelCardURL,
            encoding: .utf8
        )
        XCTAssertTrue(card.contains("Hold-out"))
        XCTAssertTrue(card.contains("Sample generations"))
    }

    func testHardwareGateBlocksTrain() async {
        let source: URL
        let modelDir: URL
        do {
            source = try writeFixtureJSONL()
            modelDir = try writeFixtureModel()
        } catch {
            XCTFail("fixture setup failed: \(error)")
            return
        }

        let service = LoRATrainService(
            libraryRoot: libraryRoot,
            availableUnifiedGBOverride: 8,
            forceFakeTrain: true
        )

        do {
            _ = try await service.train(
                sourceJSONLURL: source,
                baseModelPath: modelDir,
                baseModelId: "m",
                baseModelSourceKey: "k",
                datasetVersionId: "v",
                workerURL: URL(fileURLWithPath: "/usr/bin/true")
            )
            XCTFail("expected preflight refuse")
        } catch let error as BAMError {
            XCTAssertEqual(error.code, .preflightMemory)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testFeatureFlagLLMTrainingDefaultsOn() {
        XCTAssertTrue(FeatureFlags.default.llmTraining)
        XCTAssertTrue(FeatureFlags.default.isEnabled(.llmTraining))
    }

    // MARK: - Helpers

    private struct Materialized {
        var jobId: String
        var paths: JobPaths
    }

    private func makeMaterializedPaths() throws -> Materialized {
        let jobId = BAMID.generate()
        let jobDir = libraryRoot.appendingPathComponent("jobs/\(jobId)", isDirectory: true)
        let artifacts = jobDir.appendingPathComponent("artifacts", isDirectory: true)
        let checkpoints = jobDir.appendingPathComponent("checkpoints", isDirectory: true)
        let logs = jobDir.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: checkpoints, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)

        let paths = JobPaths(
            jobDir: jobDir.path,
            libraryRoot: libraryRoot.path,
            datasetPath: jobDir.appendingPathComponent("data/train.jsonl").path,
            baseModelPath: libraryRoot.appendingPathComponent("models/base/tiny").path,
            outputPath: artifacts.path,
            checkpointPath: checkpoints.path,
            cancelFlagPath: jobDir.appendingPathComponent("cancel.flag").path,
            logPath: logs.path
        )
        return Materialized(jobId: jobId, paths: paths)
    }

    private func writeFixtureJSONL() throws -> URL {
        let url = libraryRoot.appendingPathComponent("source.jsonl")
        let body = """
            {"messages":[{"role":"user","content":"hi"},{"role":"assistant","content":"yo"}]}
            {"messages":[{"role":"user","content":"bye"},{"role":"assistant","content":"later"}]}
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

    private func resolveLLMWorker() throws -> URL {
        let env = ProcessInfo.processInfo.environment
        if let override = env["BAM_LLM_WORKER_PATH"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return try resolveBuildProduct(named: "bam-llm-worker")
    }

    private func resolveEchoWorker() throws -> URL {
        let env = ProcessInfo.processInfo.environment
        if let override = env["BAM_ECHO_WORKER_PATH"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return try resolveBuildProduct(named: "bam-echo-worker")
    }

    private func resolveBuildProduct(named name: String) throws -> URL {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        var dir = cwd
        for _ in 0 ..< 10 {
            for config in ["debug", "release"] {
                let candidates = [
                    dir.appendingPathComponent(".build/\(config)/\(name)"),
                    dir.appendingPathComponent(".build/arm64-apple-macosx/\(config)/\(name)"),
                    dir.appendingPathComponent(".build/x86_64-apple-macosx/\(config)/\(name)"),
                ]
                for c in candidates where FileManager.default.isExecutableFile(atPath: c.path) {
                    return c
                }
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        throw XCTSkip("\(name) binary not found")
    }
}
