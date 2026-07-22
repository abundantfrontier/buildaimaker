import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import BAMCharacterStudio
import BAMCore
import BAMDatasets
import BAMInference
import BAMModelCatalog
import BAMModels
import BAMPersistence
import BAMRunners
import BAMRunnersMLX

/// Train wizard: pick dataset + local model → dry-run prepare **or** full LoRA train,
/// or specialize Apple’s on-device model via Foundation adapters.
@MainActor
final class TrainViewModel: ObservableObject {
    @Published private(set) var datasets: [DatasetRecord] = []
    @Published private(set) var localModels: [ScannedLocalModel] = []
    @Published var selectedDatasetId: String?
    @Published var selectedModelPath: String? {
        didSet { recomputeHardwareFit() }
    }
    /// Dual train path: open MLX LoRA vs Apple Foundation adapter.
    @Published var trainBackend: TrainBackend = .openMlxLora
    @Published private(set) var appleModelStatus: AppleFoundationModelStatus = .unknown
    @Published private(set) var foundationAdapters: [FoundationAdapterRecord] = []
    @Published private(set) var lastExportDirectory: String?
    /// Absolute path to Apple Adapter Training Toolkit root (UserDefaults-backed).
    @Published var toolkitRootPath: String = "" {
        didSet { persistToolkitConfig() }
    }
    @Published var toolkitPythonPath: String = "" {
        didSet { persistToolkitConfig() }
    }
    @Published private(set) var toolkitProbeDetail: String = ""
    @Published private(set) var toolkitInstalled: Bool = false
    @Published var statusMessage: String?
    @Published var resultSummary: String?
    @Published var isRunning = false
    @Published var loadError: String?
    @Published private(set) var boundCharacterName: String?
    @Published private(set) var modelCapability: LocalModelCapability = .stub(reason: "No model selected")
    @Published private(set) var lastPublishedAdapterPath: String?

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

    // Hyperparameters
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
    @Published var epochs: Int = 1

    private var datasetService: DatasetLibraryService?
    private let libraryRoot: URL
    private let scanner: LocalModelScanner
    private var catalog: ModelCatalog?
    private let featureFlags: FeatureFlags
    private var lastAppliedTrainToken: UUID?

    init(
        libraryRoot: URL = LibraryPaths.libraryRoot,
        featureFlags: FeatureFlags = .default
    ) {
        self.libraryRoot = libraryRoot
        self.featureFlags = featureFlags
        self.scanner = LocalModelScanner(
            modelsBaseURL: libraryRoot.appendingPathComponent("models/base", isDirectory: true)
        )
    }

    func bootstrap() {
        catalog = try? ModelCatalog.loadBundled()
        recomputeHardwareFit()
        loadToolkitConfig()
        do {
            datasetService = try DatasetLibraryService.openDefault()
            reload()
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func loadToolkitConfig() {
        let cfg = FoundationToolkitConfig.load()
        toolkitRootPath = cfg.toolkitRoot ?? ""
        toolkitPythonPath = cfg.pythonExecutable ?? ""
        refreshToolkitProbe()
    }

    private func persistToolkitConfig() {
        let cfg = FoundationToolkitConfig(
            toolkitRoot: toolkitRootPath.isEmpty ? nil : toolkitRootPath,
            pythonExecutable: toolkitPythonPath.isEmpty ? nil : toolkitPythonPath
        )
        cfg.save()
        refreshToolkitProbe()
    }

    func refreshToolkitProbe() {
        let probe = FoundationToolkitProbe.probe(
            config: FoundationToolkitConfig(
                toolkitRoot: toolkitRootPath.isEmpty ? nil : toolkitRootPath,
                pythonExecutable: toolkitPythonPath.isEmpty ? nil : toolkitPythonPath
            )
        )
        toolkitInstalled = probe.installed
        toolkitProbeDetail = probe.detail
    }

    func chooseToolkitFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "Select Apple Adapter Training Toolkit folder"
        panel.message = "Choose the toolkit root (contains examples/train_adapter.py)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        toolkitRootPath = url.path
    }

    /// Apply character handoff (model + mind dataset).
    func applyCharacterLaunch(_ target: CharacterStudioLaunchContext.TrainTarget) {
        guard lastAppliedTrainToken != target.token else { return }
        lastAppliedTrainToken = target.token
        boundCharacterName = target.characterName
        if target.prefersAppleFoundationAdapter, featureFlags.foundationModels {
            trainBackend = .appleFoundationAdapter
        } else if let path = target.baseModelPath, !path.isEmpty,
                  path != CharacterDraft.appleFoundationPath
        {
            trainBackend = .openMlxLora
            selectedModelPath = path
        } else if let path = target.baseModelPath, !path.isEmpty {
            selectedModelPath = path
        }
        if let ds = target.datasetId, !ds.isEmpty {
            selectedDatasetId = ds
        }
        reload()
        let backendNote = trainBackend == .appleFoundationAdapter
            ? " · Apple Foundation adapter path"
            : (target.baseModelName.map { " · \($0)" } ?? "")
        statusMessage = "Bound to character “\(target.characterName)”"
            + backendNote
            + (target.datasetId != nil ? " · mind dataset selected" : "")
    }

    func reload() {
        loadError = nil
        appleModelStatus = AppleFoundationModelSupport.probeStatus()
        do {
            if let service = datasetService {
                datasets = try service.listDatasets().filter {
                    $0.modality == .text && $0.status == .ready
                }
                if selectedDatasetId == nil {
                    selectedDatasetId = datasets.first?.id
                } else if let id = selectedDatasetId, !datasets.contains(where: { $0.id == id }) {
                    // Keep character dataset id if list briefly empty; otherwise fall back.
                    if !datasets.isEmpty {
                        selectedDatasetId = datasets.first?.id
                    }
                }
            }
            localModels = try scanner.scan()
            foundationAdapters = (try? FoundationAdapterService(libraryRoot: libraryRoot).listInstalled()) ?? []
            if selectedModelPath == nil {
                selectedModelPath = localModels.first?.localPath
            } else if let path = selectedModelPath,
                      !localModels.contains(where: { $0.localPath == path }),
                      !FileManager.default.fileExists(atPath: path)
            {
                selectedModelPath = localModels.first?.localPath
            }
            modelCapability = LocalModelCapabilityProbe.probe(path: selectedModelPath)
            resolveModelSizeClass()
            recomputeHardwareFit()
            if datasets.isEmpty {
                statusMessage = "Import a text dataset first (or finish a character mind step)."
            } else if localModels.isEmpty && selectedModelPath == nil {
                statusMessage = "Install a base model (Models or Create → Model)."
            } else if boundCharacterName == nil {
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

        // Prefer bam_install.json sourceKey → catalog.
        if let key = LocalModelCapabilityProbe.sourceKey(path: path),
           let entry = catalog?.entry(sourceKey: key)
        {
            fitParamCountB = entry.paramCountB
            fitQuantBits = entry.quantBits
            return
        }

        if let catalog {
            let scanned = localModels.first(where: { $0.localPath == path })
            if let hit = catalog.entries.first(where: { entry in
                leaf == ModelInstallService.installDirectoryName(forSourceKey: entry.sourceKey)
                    || leaf == entry.sourceKey
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

        fitParamCountB = 1.5
        fitQuantBits = 4
    }

    func recomputeHardwareFit() {
        modelCapability = LocalModelCapabilityProbe.probe(path: selectedModelPath)
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
        guard !isRunning, selectedDatasetId != nil, datasetService != nil else { return false }
        switch trainBackend {
        case .openMlxLora:
            return hardwareOK && selectedModelPath != nil
        case .appleFoundationAdapter:
            return featureFlags.foundationModels
        }
    }

    var canFullTrain: Bool {
        switch trainBackend {
        case .openMlxLora:
            return canDryRun && featureFlags.llmTraining
        case .appleFoundationAdapter:
            return canDryRun && featureFlags.foundationModels
        }
    }

    var canExportAppleToolkit: Bool {
        !isRunning
            && featureFlags.foundationModels
            && selectedDatasetId != nil
            && datasetService != nil
    }

    var canPublishAppleStub: Bool {
        !isRunning && featureFlags.foundationModels
    }

    var currentHyperparameters: LLMHyperparameters {
        LLMHyperparameters(
            loraRank: loraRank,
            epochs: epochs,
            batchSize: batchSize,
            gradAccum: gradAccum,
            maxSeqLen: maxSeqLen
        )
    }

    /// True when train will force BAM_LORA_FAKE (stubs) or worker may still fake if no mlx-lm.
    var willUseFakeTrain: Bool {
        modelCapability.isStub
    }

    func validateAndDryRun() {
        guard !isRunning else { return }
        if trainBackend == .appleFoundationAdapter {
            validateAppleAdapterPreflight()
            return
        }
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
                let prepared = try prepareJobInputs(
                    datasetId: datasetId,
                    modelPath: modelPath,
                    service: service
                )
                defer { prepared.access.stop() }

                var config = ProcessSupervisorConfig.testing
                config.helloDeadline = 10
                config.heartbeatTimeout = 5
                config.extraEnvironment = [
                    RuntimePaths.EnvironmentKey.skipInterpreterCheck: "1",
                ]
                if let pins = RuntimePaths.resolvePinsRoot() {
                    config.extraEnvironment[RuntimePaths.EnvironmentKey.pythonPinsRoot] = pins.path
                }

                var invokeWorker = true
                var workerURL: URL?
                do {
                    workerURL = try MLXWorkerClient.resolveWorkerExecutable()
                } catch {
                    invokeWorker = false
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
                    sourceJSONLURL: prepared.access.url,
                    baseModelPath: prepared.modelURL,
                    baseModelId: prepared.modelId,
                    baseModelSourceKey: prepared.sourceKey,
                    datasetVersionId: prepared.versionId,
                    chatTemplateId: ChatTemplateRegistry.qwen25Instruct,
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
                    "Model: \(prepared.sourceKey) (\(modelCapability.shortLabel))",
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

    /// Full LoRA pipeline: materialize → prepare → run → publish adapter under models/adapters.
    ///
    /// Fixture/dogfood stubs force fake train (`BAM_LORA_FAKE`). Real weight dirs run the worker
    /// without that flag so mlx-lm LoRA can execute when the runtime is installed.
    func startFullLoRATrain() {
        guard !isRunning else { return }
        if trainBackend == .appleFoundationAdapter {
            startAppleAdapterTrain()
            return
        }
        guard featureFlags.llmTraining else {
            resultSummary = "Full LoRA train is disabled (ff.llmTraining is off)."
            return
        }
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
        lastPublishedAdapterPath = nil
        let fake = willUseFakeTrain
        statusMessage = fake
            ? "Starting LoRA train (fake — stub/fixture model)…"
            : "Starting full LoRA train (real weights path)…"

        let hp = currentHyperparameters

        Task {
            defer { isRunning = false }
            do {
                let prepared = try prepareJobInputs(
                    datasetId: datasetId,
                    modelPath: modelPath,
                    service: service
                )
                defer { prepared.access.stop() }

                var config = ProcessSupervisorConfig.testing
                config.helloDeadline = 30
                config.heartbeatTimeout = 120
                config.extraEnvironment = [
                    RuntimePaths.EnvironmentKey.skipInterpreterCheck: "1",
                ]
                if let pins = RuntimePaths.resolvePinsRoot() {
                    config.extraEnvironment[RuntimePaths.EnvironmentKey.pythonPinsRoot] = pins.path
                }

                let workerURL = try? MLXWorkerClient.resolveWorkerExecutable()

                let service = LoRATrainService(
                    libraryRoot: libraryRoot,
                    supervisorConfig: config,
                    forceFakeTrain: fake
                )

                let result = try await service.train(
                    sourceJSONLURL: prepared.access.url,
                    baseModelPath: prepared.modelURL,
                    baseModelId: prepared.modelId,
                    baseModelSourceKey: prepared.sourceKey,
                    datasetVersionId: prepared.versionId,
                    chatTemplateId: ChatTemplateRegistry.qwen25Instruct,
                    hyperparameters: hp,
                    workerURL: workerURL
                )

                lastPublishedAdapterPath = result.publish?.adapterDirectory.path

                var lines = [
                    "LoRA train finished · status=\(result.status) · didTrain=\(result.didTrain) · fake=\(result.fakeTrain)",
                    "Job: \(result.materialize.spec.id)",
                    "Examples: \(result.materialize.exampleCount)",
                    "Base: \(prepared.sourceKey)",
                    "Model capability: \(modelCapability.shortLabel)",
                    "Worker: \(result.workerExecutablePath)",
                ]
                if let loss = result.finalTrainLoss {
                    lines.append(String(format: "Train loss: %.4f", loss))
                }
                if let hold = result.holdOutLoss {
                    lines.append(String(format: "Hold-out loss: %.4f", hold))
                }
                if let pub = result.publish {
                    lines.append("Adapter published: \(pub.adapterDirectory.path)")
                }
                if let msg = result.message, !msg.isEmpty {
                    lines.append("Message: \(msg)")
                }
                if result.fakeTrain {
                    lines.append(
                        "Note: fake train used (stub model and/or mlx-lm unavailable). "
                            + "Install real MLX weights + runtime for weight updates."
                    )
                }
                resultSummary = lines.joined(separator: "\n")
                statusMessage = result.status == "succeeded"
                    ? (result.fakeTrain ? "Fake LoRA train succeeded (adapter stub published)." : "LoRA train succeeded.")
                    : "LoRA train ended with status \(result.status)"

                if result.status == "succeeded" {
                    OnboardingStore().markCompleted(.dryRunOrTrain)
                }
            } catch {
                statusMessage = "LoRA train failed"
                resultSummary = error.localizedDescription
            }
        }
    }

    // MARK: - Apple Foundation adapter path

    func validateAppleAdapterPreflight() {
        appleModelStatus = AppleFoundationModelSupport.probeStatus()
        refreshToolkitProbe()
        let hostSig = FoundationAdapterService.currentSystemSignature()
        var lines = [
            "Apple Foundation adapter preflight",
            "System model: \(appleModelStatus.title) (\(appleModelStatus.rawValue))",
            "Host signature: \(hostSig)",
            "ff.foundationModels: \(featureFlags.foundationModels)",
            "Toolkit: \(toolkitProbeDetail)",
        ]
        if let reason = AppleFoundationModelSupport.unavailableReasonDescription() {
            lines.append("Unavailable reason: \(reason)")
        }
        if let ds = selectedDatasetId {
            lines.append("Dataset: \(ds)")
        } else {
            lines.append("Dataset: (none selected — export/train will need one)")
        }
        lines.append("Installed foundation adapters: \(foundationAdapters.count)")
        for a in foundationAdapters.prefix(5) {
            if let warn = FoundationAdapterService.signatureMismatchWarning(stored: a.baseModelSignature) {
                lines.append("⚠ \(a.displayName): \(warn)")
            }
        }
        lines.append(
            toolkitInstalled
                ? "Start Apple adapter train will run the toolkit CLI (export → train → import)."
                : "Start Apple adapter train will publish a stub unless you set a valid toolkit path."
        )
        resultSummary = lines.joined(separator: "\n")
        statusMessage = appleModelStatus.isUsable
            ? "Apple FM ready — train, export, or import."
            : "Apple FM not ready — you can still export/import adapters."
    }

    /// Run toolkit train when installed; otherwise stub (mirrors LoRA fake path).
    func startAppleAdapterTrain() {
        guard !isRunning else { return }
        guard featureFlags.foundationModels else {
            resultSummary = "ff.foundationModels is off."
            return
        }
        guard let datasetId = selectedDatasetId, let service = datasetService else {
            resultSummary = "Select a text dataset (character mind) first."
            return
        }

        isRunning = true
        resultSummary = nil
        lastPublishedAdapterPath = nil
        refreshToolkitProbe()
        statusMessage = toolkitInstalled
            ? "Starting Apple toolkit train…"
            : "Toolkit not set — publishing adapter stub…"

        let epochs = self.epochs
        let name = boundCharacterName.map { "\($0) adapter" } ?? "Foundation adapter"
        let forceFake = !toolkitInstalled

        Task {
            defer { isRunning = false }
            do {
                guard let dataset = try service.dataset(id: datasetId) else {
                    throw BAMError(code: .datasetInvalid, message: "Dataset not found")
                }
                let access = try service.resolveSourceAccess(for: dataset)
                defer { access.stop() }

                let jobId = BAMID.generate()
                let jobDir = libraryRoot
                    .appendingPathComponent("jobs", isDirectory: true)
                    .appendingPathComponent(jobId, isDirectory: true)
                try FileManager.default.createDirectory(at: jobDir, withIntermediateDirectories: true)

                let trainService = FoundationToolkitTrainService(
                    libraryRoot: libraryRoot,
                    config: FoundationToolkitConfig(
                        toolkitRoot: toolkitRootPath.isEmpty ? nil : toolkitRootPath,
                        pythonExecutable: toolkitPythonPath.isEmpty ? nil : toolkitPythonPath
                    ),
                    forceFakeTrain: forceFake
                )
                let result = try trainService.train(
                    sourceJSONLURL: access.url,
                    jobDir: jobDir,
                    artifactId: jobId,
                    displayName: name,
                    characterName: boundCharacterName,
                    datasetId: datasetId,
                    epochs: epochs,
                    learningRate: 1e-3,
                    batchSize: 4
                )

                lastPublishedAdapterPath = result.publish?.directoryURL.path
                lastExportDirectory = result.export?.exportDirectory.path
                foundationAdapters = (try? FoundationAdapterService(libraryRoot: libraryRoot).listInstalled()) ?? []

                var lines = [
                    result.message,
                    "usedToolkit=\(result.usedToolkit) fake=\(result.fakeTrain)",
                    "Job dir: \(jobDir.path)",
                ]
                if let pub = result.publish {
                    lines.append("Published: \(pub.directoryURL.path)")
                }
                lines.append(contentsOf: result.logLines.suffix(15))
                resultSummary = lines.joined(separator: "\n")
                statusMessage = result.fakeTrain
                    ? "Apple adapter stub published."
                    : "Apple toolkit train finished."
                OnboardingStore().markCompleted(.dryRunOrTrain)
            } catch {
                statusMessage = "Apple adapter train failed"
                resultSummary = error.localizedDescription
            }
        }
    }

    func exportForAppleToolkit() {
        guard canExportAppleToolkit else {
            resultSummary = "Select a text dataset first."
            return
        }
        guard let datasetId = selectedDatasetId, let service = datasetService else { return }

        isRunning = true
        resultSummary = nil
        statusMessage = "Exporting mind dataset for Apple toolkit…"

        Task {
            defer { isRunning = false }
            do {
                guard let dataset = try service.dataset(id: datasetId) else {
                    throw BAMError(code: .datasetInvalid, message: "Dataset not found")
                }
                let access = try service.resolveSourceAccess(for: dataset)
                defer { access.stop() }

                let jobId = BAMID.generate()
                let out = libraryRoot
                    .appendingPathComponent("jobs", isDirectory: true)
                    .appendingPathComponent(jobId, isDirectory: true)
                    .appendingPathComponent("foundation-export", isDirectory: true)

                let export = try FoundationAdapterService(libraryRoot: libraryRoot)
                    .exportDatasetForToolkit(sourceJSONLURL: access.url, outputDirectory: out)

                lastExportDirectory = export.exportDirectory.path
                resultSummary = [
                    "Toolkit export ready",
                    "Train rows: \(export.trainRowCount)",
                    "Eval rows: \(export.evalRowCount)",
                    "Directory: \(export.exportDirectory.path)",
                    "Train: \(export.trainJSONLURL.path)",
                    "Valid: \(export.evalJSONLURL.path)",
                    "See README-apple-adapter.md in that folder for CLI steps.",
                ].joined(separator: "\n")
                statusMessage = "Exported for Apple Adapter Training Toolkit."

                // Reveal in Finder for convenience.
                NSWorkspace.shared.activateFileViewerSelecting([export.exportDirectory])
            } catch {
                statusMessage = "Export failed"
                resultSummary = error.localizedDescription
            }
        }
    }

    func importAppleFMAdapter() {
        guard featureFlags.foundationModels else {
            resultSummary = "ff.foundationModels is off."
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "Import Apple Foundation adapter"
        panel.message = "Choose a .fmadapter package (file or package directory)."
        panel.allowedContentTypes = [
            UTType(filenameExtension: "fmadapter") ?? .data,
            .directory,
            .item,
        ]
        guard panel.runModal() == .OK, let url = panel.url else {
            statusMessage = "Import cancelled."
            return
        }

        isRunning = true
        defer { isRunning = false }
        do {
            let result = try FoundationAdapterService(libraryRoot: libraryRoot).importFMAdapter(
                sourceURL: url,
                displayName: url.deletingPathExtension().lastPathComponent,
                characterName: boundCharacterName,
                datasetId: selectedDatasetId
            )
            lastPublishedAdapterPath = result.directoryURL.path
            foundationAdapters = (try? FoundationAdapterService(libraryRoot: libraryRoot).listInstalled()) ?? []
            resultSummary = [
                "Imported Foundation adapter",
                "Id: \(result.artifactId)",
                "Path: \(result.directoryURL.path)",
                "Package: \(result.packageURL.lastPathComponent)",
                "Use Playground → Apple on-device + this adapter.",
            ].joined(separator: "\n")
            statusMessage = "Foundation adapter imported."
            OnboardingStore().markCompleted(.dryRunOrTrain)
        } catch {
            statusMessage = "Import failed"
            resultSummary = error.localizedDescription
        }
    }

    /// Dogfood stub when toolkit is not run in-app (mirrors BAM_LORA_FAKE for open path).
    func publishAppleAdapterStub() {
        guard canPublishAppleStub else {
            resultSummary = "Apple Foundation adapter path is disabled (ff.foundationModels)."
            return
        }
        isRunning = true
        defer { isRunning = false }
        do {
            let name = boundCharacterName.map { "\($0) (stub)" } ?? "Foundation adapter (stub)"
            let result = try FoundationAdapterService(libraryRoot: libraryRoot).publishStub(
                displayName: name,
                characterName: boundCharacterName,
                datasetId: selectedDatasetId
            )
            lastPublishedAdapterPath = result.directoryURL.path
            foundationAdapters = (try? FoundationAdapterService(libraryRoot: libraryRoot).listInstalled()) ?? []
            resultSummary = [
                "Published Foundation adapter STUB (not a real .fmadapter)",
                "Id: \(result.artifactId)",
                "Path: \(result.directoryURL.path)",
                "Playground will load base Apple FM and note the stub was not applied.",
                "For a real specialize: Export → Apple toolkit train → Import .fmadapter.",
            ].joined(separator: "\n")
            statusMessage = "Apple adapter stub published."
            OnboardingStore().markCompleted(.dryRunOrTrain)
        } catch {
            statusMessage = "Stub publish failed"
            resultSummary = error.localizedDescription
        }
    }

    // MARK: - Shared materialize inputs

    private struct PreparedJobInputs {
        var access: ResolvedSourceAccess
        var modelURL: URL
        var modelId: String
        var sourceKey: String
        var versionId: String
    }

    private func prepareJobInputs(
        datasetId: String,
        modelPath: String,
        service: DatasetLibraryService
    ) throws -> PreparedJobInputs {
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
        } else if let key = LocalModelCapabilityProbe.sourceKey(path: modelPath) {
            modelId = modelURL.lastPathComponent
            sourceKey = key
        } else {
            modelId = modelURL.lastPathComponent
            sourceKey = localModels.first(where: { $0.localPath == modelPath })?.displayName
                ?? modelURL.lastPathComponent
        }

        return PreparedJobInputs(
            access: access,
            modelURL: modelURL,
            modelId: modelId,
            sourceKey: sourceKey,
            versionId: versionId
        )
    }
}
