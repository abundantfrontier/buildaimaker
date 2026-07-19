import BAMCore
import BAMModels
import BAMPersistence
import Foundation

/// Single-slot job queue controller (concurrency = 1 training job).
///
/// Orchestrates status transitions, fake/real `TrainingRunner` execution,
/// heartbeat tracking, cancel, and persistence via `JobStore`.
public actor JobQueueController {
    public let store: JobStore
    public let runner: any TrainingRunner
    public let heartbeatTimeout: TimeInterval
    public let libraryRoot: URL

    /// Last orchestration / persistence error (best-effort surface for UI).
    public private(set) var lastError: String?

    private var isProcessing = false
    private var currentJobId: String?
    /// Cancel signals for the **current** live execution generation only.
    /// Cleared at start/end of `execute` and after applied cancels so
    /// `interrupted → queued` requeue is not poisoned.
    private var cancelRequested: Set<String> = []
    private var progressByJob: [String: JobProgressSnapshot] = [:]
    private var heartbeatByJob: [String: HeartbeatMonitor] = [:]
    private var pathsByJob: [String: JobPaths] = [:]
    private var runTask: Task<Void, Never>?
    private var heartbeatWatchTask: Task<Void, Never>?

    private var jobsChangedContinuations: [UUID: AsyncStream<[JobRecord]>.Continuation] = [:]
    private var progressContinuations: [UUID: AsyncStream<(String, JobProgressSnapshot)>.Continuation] = [:]

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    public init(
        store: JobStore,
        runner: any TrainingRunner,
        libraryRoot: URL = LibraryPaths.libraryRoot,
        heartbeatTimeout: TimeInterval = HeartbeatMonitor.defaultTimeoutSeconds
    ) {
        self.store = store
        self.runner = runner
        self.libraryRoot = libraryRoot
        self.heartbeatTimeout = heartbeatTimeout
    }

    deinit {
        runTask?.cancel()
        heartbeatWatchTask?.cancel()
    }

    // MARK: - Public API

    /// Enqueues a job (status → `queued`) and kicks the processor.
    @discardableResult
    public func enqueue(
        spec: JobSpec,
        paths: JobPaths? = nil,
        startAs: JobStatus = .queued
    ) throws -> JobRecord {
        precondition(startAs == .draft || startAs == .queued, "enqueue startAs must be draft or queued")

        let resolvedPaths = paths ?? JobPathsFactory.make(jobId: spec.id, libraryRoot: libraryRoot)
        pathsByJob[spec.id] = resolvedPaths

        try materializeJobDir(paths: resolvedPaths, spec: spec)

        let now = JobTimestamps.now()
        let configJSON = try String(data: encoder.encode(spec), encoding: .utf8) ?? "{}"
        let job = JobRecord(
            id: spec.id,
            status: startAs,
            modality: spec.modality,
            configJSON: configJSON,
            createdAt: now,
            updatedAt: now
        )
        try store.insert(job)
        // Fresh enqueue must not inherit a sticky cancel from a prior generation.
        cancelRequested.remove(spec.id)
        lastError = nil
        publishJobs()

        if startAs == .queued {
            Task { await self.processQueue() }
        }
        return job
    }

    /// Transitions draft → queued and processes.
    public func submit(jobId: String) throws {
        cancelRequested.remove(jobId)
        _ = try store.transition(id: jobId, to: .queued)
        lastError = nil
        publishJobs()
        Task { await self.processQueue() }
    }

    /// Requeues an interrupted job (`interrupted → queued`) for another run.
    public func requeue(jobId: String) throws {
        guard let job = try store.fetch(id: jobId) else {
            throw BAMError(code: .schemaInvalid, message: "Job not found: \(jobId)")
        }
        guard job.status == .interrupted else {
            throw BAMError(
                code: .schemaInvalid,
                message: "Only interrupted jobs can be requeued (got \(job.status.rawValue))"
            )
        }
        cancelRequested.remove(jobId)
        _ = try store.transition(id: jobId, to: .queued)
        lastError = nil
        publishJobs()
        Task { await self.processQueue() }
    }

    /// Request cooperative cancel for a job (queued / preparing / running).
    public func cancel(jobId: String) async throws {
        guard let job = try store.fetch(id: jobId) else {
            throw BAMError(code: .schemaInvalid, message: "Job not found: \(jobId)")
        }

        switch job.status {
        case .draft, .queued:
            _ = try store.transition(
                id: jobId,
                to: .cancelled,
                errorCode: BAMErrorCode.cancelled.rawValue,
                errorMessage: "Cancelled by user"
            )
            cancelRequested.remove(jobId)
            publishJobs()

        case .preparing, .running:
            // Always resolve paths so cancel.flag is written even after relaunch.
            let paths = resolvePaths(for: jobId)
            try? writeCancelFlag(paths: paths)

            // Orphan: no live execute loop owns this job → flip status immediately.
            if currentJobId != jobId {
                _ = try store.transition(
                    id: jobId,
                    to: .cancelled,
                    errorCode: BAMErrorCode.cancelled.rawValue,
                    errorMessage: "Cancelled by user (no active run)"
                )
                cancelRequested.remove(jobId)
                await runner.cancel(jobId: jobId)
                publishJobs()
                return
            }

            cancelRequested.insert(jobId)
            await runner.cancel(jobId: jobId)
            // Terminal status applied when the run stream observes cancel / result.

        case .succeeded, .failed, .cancelled, .interrupted:
            throw BAMError(
                code: .schemaInvalid,
                message: "Cannot cancel job in status \(job.status.rawValue)"
            )
        }
    }

    /// On launch (or explicit recovery): mark **all** preparing/running jobs not
    /// owned by this process as `interrupted`.
    ///
    /// Force-quit leaves the previous supervisor dead even when `heartbeat.json`
    /// still has a fresh mtime — design M2 requires recoverable interrupted jobs.
    public func recoverStaleJobs(now: Date = Date()) async throws {
        let recoverable = try store.fetchRecoverable()
        for job in recoverable {
            // Never interrupt a job this process is actively executing.
            if currentJobId == job.id { continue }

            let paths = resolvePaths(for: job.id)
            let hbURL = JobPathsFactory.heartbeatURL(paths: paths)
            let message: String
            if !FileManager.default.fileExists(atPath: hbURL.path) {
                message = "Missing heartbeat on recovery"
            } else if (try? HeartbeatMonitor.isFileStale(
                at: hbURL,
                timeout: heartbeatTimeout,
                now: now
            )) == true {
                message = "Stale heartbeat on recovery"
            } else {
                // Fresh heartbeat file but no live supervisor ownership → orphan.
                message = "Orphan preparing/running after relaunch"
            }

            _ = try store.transition(
                id: job.id,
                to: .interrupted,
                errorCode: BAMErrorCode.workerHung.rawValue,
                errorMessage: message
            )
            // Do not leave sticky cancel that would poison interrupted → queued.
            cancelRequested.remove(job.id)
        }
        publishJobs()
    }

    public func listJobs() throws -> [JobRecord] {
        try store.fetchAll()
    }

    public func progress(for jobId: String) -> JobProgressSnapshot? {
        progressByJob[jobId]
    }

    public func currentRunningJobId() -> String? {
        currentJobId
    }

    /// Stream of full job list snapshots after each mutation.
    public func jobsUpdates() -> AsyncStream<[JobRecord]> {
        let id = UUID()
        return AsyncStream { continuation in
            jobsChangedContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeJobsContinuation(id) }
            }
            if let snapshot = try? store.fetchAll() {
                continuation.yield(snapshot)
            }
        }
    }

    /// Stream of live progress snapshots keyed by job id.
    public func progressUpdates() -> AsyncStream<(String, JobProgressSnapshot)> {
        let id = UUID()
        return AsyncStream { continuation in
            progressContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeProgressContinuation(id) }
            }
        }
    }

    // MARK: - Queue processing

    public func processQueue() async {
        guard !isProcessing else { return }
        isProcessing = true
        defer { isProcessing = false }

        while true {
            // Concurrency = 1 at the DB layer: drain orphans before starting work.
            if !(await ensureNoForeignSlotHolders()) {
                break
            }

            let next: JobRecord?
            do {
                next = try store.fetchNextQueued()
            } catch {
                lastError = "fetchNextQueued failed: \(error.localizedDescription)"
                publishJobs()
                break
            }
            guard let next else { break }

            if cancelRequested.contains(next.id) {
                do {
                    if let job = try store.fetch(id: next.id), job.status == .queued {
                        _ = try store.transition(
                            id: next.id,
                            to: .cancelled,
                            errorCode: BAMErrorCode.cancelled.rawValue,
                            errorMessage: "Cancelled by user"
                        )
                    }
                } catch {
                    lastError = "cancel queued failed: \(error.localizedDescription)"
                }
                cancelRequested.remove(next.id)
                publishJobs()
                continue
            }

            // Refuse to start if another preparing/running row still holds the slot.
            do {
                let holders = try store.fetchRecoverable()
                if holders.contains(where: { $0.id != next.id }) {
                    lastError = "Queue blocked: another job is preparing/running"
                    publishJobs()
                    break
                }
            } catch {
                lastError = "fetchRecoverable failed: \(error.localizedDescription)"
                publishJobs()
                break
            }

            await execute(job: next)
        }
    }

    /// Interrupts any preparing/running job not owned by `currentJobId`.
    /// Returns false if a foreign holder could not be cleared.
    @discardableResult
    private func ensureNoForeignSlotHolders() async -> Bool {
        let holders: [JobRecord]
        do {
            holders = try store.fetchRecoverable()
        } catch {
            lastError = "fetchRecoverable failed: \(error.localizedDescription)"
            publishJobs()
            return false
        }
        let foreign = holders.filter { $0.id != currentJobId }
        for orphan in foreign {
            do {
                _ = try store.transition(
                    id: orphan.id,
                    to: .interrupted,
                    errorCode: BAMErrorCode.workerHung.rawValue,
                    errorMessage: "Orphan active job blocked queue"
                )
                cancelRequested.remove(orphan.id)
            } catch {
                lastError = "Failed to interrupt orphan \(orphan.id): \(error.localizedDescription)"
                publishJobs()
                return false
            }
        }
        if !foreign.isEmpty {
            publishJobs()
        }
        return true
    }

    private func execute(job: JobRecord) async {
        currentJobId = job.id
        // New execution generation — prior interrupt/cancel must not auto-cancel.
        cancelRequested.remove(job.id)
        defer {
            currentJobId = nil
            heartbeatWatchTask?.cancel()
            heartbeatWatchTask = nil
            cancelRequested.remove(job.id)
        }

        let paths = resolvePaths(for: job.id)

        let spec: JobSpec
        do {
            spec = try decodeSpec(job.configJSON, fallbackId: job.id, modality: job.modality)
        } catch {
            recordTerminal(
                jobId: job.id,
                status: .failed,
                errorCode: BAMErrorCode.schemaInvalid.rawValue,
                errorMessage: error.localizedDescription
            )
            return
        }

        // preparing
        do {
            _ = try store.transition(id: job.id, to: .preparing)
            publishJobs()
            try await runner.prepare(job: spec, paths: paths)
        } catch let error as BAMError where error.code == .cancelled {
            recordTerminal(
                jobId: job.id,
                status: .cancelled,
                errorCode: BAMErrorCode.cancelled.rawValue,
                errorMessage: error.message ?? "Cancelled"
            )
            return
        } catch {
            if cancelRequested.contains(job.id) {
                recordTerminal(
                    jobId: job.id,
                    status: .cancelled,
                    errorCode: BAMErrorCode.cancelled.rawValue,
                    errorMessage: "Cancelled by user"
                )
            } else {
                recordTerminal(
                    jobId: job.id,
                    status: .failed,
                    errorCode: (error as? BAMError)?.code.rawValue ?? BAMErrorCode.workerCrash.rawValue,
                    errorMessage: error.localizedDescription
                )
            }
            return
        }

        if cancelRequested.contains(job.id) {
            recordTerminal(
                jobId: job.id,
                status: .cancelled,
                errorCode: BAMErrorCode.cancelled.rawValue,
                errorMessage: "Cancelled by user"
            )
            return
        }

        // running
        do {
            _ = try store.transition(id: job.id, to: .running)
            publishJobs()
        } catch {
            lastError = "transition running failed: \(error.localizedDescription)"
            publishJobs()
            return
        }

        let monitor = HeartbeatMonitor(fileURL: JobPathsFactory.heartbeatURL(paths: paths))
        // Seed so the watch grace period starts at run begin (not "never touched").
        monitor.touch()
        heartbeatByJob[job.id] = monitor
        progressByJob[job.id] = JobProgressSnapshot()
        startHeartbeatWatch(jobId: job.id, monitor: monitor)

        var terminalStatus: JobStatus = .succeeded
        var errorCode: String?
        var errorMessage: String?
        var sawResult = false

        do {
            let stream = runner.run(job: spec, paths: paths)
            for try await event in stream {
                if cancelRequested.contains(job.id) {
                    await runner.cancel(jobId: job.id)
                }

                applyEvent(event, jobId: job.id, monitor: monitor)

                if case let .result(status, _, message) = event {
                    sawResult = true
                    switch status {
                    case "succeeded":
                        terminalStatus = .succeeded
                    case "cancelled":
                        terminalStatus = .cancelled
                        errorCode = BAMErrorCode.cancelled.rawValue
                        errorMessage = message ?? "Cancelled"
                    case "failed":
                        terminalStatus = .failed
                        errorCode = BAMErrorCode.workerCrash.rawValue
                        errorMessage = message ?? "Failed"
                    default:
                        terminalStatus = .failed
                        errorCode = BAMErrorCode.schemaInvalid.rawValue
                        errorMessage = "Unknown result status: \(status)"
                    }
                }

                if case let .error(code, message, _) = event {
                    terminalStatus = .failed
                    errorCode = code
                    errorMessage = message
                }

                // If heartbeat watch already interrupted us, stop consuming.
                if let current = try? store.fetch(id: job.id),
                   current.status == .interrupted
                {
                    return
                }
            }

            if !sawResult {
                if cancelRequested.contains(job.id) {
                    terminalStatus = .cancelled
                    errorCode = BAMErrorCode.cancelled.rawValue
                    errorMessage = "Cancelled by user"
                } else {
                    terminalStatus = .failed
                    errorCode = BAMErrorCode.workerCrash.rawValue
                    errorMessage = "Runner ended without result event"
                }
            }
        } catch {
            if cancelRequested.contains(job.id) {
                terminalStatus = .cancelled
                errorCode = BAMErrorCode.cancelled.rawValue
                errorMessage = "Cancelled by user"
            } else if let bam = error as? BAMError {
                terminalStatus = bam.code == .cancelled ? .cancelled : .failed
                errorCode = bam.code.rawValue
                errorMessage = bam.message ?? error.localizedDescription
            } else {
                terminalStatus = .failed
                errorCode = BAMErrorCode.workerCrash.rawValue
                errorMessage = error.localizedDescription
            }
        }

        // Persist terminal state if still running/preparing.
        if let current = try? store.fetch(id: job.id),
           current.status == .running || current.status == .preparing
        {
            recordTerminal(
                jobId: job.id,
                status: terminalStatus,
                errorCode: errorCode,
                errorMessage: errorMessage
            )
        } else {
            publishJobs()
        }
    }

    private func recordTerminal(
        jobId: String,
        status: JobStatus,
        errorCode: String?,
        errorMessage: String?
    ) {
        do {
            if let current = try store.fetch(id: jobId),
               current.status == .running || current.status == .preparing || current.status == .queued
            {
                // queued→cancelled is valid; preparing/running → terminal as given
                if JobStateMachine.canTransition(from: current.status, to: status) {
                    _ = try store.transition(
                        id: jobId,
                        to: status,
                        errorCode: errorCode,
                        errorMessage: errorMessage
                    )
                }
            }
        } catch {
            lastError = "terminal transition failed: \(error.localizedDescription)"
        }
        cancelRequested.remove(jobId)
        publishJobs()
    }

    private func applyEvent(
        _ event: RunnerEvent,
        jobId: String,
        monitor: HeartbeatMonitor
    ) {
        if case let .heartbeat(rssBytes, gpuUtil, cpuUtil, ts) = event {
            // Non-throwing; file mirror is best-effort inside touch.
            monitor.touch(
                rssBytes: rssBytes,
                gpuUtil: gpuUtil,
                cpuUtil: cpuUtil,
                ts: ts
            )
        }

        var snap = progressByJob[jobId] ?? JobProgressSnapshot()
        snap.apply(event)
        progressByJob[jobId] = snap
        publishProgress(jobId: jobId, snapshot: snap)

        // Append NDJSON line to events.jsonl when job dir exists.
        if let paths = pathsByJob[jobId],
           let line = try? event.ndjsonLine()
        {
            let eventsURL = URL(fileURLWithPath: paths.jobDir)
                .appendingPathComponent("events.jsonl", isDirectory: false)
            appendLine(line, to: eventsURL)
        }
    }

    private func startHeartbeatWatch(jobId: String, monitor: HeartbeatMonitor) {
        heartbeatWatchTask?.cancel()
        let timeout = heartbeatTimeout
        heartbeatWatchTask = Task { [weak self] in
            // Poll at 1/4 timeout resolution (min 20ms for fast tests).
            let interval = max(timeout / 4, 0.02)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard let self else { return }
                let stale = monitor.isStale(timeout: timeout)
                if stale {
                    await self.handleStaleHeartbeat(jobId: jobId)
                    return
                }
            }
        }
    }

    private func handleStaleHeartbeat(jobId: String) async {
        guard let job = try? store.fetch(id: jobId),
              job.status == .running || job.status == .preparing
        else { return }
        do {
            _ = try store.transition(
                id: jobId,
                to: .interrupted,
                errorCode: BAMErrorCode.workerHung.rawValue,
                errorMessage: "Heartbeat timed out"
            )
        } catch {
            lastError = "heartbeat interrupt failed: \(error.localizedDescription)"
        }
        // Stop the runner without sticky cancelRequested (would poison requeue).
        await runner.cancel(jobId: jobId)
        publishJobs()
    }

    // MARK: - Helpers

    private func resolvePaths(for jobId: String) -> JobPaths {
        if let existing = pathsByJob[jobId] {
            return existing
        }
        let paths = JobPathsFactory.make(jobId: jobId, libraryRoot: libraryRoot)
        pathsByJob[jobId] = paths
        return paths
    }

    private func materializeJobDir(paths: JobPaths, spec: JobSpec) throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: paths.jobDir, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: paths.outputPath, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: paths.checkpointPath, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: paths.logPath, withIntermediateDirectories: true)

        let jobURL = JobPathsFactory.jobJSONURL(paths: paths)
        let data = try encoder.encode(spec)
        try data.write(to: jobURL, options: .atomic)
    }

    private func writeCancelFlag(paths: JobPaths) throws {
        let url = URL(fileURLWithPath: paths.cancelFlagPath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("1".utf8).write(to: url, options: .atomic)
    }

    private func decodeSpec(_ json: String, fallbackId: String, modality: JobModality) throws -> JobSpec {
        guard let data = json.data(using: .utf8) else {
            throw BAMError(code: .schemaInvalid, message: "config_json is not UTF-8")
        }
        do {
            return try JSONDecoder().decode(JobSpec.self, from: data)
        } catch {
            // Minimal fallback for hand-inserted rows in tests.
            return JobSpec(id: fallbackId, modality: modality)
        }
    }

    private func appendLine(_ line: String, to url: URL) {
        let fm = FileManager.default
        let payload = Data((line + "\n").utf8)
        if !fm.fileExists(atPath: url.path) {
            try? payload.write(to: url, options: .atomic)
            return
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: payload)
    }

    private func publishJobs() {
        let snapshot = (try? store.fetchAll()) ?? []
        for cont in jobsChangedContinuations.values {
            cont.yield(snapshot)
        }
    }

    private func publishProgress(jobId: String, snapshot: JobProgressSnapshot) {
        for cont in progressContinuations.values {
            cont.yield((jobId, snapshot))
        }
    }

    private func removeJobsContinuation(_ id: UUID) {
        jobsChangedContinuations[id] = nil
    }

    private func removeProgressContinuation(_ id: UUID) {
        progressContinuations[id] = nil
    }
}

// MARK: - Convenience factory

extension JobQueueController {
    /// Opens an in-memory library DB + testing fake runner (unit tests).
    public static func makeInMemoryForTesting(
        runnerConfig: FakeRunnerConfig = .testing,
        heartbeatTimeout: TimeInterval = 2
    ) throws -> (controller: JobQueueController, database: LibraryDatabase, runner: FakeTrainingRunner) {
        let db = try LibraryDatabase.openInMemory()
        let store = JobStore(database: db)
        let runner = FakeTrainingRunner(config: runnerConfig)
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("bam-jobs-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let controller = JobQueueController(
            store: store,
            runner: runner,
            libraryRoot: tmp,
            heartbeatTimeout: heartbeatTimeout
        )
        return (controller, db, runner)
    }
}
