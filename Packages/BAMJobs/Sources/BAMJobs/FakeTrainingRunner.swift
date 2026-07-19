import BAMCore
import BAMModels
import Foundation
import os

/// Configuration for synthetic training progress (tests use short intervals).
public struct FakeRunnerConfig: Sendable, Equatable {
    /// Number of progress steps before success.
    public var stepCount: Int
    /// Delay between progress events.
    public var stepInterval: Duration
    /// Emit a heartbeat every N progress steps (in addition to step events).
    public var heartbeatEverySteps: Int
    /// Simulated prepare duration.
    public var prepareDelay: Duration
    /// Total epochs for epoch field scaling.
    public var epochs: Double
    /// Starting loss; decays per step.
    public var startLoss: Double
    /// Learning rate reported in progress.
    public var learningRate: Double
    /// Whether prepare creates job subdirectories under `paths.jobDir`.
    public var materializeDirectories: Bool

    public init(
        stepCount: Int = 10,
        stepInterval: Duration = .milliseconds(50),
        heartbeatEverySteps: Int = 2,
        prepareDelay: Duration = .milliseconds(10),
        epochs: Double = 3,
        startLoss: Double = 2.5,
        learningRate: Double = 1e-4,
        materializeDirectories: Bool = true
    ) {
        self.stepCount = max(1, stepCount)
        self.stepInterval = stepInterval
        self.heartbeatEverySteps = max(1, heartbeatEverySteps)
        self.prepareDelay = prepareDelay
        self.epochs = epochs
        self.startLoss = startLoss
        self.learningRate = learningRate
        self.materializeDirectories = materializeDirectories
    }

    /// Fast config for unit tests.
    public static let testing = FakeRunnerConfig(
        stepCount: 5,
        stepInterval: .milliseconds(5),
        heartbeatEverySteps: 1,
        prepareDelay: .milliseconds(1),
        materializeDirectories: true
    )
}

/// In-process fake runner that emits synthetic NDJSON-shaped progress events.
///
/// Cooperative cancel via `cancel(jobId:)` stops the run stream and yields
/// `result(status: cancelled)`.
public final class FakeTrainingRunner: TrainingRunner, @unchecked Sendable {
    public let id: String
    public let protocolVersion: Int
    public let config: FakeRunnerConfig

    private let cancelledJobIds = OSAllocatedUnfairLock(initialState: Set<String>())

    public init(
        id: String = "fake-training-runner",
        protocolVersion: Int = ProtocolVersions.runnerProtocolVersion,
        config: FakeRunnerConfig = FakeRunnerConfig()
    ) {
        self.id = id
        self.protocolVersion = protocolVersion
        self.config = config
    }

    public func capabilities() async throws -> RunnerCapabilities {
        RunnerCapabilities(
            modalities: [.llm, .voiceClone],
            resume: false,
            modelFamilies: ["fake", "qwen2.5"],
            maxSeqLen: 2048,
            engineIds: ["f5-tts"]
        )
    }

    public func prepare(job: JobSpec, paths: JobPaths) async throws {
        if config.materializeDirectories {
            try materializeJobLayout(paths: paths)
        }
        if config.prepareDelay > .zero {
            try await Task.sleep(for: config.prepareDelay)
        }
        if isCancelled(job.id) {
            throw BAMError(code: .cancelled, message: "Cancelled during prepare")
        }
    }

    public func run(job: JobSpec, paths: JobPaths) -> AsyncThrowingStream<RunnerEvent, Error> {
        stream(job: job, paths: paths, isResume: false)
    }

    public func resume(
        job: JobSpec,
        paths: JobPaths,
        checkpoint: CheckpointRef
    ) -> AsyncThrowingStream<RunnerEvent, Error> {
        // Fake runner does not resume weights; re-runs from step 0 with a log line.
        stream(job: job, paths: paths, isResume: true, checkpoint: checkpoint)
    }

    public func cancel(jobId: String) async {
        cancelledJobIds.withLock { state in
            state.insert(jobId)
        }
    }

    /// Clears cancel flags (tests that reuse a runner instance).
    public func resetCancelState() {
        cancelledJobIds.withLock { state in
            state.removeAll()
        }
    }

    // MARK: - Internals

    private func isCancelled(_ jobId: String) -> Bool {
        cancelledJobIds.withLock { $0.contains(jobId) }
    }

    private func stream(
        job: JobSpec,
        paths: JobPaths,
        isResume: Bool,
        checkpoint: CheckpointRef? = nil
    ) -> AsyncThrowingStream<RunnerEvent, Error> {
        let config = self.config
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    if isResume, let checkpoint {
                        continuation.yield(
                            .log(
                                level: "info",
                                message: "fake resume from \(checkpoint.path) step=\(checkpoint.step)",
                                ts: JobTimestamps.now()
                            )
                        )
                    } else {
                        continuation.yield(
                            .log(
                                level: "info",
                                message: "fake run start modality=\(job.modality.rawValue)",
                                ts: JobTimestamps.now()
                            )
                        )
                    }

                    // Initial heartbeat.
                    continuation.yield(Self.makeHeartbeat())

                    let total = config.stepCount
                    for step in 1 ... total {
                        if Task.isCancelled || self.isCancelled(job.id) {
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
                                tokensPerSec: 100 + Double(step) * 3,
                                etaSec: max(0, eta),
                                metrics: ["fake": 1]
                            )
                        )

                        if step % config.heartbeatEverySteps == 0 {
                            continuation.yield(Self.makeHeartbeat())
                        }

                        if step == total / 2, total >= 2 {
                            continuation.yield(
                                .checkpoint(path: "checkpoints/step-\(step)", step: step)
                            )
                        }
                    }

                    let artifactPath = "artifacts/adapter"
                    continuation.yield(.artifact(kind: "lora_adapter", path: artifactPath))
                    continuation.yield(
                        .result(
                            status: "succeeded",
                            artifacts: [RunnerArtifactRef(kind: "lora_adapter", path: artifactPath)],
                            message: nil
                        )
                    )
                    continuation.finish()
                } catch {
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
            rssBytes: 512 * 1024 * 1024,
            gpuUtil: 0.42,
            cpuUtil: 0.35,
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
