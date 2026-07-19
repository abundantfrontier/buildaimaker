import XCTest
import BAMModels
import BAMCore
import BAMPersistence
@testable import BAMJobs

final class JobQueueControllerTests: XCTestCase {
    func testHappyPathQueuedToSucceeded() async throws {
        let (controller, _, _) = try JobQueueController.makeInMemoryForTesting()
        let jobId = BAMID.generate()
        let spec = JobSpec.llm(
            id: jobId,
            baseModelId: DomainFixtures.baseModelId,
            baseModelSourceKey: "fake/model",
            datasetVersionId: DomainFixtures.datasetVersionId
        )

        let enqueued = try await controller.enqueue(spec: spec)
        XCTAssertEqual(enqueued.status, .queued)

        // Wait for processing to finish.
        let terminal = try await waitForStatus(controller, jobId: jobId, timeout: 5) {
            JobStateMachine.isTerminal($0)
        }
        XCTAssertEqual(terminal, .succeeded)

        let jobs = try await controller.listJobs()
        XCTAssertEqual(jobs.count, 1)
        XCTAssertEqual(jobs[0].status, .succeeded)
        XCTAssertNil(jobs[0].errorCode)

        // Progress should have advanced.
        let progress = await controller.progress(for: jobId)
        XCTAssertNotNil(progress)
        XCTAssertGreaterThan(progress?.step ?? 0, 0)
    }

    func testCancelQueuedJob() async throws {
        // Use a very slow runner so the second job stays queued.
        let db = try LibraryDatabase.openInMemory()
        let store = JobStore(database: db)
        let slow = FakeTrainingRunner(
            config: FakeRunnerConfig(
                stepCount: 100,
                stepInterval: .milliseconds(50),
                prepareDelay: .milliseconds(200)
            )
        )
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("bam-jobs-cancel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let controller = JobQueueController(
            store: store,
            runner: slow,
            libraryRoot: tmp,
            heartbeatTimeout: 30
        )

        let firstId = BAMID.generate()
        let secondId = BAMID.generate()
        _ = try await controller.enqueue(spec: makeSpec(id: firstId))
        _ = try await controller.enqueue(spec: makeSpec(id: secondId))

        // Cancel the second while it should still be queued (first is preparing/running).
        try await controller.cancel(jobId: secondId)

        let second = try await waitForStatus(controller, jobId: secondId, timeout: 3) {
            $0 == .cancelled
        }
        XCTAssertEqual(second, .cancelled)

        // First should still complete.
        let first = try await waitForStatus(controller, jobId: firstId, timeout: 15) {
            JobStateMachine.isTerminal($0)
        }
        XCTAssertEqual(first, .succeeded)
    }

    func testCancelRunningJob() async throws {
        let db = try LibraryDatabase.openInMemory()
        let store = JobStore(database: db)
        let runner = FakeTrainingRunner(
            config: FakeRunnerConfig(
                stepCount: 40,
                stepInterval: .milliseconds(40),
                prepareDelay: .milliseconds(5)
            )
        )
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("bam-jobs-cancel-run-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let controller = JobQueueController(
            store: store,
            runner: runner,
            libraryRoot: tmp,
            heartbeatTimeout: 30
        )

        let jobId = BAMID.generate()
        _ = try await controller.enqueue(spec: makeSpec(id: jobId))

        // Wait until running.
        _ = try await waitForStatus(controller, jobId: jobId, timeout: 3) { $0 == .running }
        try await controller.cancel(jobId: jobId)

        let terminal = try await waitForStatus(controller, jobId: jobId, timeout: 5) {
            JobStateMachine.isTerminal($0)
        }
        XCTAssertEqual(terminal, .cancelled)

        let job = try await controller.listJobs().first { $0.id == jobId }
        XCTAssertEqual(job?.errorCode, BAMErrorCode.cancelled.rawValue)
    }

    func testConcurrencyOneJobAtATime() async throws {
        let (controller, _, _) = try JobQueueController.makeInMemoryForTesting(
            runnerConfig: FakeRunnerConfig(
                stepCount: 4,
                stepInterval: .milliseconds(20),
                prepareDelay: .milliseconds(5)
            )
        )

        let ids = (0 ..< 3).map { _ in BAMID.generate() }
        for id in ids {
            _ = try await controller.enqueue(spec: makeSpec(id: id))
        }

        // Poll: never more than one running.
        let deadline = Date().addingTimeInterval(10)
        var sawRunning = false
        while Date() < deadline {
            let jobs = try await controller.listJobs()
            let running = jobs.filter { $0.status == .running }
            XCTAssertLessThanOrEqual(running.count, 1)
            if !running.isEmpty { sawRunning = true }
            if jobs.allSatisfy({ JobStateMachine.isTerminal($0.status) }) {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(sawRunning)
        let finalJobs = try await controller.listJobs()
        XCTAssertEqual(finalJobs.filter { $0.status == .succeeded }.count, 3)
    }

    func testRecoverStaleHeartbeatMarksInterrupted() async throws {
        let db = try LibraryDatabase.openInMemory()
        let store = JobStore(database: db)
        let runner = FakeTrainingRunner(config: .testing)
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("bam-jobs-stale-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let controller = JobQueueController(
            store: store,
            runner: runner,
            libraryRoot: tmp,
            heartbeatTimeout: 0.05
        )

        let jobId = BAMID.generate()
        let paths = JobPathsFactory.make(jobId: jobId, libraryRoot: tmp)
        try FileManager.default.createDirectory(
            atPath: paths.jobDir,
            withIntermediateDirectories: true
        )

        // Insert a "running" job as if the app crashed mid-run.
        let now = JobTimestamps.now()
        let record = JobRecord(
            id: jobId,
            status: .running,
            modality: .llm,
            configJSON: "{}",
            createdAt: now,
            updatedAt: now
        )
        try store.insert(record)

        // Write a stale heartbeat file.
        let hbURL = JobPathsFactory.heartbeatURL(paths: paths)
        let stale = HeartbeatState(
            pid: 1,
            ts: JobTimestamps.now(Date().addingTimeInterval(-60)),
            rssBytes: 1
        )
        let data = try JSONEncoder().encode(stale)
        try data.write(to: hbURL)
        // Backdate mtime.
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-60)],
            ofItemAtPath: hbURL.path
        )

        try await controller.recoverStaleJobs(now: Date())
        let job = try store.fetch(id: jobId)
        XCTAssertEqual(job?.status, .interrupted)
        XCTAssertEqual(job?.errorCode, BAMErrorCode.workerHung.rawValue)
    }

    func testStateTransitionsPersisted() async throws {
        let (controller, _, _) = try JobQueueController.makeInMemoryForTesting()
        let jobId = BAMID.generate()
        _ = try await controller.enqueue(spec: makeSpec(id: jobId))

        // Observe preparing or running at some point.
        var sawPreparingOrRunning = false
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let job = try await controller.listJobs().first(where: { $0.id == jobId }) {
                if job.status == .preparing || job.status == .running {
                    sawPreparingOrRunning = true
                }
                if JobStateMachine.isTerminal(job.status) {
                    break
                }
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(sawPreparingOrRunning)
        let final = try await controller.listJobs().first { $0.id == jobId }
        XCTAssertEqual(final?.status, .succeeded)
    }

    func testIllegalCancelOnSucceededThrows() async throws {
        let (controller, _, _) = try JobQueueController.makeInMemoryForTesting()
        let jobId = BAMID.generate()
        _ = try await controller.enqueue(spec: makeSpec(id: jobId))
        _ = try await waitForStatus(controller, jobId: jobId, timeout: 5) {
            JobStateMachine.isTerminal($0)
        }
        do {
            try await controller.cancel(jobId: jobId)
            XCTFail("expected throw")
        } catch let error as BAMError {
            XCTAssertEqual(error.code, .schemaInvalid)
        }
    }

    // MARK: - Helpers

    private func makeSpec(id: String) -> JobSpec {
        JobSpec.llm(
            id: id,
            baseModelId: DomainFixtures.baseModelId,
            baseModelSourceKey: "fake/model",
            datasetVersionId: DomainFixtures.datasetVersionId
        )
    }

    private func waitForStatus(
        _ controller: JobQueueController,
        jobId: String,
        timeout: TimeInterval,
        predicate: (JobStatus) -> Bool
    ) async throws -> JobStatus {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let job = try await controller.listJobs().first(where: { $0.id == jobId }),
               predicate(job.status)
            {
                return job.status
            }
            try await Task.sleep(for: .milliseconds(15))
        }
        let jobs = try await controller.listJobs()
        let status = jobs.first { $0.id == jobId }?.status
        XCTFail("Timeout waiting for status of \(jobId); last=\(String(describing: status))")
        return status ?? .failed
    }
}
