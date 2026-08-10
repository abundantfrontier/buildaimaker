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

        let terminal = try await waitForStatus(controller, jobId: jobId, timeout: 5) {
            JobStateMachine.isTerminal($0)
        }
        XCTAssertEqual(terminal, .succeeded)

        let jobs = try await controller.listJobs()
        XCTAssertEqual(jobs.count, 1)
        XCTAssertEqual(jobs[0].status, .succeeded)
        XCTAssertNil(jobs[0].errorCode)

        let progress = await controller.progress(for: jobId)
        XCTAssertNotNil(progress)
        XCTAssertGreaterThan(progress?.step ?? 0, 0)
        XCTAssertEqual(progress?.totalSteps, 5) // FakeRunnerConfig.testing
    }

    func testCancelQueuedJob() async throws {
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

        try await controller.cancel(jobId: secondId)

        let second = try await waitForStatus(controller, jobId: secondId, timeout: 3) {
            $0 == .cancelled
        }
        XCTAssertEqual(second, .cancelled)

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

        _ = try await waitForStatus(controller, jobId: jobId, timeout: 3) { $0 == .running }
        try await controller.cancel(jobId: jobId)

        let terminal = try await waitForStatus(controller, jobId: jobId, timeout: 5) {
            JobStateMachine.isTerminal($0)
        }
        XCTAssertEqual(terminal, .cancelled)

        let job = try await controller.listJobs().first { $0.id == jobId }
        XCTAssertEqual(job?.errorCode, BAMErrorCode.cancelled.rawValue)
    }

    func testCancelDuringPrepare() async throws {
        let db = try LibraryDatabase.openInMemory()
        let store = JobStore(database: db)
        let runner = FakeTrainingRunner(
            config: FakeRunnerConfig(
                stepCount: 5,
                stepInterval: .milliseconds(10),
                prepareDelay: .milliseconds(800)
            )
        )
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("bam-jobs-cancel-prep-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let controller = JobQueueController(
            store: store,
            runner: runner,
            libraryRoot: tmp,
            heartbeatTimeout: 30
        )

        let firstId = BAMID.generate()
        let secondId = BAMID.generate()
        _ = try await controller.enqueue(spec: makeSpec(id: firstId))
        _ = try await waitForStatus(controller, jobId: firstId, timeout: 2) { $0 == .preparing }
        try await controller.cancel(jobId: firstId)

        let terminal = try await waitForStatus(controller, jobId: firstId, timeout: 3) {
            JobStateMachine.isTerminal($0)
        }
        XCTAssertEqual(terminal, .cancelled)
        let firstJob = try await controller.listJobs().first { $0.id == firstId }
        XCTAssertEqual(firstJob?.errorCode, BAMErrorCode.cancelled.rawValue)

        // Following job can still run.
        _ = try await controller.enqueue(spec: makeSpec(id: secondId))
        let second = try await waitForStatus(controller, jobId: secondId, timeout: 5) {
            JobStateMachine.isTerminal($0)
        }
        XCTAssertEqual(second, .succeeded)
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
            // Tiny gap so created_at ordering is unambiguous even without fractional seconds.
            try await Task.sleep(for: .milliseconds(5))
        }

        let deadline = Date().addingTimeInterval(10)
        var sawRunning = false
        var firstRunningOrder: [String] = []
        while Date() < deadline {
            let jobs = try await controller.listJobs()
            let slotHolders = jobs.filter { $0.status == .preparing || $0.status == .running }
            XCTAssertLessThanOrEqual(slotHolders.count, 1, "preparing+running must be ≤1")
            let running = jobs.filter { $0.status == .running }
            if let r = running.first, !firstRunningOrder.contains(r.id) {
                firstRunningOrder.append(r.id)
                sawRunning = true
            }
            if jobs.allSatisfy({ JobStateMachine.isTerminal($0.status) }) {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(sawRunning)
        let finalJobs = try await controller.listJobs()
        XCTAssertEqual(finalJobs.filter { $0.status == .succeeded }.count, 3)
        // FIFO: first transition to running should follow enqueue order.
        XCTAssertEqual(firstRunningOrder, ids)
    }

    func testOrphanRunningBlocksUntilRecovered() async throws {
        let db = try LibraryDatabase.openInMemory()
        let store = JobStore(database: db)
        let runner = FakeTrainingRunner(config: .testing)
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("bam-jobs-orphan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let controller = JobQueueController(
            store: store,
            runner: runner,
            libraryRoot: tmp,
            heartbeatTimeout: 30
        )

        let orphanId = BAMID.generate()
        let now = JobTimestamps.now()
        try store.insert(
            JobRecord(
                id: orphanId,
                status: .running,
                modality: .llm,
                configJSON: "{}",
                createdAt: now,
                updatedAt: now
            )
        )

        let newId = BAMID.generate()
        _ = try await controller.enqueue(spec: makeSpec(id: newId))

        // processQueue should interrupt orphan then run the new job.
        let newTerminal = try await waitForStatus(controller, jobId: newId, timeout: 5) {
            JobStateMachine.isTerminal($0)
        }
        XCTAssertEqual(newTerminal, .succeeded)

        let orphan = try store.fetch(id: orphanId)
        XCTAssertEqual(orphan?.status, .interrupted)
    }

    func testRecoverFreshHeartbeatMarksInterrupted() async throws {
        let db = try LibraryDatabase.openInMemory()
        let store = JobStore(database: db)
        let runner = FakeTrainingRunner(config: .testing)
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("bam-jobs-fresh-hb-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let controller = JobQueueController(
            store: store,
            runner: runner,
            libraryRoot: tmp,
            heartbeatTimeout: 60 // HB is "fresh" within this window
        )

        let jobId = BAMID.generate()
        let paths = JobPathsFactory.make(jobId: jobId, libraryRoot: tmp)
        try FileManager.default.createDirectory(atPath: paths.jobDir, withIntermediateDirectories: true)

        let now = JobTimestamps.now()
        try store.insert(
            JobRecord(
                id: jobId,
                status: .running,
                modality: .llm,
                configJSON: "{}",
                createdAt: now,
                updatedAt: now
            )
        )

        // Fresh heartbeat (just written).
        let hbURL = JobPathsFactory.heartbeatURL(paths: paths)
        let fresh = HeartbeatState(pid: 1, ts: JobTimestamps.now(), rssBytes: 1)
        try JSONEncoder().encode(fresh).write(to: hbURL)

        try await controller.recoverStaleJobs(now: Date())
        let job = try store.fetch(id: jobId)
        XCTAssertEqual(job?.status, .interrupted)
        XCTAssertEqual(job?.errorCode, BAMErrorCode.workerHung.rawValue)
        XCTAssertTrue(job?.errorMessage?.contains("Orphan") == true)
    }

    func testCancelOrphanRunningWithoutExecute() async throws {
        let db = try LibraryDatabase.openInMemory()
        let store = JobStore(database: db)
        let runner = FakeTrainingRunner(config: .testing)
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("bam-jobs-orphan-cancel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let controller = JobQueueController(
            store: store,
            runner: runner,
            libraryRoot: tmp,
            heartbeatTimeout: 30
        )

        let jobId = BAMID.generate()
        let paths = JobPathsFactory.make(jobId: jobId, libraryRoot: tmp)
        try FileManager.default.createDirectory(atPath: paths.jobDir, withIntermediateDirectories: true)
        let now = JobTimestamps.now()
        try store.insert(
            JobRecord(
                id: jobId,
                status: .running,
                modality: .llm,
                configJSON: "{}",
                createdAt: now,
                updatedAt: now
            )
        )

        // No live execute — cancel must flip immediately and write cancel.flag.
        try await controller.cancel(jobId: jobId)
        let job = try store.fetch(id: jobId)
        XCTAssertEqual(job?.status, .cancelled)
        XCTAssertEqual(job?.errorCode, BAMErrorCode.cancelled.rawValue)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.cancelFlagPath))
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

        let now = JobTimestamps.now()
        try store.insert(
            JobRecord(
                id: jobId,
                status: .running,
                modality: .llm,
                configJSON: "{}",
                createdAt: now,
                updatedAt: now
            )
        )

        let hbURL = JobPathsFactory.heartbeatURL(paths: paths)
        let stale = HeartbeatState(
            pid: 1,
            ts: JobTimestamps.now(Date().addingTimeInterval(-60)),
            rssBytes: 1
        )
        try JSONEncoder().encode(stale).write(to: hbURL)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-60)],
            ofItemAtPath: hbURL.path
        )

        try await controller.recoverStaleJobs(now: Date())
        let job = try store.fetch(id: jobId)
        XCTAssertEqual(job?.status, .interrupted)
        XCTAssertEqual(job?.errorCode, BAMErrorCode.workerHung.rawValue)
    }

    func testLiveHeartbeatTimeoutInterrupts() async throws {
        // Long steps, no heartbeats, short timeout → live watch fires.
        let db = try LibraryDatabase.openInMemory()
        let store = JobStore(database: db)
        let runner = FakeTrainingRunner(
            config: FakeRunnerConfig(
                stepCount: 20,
                stepInterval: .milliseconds(200),
                heartbeatEverySteps: 100,
                emitHeartbeats: false,
                prepareDelay: .milliseconds(1)
            )
        )
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("bam-jobs-live-hb-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let controller = JobQueueController(
            store: store,
            runner: runner,
            libraryRoot: tmp,
            heartbeatTimeout: 0.08
        )

        let jobId = BAMID.generate()
        _ = try await controller.enqueue(spec: makeSpec(id: jobId))

        let status = try await waitForStatus(controller, jobId: jobId, timeout: 5) {
            $0 == .interrupted || JobStateMachine.isTerminal($0)
        }
        XCTAssertEqual(status, .interrupted)
        let job = try await controller.listJobs().first { $0.id == jobId }
        XCTAssertEqual(job?.errorCode, BAMErrorCode.workerHung.rawValue)

        // Queue can start a subsequent job after interrupt.
        let nextId = BAMID.generate()
        // Use a healthy runner config by reusing same controller — still no HB.
        // Re-create with normal runner for the follow-up.
        let healthy = try JobQueueController.makeInMemoryForTesting()
        _ = try await healthy.controller.enqueue(spec: makeSpec(id: nextId))
        let next = try await waitForStatus(healthy.controller, jobId: nextId, timeout: 5) {
            JobStateMachine.isTerminal($0)
        }
        XCTAssertEqual(next, .succeeded)
    }

    func testInterruptedRequeueRunsAgain() async throws {
        let db = try LibraryDatabase.openInMemory()
        let store = JobStore(database: db)
        // First run: hang via no heartbeats.
        let hangRunner = FakeTrainingRunner(
            config: FakeRunnerConfig(
                stepCount: 30,
                stepInterval: .milliseconds(150),
                emitHeartbeats: false,
                prepareDelay: .milliseconds(1)
            )
        )
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("bam-jobs-requeue-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let controller = JobQueueController(
            store: store,
            runner: hangRunner,
            libraryRoot: tmp,
            heartbeatTimeout: 0.08
        )

        let jobId = BAMID.generate()
        let spec = makeSpec(id: jobId)
        _ = try await controller.enqueue(spec: spec)

        _ = try await waitForStatus(controller, jobId: jobId, timeout: 5) { $0 == .interrupted }

        // Swap to a healthy runner by requeuing on a new controller sharing the DB.
        let healthyRunner = FakeTrainingRunner(config: .testing)
        let controller2 = JobQueueController(
            store: store,
            runner: healthyRunner,
            libraryRoot: tmp,
            heartbeatTimeout: 30
        )
        try await controller2.requeue(jobId: jobId)

        let terminal = try await waitForStatus(controller2, jobId: jobId, timeout: 5) {
            JobStateMachine.isTerminal($0)
        }
        XCTAssertEqual(terminal, .succeeded, "requeue after interrupt must not auto-cancel")
    }

    func testStateTransitionsPersisted() async throws {
        let (controller, _, _) = try JobQueueController.makeInMemoryForTesting()
        let jobId = BAMID.generate()
        _ = try await controller.enqueue(spec: makeSpec(id: jobId))

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
