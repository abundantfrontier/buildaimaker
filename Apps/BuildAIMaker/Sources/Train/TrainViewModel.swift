import Foundation
import SwiftUI
import BAMCore
import BAMDatasets
import BAMModelCatalog
import BAMModels
import BAMPersistence
import BAMRunners
import BAMRunnersMLX

/// Train wizard: pick dataset + local/fixture model → Validate & dry-run (prepare only).
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

    private var datasetService: DatasetLibraryService?
    private let libraryRoot: URL
    private let scanner: LocalModelScanner

    init(libraryRoot: URL = LibraryPaths.libraryRoot) {
        self.libraryRoot = libraryRoot
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
                guard let dataset = try service.dataset(id: datasetId) else {
                    throw BAMError(code: .datasetInvalid, message: "Dataset not found")
                }
                let access = try service.resolveSourceAccess(for: dataset)
                defer { access.stop() }

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

                let chatTemplate = ChatTemplateRegistry.qwen25Instruct

                // Prefer materialize + prepare via worker; fall back to materialize-only.
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
                    sourceJSONLURL: access.url,
                    baseModelPath: modelURL,
                    baseModelId: modelId,
                    baseModelSourceKey: sourceKey,
                    datasetVersionId: versionId,
                    chatTemplateId: chatTemplate,
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
            } catch {
                statusMessage = "Dry-run failed"
                resultSummary = error.localizedDescription
            }
        }
    }
}
