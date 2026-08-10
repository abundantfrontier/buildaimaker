import BAMCore
import BAMJobs
import BAMModels
import Foundation
import os

/// Config for the Foundation adapter job runner.
public struct FoundationModelsAdapterRunnerConfig: Sendable, Equatable {
    public var stepCount: Int
    public var stepInterval: Duration
    public var prepareDelay: Duration
    public var emitHeartbeats: Bool
    /// Force stub even when toolkit is installed (tests / dogfood).
    public var forceFakeTrain: Bool

    public init(
        stepCount: Int = 6,
        stepInterval: Duration = .milliseconds(40),
        prepareDelay: Duration = .milliseconds(10),
        emitHeartbeats: Bool = true,
        forceFakeTrain: Bool = false
    ) {
        self.stepCount = max(1, stepCount)
        self.stepInterval = stepInterval
        self.prepareDelay = prepareDelay
        self.emitHeartbeats = emitHeartbeats
        self.forceFakeTrain = forceFakeTrain
    }

    public static let testing = FoundationModelsAdapterRunnerConfig(
        stepCount: 3,
        stepInterval: .milliseconds(5),
        prepareDelay: .milliseconds(1),
        forceFakeTrain: true
    )
}

/// `TrainingRunner` for `JobModality.foundationAdapter`.
///
/// Prepare exports the mind dataset into the job dir. Run invokes
/// `FoundationToolkitTrainService` (Apple toolkit when configured, else stub).
public final class FoundationModelsAdapterRunner: TrainingRunner, @unchecked Sendable {
    public let id: String
    public let protocolVersion: Int
    public let config: FoundationModelsAdapterRunnerConfig
    public var toolkitConfig: FoundationToolkitConfig

    private let cancelledJobIds = OSAllocatedUnfairLock(initialState: Set<String>())

    public init(
        id: String = "foundation-models-adapter-runner",
        protocolVersion: Int = ProtocolVersions.runnerProtocolVersion,
        config: FoundationModelsAdapterRunnerConfig = FoundationModelsAdapterRunnerConfig(),
        toolkitConfig: FoundationToolkitConfig = .load()
    ) {
        self.id = id
        self.protocolVersion = protocolVersion
        self.config = config
        self.toolkitConfig = toolkitConfig
    }

    public func capabilities() async throws -> RunnerCapabilities {
        RunnerCapabilities(
            modalities: [.foundationAdapter],
            resume: false,
            modelFamilies: ["apple-foundation"],
            maxSeqLen: nil,
            engineIds: ["foundation-adapter"]
        )
    }

    public func prepare(job: JobSpec, paths: JobPaths) async throws {
        try Self.validateJob(job, paths: paths)
        try materializeLayout(paths: paths)
        // Export dataset into job dir when dataset path is present.
        if let datasetPath = paths.datasetPath {
            let libraryRoot = URL(fileURLWithPath: paths.libraryRoot, isDirectory: true)
            let jobDir = URL(fileURLWithPath: paths.jobDir, isDirectory: true)
            let exportDir = jobDir.appendingPathComponent("foundation-export", isDirectory: true)
            _ = try FoundationAdapterService(libraryRoot: libraryRoot)
                .exportDatasetForToolkit(
                    sourceJSONLURL: URL(fileURLWithPath: datasetPath),
                    outputDirectory: exportDir
                )
        }
        if config.prepareDelay > .zero {
            try await Task.sleep(for: config.prepareDelay)
        }
        if isCancelled(job.id) {
            throw BAMError(code: .cancelled, message: "Cancelled during prepare")
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
        stream(job: job, paths: paths, resumeNote: "foundation adapter resume from \(checkpoint.path)")
    }

    public func cancel(jobId: String) async {
        cancelledJobIds.withLock { $0.insert(jobId) }
    }

    public func resetCancelState() {
        cancelledJobIds.withLock { $0.removeAll() }
    }

    // MARK: - Internals

    private func isCancelled(_ jobId: String) -> Bool {
        cancelledJobIds.withLock { $0.contains(jobId) }
    }

    private func stream(
        job: JobSpec,
        paths: JobPaths,
        resumeNote: String? = nil
    ) -> AsyncThrowingStream<RunnerEvent, Error> {
        let config = self.config
        let toolkitConfig = self.toolkitConfig
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try Self.validateJob(job, paths: paths)

                    if let resumeNote {
                        continuation.yield(.log(level: "info", message: resumeNote, ts: JobTimestamps.now()))
                    } else {
                        continuation.yield(
                            .log(
                                level: "info",
                                message: "foundation adapter train start method=\(job.method ?? "foundation_adapter")",
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
                            continuation.yield(.result(status: "cancelled", artifacts: [], message: "cancelled"))
                            continuation.finish()
                            return
                        }
                        if config.stepInterval > .zero {
                            try await Task.sleep(for: config.stepInterval)
                        }
                        if Task.isCancelled || self.isCancelled(job.id) {
                            continuation.yield(.result(status: "cancelled", artifacts: [], message: "cancelled"))
                            continuation.finish()
                            return
                        }
                        let eta = Double(total - step) * Self.durationSeconds(config.stepInterval)
                        continuation.yield(
                            .progress(
                                step: step,
                                epoch: Double(step) / Double(total),
                                loss: max(0.2, 1.5 - Double(step) * 0.15),
                                lr: job.hyperparameters?.learningRate,
                                tokensPerSec: nil,
                                etaSec: max(0, eta),
                                metrics: ["totalSteps": Double(total), "foundationAdapter": 1]
                            )
                        )
                        if config.emitHeartbeats {
                            continuation.yield(Self.makeHeartbeat())
                        }
                    }

                    let libraryRoot = URL(fileURLWithPath: paths.libraryRoot, isDirectory: true)
                    let jobDir = URL(fileURLWithPath: paths.jobDir, isDirectory: true)
                    guard let datasetPath = paths.datasetPath else {
                        throw BAMError(
                            code: .schemaInvalid,
                            message: "foundationAdapter requires JobPaths.datasetPath"
                        )
                    }

                    let service = FoundationToolkitTrainService(
                        libraryRoot: libraryRoot,
                        config: toolkitConfig,
                        forceFakeTrain: config.forceFakeTrain
                    )
                    let epochs = job.hyperparameters?.epochs ?? 3
                    let lr = job.hyperparameters?.learningRate ?? 1e-3
                    let batch = job.hyperparameters?.batchSize ?? 4
                    let result = try service.train(
                        sourceJSONLURL: URL(fileURLWithPath: datasetPath),
                        jobDir: jobDir,
                        artifactId: job.id,
                        displayName: "Foundation adapter \(job.id.prefix(8))",
                        datasetId: job.datasetVersionId,
                        epochs: epochs,
                        learningRate: lr,
                        batchSize: batch
                    )

                    for line in result.logLines.suffix(12) {
                        continuation.yield(.log(level: "info", message: line, ts: JobTimestamps.now()))
                    }

                    let rel = "artifacts/foundation_adapter"
                    if let publish = result.publish {
                        // Mirror into job artifacts for queue consumers.
                        let artDir = jobDir.appendingPathComponent(rel, isDirectory: true)
                        try? FileManager.default.createDirectory(at: artDir, withIntermediateDirectories: true)
                        let marker = artDir.appendingPathComponent("published_path.txt")
                        try? publish.directoryURL.path.write(to: marker, atomically: true, encoding: .utf8)
                    }

                    continuation.yield(.artifact(kind: "foundation_adapter", path: rel))
                    continuation.yield(
                        .result(
                            status: "succeeded",
                            artifacts: [RunnerArtifactRef(kind: "foundation_adapter", path: rel)],
                            message: result.message + (result.fakeTrain ? " fake=true" : " fake=false")
                        )
                    )
                    continuation.finish()
                } catch {
                    if let bam = error as? BAMError {
                        let msg = bam.message ?? bam.localizedDescription
                        continuation.yield(
                            .error(code: bam.code.rawValue, message: msg, retriable: false)
                        )
                        continuation.yield(
                            .result(status: "failed", artifacts: [], message: msg)
                        )
                    } else {
                        continuation.yield(
                            .error(code: "BAM_UNKNOWN", message: error.localizedDescription, retriable: false)
                        )
                        continuation.yield(
                            .result(status: "failed", artifacts: [], message: error.localizedDescription)
                        )
                    }
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public static func validateJob(_ job: JobSpec, paths: JobPaths) throws {
        guard job.modality == .foundationAdapter else {
            throw BAMError(
                code: .schemaInvalid,
                message: "FoundationModelsAdapterRunner only handles foundationAdapter modality"
            )
        }
        guard paths.datasetPath != nil else {
            throw BAMError(
                code: .schemaInvalid,
                message: "foundationAdapter requires JobPaths.datasetPath (mind JSONL)"
            )
        }
    }

    private func materializeLayout(paths: JobPaths) throws {
        let fm = FileManager.default
        for rel in ["artifacts", "checkpoints", "logs", "data"] {
            let dir = URL(fileURLWithPath: paths.jobDir, isDirectory: true)
                .appendingPathComponent(rel, isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    private static func makeHeartbeat() -> RunnerEvent {
        .heartbeat(rssBytes: 256 * 1024 * 1024, gpuUtil: nil, cpuUtil: 0.2, ts: JobTimestamps.now())
    }

    private static func durationSeconds(_ d: Duration) -> Double {
        let c = d.components
        return Double(c.seconds) + Double(c.attoseconds) / 1e18
    }
}

