import AVFoundation
import BAMAudioFX
import BAMCharacterStudio
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
    /// True after the first intentional load; blocks accidental save of an empty draft.
    private var didLoadOnce = false
    /// When true, skip auto-persist during programmatic load/select.
    private var suppressPersist = false

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
        isPlayingPreview = false
        audioPlayer?.stop()
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
                buildMind(importDataset: true)
                // Stay on mind so user sees previews; they press Continue again.
            }
        case .voice:
            if voiceReady {
                saveCharacter()
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
        isPlayingPreview = false
        audioPlayer?.stop()
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
                let p = CreatureFXParams.fromPreset(vp)
                draft.size = p.size
                draft.grit = p.grit
                draft.atmosphere = p.atmosphere
                draft.textureBuzzSaw = p.textures.contains(.buzzSaw)
                draft.textureSongbird = p.textures.contains(.songbird)
                draft.textureDrip = p.textures.contains(.drip)
                draft.textureServo = p.textures.contains(.servo)
            }
        }
    }

    func buildMind(importDataset: Bool) {
        isWorking = true
        lastError = nil
        defer { isWorking = false }

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

        if importDataset {
            do {
                let id = try saveDataset(jsonl: result.jsonl, name: "\(draft.displayTitle) mind")
                draft.datasetId = id
                statusMessage =
                    "Saved \(result.rowCount) practice lines. Press “Continue → Voice” below."
            } catch {
                lastError = (error as? BAMError)?.errorDescription ?? error.localizedDescription
            }
        }

        persistDraft()
    }

    func riffMore() {
        guard let bible = draft.bible, !draft.examples.isEmpty else {
            buildMind(importDataset: false)
            return
        }
        let jsonl = encodeCurrentJSONL()
        let current = CorpusBuildResult(bible: bible, examples: draft.examples, jsonl: jsonl)
        let next = corpus.riff(result: current, extra: 3)
        draft.examples = next.examples
        draft.bible = next.bible
        statusMessage = "Riffed +3 lines (now \(next.rowCount))."
        persistDraft()
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
        isWorking = true
        lastError = nil
        statusMessage = "Speaking line + applying creature FX…"

        let speechText = voicePreviewSpeechText()
        let params = currentFXParams()
        let characterName = draft.displayTitle
        let characterId = draft.id

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
                if result.usedSystemTTS {
                    statusMessage =
                        "Voice ready (\(params.preset.title)) — TTS + FX. Press “Finish & save” below."
                } else {
                    statusMessage =
                        "Voice ready (\(params.preset.title)) — buzz fallback (TTS unavailable). Press “Finish & save”."
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
        do {
            audioPlayer = try AVAudioPlayer(contentsOf: url)
            audioPlayer?.prepareToPlay()
            isPlayingPreview = true
            audioPlayer?.play()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func saveCharacter() {
        // Ensure mind exists even if user skipped rebuilding.
        if draft.examples.isEmpty {
            buildMind(importDataset: true)
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
        let preset = CreatureVoicePreset(rawValue: draft.voicePreset) ?? .alien
        var textures = Set<CreatureTextureID>()
        if draft.textureBuzzSaw { textures.insert(.buzzSaw) }
        if draft.textureSongbird { textures.insert(.songbird) }
        if draft.textureDrip { textures.insert(.drip) }
        if draft.textureServo { textures.insert(.servo) }
        return CreatureFXParams(
            preset: preset,
            size: draft.size,
            grit: draft.grit,
            atmosphere: draft.atmosphere,
            textures: textures
        )
    }

    func applyVoicePreset(_ preset: CreatureVoicePreset) {
        draft.voicePreset = preset.rawValue
        let p = CreatureFXParams.fromPreset(preset)
        draft.size = p.size
        draft.grit = p.grit
        draft.atmosphere = p.atmosphere
        draft.textureBuzzSaw = p.textures.contains(.buzzSaw)
        draft.textureSongbird = p.textures.contains(.songbird)
        draft.textureDrip = p.textures.contains(.drip)
        draft.textureServo = p.textures.contains(.servo)
    }

    // MARK: - Private

    private func saveDataset(jsonl: String, name: String) throws -> String {
        let service = try DatasetLibraryService.openDefault()

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("bam-char-\(UUID().uuidString).jsonl")
        try jsonl.data(using: .utf8)!.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let result = try service.importer.importDataset(
            DatasetImportRequest(sourceURL: tmp, name: name, importMode: .copy)
        )
        return result.dataset.id
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
