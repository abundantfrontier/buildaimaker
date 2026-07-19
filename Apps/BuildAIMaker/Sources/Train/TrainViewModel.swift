import Foundation
import SwiftUI
import BAMCore
import BAMDatasets
import BAMModelCatalog
import BAMModels
import BAMPersistence
import BAMRunners
import BAMRunnersMLX

/// Train wizard: pick dataset + local/fixture model → dry-run or full LoRA train.
@MainActor
final class TrainViewModel: ObservableObject {
    @Published private(set) var datasets: [DatasetRecord] = []
    @Published private(set) var localModels: [ScannedLocalModel] = []
    @Published var selectedDatasetId: String?
    @Published var selectedModelPath: String?
    @Published var statusMessage: String?
    @Published var resultSummary: String?
    @Published var isRunning = false
    @Published var loadError: String?
    @Published var hardwareMessage: String?
    @Published var hardwareOK = true
    @Published private(set) var llmTrainingEnabled: Bool = FeatureFlags.default.llmTraining
    /// Set when last failure was `BAM_RUNTIME_INTEGRITY` (Settings → Repair CTA).
    @Published var needsRuntimeRepair = false

    private var datasetService: DatasetLibraryService?
    private let libraryRoot: URL
    private let scanner: LocalModelScanner
    private let featureFlags: FeatureFlags

    init(
        libraryRoot: URL = LibraryPaths.libraryRoot,
        featureFlags: FeatureFlags = .default
    ) {
        self.libraryRoot = libraryRoot
        self.featureFlags = featureFlags
        self.llmTrainingEnabled = featureFlags.llmTraining
        self.scanner = LocalModelScanner(
            modelsBaseURL: libraryRoot.appendingPathComponent("models/base", isDirectory: true)
        )
    }

    func bootstrap() {
        refreshHardware()
        do {
            datasetService = try DatasetLibraryService.openDefault()
            reload()
        } catch {
            loadError = error.localizedDescription
        }
    }

    func reload() {
        loadError = nil
        do {
            if let service = datasetService {
                datasets = try service.listDatasets().filter {
                    $0.modality == .text && $0.status == .ready
                }
                if selectedDatasetId == nil {
                    selectedDatasetId = datasets.first?.id
                }
            }
            localModels = try scanner.scan()
            if selectedModelPath == nil {
                selectedModelPath = localModels.first?.localPath
            }
            if datasets.isEmpty {
                statusMessage = "Import a text dataset first (Datasets sidebar)."
            } else if localModels.isEmpty {
                statusMessage = "Install the fixture model or add a base model (Models sidebar)."
            } else {
                statusMessage = nil
            }
        } catch {
            loadError = error.localizedDescription
        }
    }

    func refreshHardware() {
        let gate = HardwareFitGate.check()
        hardwareOK = gate.allowed
        hardwareMessage = gate.allowed
            ? "Hardware: ~\(gate.availableUnifiedGB) GB unified memory (minimum \(gate.minimumRequiredGB) GB)."
            : gate.message
    }

    var canDryRun: Bool {
        !isRunning
            && hardwareOK
            && selectedDatasetId != nil
            && selectedModelPath != nil
            && datasetService != nil
    }

    var canTrain: Bool {
        canDryRun && llmTrainingEnabled
    }

    func validateAndDryRun() {
        guard !isRunning else { return }
        guard hardwareOK else {
            resultSummary = hardwareMessage
            return
        }
        guard let datasetId = selectedDatasetId,
              let modelPath = selectedModelPath,
              let service = datasetService
        else {
            resultSummary = "Select a dataset and a local base model."
            return
        }

        isRunning = true
        resultSummary = nil
        statusMessage = "Materializing job + prepare (no weight updates)…"

        Task {
            defer { isRunning = false }
            do {
                let ctx = try makeTrainContext(
                    datasetId: datasetId,
                    modelPath: modelPath,
                    service: service
                )
                defer { ctx.access.stop() }

                var invokeWorker = true
                var workerURL: URL?
                do {
                    workerURL = try MLXWorkerClient.resolveWorkerExecutable()
                } catch {
                    invokeWorker = false
                }

                var config = ProcessSupervisorConfig.testing
                config.helloDeadline = 10
                config.heartbeatTimeout = 5
                config.extraEnvironment = [
                    RuntimePaths.EnvironmentKey.skipInterpreterCheck: "1",
                ]
                if let pins = RuntimePaths.resolvePinsRoot() {
                    config.extraEnvironment[RuntimePaths.EnvironmentKey.pythonPinsRoot] = pins.path
                }

                let dryRun = DryRunService(
                    libraryRoot: libraryRoot,
                    supervisorConfig: config,
                    invokeWorker: invokeWorker,
                    availableUnifiedGBOverride: nil
                )

                let result = try await dryRun.validateAndDryRun(
                    sourceJSONLURL: ctx.access.url,
                    baseModelPath: ctx.modelURL,
                    baseModelId: ctx.modelId,
                    baseModelSourceKey: ctx.sourceKey,
                    datasetVersionId: ctx.versionId,
                    chatTemplateId: ctx.chatTemplate,
                    workerURL: workerURL
                )

                let jobDir = result.materialize.paths.jobDir
                let lines = [
                    "Dry-run OK (prepare only; didTrain=\(result.didTrain))",
                    "Job: \(result.materialize.spec.id)",
                    "Examples: \(result.materialize.exampleCount)",
                    "Normalized: \(result.materialize.normalizedJSONLURL.path)",
                    "Job dir: \(jobDir)",
                    "Worker: \(result.workerExecutablePath)",
                    result.workerId.map { "Worker id: \($0)" } ?? "Worker: materialize-only",
                ]
                resultSummary = lines.joined(separator: "\n")
                statusMessage = "Validate & dry-run succeeded."
                needsRuntimeRepair = false
            } catch {
                applyFailure(error, status: "Dry-run failed")
            }
        }
    }

    /// Full LoRA train: materialize → ProcessSupervisor prepare+run → publish adapter.
    func trainLoRA() {
        guard !isRunning else { return }
        guard llmTrainingEnabled else {
            resultSummary = "ff.llmTraining is off."
            return
        }
        guard hardwareOK else {
            resultSummary = hardwareMessage
            return
        }
        guard let datasetId = selectedDatasetId,
              let modelPath = selectedModelPath,
              let service = datasetService
        else {
            resultSummary = "Select a dataset and a local base model."
            return
        }

        isRunning = true
        resultSummary = nil
        statusMessage = "LoRA train: materialize → prepare → run…"

        Task {
            defer { isRunning = false }
            do {
                let ctx = try makeTrainContext(
                    datasetId: datasetId,
                    modelPath: modelPath,
                    service: service
                )
                defer { ctx.access.stop() }

                let workerURL = try MLXWorkerClient.resolveWorkerExecutable()

                var config = ProcessSupervisorConfig.testing
                config.helloDeadline = 15
                config.heartbeatTimeout = 20
                config.extraEnvironment = [
                    RuntimePaths.EnvironmentKey.skipInterpreterCheck: "1",
                    // Dogfood UI defaults to fake unless managed mlx-lm is installed;
                    // set BAM_LORA_REAL=1 in the environment to force the Python path.
                    "BAM_LORA_FAKE": ProcessInfo.processInfo.environment["BAM_LORA_REAL"] == "1"
                        ? "0" : "1",
                ]
                if let pins = RuntimePaths.resolvePinsRoot() {
                    config.extraEnvironment[RuntimePaths.EnvironmentKey.pythonPinsRoot] = pins.path
                }

                let serviceTrain = LoRATrainService(
                    libraryRoot: libraryRoot,
                    supervisorConfig: config,
                    forceFakeTrain: ProcessInfo.processInfo.environment["BAM_LORA_REAL"] != "1"
                )

                let result = try await serviceTrain.train(
                    sourceJSONLURL: ctx.access.url,
                    baseModelPath: ctx.modelURL,
                    baseModelId: ctx.modelId,
                    baseModelSourceKey: ctx.sourceKey,
                    datasetVersionId: ctx.versionId,
                    chatTemplateId: ctx.chatTemplate,
                    workerURL: workerURL
                )

                var lines = [
                    "LoRA train \(result.status) (didTrain=\(result.didTrain), fake=\(result.fakeTrain))",
                    "Job: \(result.materialize.spec.id)",
                    "Examples: \(result.materialize.exampleCount)",
                    "Worker: \(result.workerExecutablePath)",
                ]
                if let loss = result.finalTrainLoss {
                    lines.append(String(format: "Final train loss: %.4f", loss))
                }
                if let hold = result.holdOutLoss {
                    lines.append(String(format: "Hold-out loss: %.4f", hold))
                }
                if let publish = result.publish {
                    lines.append("Adapter id: \(publish.artifactId)")
                    lines.append("Adapter path: \(publish.adapterDirectory.path)")
                    lines.append("Model card: \(publish.modelCardURL.path)")
                }
                if let message = result.message {
                    lines.append("Message: \(message)")
                }
                resultSummary = lines.joined(separator: "\n")
                statusMessage = result.status == "succeeded"
                    ? "LoRA train succeeded — adapter under models/adapters/."
                    : "LoRA train finished with status \(result.status)."
                needsRuntimeRepair = false
            } catch {
                applyFailure(error, status: "LoRA train failed")
            }
        }
    }

    /// Map integrity failures onto Settings → Repair recovery copy.
    private func applyFailure(_ error: Error, status: String) {
        needsRuntimeRepair = RuntimeRecovery.isIntegrityFailure(error)
        statusMessage = RuntimeRecovery.augmentStatus(status, error: error)
        if let recovery = RuntimeRecovery.userMessage(for: error) {
            resultSummary = recovery
        } else {
            resultSummary = error.localizedDescription
        }
    }

    // MARK: - Shared context

    private struct TrainContext {
        var access: ResolvedSourceAccess
        var modelURL: URL
        var modelId: String
        var sourceKey: String
        var versionId: String
        var chatTemplate: String
    }

    private func makeTrainContext(
        datasetId: String,
        modelPath: String,
        service: DatasetLibraryService
    ) throws -> TrainContext {
        guard let dataset = try service.dataset(id: datasetId) else {
            throw BAMError(code: .datasetInvalid, message: "Dataset not found")
        }
        let access = try service.resolveSourceAccess(for: dataset)

        let version = try service.latestVersion(datasetId: datasetId)
        let versionId = version?.id ?? BAMID.generate()

        let modelURL = URL(fileURLWithPath: modelPath, isDirectory: true)
        let modelId: String
        let sourceKey: String
        if modelURL.lastPathComponent == FixtureModel.installDirectoryName
            || modelURL.path.contains(FixtureModel.installDirectoryName)
        {
            modelId = FixtureModel.stableModelID
            sourceKey = FixtureModel.sourceKey
        } else {
            modelId = BAMID.generate()
            sourceKey = localModels.first(where: { $0.localPath == modelPath })?.displayName
                ?? modelURL.lastPathComponent
        }

        return TrainContext(
            access: access,
            modelURL: modelURL,
            modelId: modelId,
            sourceKey: sourceKey,
            versionId: versionId,
            chatTemplate: ChatTemplateRegistry.qwen25Instruct
        )
    }
}
