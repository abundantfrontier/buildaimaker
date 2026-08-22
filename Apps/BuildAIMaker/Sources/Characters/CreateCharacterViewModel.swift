import AVFoundation
import BAMAudioFX
import BAMCharacterStudio
import BAMControlPlane
import BAMCore
import BAMDatasets
import BAMInference
import BAMModelCatalog
import BAMModels
import BAMPersistence
import Foundation
import SwiftUI

/// One installed base model the character wizard can bind to.
struct WizardInstalledModel: Identifiable, Equatable, Hashable {
    var id: String { localPath }
    var localPath: String
    var directoryName: String
    var name: String
    var sourceKey: String?
    var isFixture: Bool
    var isDogfoodStub: Bool
    /// Apple on-device Foundation Model (system, not under models/base).
    var isAppleFoundation: Bool

    var subtitle: String {
        if isAppleFoundation {
            return "SystemLanguageModel · chat default on this Mac (no download)"
        }
        if let sourceKey, !sourceKey.isEmpty { return sourceKey }
        return localPath
    }

    var badge: String? {
        if isAppleFoundation { return "Apple" }
        if isFixture { return "Fixture" }
        if isDogfoodStub { return "Stub" }
        return nil
    }

    static func appleFoundation() -> WizardInstalledModel {
        WizardInstalledModel(
            localPath: CharacterDraft.appleFoundationPath,
            directoryName: "apple-foundation",
            name: CharacterDraft.appleFoundationDisplayName,
            sourceKey: CharacterDraft.appleFoundationSourceKey,
            isFixture: false,
            isDogfoodStub: false,
            isAppleFoundation: true
        )
    }
}

/// Whether library models are available for character selection.
enum WizardModelStatus: Equatable {
    case noneInstalled
    case ready(count: Int)

    var title: String {
        switch self {
        case .noneInstalled: return "No models available yet"
        case .ready(let n): return "\(n) model\(n == 1 ? "" : "s") available"
        }
    }

    var detail: String {
        switch self {
        case .noneInstalled:
            return "Apple on-device model is not ready, and no open models are installed. Enable Apple Intelligence or install a catalog model."
        case .ready:
            return "Pick Apple on-device (chat) and/or an open MLX model for later train. You can install more anytime."
        }
    }

    var symbol: String {
        switch self {
        case .noneInstalled: return "cpu"
        case .ready: return "checkmark.circle"
        }
    }

    var hasModels: Bool {
        if case .ready = self { return true }
        return false
    }
}

@MainActor
final class CreateCharacterViewModel: ObservableObject {
    enum Step: Int, CaseIterable, Identifiable {
        case meet = 0
        case model = 1
        case mind = 2
        case voice = 3
        case done = 4

        var id: Int { rawValue }

        static var userSteps: [Step] { [.meet, .model, .mind, .voice] }

        var shortTitle: String {
            switch self {
            case .meet: return "Name"
            case .model: return "Model"
            case .mind: return "Story"
            case .voice: return "Voice"
            case .done: return "Done"
            }
        }

        var title: String { shortTitle }

        /// Shown in the “What to do now” banner.
        var instruction: String {
            switch self {
            case .meet:
                return "Type a name and pick a creature type, then press Continue."
            case .model:
                return "Select Apple’s on-device model (if ready) or an open MLX model for this character."
            case .mind:
                return "Paste a story, then Build how they talk — this creates training text for the model you picked."
            case .voice:
                return "Pick a voice preset, then Hear their voice — system TTS speaks a short line, then creature FX."
            case .done:
                return "Character saved with a selected model. Open Playground or Train next."
            }
        }
    }

    @Published var step: Step = .meet
    @Published var draft = CharacterDraft()
    @Published var statusMessage: String?
    @Published var isWorking = false
    @Published var lastError: String?
    @Published var isPlayingPreview = false
    @Published var modelStatus: WizardModelStatus = .noneInstalled
    @Published var installedModels: [WizardInstalledModel] = []
    @Published var catalogEntries: [CatalogEntry] = []
    /// sourceKey currently being installed (disables that row’s button).
    @Published var installingSourceKey: String?
    @Published var isInstallingFixture = false

    private let store = CharacterLibraryStore()
    private let corpus = CorpusBuilder()
    private var audioPlayer: AVAudioPlayer?
    /// Clears `isPlayingPreview` when the clip finishes (no AVAudioPlayerDelegate needed).
    private var previewEndTask: Task<Void, Never>?
    /// True after the first intentional load; blocks accidental save of an empty draft.
    private var didLoadOnce = false
    /// When true, skip auto-persist during programmatic load/select.
    private var suppressPersist = false
    /// Shared Action API — mind writes go through `character.importMind`.
    private weak var controlPlane: ControlPlaneEnvironment?

    func attachControlPlane(_ plane: ControlPlaneEnvironment) {
        controlPlane = plane
    }

    /// When true, user is re-editing a previously finished character.
    @Published private(set) var isEditingComplete: Bool = false

    init(initialDraft: CharacterDraft? = nil) {
        if let existing = initialDraft {
            self.draft = existing
            self.applyLoadedDraft(existing, preferEdit: existing.isComplete)
            self.didLoadOnce = true
        }
    }

    /// Load an existing draft to resume (or start fresh if nil).
    ///
    /// Finished characters open in **edit** mode (content steps), not stuck on Done.
    func load(draft existing: CharacterDraft?) {
        suppressPersist = true
        defer {
            suppressPersist = false
            didLoadOnce = true
        }
        if let existing {
            draft = existing
            applyLoadedDraft(existing, preferEdit: existing.isComplete)
        } else if !didLoadOnce {
            // Only allocate a brand-new draft on first open of a Create session.
            draft = CharacterDraft()
            step = .meet
            isEditingComplete = false
            statusMessage = nil
        }
        lastError = nil
        stopPreview(clearStatus: false)
        refreshModels()
    }

    private func applyLoadedDraft(_ existing: CharacterDraft, preferEdit: Bool) {
        if preferEdit, existing.isComplete {
            // Re-open the wizard for edits — clear complete so Save can re-finish.
            isEditingComplete = true
            draft.isComplete = false
            let raw = existing.editStepRaw
            step = Step(rawValue: min(max(raw, 0), 3)) ?? .meet
            statusMessage =
                "Editing “\(existing.displayTitle)” — use Back / Continue to change any step, then Finish & save."
        } else {
            isEditingComplete = false
            let raw = existing.resumeStepRaw
            step = Step(rawValue: min(raw, 3)) ?? .meet
            if existing.isComplete {
                step = .done
            }
            statusMessage = existing.isComplete
                ? nil
                : "Resumed — \(existing.progressLabel). Continue with the green button."
        }
    }

    /// Jump back into content steps from the Done screen (or force full re-edit).
    func beginEditing(from stepTarget: Step = .meet) {
        isEditingComplete = true
        draft.isComplete = false
        step = stepTarget == .done ? .meet : stepTarget
        statusMessage = "Editing “\(draft.displayTitle)” — Finish & save when you’re done."
        persistDraft()
    }

    /// Persist current wizard state so Cancel / crash / leave path can resume.
    @discardableResult
    func persistDraft(markComplete: Bool = false) -> Bool {
        guard didLoadOnce, !suppressPersist else { return false }
        // Never write a nameless new shell that was never intentional (defense in depth).
        let named = !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if !named, !draft.hasSelectedBaseModel, draft.examples.isEmpty, !markComplete {
            return false
        }
        draft.wizardStepRaw = step.rawValue
        if markComplete {
            draft.isComplete = true
            draft.wizardStepRaw = Step.done.rawValue
        }
        do {
            try store.save(draft)
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    var canGoNextFromMeet: Bool {
        !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var canGoNextFromModel: Bool {
        draft.hasSelectedBaseModel
    }

    var canBuildMind: Bool {
        !draft.storyPaste.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var mindBuilt: Bool { !draft.examples.isEmpty }
    var voiceReady: Bool { draft.previewAudioPath != nil }

    var primaryActionTitle: String {
        switch step {
        case .meet: return "Continue → Model"
        case .model: return "Continue → Story"
        case .mind:
            return mindBuilt ? "Continue → Voice" : "Build how they talk"
        case .voice:
            if voiceReady {
                return isEditingComplete ? "Save changes" : "Finish & save"
            }
            return "Hear their voice"
        case .done: return "Close"
        }
    }

    var primaryActionHint: String {
        switch step {
        case .meet:
            return canGoNextFromMeet ? "Next: pick a base model" : "Enter a name first"
        case .model:
            return canGoNextFromModel
                ? "Model set — continue to story"
                : "Install and select a model first"
        case .mind:
            return mindBuilt
                ? "Story is ready — continue to voice"
                : "Builds practice dialogues from your paste"
        case .voice:
            return voiceReady
                ? (isEditingComplete ? "Updates the saved character" : "Saves the character to your library")
                : "Speaks a short line (system TTS) + creature FX"
        case .done:
            return "Use the footer to edit, open Playground, or close"
        }
    }

    var primaryActionEnabled: Bool {
        switch step {
        case .meet: return canGoNextFromMeet
        case .model: return canGoNextFromModel
        case .mind: return canBuildMind || mindBuilt
        case .voice: return true
        case .done: return true
        }
    }

    func performPrimaryAction() {
        lastError = nil
        switch step {
        case .meet:
            guard canGoNextFromMeet else { return }
            step = .model
            persistDraft()
        case .model:
            guard canGoNextFromModel else { return }
            step = .mind
            persistDraft()
        case .mind:
            if mindBuilt {
                step = .voice
                persistDraft()
            } else {
                Task { await buildMindAndImport() }
            }
        case .voice:
            if voiceReady {
                Task { await saveCharacter() }
            } else {
                renderVoicePreview()
            }
        case .done:
            break
        }
    }

    func goBack() {
        if step == .done {
            beginEditing(from: .voice)
            return
        }
        guard let prev = Step(rawValue: step.rawValue - 1) else { return }
        step = prev
        statusMessage = nil
        lastError = nil
        persistDraft()
    }

    func resetForAnother() {
        draft = CharacterDraft()
        step = .meet
        isEditingComplete = false
        statusMessage = nil
        lastError = nil
        stopPreview(clearStatus: false)
        refreshModels()
    }

    /// Call when user dismisses the sheet without finishing — keeps draft for Continue.
    func saveAndExit() {
        if step != .done {
            draft.isComplete = false
            persistDraft()
            statusMessage = "Progress saved. Open this character again to continue."
        }
    }

    /// Refresh catalog + installed models under models/base, plus Apple FM when ready.
    func refreshModels() {
        if let catalog = try? ModelCatalog.loadBundled() {
            catalogEntries = catalog.entries
        } else {
            catalogEntries = []
        }

        var rows: [WizardInstalledModel] = []

        // Prefer Apple on-device model first when SystemLanguageModel is available.
        let appleStatus = AppleFoundationModelSupport.probeStatus()
        if appleStatus.isUsable {
            rows.append(.appleFoundation())
        }

        let scanned = (try? LocalModelScanner().scan()) ?? []
        rows.append(contentsOf: scanned.map { scan in
            let meta = ModelInstallService.installMetadata(
                at: URL(fileURLWithPath: scan.localPath)
            )
            let isFixture = scan.directoryName == FixtureModel.installDirectoryName
                || meta?.sourceKey == FixtureModel.sourceKey
            let name = meta?.name
                ?? (isFixture ? FixtureModel.displayName : scan.displayName)
            return WizardInstalledModel(
                localPath: scan.localPath,
                directoryName: scan.directoryName,
                name: name,
                sourceKey: meta?.sourceKey,
                isFixture: isFixture,
                isDogfoodStub: meta?.dogfoodStub ?? false,
                isAppleFoundation: false
            )
        })

        installedModels = rows

        if installedModels.isEmpty {
            modelStatus = .noneInstalled
        } else {
            modelStatus = .ready(count: installedModels.count)
        }

        // Drop selection if path vanished (except keep Apple selection if still usable).
        if let path = draft.baseModelPath,
           !installedModels.contains(where: { $0.localPath == path })
        {
            if draft.usesAppleFoundationModel, appleStatus.isUsable {
                selectModel(.appleFoundation())
            } else if !installedModels.isEmpty {
                draft.baseModelPath = nil
                draft.baseModelId = nil
            }
        }

        // Auto-select Apple when available, else sole local model.
        if !draft.hasSelectedBaseModel {
            if let apple = installedModels.first(where: \.isAppleFoundation) {
                selectModel(apple)
            } else if installedModels.count == 1 {
                selectModel(installedModels[0])
            }
        }
    }

    func selectModel(_ model: WizardInstalledModel) {
        draft.baseModelPath = model.localPath
        draft.baseModelName = model.name
        draft.baseModelSourceKey = model.sourceKey
        draft.baseModelId = model.directoryName
        if model.isAppleFoundation {
            statusMessage = "Using Apple on-device model for chat. Open MLX models below are optional for fine-tune later."
        } else {
            statusMessage = "Using \(model.name) for this character."
        }
        if didLoadOnce, !suppressPersist {
            persistDraft()
        }
    }

    func isSelected(_ model: WizardInstalledModel) -> Bool {
        draft.baseModelPath == model.localPath
    }

    /// Install a catalog row (fixture or offline dogfood stub). Multiple installs allowed.
    func installCatalogEntry(_ entry: CatalogEntry) {
        installingSourceKey = entry.sourceKey
        isInstallingFixture = entry.isFixture || entry.sourceKey == FixtureModel.sourceKey
        lastError = nil
        defer {
            installingSourceKey = nil
            isInstallingFixture = false
        }
        do {
            let result = try ModelInstallService().installCatalogEntry(entry, overwrite: true)
            if entry.isFixture || entry.sourceKey == FixtureModel.sourceKey {
                OnboardingStore().markCompleted(.installFixture)
            }
            refreshModels()
            // Select the model just installed.
            if let match = installedModels.first(where: { $0.localPath == result.modelRecord.localPath }) {
                selectModel(match)
            } else if let match = installedModels.first(where: { $0.sourceKey == entry.sourceKey }) {
                selectModel(match)
            }
            let kind = entry.isFixture ? "Fixture" : (FeatureFlags.default.hfHubDownload ? "Model" : "Stub model")
            statusMessage = "\(kind) installed: \(entry.name). Selected for this character."
        } catch {
            lastError = (error as? BAMError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Convenience: install the offline fixture (same as catalog fixture row).
    func installFixtureForLater() {
        let entry = catalogEntries.first(where: { $0.isFixture })
            ?? CatalogEntry(
                sourceKey: FixtureModel.sourceKey,
                name: FixtureModel.displayName,
                archFamily: FixtureModel.archFamily,
                paramCountB: 0.001,
                quantBits: 16,
                minRamGB: 8,
                chatTemplateId: "qwen2.5-instruct",
                license: FixtureModel.license,
                format: "mlx",
                isFixture: true
            )
        installCatalogEntry(entry)
    }

    func isCatalogEntryInstalled(_ entry: CatalogEntry) -> Bool {
        ModelInstallService().isInstalled(entry)
            || installedModels.contains { $0.sourceKey == entry.sourceKey }
    }

    func applySpeciesPreset(_ preset: CreatureSpeciesPreset) {
        draft.speciesPreset = preset
        if preset != .custom {
            draft.vibe = preset.suggestedVibe
            draft.voicePreset = preset.voicePresetRawValue
            if let vp = CreatureVoicePreset(rawValue: preset.voicePresetRawValue) {
                applyVoicePreset(vp)
            }
        }
    }

    /// Build practice lines and write the mind dataset via `character.importMind`.
    func buildMindAndImport() async {
        guard !isWorking else { return }
        isWorking = true
        lastError = nil
        defer { isWorking = false }

        let jsonl = buildMindCorpus()
        guard persistDraft() else { return }
        await importMindDataset(jsonl: jsonl)
    }

    func riffMore() {
        Task { await riffMoreAndImport() }
    }

    func riffMoreAndImport() async {
        guard !isWorking else { return }
        isWorking = true
        lastError = nil
        defer { isWorking = false }

        if draft.bible == nil || draft.examples.isEmpty {
            let jsonl = buildMindCorpus()
            guard persistDraft() else { return }
            await importMindDataset(jsonl: jsonl)
            return
        }
        guard let bible = draft.bible else { return }
        let jsonl = encodeCurrentJSONL()
        let current = CorpusBuildResult(bible: bible, examples: draft.examples, jsonl: jsonl)
        let next = corpus.riff(result: current, extra: 3)
        draft.examples = next.examples
        draft.bible = next.bible
        statusMessage = "Riffed +3 lines (now \(next.rowCount))."
        guard persistDraft() else { return }
        await importMindDataset(jsonl: next.jsonl.isEmpty ? encodeCurrentJSONL() : next.jsonl)
    }

    /// Template corpus only (no library write). Returns JSONL for import.
    @discardableResult
    private func buildMindCorpus() -> String {
        let tags = Set(draft.styleTags)
        let result = corpus.build(
            name: draft.name,
            species: draft.resolvedSpecies,
            vibe: draft.vibe,
            paste: draft.storyPaste.isEmpty
                ? "I am \(draft.displayTitle), a \(draft.resolvedSpecies). \(draft.vibe)"
                : draft.storyPaste,
            styleTags: tags,
            riffExtra: max(0, draft.riffCount)
        )
        draft.bible = result.bible
        draft.examples = result.examples
        statusMessage = "Built \(result.rowCount) practice lines. Press Continue → Voice when ready."
        return result.jsonl
    }

    /// Line spoken by system TTS before creature FX (from mind samples or a default).
    func voicePreviewSpeechText() -> String {
        if let line = draft.examples.first(where: {
            !$0.assistant.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        })?.assistant {
            // Keep utterance short for snappy preview.
            let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.count <= 160 { return t }
            let idx = t.index(t.startIndex, offsetBy: 160)
            return String(t[..<idx]).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
        }
        let name = draft.displayTitle
        let species = draft.resolvedSpecies
        let vibe = draft.vibe.trimmingCharacters(in: .whitespacesAndNewlines)
        if !vibe.isEmpty {
            return "Hello. I am \(name), a \(species). \(vibe)."
        }
        return "Hello. I am \(name), a \(species). I mean you no harm."
    }

    func renderVoicePreview() {
        guard !isWorking else { return }
        stopPreview(clearStatus: false)
        isWorking = true
        lastError = nil
        let speechText = voicePreviewSpeechText()
        let params = currentFXParams()
        let characterName = draft.displayTitle
        let characterId = draft.id
        switch CatalogTTSRuntime.currentStatus() {
        case .ready:
            statusMessage = "Speaking as \(params.preset.catalogSpeakerLabel)…"
        case .installing(let note):
            statusMessage = "\(note) Using a Mac voice this time."
        default:
            statusMessage = "Speaking line…"
        }
        Task.detached { await CatalogTTSRuntime.ensureReady() }

        Task { @MainActor in
            defer { isWorking = false }
            do {
                let dir = try store.characterDirectory(id: characterId)
                let result = try await CreatureFXRenderer.renderSpokenPreview(
                    speechText: speechText,
                    params: params,
                    characterName: characterName,
                    outputDirectory: dir
                )
                draft.previewAudioPath = result.audioURL.path
                draft.voiceProfilePath = result.profileURL.path
                if result.usedCatalogTTS {
                    let speaker = result.catalogVoiceId.map { $0.replacingOccurrences(of: "_", with: " ") } ?? params.preset.catalogSpeakerLabel
                    statusMessage =
                        "Voice ready (\(params.preset.title) · \(speaker)). Press “Finish & save”."
                } else if result.usedSystemTTS {
                    let line = result.spokenText.map { " “\($0.prefix(48))\($0.count > 48 ? "…" : "")”" } ?? ""
                    statusMessage =
                        "Voice ready (\(params.preset.title)) — Mac voice\(line). Character speakers install in the background."
                } else {
                    statusMessage =
                        "Voice is buzz-only (system TTS failed). Check macOS speech voices in System Settings → Accessibility → Spoken Content."
                }
                persistDraft()
                playPreview()
            } catch {
                lastError = error.localizedDescription
                statusMessage = nil
            }
        }
    }

    func playPreview() {
        guard let path = draft.previewAudioPath else { return }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else {
            lastError = "Preview file missing — press Hear their voice again."
            return
        }
        do {
            stopPreview(clearStatus: false)
            // New player instance each time (avoids replaying a stale buffer).
            let player = try AVAudioPlayer(contentsOf: url)
            player.prepareToPlay()
            player.volume = 1.0
            audioPlayer = player
            isPlayingPreview = true
            guard player.play() else {
                isPlayingPreview = false
                lastError = "Could not start audio playback."
                return
            }
            // Auto-clear playing state when the clip ends.
            let duration = player.duration
            previewEndTask = Task { @MainActor in
                let ns = UInt64(max(0.05, duration + 0.05) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: ns)
                guard !Task.isCancelled else { return }
                if self.audioPlayer === player {
                    self.isPlayingPreview = false
                    self.audioPlayer = nil
                }
            }
        } catch {
            isPlayingPreview = false
            lastError = error.localizedDescription
        }
    }

    /// Stop the voice preview (sound test) immediately.
    func stopPreview(clearStatus: Bool = true) {
        previewEndTask?.cancel()
        previewEndTask = nil
        audioPlayer?.stop()
        audioPlayer = nil
        isPlayingPreview = false
        if clearStatus, draft.previewAudioPath != nil {
            // Keep a light hint only when user explicitly stopped.
            // Don't clobber richer status from render.
        }
    }

    func saveCharacter() async {
        if draft.examples.isEmpty {
            _ = buildMindCorpus()
            _ = persistDraft()
            await importMindDataset(jsonl: encodeCurrentJSONL())
        } else if draft.datasetId == nil {
            await importMindDataset(jsonl: encodeCurrentJSONL())
        }
        let wasEditing = isEditingComplete
        guard persistDraft(markComplete: true) else { return }
        isEditingComplete = false
        statusMessage = wasEditing
            ? "Changes saved for “\(draft.displayTitle)”."
            : "Saved “\(draft.displayTitle)”."
        step = .done
    }

    func currentFXParams() -> CreatureFXParams {
        draft.creatureFXParams()
    }

    func applyVoicePresetAndHear(_ preset: CreatureVoicePreset) {
        applyVoicePreset(preset)
        renderVoicePreview()
    }

    func applyVoiceRegister(_ register: VoiceRegister) {
        draft.voiceRegister = register.rawValue
        let preset = CreatureVoicePreset(rawValue: draft.voicePreset) ?? .alien
        let p = CreatureFXParams.fromPreset(preset, register: register)
        draft.size = p.size
        draft.formant = p.formant
        draft.previewAudioPath = nil
        renderVoicePreview()
    }

    func applyVoicePreset(_ preset: CreatureVoicePreset) {
        draft.voicePreset = preset.rawValue
        let register = preset.defaultRegister
        draft.voiceRegister = register.rawValue
        let p = CreatureFXParams.fromPreset(preset, register: register)
        draft.size = p.size
        draft.grit = p.grit
        draft.atmosphere = p.atmosphere
        draft.formant = p.formant
        draft.metallic = p.metallic
        draft.tremble = p.tremble
        draft.breath = p.breath
        draft.speed = p.speed
        draft.robotize = p.robotize
        draft.textureIdSet = Set(p.textures.map(\.rawValue))
        draft.textureLevels = p.textureMix
        // Clear stale preview so Hear re-renders with new preset.
        draft.previewAudioPath = nil
    }

    /// Update a voice slider and invalidate the old preview WAV.
    func setVoiceKnob(_ keyPath: WritableKeyPath<CharacterDraft, Double>, to value: Double) {
        draft[keyPath: keyPath] = value
        draft.previewAudioPath = nil
    }

    func toggleTexture(_ id: CreatureTextureID) {
        let next = draft.textureLevel(id.rawValue) < 0.02 ? 0.4 : 0
        setTextureLevel(id, next)
    }

    func isTextureOn(_ id: CreatureTextureID) -> Bool {
        draft.textureLevel(id.rawValue) > 0.02
    }

    func textureLevel(_ id: CreatureTextureID) -> Double {
        draft.textureLevel(id.rawValue)
    }

    func setTextureLevel(_ id: CreatureTextureID, _ value: Double) {
        draft.setTextureLevel(id.rawValue, value)
        draft.previewAudioPath = nil
    }

    // MARK: - Private

    /// Write mind JSONL through `character.importMind` (same path as MCP).
    private func importMindDataset(jsonl: String) async {
        let name = "\(draft.displayTitle) mind"
        if let plane = controlPlane, plane.isReady {
            let outcome = await plane.invoke(
                CharacterImportMindHandler.id,
                params: .object([
                    "characterId": .string(draft.id),
                    "jsonl": .string(jsonl),
                    "name": .string(name),
                    "identityPolicy": .string(MindIdentityPolicy.mergeByStableId.rawValue),
                ])
            )
            if outcome.ok, let id = outcome.data?["datasetId"]?.stringValue {
                draft.datasetId = id
                persistDraft()
                OnboardingStore().markCompleted(.importDataset)
                if outcome.data?["unchanged"]?.boolValue != true {
                    MVPMetricsStore.shared.increment(.datasetImportOK)
                }
                let rows = outcome.data?["rowCount"]?.intValue ?? draft.examples.count
                if outcome.data?["unchanged"]?.boolValue == true {
                    statusMessage = "Mind unchanged (\(rows) lines). Press Continue → Voice."
                } else if outcome.data?["created"]?.boolValue == true {
                    statusMessage = "Saved \(rows) practice lines. Press “Continue → Voice” below."
                } else {
                    statusMessage = "Updated mind dataset (\(rows) lines). Press Continue → Voice."
                }
                return
            }
            if outcome.error?.code != ActionErrorCode.unknownAction.rawValue {
                lastError = outcome.error?.message ?? "Mind import failed"
                return
            }
            // Handler not registered yet — same upsert as the handler uses.
        }
        do {
            let id = try saveDatasetFallback(jsonl: jsonl, name: name)
            draft.datasetId = id
            OnboardingStore().markCompleted(.importDataset)
            MVPMetricsStore.shared.increment(.datasetImportOK)
            statusMessage = "Saved practice lines. Press “Continue → Voice” below."
            persistDraft()
        } catch {
            lastError = (error as? BAMError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Local upsert when the control plane is not attached (tests / previews).
    private func saveDatasetFallback(jsonl: String, name: String) throws -> String {
        let service = try DatasetLibraryService.openDefault()
        let result = try service.upsertMindJSONL(
            jsonl: jsonl,
            name: name,
            existingDatasetId: draft.datasetId,
            policy: .mergeByStableId
        )
        return result.datasetId
    }

    private func encodeCurrentJSONL() -> String {
        guard let system = draft.bible?.systemPrompt else { return "" }
        var lines: [String] = []
        for ex in draft.examples {
            let row: [String: Any] = [
                "messages": [
                    ["role": "system", "content": system],
                    ["role": "user", "content": ex.user],
                    ["role": "assistant", "content": ex.assistant],
                ],
            ]
            if let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]),
               let line = String(data: data, encoding: .utf8)
            {
                lines.append(line)
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
