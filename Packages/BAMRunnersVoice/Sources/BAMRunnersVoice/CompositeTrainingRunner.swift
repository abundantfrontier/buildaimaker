import BAMCore
import BAMJobs
import BAMModels
import Foundation
import os

/// Routes `TrainingRunner` calls by `JobSpec.modality`.
///
/// Used so a single `JobQueueController` can run LLM fake jobs and voice-clone
/// stub jobs without dual processors fighting over the queue slot.
public final class CompositeTrainingRunner: TrainingRunner, @unchecked Sendable {
    public let id: String
    public let protocolVersion: Int

    private let llm: any TrainingRunner
    private let voice: any TrainingRunner
    private let cancelledJobIds = OSAllocatedUnfairLock(initialState: Set<String>())

    public init(
        llm: any TrainingRunner,
        voice: any TrainingRunner,
        id: String = "composite-training-runner",
        protocolVersion: Int = ProtocolVersions.runnerProtocolVersion
    ) {
        self.llm = llm
        self.voice = voice
        self.id = id
        self.protocolVersion = protocolVersion
    }

    public func capabilities() async throws -> RunnerCapabilities {
        let llmCaps = try await llm.capabilities()
        let voiceCaps = try await voice.capabilities()
        var modalities = Set(llmCaps.modalities)
        modalities.formUnion(voiceCaps.modalities)
        var families = llmCaps.modelFamilies
        for f in voiceCaps.modelFamilies where !families.contains(f) {
            families.append(f)
        }
        var engines = llmCaps.engineIds ?? []
        for e in voiceCaps.engineIds ?? [] where !engines.contains(e) {
            engines.append(e)
        }
        return RunnerCapabilities(
            modalities: JobModality.allCases.filter { modalities.contains($0) },
            resume: llmCaps.resume || voiceCaps.resume,
            modelFamilies: families,
            maxSeqLen: llmCaps.maxSeqLen ?? voiceCaps.maxSeqLen,
            engineIds: engines.isEmpty ? nil : engines
        )
    }

    public func prepare(job: JobSpec, paths: JobPaths) async throws {
        try await runner(for: job.modality).prepare(job: job, paths: paths)
    }

    public func run(job: JobSpec, paths: JobPaths) -> AsyncThrowingStream<RunnerEvent, Error> {
        runner(for: job.modality).run(job: job, paths: paths)
    }

    public func resume(
        job: JobSpec,
        paths: JobPaths,
        checkpoint: CheckpointRef
    ) -> AsyncThrowingStream<RunnerEvent, Error> {
        runner(for: job.modality).resume(job: job, paths: paths, checkpoint: checkpoint)
    }

    public func cancel(jobId: String) async {
        cancelledJobIds.withLock { $0.insert(jobId) }
        await llm.cancel(jobId: jobId)
        await voice.cancel(jobId: jobId)
    }

    private func runner(for modality: JobModality) -> any TrainingRunner {
        switch modality {
        case .voiceClone, .voiceFinetune:
            return voice
        case .llm:
            return llm
        }
    }
}
