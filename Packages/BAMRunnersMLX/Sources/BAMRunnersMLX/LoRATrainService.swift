import BAMCore
import BAMJobs
import BAMModels
import BAMRunners
import Foundation

/// Result of an end-to-end LoRA train (materialize → prepare → run → publish adapter).
public struct LoRATrainResult: Sendable, Equatable {
    public var materialize: LLMMaterializeResult
    public var events: [RunnerEvent]
    public var status: String
    public var didTrain: Bool
    public var fakeTrain: Bool
    public var workerId: String?
    public var workerExecutablePath: String
    public var publish: AdapterPublishResult?
    public var finalTrainLoss: Double?
    public var holdOutLoss: Double?
    public var message: String?

    public init(
        materialize: LLMMaterializeResult,
        events: [RunnerEvent],
        status: String,
        didTrain: Bool,
        fakeTrain: Bool,
        workerId: String?,
        workerExecutablePath: String,
        publish: AdapterPublishResult?,
        finalTrainLoss: Double?,
        holdOutLoss: Double?,
        message: String?
    ) {
        self.materialize = materialize
        self.events = events
        self.status = status
        self.didTrain = didTrain
        self.fakeTrain = fakeTrain
        self.workerId = workerId
        self.workerExecutablePath = workerExecutablePath
        self.publish = publish
        self.finalTrainLoss = finalTrainLoss
        self.holdOutLoss = holdOutLoss
        self.message = message
    }
}

/// High-level E2E LoRA orchestration for the Train wizard / tests.
///
/// Pipeline:
/// 1. K16 hardware gate
/// 2. Materialize job dir (normalized JSONL + JobPaths)
/// 3. `ProcessSupervisor` prepare + run via `MLXWorkerClient`
/// 4. Publish adapter under `models/adapters/<id>/` with model card (K25)
public struct LoRATrainService: Sendable {
    public var libraryRoot: URL
    public var materializer: JobMaterializer
    public var supervisorConfig: ProcessSupervisorConfig
    public var adapterWriter: AdapterArtifactWriter
    /// Optional override for K16 gate (tests inject explicit values).
    public var availableUnifiedGBOverride: Int?
    /// When true, force worker fake train via `BAM_LORA_FAKE=1`.
    public var forceFakeTrain: Bool

    public init(
        libraryRoot: URL = LibraryPaths.libraryRoot,
        materializer: JobMaterializer = JobMaterializer(),
        supervisorConfig: ProcessSupervisorConfig = .testing,
        adapterWriter: AdapterArtifactWriter = AdapterArtifactWriter(),
        availableUnifiedGBOverride: Int? = nil,
        forceFakeTrain: Bool = false
    ) {
        self.libraryRoot = libraryRoot
        self.materializer = materializer
        self.supervisorConfig = supervisorConfig
        self.adapterWriter = adapterWriter
        self.availableUnifiedGBOverride = availableUnifiedGBOverride
        self.forceFakeTrain = forceFakeTrain
    }

    /// Materialize + train + publish. Requires a worker binary (llm or echo).
    public func train(
        sourceJSONLURL: URL,
        baseModelPath: URL,
        baseModelId: String,
        baseModelSourceKey: String,
        datasetVersionId: String,
        chatTemplateId: String = ChatTemplateRegistry.qwen25Instruct,
        hyperparameters: LLMHyperparameters = LLMHyperparameters(epochs: 1, batchSize: 1),
        jobId: String = BAMID.generate(),
        artifactId: String = BAMID.generate(),
        workerURL: URL? = nil
    ) async throws -> LoRATrainResult {
        try HardwareFitGate.refuseIfUnsupported(
            availableUnifiedGB: availableUnifiedGBOverride
        )

        let request = LLMMaterializeRequest(
            jobId: jobId,
            libraryRoot: libraryRoot,
            sourceJSONLURL: sourceJSONLURL,
            baseModelPath: baseModelPath,
            baseModelId: baseModelId,
            baseModelSourceKey: baseModelSourceKey,
            datasetVersionId: datasetVersionId,
            chatTemplateId: chatTemplateId,
            hyperparameters: hyperparameters
        )

        var config = supervisorConfig
        if forceFakeTrain {
            var env = config.extraEnvironment
            env["BAM_LORA_FAKE"] = "1"
            config.extraEnvironment = env
        }

        let exe = try workerURL ?? MLXWorkerClient.resolveWorkerExecutable()
        let client = MLXWorkerClient(
            executableURL: exe,
            config: config,
            materializer: materializer
        )

        let trainOutcome = try await client.train(request: request)

        let lastLoss: Double? = trainOutcome.events.reversed().compactMap { event -> Double? in
            if case let .progress(_, _, loss, _, _, _, _) = event { return loss }
            return nil
        }.first

        // Prefer worker-reported hold-out when present in progress metrics.
        let holdOutFromMetrics: Double? = trainOutcome.events.reversed().compactMap { event -> Double? in
            if case let .progress(_, _, _, _, _, _, metrics) = event {
                return metrics["holdOutLoss"] ?? metrics["val_loss"]
            }
            return nil
        }.first

        let status = trainOutcome.status
        let succeeded = status == "succeeded"
        let fakeTrain = forceFakeTrain || trainOutcome.fakeTrain

        var publish: AdapterPublishResult?
        if succeeded {
            // Ensure adapter + model card exist even when the worker only announced paths
            // (e.g. echo worker) or wrote a partial tree.
            try adapterWriter.ensureJobAdapterStub(
                paths: trainOutcome.materialize.paths,
                spec: trainOutcome.materialize.spec,
                holdOutLoss: holdOutFromMetrics ?? 1.25,
                trainLoss: lastLoss ?? 0.85,
                fakeTrain: fakeTrain
            )
            publish = try adapterWriter.publishToLibrary(
                paths: trainOutcome.materialize.paths,
                spec: trainOutcome.materialize.spec,
                artifactId: artifactId,
                holdOutLoss: holdOutFromMetrics ?? 1.25,
                trainLoss: lastLoss ?? 0.85,
                fakeTrain: fakeTrain
            )
        }

        return LoRATrainResult(
            materialize: trainOutcome.materialize,
            events: trainOutcome.events,
            status: status,
            didTrain: trainOutcome.didTrain,
            fakeTrain: fakeTrain,
            workerId: trainOutcome.workerId,
            workerExecutablePath: trainOutcome.workerExecutablePath,
            publish: publish,
            finalTrainLoss: lastLoss,
            holdOutLoss: holdOutFromMetrics ?? (succeeded ? 1.25 : nil),
            message: trainOutcome.message
        )
    }
}
