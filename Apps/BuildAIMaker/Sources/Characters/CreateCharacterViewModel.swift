import AVFoundation
import BAMAudioFX
import BAMCharacterStudio
import BAMCore
import BAMDatasets
import BAMModels
import BAMPersistence
import Foundation
import SwiftUI

@MainActor
final class CreateCharacterViewModel: ObservableObject {
    enum Step: Int, CaseIterable, Identifiable {
        case meet = 0
        case mind = 1
        case voice = 2
        case done = 3

        var id: Int { rawValue }

        static var userSteps: [Step] { [.meet, .mind, .voice] }

        var shortTitle: String {
            switch self {
            case .meet: return "Name"
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
            case .mind:
                return "Paste a short story (or leave blank), then press Build how they talk."
            case .voice:
                return "Pick a voice preset, press Hear their voice, then Finish & save."
            case .done:
                return "Character saved. Choose what to do next below."
            }
        }
    }

    @Published var step: Step = .meet
    @Published var draft = CharacterDraft()
    @Published var statusMessage: String?
    @Published var isWorking = false
    @Published var lastError: String?
    @Published var isPlayingPreview = false

    private let store = CharacterLibraryStore()
    private let corpus = CorpusBuilder()
    private var audioPlayer: AVAudioPlayer?

    var canGoNextFromMeet: Bool {
        !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var canBuildMind: Bool {
        !draft.storyPaste.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var mindBuilt: Bool { !draft.examples.isEmpty }
    var voiceReady: Bool { draft.previewAudioPath != nil }

    var primaryActionTitle: String {
        switch step {
        case .meet: return "Continue → Story"
        case .mind:
            return mindBuilt ? "Continue → Voice" : "Build how they talk"
        case .voice:
            return voiceReady ? "Finish & save" : "Hear their voice"
        case .done: return "Close"
        }
    }

    var primaryActionHint: String {
        switch step {
        case .meet:
            return canGoNextFromMeet ? "Next: write how they talk" : "Enter a name first"
        case .mind:
            return mindBuilt
                ? "Story is ready — continue to voice"
                : "Builds practice dialogues from your paste"
        case .voice:
            return voiceReady
                ? "Saves the character to your library"
                : "Generates a short creature sound preview"
        case .done:
            return "Use the buttons above"
        }
    }

    var primaryActionEnabled: Bool {
        switch step {
        case .meet: return canGoNextFromMeet
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
            step = .mind
        case .mind:
            if mindBuilt {
                step = .voice
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
        guard let prev = Step(rawValue: step.rawValue - 1), prev != .done else { return }
        step = prev
        statusMessage = nil
        lastError = nil
    }

    func resetForAnother() {
        draft = CharacterDraft()
        step = .meet
        statusMessage = nil
        lastError = nil
        isPlayingPreview = false
        audioPlayer?.stop()
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

        try? store.save(draft)
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
        try? store.save(draft)
    }

    func renderVoicePreview() {
        isWorking = true
        lastError = nil
        defer { isWorking = false }

        do {
            let dir = try store.characterDirectory(id: draft.id)
            let params = currentFXParams()
            let result = try CreatureFXRenderer.renderPreview(
                params: params,
                characterName: draft.displayTitle,
                outputDirectory: dir
            )
            draft.previewAudioPath = result.audioURL.path
            draft.voiceProfilePath = result.profileURL.path
            statusMessage = "Voice ready (\(params.preset.title)). Press “Finish & save” below."
            try store.save(draft)
            playPreview()
        } catch {
            lastError = error.localizedDescription
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
        do {
            // Ensure mind exists even if user skipped rebuilding.
            if draft.examples.isEmpty {
                buildMind(importDataset: true)
            }
            try store.save(draft)
            statusMessage = nil
            step = .done
        } catch {
            lastError = error.localizedDescription
        }
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
