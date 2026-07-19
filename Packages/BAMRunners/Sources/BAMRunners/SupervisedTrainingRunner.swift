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

    public func prepare(job: JobSpec, paths: JobPaths) async throws {
        try PathJail.validate(paths: paths)
        try PathJail.validateModalityRequirements(job: job, paths: paths)

        // Encode job to raw JSON so we can path-jail any accidental free path keys.
        let rawSpec = try ProtocolCodec.encoder.encode(job)

        let supervisor = ProcessSupervisor(
            executableURL: executableURL,
            arguments: arguments,
            config: config
        )
        let caps = try await supervisor.start(paths: paths)
        try await supervisor.prepare(job: job, paths: paths, rawSpecJSON: rawSpec)

        lock.withLock { state in
            state.supervisor = supervisor
            state.activePaths = paths
            state.activeJobId = job.id
            state.cachedCaps = caps
        }
    }

    public func run(job: JobSpec, paths: JobPaths) -> AsyncThrowingStream<RunnerEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let supervisor = try await self.requireSupervisor(jobId: job.id, paths: paths)
                    for try await event in await supervisor.run(job: job, paths: paths) {
                        continuation.yield(event)
                        if case .result = event {
                            continuation.finish()
                            await self.clearSupervisor()
                            return
                        }
                    }
                    continuation.finish()
                    await self.clearSupervisor()
                } catch {
                    continuation.finish(throwing: error)
                    await self.clearSupervisor()
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
                    // Resume may need a fresh worker if prepare was not called.
                    var supervisor = await self.currentSupervisor()
                    if supervisor == nil {
                        try await self.prepare(job: job, paths: paths)
                        supervisor = await self.currentSupervisor()
                    }
                    guard let supervisor else {
                        throw BAMError(code: .workerCrash, message: "No supervisor for resume")
                    }
                    for try await event in await supervisor.resume(
                        job: job,
                        paths: paths,
                        checkpoint: checkpoint
                    ) {
                        continuation.yield(event)
                        if case .result = event {
                            continuation.finish()
                            await self.clearSupervisor()
                            return
                        }
                    }
                    continuation.finish()
                    await self.clearSupervisor()
                } catch {
                    continuation.finish(throwing: error)
                    await self.clearSupervisor()
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
            // Still try to write cancel.flag if we can reconstruct paths — no-op here.
            return
        }
        await supervisor.cancel(jobId: jobId, paths: paths)
    }

    // MARK: - Internals

    private func requireSupervisor(jobId: String, paths: JobPaths) async throws -> ProcessSupervisor {
        if let existing = lock.withLock({ $0.supervisor }) {
            return existing
        }
        // Lazy start if prepare was skipped.
        try await prepare(
            job: JobSpec(id: jobId, modality: .llm),
            paths: paths
        )
        guard let supervisor = lock.withLock({ $0.supervisor }) else {
            throw BAMError(code: .workerCrash, message: "Failed to start supervisor")
        }
        return supervisor
    }

    private func currentSupervisor() -> ProcessSupervisor? {
        lock.withLock { $0.supervisor }
    }

    private func clearSupervisor() {
        lock.withLock { state in
            state.supervisor = nil
            state.activePaths = nil
            state.activeJobId = nil
        }
    }
}

// MARK: - JobQueueController convenience

extension JobQueueController {
    /// Optional real-supervisor wiring. Default production/UI path still uses
    /// `FakeTrainingRunner` via the primary initializer / `makeInMemoryForTesting`.
    public static func makeWithSupervisedRunner(
        store: JobStore,
        executableURL: URL,
        arguments: [String] = [],
        libraryRoot: URL = LibraryPaths.libraryRoot,
        supervisorConfig: ProcessSupervisorConfig = ProcessSupervisorConfig(),
        heartbeatTimeout: TimeInterval = HeartbeatMonitor.defaultTimeoutSeconds
    ) -> JobQueueController {
        let runner = SupervisedTrainingRunner(
            executableURL: executableURL,
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
