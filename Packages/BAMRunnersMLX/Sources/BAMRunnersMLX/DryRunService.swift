import BAMCore
import BAMJobs
import BAMModels
import BAMRunners
import Foundation

/// High-level Validate & dry-run orchestration for the Train wizard.
public struct DryRunService: Sendable {
    public var libraryRoot: URL
    public var materializer: JobMaterializer
    public var supervisorConfig: ProcessSupervisorConfig
    /// When false, skip process spawn and only materialize (tests / missing worker).
    public var invokeWorker: Bool
    /// Optional override for K16 gate (tests inject explicit values).
    public var availableUnifiedGBOverride: Int?

    public init(
        libraryRoot: URL = LibraryPaths.libraryRoot,
        materializer: JobMaterializer = JobMaterializer(),
        supervisorConfig: ProcessSupervisorConfig = .testing,
        invokeWorker: Bool = true,
        availableUnifiedGBOverride: Int? = nil
    ) {
        self.libraryRoot = libraryRoot
        self.materializer = materializer
        self.supervisorConfig = supervisorConfig
        self.invokeWorker = invokeWorker
        self.availableUnifiedGBOverride = availableUnifiedGBOverride
    }

    /// Builds a materialize request from UI selections and runs dry-run (or materialize-only).
    public func validateAndDryRun(
        sourceJSONLURL: URL,
        baseModelPath: URL,
        baseModelId: String,
        baseModelSourceKey: String,
        datasetVersionId: String,
        chatTemplateId: String = ChatTemplateRegistry.qwen25Instruct,
        hyperparameters: LLMHyperparameters = LLMHyperparameters(epochs: 1, batchSize: 1),
        jobId: String = BAMID.generate(),
        workerURL: URL? = nil
    ) async throws -> MLXDryRunResult {
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

        if !invokeWorker {
            let mat = try materializer.materialize(request)
            return MLXDryRunResult(
                materialize: mat,
                workerId: nil,
                capabilities: nil,
                prepareLogMessages: [],
                didTrain: false,
                workerExecutablePath: "(materialize-only)"
            )
        }

        // L1: every helper launch path goes through WorkerSpawn (resolve or explicit URL).
        let exe: URL
        if let workerURL {
            exe = try WorkerSpawn.prepareExecutableURL(workerURL).url
        } else {
            exe = try MLXWorkerClient.resolveWorkerExecutable()
        }
        let client = MLXWorkerClient(
            executableURL: exe,
            config: supervisorConfig,
            materializer: materializer
        )
        return try await client.dryRun(request: request)
    }
}
