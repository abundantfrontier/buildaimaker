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
    @Published var selectedModelPath: String? {
        didSet { recomputeHardwareFit() }
    }
    @Published var statusMessage: String?
    @Published var resultSummary: String?
    @Published var isRunning = false
    @Published var loadError: String?

    // Hardware Fit panel
    @Published var hardwareOK = true
    @Published var hardwareWarning = false
    @Published var hardwareMessage: String?
    @Published var fitPeakGB: Double?
    @Published var fitRequiredGB: Double?
    @Published var fitAvailableGB: Double?
    @Published var fitStatus: HardwareFitGate.FitStatus = .ok
    @Published var fitSuggestions: [String] = []
    @Published var fitParamCountB: Double = 1.5
    @Published var fitQuantBits: Int = 4

    // Hyperparameters affecting the estimator
    @Published var loraRank: Int = 16 {
        didSet { recomputeHardwareFit() }
    }
    @Published var maxSeqLen: Int = 2048 {
        didSet { recomputeHardwareFit() }
    }
    @Published var batchSize: Int = 1 {
        didSet { recomputeHardwareFit() }
    }
    @Published var gradAccum: Int = 4 {
        didSet { recomputeHardwareFit() }
    }

    private var datasetService: DatasetLibraryService?
    private let libraryRoot: URL
    private let scanner: LocalModelScanner
    private var catalog: ModelCatalog?

    init(libraryRoot: URL = LibraryPaths.libraryRoot) {
        self.libraryRoot = libraryRoot
        self.scanner = LocalModelScanner(
            modelsBaseURL: libraryRoot.appendingPathComponent("models/base", isDirectory: true)
        )
    }

    func bootstrap() {
        catalog = try? ModelCatalog.loadBundled()
        recomputeHardwareFit()
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
            resolveModelSizeClass()
            recomputeHardwareFit()
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

    /// Maps selected local model → catalog size class (paramCountB / quantBits).
    func resolveModelSizeClass() {
        guard let path = selectedModelPath else {
            fitParamCountB = 1.5
            fitQuantBits = 4
            return
        }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        let leaf = url.lastPathComponent

        if leaf == FixtureModel.installDirectoryName
            || path.contains(FixtureModel.installDirectoryName)
        {
            if let entry = catalog?.fixtureEntry ?? catalog?.entry(sourceKey: FixtureModel.sourceKey) {
                fitParamCountB = entry.paramCountB
                fitQuantBits = entry.quantBits
            } else {
                fitParamCountB = 0.001
                fitQuantBits = 16
            }
            return
        }

        // Match catalog by path component / sourceKey tail / display name.
        if let catalog {
            let scanned = localModels.first(where: { $0.localPath == path })
            if let hit = catalog.entries.first(where: { entry in
                leaf == entry.sourceKey
                    || leaf.contains(entry.sourceKey.split(separator: "/").last.map(String.init) ?? "\u{0}")
                    || path.localizedCaseInsensitiveContains(entry.sourceKey)
                    || scanned?.displayName == entry.name
                    || scanned?.displayName == entry.archFamily
            }) {
                fitParamCountB = hit.paramCountB
                fitQuantBits = hit.quantBits
                return
            }
        }

        // Conservative default for unknown local folders.
        fitParamCountB = 1.5
        fitQuantBits = 4
    }

    func recomputeHardwareFit() {
        resolveModelSizeClass()
        let available = Double(HardwareFitGate.probeAvailableUnifiedGB())
        let input = HardwareFitGate.EstimateInput(
            paramCountB: fitParamCountB,
            quantBits: fitQuantBits,
            loraRank: loraRank,
            maxSeqLen: maxSeqLen,
            batchSize: batchSize,
            gradAccum: gradAccum,
            availableUnifiedGB: available
        )
        let est = HardwareFitGate.estimate(input)
        fitStatus = est.status
        fitPeakGB = est.peakGB
        fitRequiredGB = est.requiredGB
        fitAvailableGB = est.availableUnifiedGB
        fitSuggestions = est.suggestions
        hardwareMessage = est.message
        hardwareOK = est.allowed
        hardwareWarning = est.status == .warning
    }

    var canDryRun: Bool {
        !isRunning
            && hardwareOK
            && selectedDatasetId != nil
            && selectedModelPath != nil
            && datasetService != nil
    }

    var currentHyperparameters: LLMHyperparameters {
        LLMHyperparameters(
            loraRank: loraRank,
            epochs: 1, // Dry-run uses a single epoch; real train PR will expose epochs.
            batchSize: batchSize,
            gradAccum: gradAccum,
            maxSeqLen: maxSeqLen
        )
    }

    func validateAndDryRun() {
        guard !isRunning else { return }
        recomputeHardwareFit()
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

        let hp = currentHyperparameters
        let paramB = fitParamCountB
        let quant = fitQuantBits

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
                    availableUnifiedGBOverride: nil,
                    fitParamCountB: paramB,
                    fitQuantBits: quant
                )

                let result = try await dryRun.validateAndDryRun(
                    sourceJSONLURL: access.url,
                    baseModelPath: modelURL,
                    baseModelId: modelId,
                    baseModelSourceKey: sourceKey,
                    datasetVersionId: versionId,
                    chatTemplateId: chatTemplate,
                    hyperparameters: hp,
                    workerURL: workerURL,
                    paramCountB: paramB,
                    quantBits: quant
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
                    String(
                        format: "Hardware fit: peak ~%.2f GB / required ~%.2f GB (status=%@)",
                        fitPeakGB ?? 0,
                        fitRequiredGB ?? 0,
                        fitStatus.rawValue
                    ),
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
