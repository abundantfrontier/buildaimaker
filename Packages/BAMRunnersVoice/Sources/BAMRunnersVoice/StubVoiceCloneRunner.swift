import BAMCore
import BAMJobs
import BAMModels
import Foundation
import os

/// Configuration for the stub voice-clone runner (no F5-TTS / multi-GB download).
public struct StubVoiceCloneRunnerConfig: Sendable, Equatable {
    public var stepCount: Int
    public var stepInterval: Duration
    public var prepareDelay: Duration
    public var emitHeartbeats: Bool

    public init(
        stepCount: Int = 5,
        stepInterval: Duration = .milliseconds(40),
        prepareDelay: Duration = .milliseconds(10),
        emitHeartbeats: Bool = true
    ) {
        self.stepCount = max(1, stepCount)
        self.stepInterval = stepInterval
        self.prepareDelay = prepareDelay
        self.emitHeartbeats = emitHeartbeats
    }

    public static let testing = StubVoiceCloneRunnerConfig(
        stepCount: 3,
        stepInterval: .milliseconds(5),
        prepareDelay: .milliseconds(1)
    )
}

/// In-process voice-clone runner that materializes a **stub** `voice_profile` artifact.
///
/// Product path while F5-TTS is not installed: validates consent fields +
/// `JobPaths.referenceAudioPath`, copies ref WAV into library `voices/<id>/`,
/// writes `profile.json`, and emits synthetic progress. Never loads XTTS.
public final class StubVoiceCloneRunner: TrainingRunner, @unchecked Sendable {
    public let id: String
    public let protocolVersion: Int
    public let config: StubVoiceCloneRunnerConfig

    /// Optional override for voice profile id (defaults to job id).
    public var voiceProfileIdOverride: String?

    private let cancelledJobIds = OSAllocatedUnfairLock(initialState: Set<String>())

    public init(
        id: String = "stub-voice-clone-runner",
        protocolVersion: Int = ProtocolVersions.runnerProtocolVersion,
        config: StubVoiceCloneRunnerConfig = StubVoiceCloneRunnerConfig()
    ) {
        self.id = id
        self.protocolVersion = protocolVersion
        self.config = config
    }

    public func capabilities() async throws -> RunnerCapabilities {
        RunnerCapabilities(
            modalities: [.voiceClone],
            resume: false,
            modelFamilies: ["f5-tts"],
            maxSeqLen: nil,
            engineIds: [VoiceCloneMaterializer.defaultEngineId]
        )
    }

    public func prepare(job: JobSpec, paths: JobPaths) async throws {
        try Self.validateJob(job, paths: paths)
        try VoiceCloneMaterializer.materializeJobLayout(job: job, paths: paths)
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
        // Stub does not resume weights; re-runs full stub materialization.
        stream(job: job, paths: paths, resumeNote: "stub resume from \(checkpoint.path)")
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
        let profileId = voiceProfileIdOverride ?? job.id
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try Self.validateJob(job, paths: paths)

                    if let resumeNote {
                        continuation.yield(
                            .log(level: "info", message: resumeNote, ts: JobTimestamps.now())
                        )
                    } else {
                        continuation.yield(
                            .log(
                                level: "info",
                                message: "stub voice clone start engine=\(job.engineId ?? VoiceCloneMaterializer.defaultEngineId)",
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
                            continuation.yield(
                                .result(status: "cancelled", artifacts: [], message: "cancelled")
                            )
                            continuation.finish()
                            return
                        }

                        let eta = Double(total - step) * config.stepInterval.seconds
                        continuation.yield(
                            .progress(
                                step: step,
                                epoch: Double(step) / Double(total),
                                loss: nil,
                                lr: nil,
                                tokensPerSec: nil,
                                etaSec: max(0, eta),
                                metrics: ["totalSteps": Double(total), "voiceClone": 1]
                            )
                        )
                        if config.emitHeartbeats {
                            continuation.yield(Self.makeHeartbeat())
                        }
                    }

                    // Materialize stub voice_profile under library + job artifacts.
                    let libraryRoot = URL(fileURLWithPath: paths.libraryRoot, isDirectory: true)
                    guard let refPath = paths.referenceAudioPath else {
                        throw BAMError(
                            code: .pathEscape,
                            message: "voiceClone requires JobPaths.referenceAudioPath"
                        )
                    }
                    let (_, profile) = try VoiceCloneMaterializer.materializeWithStubProfile(
                        job: job,
                        libraryRoot: libraryRoot,
                        referenceAudioPath: refPath,
                        voiceProfileId: profileId
                    )

                    let relativeArtifact = "artifacts/voice_profile"
                    continuation.yield(.artifact(kind: "voice_profile", path: relativeArtifact))
                    continuation.yield(
                        .log(
                            level: "info",
                            message: "stub voice_profile written \(profile.voiceProfileDir)",
                            ts: JobTimestamps.now()
                        )
                    )
                    continuation.yield(
                        .result(
                            status: "succeeded",
                            artifacts: [
                                RunnerArtifactRef(kind: "voice_profile", path: relativeArtifact),
                            ],
                            message: "stub=\(profile.stub)"
                        )
                    )
                    continuation.finish()
                } catch {
                    if let bam = error as? BAMError {
                        continuation.yield(
                            .error(code: bam.code.rawValue, message: bam.message ?? bam.code.rawValue, retriable: false)
                        )
                        continuation.yield(
                            .result(status: "failed", artifacts: [], message: bam.message)
                        )
                        continuation.finish()
                    } else {
                        continuation.finish(throwing: error)
                    }
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    /// Shared prepare/run gate: modality, engine license, consent fields, jailed reference path.
    public static func validateJob(_ job: JobSpec, paths: JobPaths) throws {
        guard job.modality == .voiceClone else {
            throw BAMError(
                code: .schemaInvalid,
                message: "StubVoiceCloneRunner requires modality voiceClone, got \(job.modality.rawValue)"
            )
        }
        try VoiceCloneMaterializer.assertJobEngineAllowed(job)

        guard let consentId = job.consentRecordId, !consentId.isEmpty else {
            throw BAMError(
                code: .consentRequired,
                message: "voiceClone JobSpec requires consentRecordId"
            )
        }
        guard let consentHash = job.consentContentHash, !consentHash.isEmpty else {
            throw BAMError(
                code: .consentRequired,
                message: "voiceClone JobSpec requires consentContentHash"
            )
        }
        _ = consentId
        _ = consentHash

        try VoiceCloneMaterializer.validateVoicePaths(paths)
    }

    private static func makeHeartbeat() -> RunnerEvent {
        .heartbeat(
            rssBytes: 256 * 1024 * 1024,
            gpuUtil: 0.1,
            cpuUtil: 0.2,
            ts: JobTimestamps.now()
        )
    }
}

private extension Duration {
    var seconds: Double {
        let c = components
        return Double(c.seconds) + Double(c.attoseconds) / 1e18
    }
}
