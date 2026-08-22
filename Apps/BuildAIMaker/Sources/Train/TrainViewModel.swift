import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import BAMCharacterStudio
import BAMControlPlane
import BAMCore
import BAMDatasets
import BAMInference
import BAMJobs
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
    /// Last teaching attempt, in plain language (current visit or leftover).
    @Published var lastRun: TeachRunStatus?
    @Published var isRunning = false
    @Published var showAdvanced = false
    /// Dataset rows labeled with the character they belong to.
    @Published private(set) var mindPicks: [MindPick] = []
    /// Shown when stories and model belong to different characters.
    @Published private(set) var pairNote: String?
    @Published var loadError: String?
    @Published private(set) var boundCharacterName: String?
    @Published private(set) var boundCharacterId: String?
    @Published private(set) var modelCapability: LocalModelCapability = .stub(reason: "No model selected")
    @Published private(set) var lastPublishedAdapterPath: String?
    /// Cached mlx-lm / worker probe. Never call `AppJobQueueFactory.openLoRABlocker()` from SwiftUI body.
    @Published private(set) var openLoRABlockerMessage: String?
    @Published private(set) var teachingToolsChecked = false

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
        boundCharacterId = target.characterId
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
        syncModelToSelectedMind()
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
                refreshMindPicks()
                if selectedDatasetId == nil {
                    selectedDatasetId = preferredDatasetId()
                } else if let id = selectedDatasetId, !datasets.contains(where: { $0.id == id }) {
                    if !datasets.isEmpty {
                        selectedDatasetId = preferredDatasetId()
                    }
                }
            }
            localModels = try scanner.scan()
            foundationAdapters = (try? FoundationAdapterService(libraryRoot: libraryRoot).listInstalled()) ?? []
            if selectedModelPath == nil || selectedModelBelongsToOtherMind() {
                syncModelToSelectedMind()
            }
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

    /// True when open LoRA cannot update real weights (stub model, no mlx-lm, or no worker).
    var willUseFakeTrain: Bool {
        modelCapability.isStub || (teachingToolsChecked && openLoRABlockerMessage != nil)
    }

    var openLoRAStartTitle: String {
        willUseFakeTrain ? "Try a practice run" : "Start teaching"
    }

    var selectedDatasetName: String {
        mindPicks.first(where: { $0.datasetId == selectedDatasetId })?.title
            ?? datasets.first(where: { $0.id == selectedDatasetId })?.name
            ?? "None yet"
    }

    var selectedModelName: String {
        friendlyModelName(path: selectedModelPath)
    }

    func friendlyModelName(path: String?) -> String {
        guard let path, !path.isEmpty else { return "None yet" }
        if let named = mindPicks.first(where: { $0.modelPath == path })?.modelName,
           !named.isEmpty
        {
            return named
        }
        if let scan = localModels.first(where: { $0.localPath == path }) {
            let leaf = scan.directoryName
                .replacingOccurrences(of: "mlx-community--", with: "")
                .replacingOccurrences(of: "--", with: " ")
            if scan.displayName == scan.modelType || scan.displayName.contains("_") {
                return leaf
            }
            return scan.displayName
        }
        return URL(fileURLWithPath: path).lastPathComponent
            .replacingOccurrences(of: "mlx-community--", with: "")
    }

    /// Keep the starting model on the same character as the selected stories.
    func syncModelToSelectedMind() {
        guard let id = selectedDatasetId,
              let pick = mindPicks.first(where: { $0.datasetId == id })
        else {
            pairNote = nil
            return
        }
        if let path = pick.modelPath,
           !path.isEmpty,
           path != CharacterDraft.appleFoundationPath
        {
            selectedModelPath = path
            modelCapability = LocalModelCapabilityProbe.probe(path: path)
            resolveModelSizeClass()
            recomputeHardwareFit()
        }
        if let who = pick.characterName {
            if let bound = boundCharacterName, bound != who {
                pairNote = "These stories belong to \(who). Using \(who)’s model so they stay a pair."
            } else {
                pairNote = "\(who)’s stories + \(friendlyModelName(path: selectedModelPath))"
            }
        } else {
            pairNote = "These stories aren’t tied to a character. Model left as-is."
        }
    }

    private func preferredDatasetId() -> String? {
        if let bound = boundCharacterId,
           let pick = mindPicks.first(where: { $0.characterId == bound })
        {
            return pick.datasetId
        }
        if let bound = boundCharacterName,
           let pick = mindPicks.first(where: { $0.characterName == bound })
        {
            return pick.datasetId
        }
        return mindPicks.first(where: { $0.characterName != nil })?.datasetId
            ?? datasets.first?.id
    }

    private func selectedModelBelongsToOtherMind() -> Bool {
        guard let id = selectedDatasetId,
              let pick = mindPicks.first(where: { $0.datasetId == id }),
              let path = pick.modelPath, !path.isEmpty
        else { return false }
        return selectedModelPath != path
    }

    private func refreshMindPicks() {
        let chars = (try? CharacterLibraryStore().list()) ?? []
        var picks: [MindPick] = []
        for ds in datasets {
            let owners = chars.filter { $0.datasetId == ds.id }
            if owners.isEmpty {
                picks.append(
                    MindPick(
                        datasetId: ds.id,
                        title: "\(ds.name) (not a character)",
                        characterId: nil,
                        characterName: nil,
                        modelPath: nil,
                        modelName: nil
                    )
                )
            } else {
                for owner in owners {
                    let mine = owner.id == boundCharacterId
                        || owner.displayTitle == boundCharacterName
                    let label = mine
                        ? "\(ds.name) — this character"
                        : "\(ds.name) — \(owner.displayTitle)"
                    picks.append(
                        MindPick(
                            datasetId: ds.id,
                            title: label,
                            characterId: owner.id,
                            characterName: owner.displayTitle,
                            modelPath: owner.baseModelPath,
                            modelName: owner.baseModelName
                        )
                    )
                }
            }
        }
        mindPicks = picks.sorted { a, b in
            let aMine = a.characterId == boundCharacterId
            let bMine = b.characterId == boundCharacterId
            if aMine != bMine { return aMine }
            let aChar = a.characterName != nil
            let bChar = b.characterName != nil
            if aChar != bChar { return aChar }
            return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
        }
    }

    var storiesReady: Bool { selectedDatasetId != nil && !datasets.isEmpty }
    var modelReady: Bool {
        selectedModelPath != nil && !modelCapability.isStub
    }
    var toolsReady: Bool { teachingToolsChecked && !willUseFakeTrain }
    var macReady: Bool { hardwareOK }

    /// Probe mlx-lm off the main thread. Body must not spawn `python -c import`.
    func warmupTeachingTools() async {
        let blocker = await Task.detached(priority: .userInitiated) {
            AppJobQueueFactory.openLoRABlocker()
        }.value
        openLoRABlockerMessage = blocker
        teachingToolsChecked = true
    }

    var canStartTeaching: Bool {
        canFullTrain && storiesReady && selectedModelPath != nil
    }


    var teachStarter: TeachStarter {
        TeachStarter.matching(
            epochs: epochs,
            rank: loraRank,
            maxSeqLen: maxSeqLen,
            batchSize: batchSize,
            gradAccum: gradAccum
        )
    }

    var teachCoachLine: String {
        TeachAdvice.coach(
            epochs: epochs,
            rank: loraRank,
            batchSize: batchSize
        )
    }

    func applyTeachStarter(_ starter: TeachStarter) {
        guard starter != .custom else { return }
        epochs = starter.epochs
        loraRank = starter.rank
        maxSeqLen = starter.maxSeqLen
        batchSize = starter.batchSize
        gradAccum = starter.gradAccum
        recomputeHardwareFit()
    }

    var appleStartTitle: String {

        toolkitInstalled ? "Queue Apple train" : "Start (stub)"
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
                config.extraEnvironment[RuntimePaths.EnvironmentKey.managedEnvRoot] =
                    RuntimePaths.managedEnvRoot().path

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

    /// Enqueue open LoRA or Apple adapter on the **shared** job queue (same as MCP / Jobs).
    func startQueuedTrain(via controlPlane: ControlPlaneEnvironment) {
        guard !isRunning else { return }
        if trainBackend == .appleFoundationAdapter {
            startQueuedAppleTrain(via: controlPlane)
            return
        }
        guard featureFlags.llmTraining else {
            resultSummary = "Full LoRA train is disabled (ff.llmTraining is off)."
            return
        }
        guard selectedDatasetId != nil, selectedModelPath != nil else {
            resultSummary = "Select a dataset and a local base model."
            return
        }

        isRunning = true
        resultSummary = nil
        lastPublishedAdapterPath = nil
        statusMessage = "Starting teaching…"

        Task {
            defer { isRunning = false }
            if !teachingToolsChecked {
                await warmupTeachingTools()
            }
            recomputeHardwareFit()
            guard hardwareOK else {
                resultSummary = hardwareMessage
                statusMessage = "This Mac may be too small for this starting model."
                return
            }
            let fake = willUseFakeTrain
            statusMessage = fake
                ? "Starting a practice run (won’t really change the character)…"
                : "Starting teaching…"
            await enqueueAndWatch(
                via: controlPlane,
                recipe: "mlx_lora",
                fakeNote: fake
                    ? "Open LoRA runner is fake until mlx-lm + worker are available."
                    : "Queued on the same Jobs list as MCP finetune.start."
            )
        }
    }

    func startQueuedAppleTrain(via controlPlane: ControlPlaneEnvironment) {
        guard !isRunning else { return }
        guard featureFlags.foundationModels else {
            resultSummary = "ff.foundationModels is off."
            return
        }
        guard selectedDatasetId != nil else {
            resultSummary = "Select a text dataset (character mind) first."
            return
        }
        isRunning = true
        resultSummary = nil
        lastPublishedAdapterPath = nil
        refreshToolkitProbe()
        let stub = !toolkitInstalled
        statusMessage = stub
            ? "Queuing Apple adapter (stub — no toolkit)…"
            : "Queuing Apple adapter train…"

        Task {
            defer { isRunning = false }
            await enqueueAndWatch(
                via: controlPlane,
                recipe: "apple_adapter",
                fakeNote: stub
                    ? "No Adapter Training Toolkit — queue uses a stub adapter runner."
                    : "Queued Apple adapter job (same queue as MCP)."
            )
        }
    }

    private func enqueueAndWatch(
        via controlPlane: ControlPlaneEnvironment,
        recipe: String,
        fakeNote: String
    ) async {
        let outcome: ActionOutcome
        if let characterId = boundCharacterId {
            outcome = await controlPlane.invoke(
                FinetuneStartHandler.id,
                params: .object([
                    "characterId": .string(characterId),
                    "recipe": .string(recipe),
                    "datasetId": selectedDatasetId.map { .string($0) } ?? .null,
                    "baseModelPath": selectedModelPath.map { .string($0) } ?? .null,
                ])
            )
        } else {
            outcome = await enqueueLabJob(recipe: recipe, via: controlPlane)
        }

        guard outcome.ok, let jobId = outcome.jobId ?? outcome.data?["jobId"]?.stringValue else {
            statusMessage = "Queue failed"
            resultSummary = outcome.error?.message ?? "Unknown enqueue error"
            return
        }

        lastRun = TeachRunStatus.working(jobId: jobId, recipe: recipe)
        statusMessage = "Teaching is running. You can watch progress here or under Jobs."
        var lastStatus = "queued"
        for _ in 0..<600 {
            let poll = await controlPlane.invoke(
                JobGetHandler.id,
                params: .object(["jobId": .string(jobId)])
            )
            let st = poll.data?["status"]?.stringValue ?? lastStatus
            lastStatus = st
            let err = poll.data?["errorMessage"]?.stringValue
            let errCode = poll.data?["errorCode"]?.stringValue
            let updated = poll.data?["updatedAt"]?.stringValue
            lastRun = TeachRunStatus.fromPoll(
                jobId: jobId,
                status: st,
                errorCode: errCode,
                errorMessage: err,
                updatedAt: updated,
                recipe: recipe,
                fakeNote: fakeNote,
                fromThisVisit: true
            )
            resultSummary = lastRun?.rawDetail
            if ["succeeded", "failed", "cancelled", "interrupted"].contains(st) {
                statusMessage = lastRun?.headline
                if st == "succeeded" {
                    OnboardingStore().markCompleted(.dryRunOrTrain)
                    MVPMetricsStore.shared.increment(.trainCompleted)
                    publishAdapterIfReal(jobId: jobId)
                    lastRun = TeachRunStatus.fromPoll(
                        jobId: jobId,
                        status: st,
                        errorCode: errCode,
                        errorMessage: err,
                        updatedAt: updated,
                        recipe: recipe,
                        fakeNote: fakeNote,
                        fromThisVisit: true
                    )
                }
                return
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        statusMessage = "Still running — open Jobs if you want the live log."
    }

    /// Copy a real job adapter into models/adapters and pin it on the character.
    func publishAdapterIfReal(jobId: String) {
        let paths = JobPathsFactory.make(jobId: jobId)
        let weights = URL(fileURLWithPath: paths.outputPath)
            .appendingPathComponent("adapter/adapters.safetensors")
        let size = (try? FileManager.default.attributesOfItem(atPath: weights.path)[.size] as? NSNumber)?
            .intValue ?? 0
        guard size >= 50_000 else { return }
        let specURL = JobPathsFactory.jobJSONURL(paths: paths)
        guard let data = try? Data(contentsOf: specURL),
              let spec = try? JSONDecoder().decode(JobSpec.self, from: data)
        else { return }
        do {
            let published = try AdapterArtifactWriter().publishToLibrary(
                paths: paths,
                spec: spec,
                fakeTrain: false
            )
            lastPublishedAdapterPath = published.adapterDirectory.path
            if let characterId = boundCharacterId,
               var draft = try? CharacterLibraryStore().load(id: characterId)
            {
                draft.adapterId = published.artifactId
                draft.adapterPath = published.adapterDirectory.path
                draft.adapterName = "\(draft.displayTitle) teach"
                try? CharacterLibraryStore().save(draft)
            }
        } catch {
            // Non-fatal: job folder still has the weights.
        }
    }

    /// Show the latest saved job so leftover failures are labeled, not mistaken for now.
    func loadLeftoverRun(via controlPlane: ControlPlaneEnvironment) async {
        if lastRun?.isFromThisVisit == true { return }
        let jobs = (try? await controlPlane.jobQueue.listJobs()) ?? []
        guard let job = jobs
            .filter({ $0.modality == .llm || $0.modality == .foundationAdapter })
            .max(by: { $0.updatedAt < $1.updatedAt })
        else { return }
        lastRun = TeachRunStatus.from(job: job, fromThisVisit: false)
        statusMessage = lastRun?.headline
        resultSummary = lastRun?.rawDetail
        // Do not re-copy adapters on every Teach visit. mlx-lm leaves ~16
        // checkpoint files in the job folder; copying them blocked Refresh
        // and Start teaching. Pin happens when a job we started this visit succeeds.
    }

    /// Lab Train without a bound character: same shared queue, no Action API character id.
    private func enqueueLabJob(recipe: String, via controlPlane: ControlPlaneEnvironment) async -> ActionOutcome {
        let ctx = ActionContext(source: .ui)
        guard let datasetId = selectedDatasetId else {
            return .failure(.validationError, message: "No dataset", context: ctx)
        }
        do {
            let datasets = try DatasetLibraryService.openDefault()
            guard let dataset = try datasets.dataset(id: datasetId),
                  let version = try datasets.latestVersion(datasetId: datasetId)
            else {
                return .failure(.notFound, message: "Dataset missing", context: ctx)
            }
            let access = try datasets.resolveSourceAccess(for: dataset)
            defer { access.stop() }
            let jobId = BAMID.generate()
            let spec: JobSpec
            let paths: JobPaths
            if recipe == "apple_adapter" {
                spec = .foundationAdapter(id: jobId, datasetVersionId: version.id)
                paths = JobPathsFactory.make(
                    jobId: jobId,
                    libraryRoot: libraryRoot,
                    datasetPath: access.url.path
                )
            } else {
                guard let modelPath = selectedModelPath else {
                    return .failure(.validationError, message: "No model", context: ctx)
                }
                spec = .llm(
                    id: jobId,
                    baseModelId: URL(fileURLWithPath: modelPath).lastPathComponent,
                    baseModelSourceKey: modelPath,
                    datasetVersionId: version.id,
                    hyperparameters: currentHyperparameters
                )
                paths = JobPathsFactory.make(
                    jobId: jobId,
                    libraryRoot: libraryRoot,
                    datasetPath: access.url.path,
                    baseModelPath: modelPath
                )
            }
            let rec = try await controlPlane.jobQueue.enqueue(spec: spec, paths: paths)
            return .success(
                data: .object(["jobId": .string(rec.id), "status": .string(rec.status.rawValue)]),
                jobId: rec.id,
                context: ctx
            )
        } catch {
            return .failure(.internalError, message: error.localizedDescription, context: ctx)
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

/// A mind dataset plus the character / model it belongs to.
struct MindPick: Equatable, Identifiable {
    var id: String { datasetId + (characterId ?? "") }
    var datasetId: String
    var title: String
    var characterId: String?
    var characterName: String?
    var modelPath: String?
    var modelName: String?
}

/// One teaching attempt, written for someone who has never fine-tuned.
struct TeachRunStatus: Equatable {
    enum Phase: String, Equatable {
        case working
        case succeeded
        case failed
        case cancelled
    }

    var phase: Phase
    var isFromThisVisit: Bool
    var headline: String
    var explanation: String
    var nextStep: String
    var whenLabel: String
    var jobId: String?
    var rawDetail: String?

    static func working(jobId: String, recipe: String) -> TeachRunStatus {
        TeachRunStatus(
            phase: .working,
            isFromThisVisit: true,
            headline: "Teaching is running…",
            explanation: "BuildAIMaker is reading the stories and updating the character. This can take a while — leave the app open.",
            nextStep: "You can keep this page open, or check Jobs for the live log.",
            whenLabel: "Started just now",
            jobId: jobId,
            rawDetail: "job \(jobId)\nrecipe \(recipe)"
        )
    }

    static func from(job: JobRecord, fromThisVisit: Bool) -> TeachRunStatus {
        fromPoll(
            jobId: job.id,
            status: job.status.rawValue,
            errorCode: job.errorCode,
            errorMessage: job.errorMessage,
            updatedAt: job.updatedAt,
            recipe: nil,
            fakeNote: nil,
            fromThisVisit: fromThisVisit
        )
    }

    static func fromPoll(
        jobId: String,
        status: String,
        errorCode: String?,
        errorMessage: String?,
        updatedAt: String?,
        recipe: String?,
        fakeNote: String?,
        fromThisVisit: Bool
    ) -> TeachRunStatus {
        let phase: Phase
        switch status {
        case "succeeded": phase = .succeeded
        case "failed": phase = .failed
        case "cancelled", "interrupted": phase = .cancelled
        default: phase = .working
        }
        let when = whenLabel(updatedAt: updatedAt, fromThisVisit: fromThisVisit)
        let human = humanize(errorCode: errorCode, errorMessage: errorMessage)
        let headline: String
        let explanation: String
        let nextStep: String
        switch phase {
        case .working:
            headline = fromThisVisit ? "Teaching is running…" : "A teaching job is still running"
            explanation = "This is the current job, not an old leftover."
            nextStep = "Leave the app open. Open Jobs if you want the live log."
        case .succeeded:
            let note = Self.successHonesty(jobId: jobId)
            headline = fromThisVisit ? "Teaching finished" : "Last teaching run succeeded"
            explanation = note.explanation
            nextStep = note.nextStep
        case .failed:
            headline = fromThisVisit ? "Teaching didn’t finish" : "Last teaching attempt failed — leftover, not running now"
            explanation = human.explanation
            nextStep = human.nextStep
        case .cancelled:
            let hung = (errorCode ?? "").contains("HUNG")
                || (errorMessage ?? "").localizedCaseInsensitiveContains("heartbeat")
            if hung {
                headline = fromThisVisit
                    ? "Teaching was still loading the model"
                    : "Last attempt was cut off while the model loaded"
                explanation = human.explanation
                nextStep = human.nextStep
            } else {
                headline = fromThisVisit ? "Teaching was stopped" : "Last teaching attempt was stopped"
                explanation = "The job did not finish."
                nextStep = "Press Start teaching when you want to try again."
            }
        }
        var raw: [String] = ["job \(jobId)", "status \(status)"]
        if let recipe { raw.append("recipe \(recipe)") }
        if let errorCode { raw.append("code \(errorCode)") }
        if let errorMessage { raw.append(errorMessage) }
        if let fakeNote { raw.append(fakeNote) }
        return TeachRunStatus(
            phase: phase,
            isFromThisVisit: fromThisVisit,
            headline: headline,
            explanation: explanation,
            nextStep: nextStep,
            whenLabel: when,
            jobId: jobId,
            rawDetail: raw.joined(separator: "\n")
        )
    }

    private static func whenLabel(updatedAt: String?, fromThisVisit: Bool) -> String {
        if fromThisVisit { return "From this visit" }
        guard let raw = updatedAt, let date = JobTimestamps.parse(raw) else {
            return "From an earlier visit"
        }
        let mins = Int(Date().timeIntervalSince(date) / 60)
        if mins < 1 { return "Updated just now (saved job)" }
        if mins < 60 { return "Updated \(mins) min ago — leftover, not running now" }
        let hours = mins / 60
        if hours < 24 { return "Updated \(hours)h ago — leftover, not running now" }
        return "From an earlier day — leftover, not running now"
    }

    private static func successHonesty(jobId: String) -> (explanation: String, nextStep: String) {
        let paths = JobPathsFactory.make(jobId: jobId)
        let weights = URL(fileURLWithPath: paths.outputPath)
            .appendingPathComponent("adapter/adapters.safetensors")
        let size = (try? FileManager.default.attributesOfItem(atPath: weights.path)[.size] as? NSNumber)?
            .int64Value ?? 0
        let mb = Double(size) / 1_000_000
        if size < 50_000 {
            return (
                "The job was marked done, but no real adapter file was saved. Playground will not sound different.",
                "Press Start teaching again for a real pass."
            )
        }
        var start: Date?
        var end: Date?
        if let specData = try? Data(contentsOf: JobPathsFactory.jobJSONURL(paths: paths)),
           let spec = try? JSONDecoder().decode(JobSpec.self, from: specData)
        {
            _ = spec
        }
        let hb = JobPathsFactory.heartbeatURL(paths: paths)
        // Duration from job folder timestamps
        if let created = (try? FileManager.default.attributesOfItem(atPath: JobPathsFactory.jobJSONURL(paths: paths).path)[.creationDate] as? Date) {
            start = created
        }
        if let modified = (try? FileManager.default.attributesOfItem(atPath: weights.path)[.modificationDate] as? Date) {
            end = modified
        }
        let secs = (start != nil && end != nil) ? end!.timeIntervalSince(start!) : 0
        if secs > 0, secs < 90 {
            return (
                "A real adapter was saved (about \(String(format: "%.0f", mb)) MB) after a short first pass (\(Int(secs))s). That is a few training steps, not a long fine-tune. Playground can use it; a longer teach will learn more.",
                "Open Playground and pick this character, or Start teaching again for a fuller pass."
            )
        }
        return (
            "A real adapter was saved (about \(String(format: "%.0f", mb)) MB). Try them in Playground.",
            "Open Playground and pick this character."
        )
    }

    private static func humanize(errorCode: String?, errorMessage: String?) -> (explanation: String, nextStep: String) {
        let blob = "\(errorCode ?? "") \(errorMessage ?? "")"
        if blob.contains("PATH_ESCAPE") || blob.contains("path escape") || blob.contains("bin/python3") {
            return (
                "Teaching stopped before it learned anything. The tools treated the Python shortcut in Settings as unsafe. That is a setup bug, not something you did wrong.",
                "Try Start teaching again. If it fails, open Settings and tap Repair."
            )
        }
        if blob.contains("call prepare first") || blob.contains("No supervisor") {
            return (
                "Teaching stopped on a wiring bug: the helper was started twice. That is fixed in this build — try Start teaching again.",
                "Press Start teaching once more."
            )
        }
        if blob.contains("MODEL_WEIGHTS")
            || blob.contains("vision_embedder")
            || blob.contains("parameters not in model")
        {
            return (
                "Teaching loaded Gemma 4, then stopped: the file also has picture weights the text trainer doesn’t use. The next try skips those.",
                "Press Start teaching again. You do not need Settings → Repair."
            )
        }
        if blob.contains("MODEL_UNSUPPORTED")
            || blob.contains("not supported")
            || blob.contains("isn't supported")
            || blob.contains("isn’t supported")
            || blob.contains("gemma4_unified")
            || blob.contains("Gemma 4 unified")
        {
            return (
                "Teaching reached the model, then stopped: Gemma 4’s newer layout wasn’t wired into the trainer. That’s a software fix, not Settings.",
                "Press Start teaching again on this build."
            )
        }
        if blob.contains("DATASET_INVALID") || blob.contains("Training set not found") {
            return (
                "The stories file wasn’t in the layout teaching expects.",
                "Try again — this build copies stories into the right files first."
            )
        }
        if blob.contains("helper binary not found") || blob.contains("No worker binary found") {
            return (
                "BuildAIMaker couldn’t find its teaching helper next to the app.",
                "Quit the app and open it again, then retry."
            )
        }
        if blob.contains("No module named 'mlx_lm'") || blob.contains("mlx-lm is not") {
            return (
                "The teaching software isn’t installed yet.",
                "Open Settings → Training runtime and tap Repair, then come back here."
            )
        }
        if blob.contains("HUNG") || blob.localizedCaseInsensitiveContains("heartbeat") {
            return (
                "The starting model was still loading when the app decided the job had frozen. That is a timeout, not you pressing Stop.",
                "Press Start teaching again. This build keeps sending “still working” while Gemma 4 loads."
            )
        }
        if blob.contains("WORKER_CRASH") || blob.contains("exited before hello") {
            return (
                "The teaching helper started, then quit before it could learn.",
                "Try again. If it fails, open Jobs and check the log."
            )
        }
        if let errorMessage, !errorMessage.isEmpty {
            return (
                "Teaching stopped: \(errorMessage)",
                "You can try again, or open Jobs for the full log."
            )
        }
        return (
            "Teaching stopped before it finished.",
            "Try again, or open Jobs to see the log."
        )
    }
}

enum TeachStarter: String, CaseIterable, Identifiable, Equatable {
    case firstTry
    case learnMore
    case biggerChange
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .firstTry: return "First try"
        case .learnMore: return "Learn more"
        case .biggerChange: return "Bigger change"
        case .custom: return "Custom"
        }
    }

    var epochs: Int {
        switch self {
        case .learnMore: return 3
        default: return 1
        }
    }

    var rank: Int {
        switch self {
        case .biggerChange: return 32
        default: return 16
        }
    }

    var maxSeqLen: Int { 2048 }
    var batchSize: Int { 1 }
    var gradAccum: Int { 4 }

    static func matching(
        epochs: Int,
        rank: Int,
        maxSeqLen: Int,
        batchSize: Int,
        gradAccum: Int
    ) -> TeachStarter {
        for starter in [TeachStarter.firstTry, .learnMore, .biggerChange] {
            if epochs == starter.epochs,
               rank == starter.rank,
               maxSeqLen == starter.maxSeqLen,
               batchSize == starter.batchSize,
               gradAccum == starter.gradAccum
            {
                return starter
            }
        }
        return .custom
    }
}

enum TeachAdvice {
    static func epochs(_ value: Int) -> String {
        switch value {
        case 1:
            return "Best first setting. One pass over the stories. Fast enough to see if teaching works."
        case 2, 3:
            return "They’ll practice the same stories a few times. Use this if the first try still sounds generic."
        default:
            return "Lots of rereads can make them parrot the stories and take much longer. Try 1–3 first."
        }
    }

    static func changeAmount(_ rank: Int) -> String {
        if rank <= 8 {
            return "A light touch. Good if you only want a hint of their voice."
        }
        if rank <= 16 {
            return "Good default. Enough room to pick up phrasing without needing a huge Mac."
        }
        if rank <= 32 {
            return "A bigger rewrite. Use if they still sound like the starting model. Uses more memory."
        }
        return "A very big rewrite. Easy to overfit or run out of memory. Only if 16–32 was too timid."
    }

    static func snippet(_ len: Int) -> String {
        if len <= 1024 {
            return "Short memories. Faster, but they may forget the start of a long speech."
        }
        if len <= 2048 {
            return "Default. Fits most story turns. Raise only if lines are long."
        }
        return "Long memories. Needed for big speeches; slower and hungrier."
    }

    static func batch(_ n: Int) -> String {
        if n == 1 {
            return "One example at a time. Safest on a laptop. Keep this unless teaching is stable and you want speed."
        }
        return "Several examples at once. Faster, but needs more memory. If the Mac complains, go back to 1."
    }

    static func careful(_ n: Int) -> String {
        if n <= 2 {
            return "Bigger steps. Quicker, a bit rougher."
        }
        if n <= 4 {
            return "Default. Smooth enough for a first teach."
        }
        return "Tiny careful steps. Slower. Use if teaching looks unstable."
    }

    static func coach(epochs: Int, rank: Int, batchSize: Int) -> String {
        if epochs == 1 && rank <= 16 && batchSize == 1 {
            return "You’re set for a first try: one reread, a moderate change. Expect minutes, not hours. If they still sound generic, tap Learn more."
        }
        if epochs >= 3 && rank <= 16 {
            return "They’ll reread the stories a few times. Plan on a longer wait. If they start repeating lines, go back to one reread."
        }
        if rank >= 32 {
            return "This is a bigger rewrite. Watch memory on the checklist. If teaching fails or the Mac gets hot, drop “how much they can change” to 16."
        }
        return "Custom mix. Change one knob, teach, then listen in Playground before changing another."
    }
}
