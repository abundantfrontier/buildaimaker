import BAMCore
import BAMJobs
import BAMModels
import Foundation
import os

/// `TrainingRunner` backed by `ProcessSupervisor` + a real helper executable.
///
/// Default app wiring still uses `FakeTrainingRunner`. Construct this runner
/// (or use `JobQueueController.makeWithSupervisedRunner`) to exercise the
/// real NDJSON process path.
public final class SupervisedTrainingRunner: TrainingRunner, @unchecked Sendable {
    public let id: String
    public let protocolVersion: Int

    public let executableURL: URL
    public let arguments: [String]
    public let config: ProcessSupervisorConfig

    private let lock = OSAllocatedUnfairLock(initialState: State())

    private struct State {
        var supervisor: ProcessSupervisor?
        var activePaths: JobPaths?
        var activeJobId: String?
        var cachedCaps: RunnerCapabilities?
        /// Original raw JobSpec JSON for path-jail side-channel (never re-encoded).
        var rawSpecJSON: Data?
    }

    public init(
        executableURL: URL,
        arguments: [String] = [],
        config: ProcessSupervisorConfig = ProcessSupervisorConfig(),
        id: String = "supervised-training-runner",
        protocolVersion: Int = ProtocolVersions.runnerProtocolVersion
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.config = config
        self.id = id
        self.protocolVersion = protocolVersion
    }

    public func capabilities() async throws -> RunnerCapabilities {
        if let caps = lock.withLock({ $0.cachedCaps }) {
            return caps
        }
        return RunnerCapabilities(
            modalities: [.llm],
            resume: true,
            modelFamilies: [],
            maxSeqLen: nil
        )
    }

    /// Protocol `TrainingRunner` entry — no raw side-channel available.
    public func prepare(job: JobSpec, paths: JobPaths) async throws {
        try await prepare(job: job, paths: paths, rawSpecJSON: nil)
    }

    /// Preferred prepare path: pass the **original** store/disk JobSpec JSON so free path
    /// keys (e.g. legacy `referenceAudioPath`) are path-jailed. Never pass re-encoded
    /// Codable output — that drops unknown keys and makes the side-channel a no-op.
    public func prepare(job: JobSpec, paths: JobPaths, rawSpecJSON: Data?) async throws {
        try PathJail.validate(paths: paths)
        try PathJail.validateModalityRequirements(job: job, paths: paths)
        if let rawSpecJSON {
            try PathJail.validateRawJobSpecPaths(rawSpecJSON: rawSpecJSON, paths: paths)
        }

        let supervisor = ProcessSupervisor(
            executableURL: executableURL,
            arguments: arguments,
            config: config
        )
        let caps = try await supervisor.start(paths: paths)
        try await supervisor.prepare(job: job, paths: paths, rawSpecJSON: rawSpecJSON)

        lock.withLock { state in
            state.supervisor = supervisor
            state.activePaths = paths
            state.activeJobId = job.id
            state.cachedCaps = caps
            state.rawSpecJSON = rawSpecJSON
        }
    }

    public func run(job: JobSpec, paths: JobPaths) -> AsyncThrowingStream<RunnerEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let supervisor = try await self.requireSupervisor(jobId: job.id)
                    for try await event in await supervisor.run(job: job, paths: paths) {
                        continuation.yield(event)
                        if case .result = event {
                            continuation.finish()
                            self.clearSupervisor()
                            return
                        }
                    }
                    continuation.finish()
                    self.clearSupervisor()
                } catch {
                    continuation.finish(throwing: error)
                    self.clearSupervisor()
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    public func resume(
        job: JobSpec,
        paths: JobPaths,
        checkpoint: CheckpointRef
    ) -> AsyncThrowingStream<RunnerEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    // Fail closed if prepare never ran (do not invent a bare llm JobSpec).
                    let supervisor = try await self.requireSupervisor(jobId: job.id)
                    for try await event in await supervisor.resume(
                        job: job,
                        paths: paths,
                        checkpoint: checkpoint
                    ) {
                        continuation.yield(event)
                        if case .result = event {
                            continuation.finish()
                            self.clearSupervisor()
                            return
                        }
                    }
                    continuation.finish()
                    self.clearSupervisor()
                } catch {
                    continuation.finish(throwing: error)
                    self.clearSupervisor()
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    public func cancel(jobId: String) async {
        let (supervisor, paths) = lock.withLock { state -> (ProcessSupervisor?, JobPaths?) in
            (state.supervisor, state.activePaths)
        }
        guard let supervisor, let paths else {
            return
        }
        await supervisor.cancel(jobId: jobId, paths: paths)
    }

    // MARK: - Internals

    private func requireSupervisor(jobId: String) throws -> ProcessSupervisor {
        guard let existing = lock.withLock({ $0.supervisor }) else {
            throw BAMError(
                code: .workerCrash,
                message: "No supervisor for job \(jobId); call prepare first"
            )
        }
        return existing
    }

    private func clearSupervisor() {
        lock.withLock { state in
            state.supervisor = nil
            state.activePaths = nil
            state.activeJobId = nil
            state.rawSpecJSON = nil
        }
    }
}

// MARK: - JobQueueController convenience

extension JobQueueController {
    /// Optional real-supervisor wiring. Default production/UI path still uses
    /// `FakeTrainingRunner` via the primary initializer / `makeInMemoryForTesting`.
    ///
    /// `executableURL` must be a `bam-*-worker` helper; L1 is enforced again in
    /// `ProcessSupervisor.start`.
    public static func makeWithSupervisedRunner(
        store: JobStore,
        executableURL: URL,
        arguments: [String] = [],
        libraryRoot: URL = LibraryPaths.libraryRoot,
        supervisorConfig: ProcessSupervisorConfig = ProcessSupervisorConfig(),
        heartbeatTimeout: TimeInterval = HeartbeatMonitor.defaultTimeoutSeconds
    ) throws -> JobQueueController {
        // Fail closed at construction when the URL is not a policy helper.
        let prepared = try WorkerSpawn.prepareExecutableURL(executableURL)
        let runner = SupervisedTrainingRunner(
            executableURL: prepared.url,
            arguments: arguments,
            config: supervisorConfig
        )
        return JobQueueController(
            store: store,
            runner: runner,
            libraryRoot: libraryRoot,
            heartbeatTimeout: heartbeatTimeout
        )
    }
}
