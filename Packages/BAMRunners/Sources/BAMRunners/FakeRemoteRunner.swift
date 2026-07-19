import BAMCore
import BAMJobs
import BAMModels
import Foundation
import os

/// Timing / behavior for the in-process remote emulator.
public struct FakeRemoteRunnerConfig: Sendable, Equatable {
    /// Simulated progress steps while phase == `.running`.
    public var stepCount: Int
    /// Delay between progress events.
    public var stepInterval: Duration
    /// Simulated connect latency.
    public var connectDelay: Duration
    /// Simulated upload phase duration.
    public var uploadDelay: Duration
    /// Simulated remote queue wait.
    public var queueDelay: Duration
    /// Simulated artifact download duration.
    public var downloadDelay: Duration
    /// Emit heartbeat every N progress steps.
    public var heartbeatEverySteps: Int
    /// Whether heartbeats are emitted at all.
    public var emitHeartbeats: Bool
    /// Total epochs for epoch field scaling.
    public var epochs: Double
    /// Starting loss; decays per step.
    public var startLoss: Double
    /// Learning rate reported in progress.
    public var learningRate: Double
    /// Whether prepare / download materialize job directories under `paths.jobDir`.
    public var materializeDirectories: Bool

    public init(
        stepCount: Int = 10,
        stepInterval: Duration = .milliseconds(50),
        connectDelay: Duration = .milliseconds(10),
        uploadDelay: Duration = .milliseconds(10),
        queueDelay: Duration = .milliseconds(5),
        downloadDelay: Duration = .milliseconds(10),
        heartbeatEverySteps: Int = 2,
        emitHeartbeats: Bool = true,
        epochs: Double = 3,
        startLoss: Double = 2.5,
        learningRate: Double = 1e-4,
        materializeDirectories: Bool = true
    ) {
        self.stepCount = max(1, stepCount)
        self.stepInterval = stepInterval
        self.connectDelay = connectDelay
        self.uploadDelay = uploadDelay
        self.queueDelay = queueDelay
        self.downloadDelay = downloadDelay
        self.heartbeatEverySteps = max(1, heartbeatEverySteps)
        self.emitHeartbeats = emitHeartbeats
        self.epochs = epochs
        self.startLoss = startLoss
        self.learningRate = learningRate
        self.materializeDirectories = materializeDirectories
    }

    /// Fast config for unit tests.
    public static let testing = FakeRemoteRunnerConfig(
        stepCount: 5,
        stepInterval: .milliseconds(5),
        connectDelay: .milliseconds(1),
        uploadDelay: .milliseconds(1),
        queueDelay: .milliseconds(1),
        downloadDelay: .milliseconds(1),
        heartbeatEverySteps: 1,
        materializeDirectories: true
    )
}

/// In-process **fake** remote runner — no network, no SSH, no cloud API.
///
/// Emulates the remote job lifecycle for interface stability (K22 / PR-Remote-Fake):
/// `connect` → `submit` → pending → uploading → queued → running → downloading → terminal.
///
/// Product wiring must keep `ff.cloudRunner` off (`CloudPolicy`). This type exists so
/// queue/UI code can depend on `RemoteRunner` without a real backend.
public final class FakeRemoteRunner: RemoteRunner, @unchecked Sendable {
    public let id: String
    public let protocolVersion: Int
    public let kind: RemoteRunnerKind = .fake
    public let endpoint: RemoteEndpointInfo
    public let config: FakeRemoteRunnerConfig

    private let lock = OSAllocatedUnfairLock(initialState: State())

    private struct JobState {
        var phase: RemoteJobPhase
        var handle: RemoteJobHandle
        var artifacts: [RunnerArtifactRef]
    }

    private struct State {
        var connected = false
        var cancelledJobIds: Set<String> = []
        var jobs: [String: JobState] = [:] // keyed by localJobId
        var phaseHistory: [String: [RemoteJobPhase]] = [:]
    }

    public init(
        id: String = "fake-remote-runner",
        protocolVersion: Int = ProtocolVersions.runnerProtocolVersion,
        endpoint: RemoteEndpointInfo = .fake,
        config: FakeRemoteRunnerConfig = FakeRemoteRunnerConfig()
    ) {
        self.id = id
        self.protocolVersion = protocolVersion
        self.endpoint = endpoint
        self.config = config
    }

    // MARK: - RemoteRunner

    public func isConnected() async -> Bool {
        lock.withLock { $0.connected }
    }

    public func connect() async throws {
        if config.connectDelay > .zero {
            try await Task.sleep(for: config.connectDelay)
        }
        lock.withLock { state in
            state.connected = true
        }
    }

    public func disconnect() async {
        lock.withLock { state in
            state.connected = false
        }
    }

    public func submit(job: JobSpec, paths: JobPaths) async throws -> RemoteJobHandle {
        try requireConnected()
        if isCancelled(job.id) {
            throw BAMError(code: .cancelled, message: "Cancelled before submit")
        }

        let handle = RemoteJobHandle(
            remoteJobId: "remote-\(job.id)",
            localJobId: job.id
        )
        lock.withLock { state in
            state.jobs[job.id] = JobState(
                phase: .pending,
                handle: handle,
                artifacts: []
            )
            state.phaseHistory[job.id, default: []].append(.pending)
        }
        return handle
    }

    public func remoteStatus(handle: RemoteJobHandle) async throws -> RemoteJobPhase {
        try requireConnected()
        return try lock.withLock { state in
            guard let job = state.jobs[handle.localJobId] else {
                throw BAMError(
                    code: .schemaInvalid,
                    message: "Unknown remote job handle localId=\(handle.localJobId)"
                )
            }
            return job.phase
        }
    }

    public func fetchArtifacts(
        handle: RemoteJobHandle,
        paths: JobPaths
    ) async throws -> [RunnerArtifactRef] {
        try requireConnected()
        let phase = try await remoteStatus(handle: handle)
        guard phase == .succeeded || phase == .downloading else {
            throw BAMError(
                code: .schemaInvalid,
                message: "Artifacts not available in phase \(phase.rawValue)"
            )
        }

        if config.materializeDirectories {
            try materializeJobLayout(paths: paths)
            let artifactURL = URL(fileURLWithPath: paths.outputPath)
                .appendingPathComponent("adapter", isDirectory: true)
            try FileManager.default.createDirectory(
                at: artifactURL,
                withIntermediateDirectories: true
            )
            let marker = artifactURL.appendingPathComponent("fake-remote.marker")
            try Data("fake-remote\n".utf8).write(to: marker, options: .atomic)
        }

        let artifacts = [
            RunnerArtifactRef(kind: "lora_adapter", path: "artifacts/adapter"),
        ]
        lock.withLock { state in
            if var job = state.jobs[handle.localJobId] {
                job.artifacts = artifacts
                state.jobs[handle.localJobId] = job
            }
        }
        return artifacts
    }

    /// Phases recorded for a local job id (test/diagnostics aid).
    public func phaseHistory(localJobId: String) -> [RemoteJobPhase] {
        lock.withLock { $0.phaseHistory[localJobId] ?? [] }
    }

    /// Clears cancel flags and job bookkeeping (tests that reuse a runner).
    public func reset() {
        lock.withLock { state in
            state.cancelledJobIds.removeAll()
            state.jobs.removeAll()
            state.phaseHistory.removeAll()
            // leave connected as-is
        }
    }

    // MARK: - TrainingRunner

    public func capabilities() async throws -> RunnerCapabilities {
        RunnerCapabilities(
            modalities: [.llm],
            resume: false,
            modelFamilies: ["fake-remote", "qwen2.5"],
            maxSeqLen: 2048,
            engineIds: nil
        )
    }

    public func prepare(job: JobSpec, paths: JobPaths) async throws {
        try requireConnected()
        if config.materializeDirectories {
            try materializeJobLayout(paths: paths)
        }
        // Ensure a handle exists (queue path may call prepare before explicit submit).
        if lock.withLock({ $0.jobs[job.id] == nil }) {
            _ = try await submit(job: job, paths: paths)
        }
        try setPhase(localJobId: job.id, .uploading)
        if config.uploadDelay > .zero {
            try await Task.sleep(for: config.uploadDelay)
        }
        if isCancelled(job.id) {
            try setPhase(localJobId: job.id, .cancelled)
            throw BAMError(code: .cancelled, message: "Cancelled during remote upload")
        }
        try setPhase(localJobId: job.id, .queued)
        if config.queueDelay > .zero {
            try await Task.sleep(for: config.queueDelay)
        }
        if isCancelled(job.id) {
            try setPhase(localJobId: job.id, .cancelled)
            throw BAMError(code: .cancelled, message: "Cancelled while queued remotely")
        }
    }

    public func run(job: JobSpec, paths: JobPaths) -> AsyncThrowingStream<RunnerEvent, Error> {
        stream(job: job, paths: paths)
    }

    public func resume(
        job: JobSpec,
        paths: JobPaths,
        checkpoint: CheckpointRef
    ) -> AsyncThrowingStream<RunnerEvent, Error> {
        // Fake remote does not resume weights; re-runs with a log line.
        stream(job: job, paths: paths, resumeFrom: checkpoint)
    }

    public func cancel(jobId: String) async {
        lock.withLock { state in
            state.cancelledJobIds.insert(jobId)
            if var job = state.jobs[jobId], !job.phase.isTerminal {
                job.phase = .cancelled
                state.jobs[jobId] = job
                state.phaseHistory[jobId, default: []].append(.cancelled)
            }
        }
    }

    // MARK: - Internals

    private func requireConnected() throws {
        let connected = lock.withLock { $0.connected }
        guard connected else {
            throw BAMError(
                code: .capabilityUnsupported,
                message: "Remote runner not connected (\(CloudPolicy.deferredMessage))"
            )
        }
    }

    private func isCancelled(_ jobId: String) -> Bool {
        lock.withLock { $0.cancelledJobIds.contains(jobId) }
    }

    private func setPhase(localJobId: String, _ phase: RemoteJobPhase) throws {
        try lock.withLock { state in
            guard var job = state.jobs[localJobId] else {
                throw BAMError(
                    code: .schemaInvalid,
                    message: "No remote job for localId=\(localJobId)"
                )
            }
            job.phase = phase
            state.jobs[localJobId] = job
            state.phaseHistory[localJobId, default: []].append(phase)
        }
    }

    private func stream(
        job: JobSpec,
        paths: JobPaths,
        resumeFrom: CheckpointRef? = nil
    ) -> AsyncThrowingStream<RunnerEvent, Error> {
        let config = self.config
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try self.requireConnected()

                    if self.lock.withLock({ $0.jobs[job.id] == nil }) {
                        _ = try await self.submit(job: job, paths: paths)
                    }

                    try self.setPhase(localJobId: job.id, .running)

                    if let checkpoint = resumeFrom {
                        continuation.yield(
                            .log(
                                level: "info",
                                message: "fake-remote resume from \(checkpoint.path) step=\(checkpoint.step)",
                                ts: JobTimestamps.now()
                            )
                        )
                    } else {
                        continuation.yield(
                            .log(
                                level: "info",
                                message: "fake-remote run start modality=\(job.modality.rawValue) endpoint=\(self.endpoint.id)",
                                ts: JobTimestamps.now()
                            )
                        )
                    }

                    if config.emitHeartbeats {
                        continuation.yield(Self.makeHeartbeat())
                    }

                    let total = config.stepCount
                    for step in 1 ... total {
                        if Task.isCancelled || self.isCancelled(job.id) {
                            try? self.setPhase(localJobId: job.id, .cancelled)
                            try? self.writeCancelFlag(paths: paths)
                            continuation.yield(
                                .result(status: "cancelled", artifacts: [], message: "cancelled")
                            )
                            continuation.finish()
                            return
                        }

                        if config.stepInterval > .zero {
                            try await Task.sleep(for: config.stepInterval)
                        }

                        if Task.isCancelled || self.isCancelled(job.id) {
                            try? self.setPhase(localJobId: job.id, .cancelled)
                            try? self.writeCancelFlag(paths: paths)
                            continuation.yield(
                                .result(status: "cancelled", artifacts: [], message: "cancelled")
                            )
                            continuation.finish()
                            return
                        }

                        let epoch = config.epochs * (Double(step) / Double(total))
                        let loss = max(0.05, config.startLoss * pow(0.85, Double(step)))
                        let eta = Double(total - step) * config.stepInterval.seconds

                        continuation.yield(
                            .progress(
                                step: step,
                                epoch: epoch,
                                loss: loss,
                                lr: config.learningRate,
                                tokensPerSec: 80 + Double(step) * 2,
                                etaSec: max(0, eta),
                                metrics: [
                                    "fakeRemote": 1,
                                    "totalSteps": Double(total),
                                ]
                            )
                        )

                        if config.emitHeartbeats, step % config.heartbeatEverySteps == 0 {
                            continuation.yield(Self.makeHeartbeat())
                        }

                        if step == total / 2, total >= 2 {
                            continuation.yield(
                                .checkpoint(path: "checkpoints/step-\(step)", step: step)
                            )
                        }
                    }

                    // Download phase then success.
                    try self.setPhase(localJobId: job.id, .downloading)
                    continuation.yield(
                        .log(
                            level: "info",
                            message: "fake-remote downloading artifacts",
                            ts: JobTimestamps.now()
                        )
                    )
                    if config.downloadDelay > .zero {
                        try await Task.sleep(for: config.downloadDelay)
                    }

                    if Task.isCancelled || self.isCancelled(job.id) {
                        try? self.setPhase(localJobId: job.id, .cancelled)
                        continuation.yield(
                            .result(status: "cancelled", artifacts: [], message: "cancelled")
                        )
                        continuation.finish()
                        return
                    }

                    let handle = RemoteJobHandle(
                        remoteJobId: "remote-\(job.id)",
                        localJobId: job.id
                    )
                    let artifacts = try await self.fetchArtifacts(handle: handle, paths: paths)
                    try self.setPhase(localJobId: job.id, .succeeded)

                    let artifactPath = "artifacts/adapter"
                    continuation.yield(.artifact(kind: "lora_adapter", path: artifactPath))
                    continuation.yield(
                        .result(
                            status: "succeeded",
                            artifacts: artifacts,
                            message: nil
                        )
                    )
                    continuation.finish()
                } catch {
                    try? self.setPhase(localJobId: job.id, .failed)
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private static func makeHeartbeat() -> RunnerEvent {
        .heartbeat(
            rssBytes: 256 * 1024 * 1024,
            gpuUtil: 0.55,
            cpuUtil: 0.2,
            ts: JobTimestamps.now()
        )
    }

    private func materializeJobLayout(paths: JobPaths) throws {
        let fm = FileManager.default
        let dirs = [
            paths.jobDir,
            paths.outputPath,
            paths.checkpointPath,
            paths.logPath,
        ]
        for path in dirs {
            try fm.createDirectory(
                atPath: path,
                withIntermediateDirectories: true
            )
        }
    }

    private func writeCancelFlag(paths: JobPaths) throws {
        let url = URL(fileURLWithPath: paths.cancelFlagPath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("1".utf8).write(to: url, options: .atomic)
    }
}

private extension Duration {
    var seconds: Double {
        let c = components
        return Double(c.seconds) + Double(c.attoseconds) / 1e18
    }
}
