import BAMCore
import BAMJobs
import BAMModels
import XCTest

@testable import BAMRunners

final class ProcessSupervisorTests: XCTestCase {
    private var libraryRoot: URL!

    override func setUpWithError() throws {
        libraryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("bam-sup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: libraryRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: libraryRoot)
    }

    func testHappyPathWithEchoWorker() async throws {
        let exe = try resolveEchoWorker()
        let jobId = UUID().uuidString
        let paths = makePaths(jobId: jobId)
        let job = JobSpec.llm(
            id: jobId,
            baseModelId: UUID().uuidString,
            baseModelSourceKey: "echo/model",
            datasetVersionId: UUID().uuidString
        )

        var config = ProcessSupervisorConfig.testing
        config.extraEnvironment = [
            "BAM_ECHO_MODE": "happy",
            "BAM_ECHO_STEPS": "3",
            "BAM_ECHO_STEP_MS": "20",
        ]
        let supervisor = ProcessSupervisor(executableURL: exe, config: config)
        let caps = try await supervisor.start(paths: paths)
        XCTAssertTrue(caps.modalities.contains(.llm))
        try await supervisor.prepare(job: job, paths: paths)

        var sawProgress = false
        var resultStatus: String?
        for try await event in await supervisor.run(job: job, paths: paths) {
            if case .progress = event { sawProgress = true }
            if case let .result(status, _, _) = event { resultStatus = status }
        }
        XCTAssertTrue(sawProgress)
        XCTAssertEqual(resultStatus, "succeeded")
    }

    func testCancelMidRunWritesFlagAndResult() async throws {
        let exe = try resolveEchoWorker()
        let jobId = UUID().uuidString
        let paths = makePaths(jobId: jobId)
        let job = JobSpec(id: jobId, modality: .llm)

        var config = ProcessSupervisorConfig.testing
        config.extraEnvironment = [
            "BAM_ECHO_MODE": "cancel",
            "BAM_ECHO_STEPS": "20",
            "BAM_ECHO_STEP_MS": "80",
        ]
        // Longer grace so worker can observe cancel.flag cooperatively.
        config.cancelGraceT1 = 2
        config.cancelGraceT2 = 1

        let supervisor = ProcessSupervisor(executableURL: exe, config: config)
        _ = try await supervisor.start(paths: paths)
        try await supervisor.prepare(job: job, paths: paths)

        let stream = await supervisor.run(job: job, paths: paths)
        var resultStatus: String?

        let cancelTask = Task {
            try? await Task.sleep(for: .milliseconds(120))
            await supervisor.cancel(jobId: jobId, paths: paths)
        }

        for try await event in stream {
            if case let .result(status, _, _) = event {
                resultStatus = status
            }
        }
        await cancelTask.value

        XCTAssertEqual(resultStatus, "cancelled")
        XCTAssertTrue(CancelFlag.exists(at: paths.cancelFlagPath))
    }

    func testHungWorkerDetected() async throws {
        let exe = try resolveEchoWorker()
        let jobId = UUID().uuidString
        let paths = makePaths(jobId: jobId)
        let job = JobSpec(id: jobId, modality: .llm)

        var config = ProcessSupervisorConfig.testing
        config.heartbeatTimeout = 0.4
        config.extraEnvironment = ["BAM_ECHO_MODE": "hung"]

        let supervisor = ProcessSupervisor(executableURL: exe, config: config)
        _ = try await supervisor.start(paths: paths)
        try await supervisor.prepare(job: job, paths: paths)

        var sawHung = false
        do {
            for try await _ in await supervisor.run(job: job, paths: paths) {
                // may not get events
            }
        } catch let error as BAMError {
            sawHung = error.code == .workerHung
        }
        XCTAssertTrue(sawHung, "expected BAM_WORKER_HUNG")
    }

    func testProtocolMismatchOnHello() async throws {
        let exe = try resolveEchoWorker()
        let jobId = UUID().uuidString
        let paths = makePaths(jobId: jobId)

        var config = ProcessSupervisorConfig.testing
        config.extraEnvironment = ["BAM_ECHO_MODE": "mismatch"]

        let supervisor = ProcessSupervisor(executableURL: exe, config: config)
        do {
            _ = try await supervisor.start(paths: paths)
            XCTFail("expected protocol mismatch")
        } catch let error as BAMError {
            XCTAssertEqual(error.code, .protocolMismatch)
        }
    }

    func testPathJailBlocksEscapingReferenceAudio() async throws {
        let exe = try resolveEchoWorker()
        let jobId = UUID().uuidString
        var paths = makePaths(jobId: jobId)
        paths.referenceAudioPath = "/tmp/not-under-library/evil.wav"
        let job = JobSpec.voiceClone(
            id: jobId,
            consentRecordId: UUID().uuidString,
            consentContentHash: "sha256:dead"
        )

        var config = ProcessSupervisorConfig.testing
        config.extraEnvironment = ["BAM_ECHO_MODE": "happy"]
        let supervisor = ProcessSupervisor(executableURL: exe, config: config)
        // start validates job paths under library root — escaping ref fails validate.
        do {
            _ = try await supervisor.start(paths: paths)
            try await supervisor.prepare(job: job, paths: paths)
            XCTFail("expected path escape")
        } catch let error as BAMError {
            XCTAssertEqual(error.code, .pathEscape)
        }
    }

    func testSupervisedTrainingRunnerEndToEnd() async throws {
        let exe = try resolveEchoWorker()
        let jobId = UUID().uuidString
        let paths = makePaths(jobId: jobId)
        let job = JobSpec(id: jobId, modality: .llm)

        var config = ProcessSupervisorConfig.testing
        config.extraEnvironment = [
            "BAM_ECHO_MODE": "happy",
            "BAM_ECHO_STEPS": "2",
            "BAM_ECHO_STEP_MS": "15",
        ]
        let runner = SupervisedTrainingRunner(
            executableURL: exe,
            config: config
        )
        try await runner.prepare(job: job, paths: paths)
        var resultStatus: String?
        for try await event in runner.run(job: job, paths: paths) {
            if case let .result(status, _, _) = event {
                resultStatus = status
            }
        }
        XCTAssertEqual(resultStatus, "succeeded")
    }

    func testCancelFlagHelper() throws {
        let flag = libraryRoot.appendingPathComponent("cancel.flag").path
        XCTAssertFalse(CancelFlag.exists(at: flag))
        try CancelFlag.write(at: flag)
        XCTAssertTrue(CancelFlag.exists(at: flag))
        CancelFlag.clear(at: flag)
        XCTAssertFalse(CancelFlag.exists(at: flag))
    }

    // MARK: - Helpers

    private func makePaths(jobId: String) -> JobPaths {
        JobPathsFactory.make(jobId: jobId, libraryRoot: libraryRoot)
    }

    private func resolveEchoWorker() throws -> URL {
        let env = ProcessInfo.processInfo.environment
        if let override = env["BAM_ECHO_WORKER_PATH"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        // Walk up from CWD for .build/**/bam-echo-worker
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
        throw XCTSkip("bam-echo-worker binary not found — run `swift build` first")
    }
}
