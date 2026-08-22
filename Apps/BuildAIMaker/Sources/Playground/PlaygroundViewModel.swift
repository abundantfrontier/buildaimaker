import AppKit
import AVFoundation
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import BAMAudioFX
import BAMCharacterStudio
import BAMCore
import BAMInference
import BAMModelCatalog
import BAMRunnersMLX

/// Scanned adapter under `models/adapters` (open LoRA) or `models/foundation-adapters`.
struct ScannedAdapter: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable, Equatable {
        case openLora
        case foundation
    }

    var directoryName: String
    var localPath: String
    var displayName: String
    var hasAdapterConfig: Bool
    var kind: Kind
    var isFake: Bool

    var id: String { localPath }
}

/// Text playground: base vs adapter chat with A/B toggle and JSONL export.
///
/// Uses real `mlx-lm generate` when the managed/system Python has mlx_lm **and**
/// the selected base model is not a fixture/stub. Otherwise falls back to echo
/// (character system prompt still applies).
@MainActor
final class PlaygroundViewModel: ObservableObject {
    @Published private(set) var baseModels: [ScannedLocalModel] = []
    @Published private(set) var adapters: [ScannedAdapter] = []
    @Published var selectedBasePath: String?
    @Published var selectedAdapterPath: String?
    /// A/B: when false, completions ignore the selected adapter (base only).
    @Published var adapterEnabled: Bool = true
    @Published var systemPrompt: String = "You are a helpful assistant."
    @Published var draft: String = ""
    @Published private(set) var messages: [InferenceChatMessage] = []
    @Published private(set) var isGenerating = false
    @Published var statusMessage: String?
    @Published var errorMessage: String?
    @Published private(set) var backendId: String = "echo"
    @Published private(set) var lastLatencyMs: Double?
    @Published private(set) var lastWasStub: Bool?
    @Published private(set) var playgroundEnabled: Bool = FeatureFlags.default.playground
    @Published var exportMessage: String?
    @Published private(set) var lastTracePath: String?
    /// Character handoff banner.
    @Published private(set) var boundCharacterName: String?
    @Published private(set) var modelCapability: LocalModelCapability = .stub(reason: "No model selected")
    @Published private(set) var mlxAvailable: Bool = false
    @Published private(set) var usingRealGenerate: Bool = false

    /// Caption next to the character picker — must match the live backend, not “any real model”.
    var backendCaption: String {
        switch backendId {
        case AppleFoundationLLMBackend.id:
            return "Apple on-device"
        case MLXGenerateBackend.id:
            return "Local MLX"
        default:
            return usingRealGenerate ? "Local model" : "Demo replies"
        }
    }
    /// Backend preference: Apple on-device first when available.
    @Published var backendPreference: LLMBackendPreference = .automatic {
        didSet { resolveBackend() }
    }
    @Published private(set) var appleModelStatus: AppleFoundationModelStatus = .unknown
    @Published private(set) var mlxPythonAvailable: Bool = false
    /// When true, each assistant reply is spoken (system TTS + creature FX).
    @Published var speakReplies: Bool = UserDefaults.standard.bool(forKey: "bam.playground.speakReplies") {
        didSet {
            UserDefaults.standard.set(speakReplies, forKey: "bam.playground.speakReplies")
            if !speakReplies { stopSpeaking() }
        }
    }
    @Published private(set) var isSpeaking = false
    @Published private(set) var lastSpokenNote: String?
    @Published private(set) var boundCharacterId: String?
    @Published private(set) var voiceParams: CreatureFXParams?
    @Published private(set) var characters: [CharacterDraft] = []

    private let libraryRoot: URL
    private let featureFlags: FeatureFlags
    private var backend: any LLMBackend
    private let forceEcho: Bool
    private let baseScanner: LocalModelScanner
    private let metricsStore: MVPMetricsStore
    private var traceRecorder: PlaygroundTraceRecorder
    private var lastAppliedPlaygroundToken: UUID?
    private var lastIncomingChatNonce: String = ""
    private var audioPlayer: AVAudioPlayer?
    private var speakEndTask: Task<Void, Never>?
    private var speakGeneration = 0

    init(
        libraryRoot: URL = LibraryPaths.libraryRoot,
        featureFlags: FeatureFlags = .default,
        backend: (any LLMBackend)? = nil,
        forceEcho: Bool = false,
        metricsStore: MVPMetricsStore = .shared
    ) {
        self.libraryRoot = libraryRoot
        self.featureFlags = featureFlags
        self.playgroundEnabled = featureFlags.playground
        self.forceEcho = forceEcho
        // Do not probe mlx-lm here: PlaygroundView constructs this during SwiftUI
        // layout. A Process.waitUntilExit on the main thread aborts AttributeGraph.
        if let backend {
            self.backend = backend
        } else if forceEcho {
            self.backend = EchoLLMBackend()
        } else {
            self.backend = AppleFoundationLLMBackend.makeIfAvailable() ?? EchoLLMBackend()
        }
        self.backendId = self.backend.backendId
        self.baseScanner = LocalModelScanner(
            modelsBaseURL: libraryRoot.appendingPathComponent("models/base", isDirectory: true)
        )
        self.metricsStore = metricsStore
        self.traceRecorder = PlaygroundTraceRecorder.underLibraryRoot(
            libraryRoot,
            enabled: PlaygroundTraceRecorder.isEnabled()
        )
        self.appleModelStatus = AppleFoundationModelSupport.probeStatus()
        self.mlxPythonAvailable = false
        self.usingRealGenerate = !self.backend.backendId.contains("echo")
    }

    func bootstrap() {
        reloadCharacters()
        reload()
        Task.detached { [weak self] in
            _ = MLXGenerateBackend.isAvailable()
            guard let self else { return }
            await self.onSelectedBaseModelChanged()
        }
    }

    func reloadCharacters() {
        characters = (try? CharacterLibraryStore().list()) ?? []
    }

    /// Bind a library character (picker or MCP). Clears the transcript when the id changes.
    func bindCharacter(id: String?) {
        reloadCharacters()
        guard let id, !id.isEmpty else {
            boundCharacterId = nil
            boundCharacterName = nil
            voiceParams = nil
            lastAppliedPlaygroundToken = nil
            statusMessage = "No character selected — pick one to chat in-character."
            return
        }
        if boundCharacterId == id, boundCharacterName != nil { return }
        guard let draft = try? CharacterLibraryStore().load(id: id) else {
            errorMessage = "Character not found."
            return
        }
        lastAppliedPlaygroundToken = nil
        applyCharacterLaunch(
            CharacterStudioLaunchContext.PlaygroundTarget(
                characterId: draft.id,
                characterName: draft.displayTitle,
                baseModelPath: draft.baseModelPath,
                baseModelName: draft.baseModelName,
                baseModelSourceKey: draft.baseModelSourceKey,
                systemPrompt: draft.bible?.systemPrompt,
                adapterPath: draft.adapterPath,
                adapterName: draft.adapterName,
                voiceParams: draft.creatureFXParams()
            )
        )
    }

    /// Apply character wizard / list handoff (model path + system prompt).
    func applyCharacterLaunch(_ target: CharacterStudioLaunchContext.PlaygroundTarget) {
        guard lastAppliedPlaygroundToken != target.token else { return }
        lastAppliedPlaygroundToken = target.token
        boundCharacterId = target.characterId
        boundCharacterName = target.characterName
        voiceParams = target.voiceParams
            ?? (try? CharacterLibraryStore().load(id: target.characterId))?.creatureFXParams()

        let usesApple = target.baseModelSourceKey == CharacterDraft.appleFoundationSourceKey
            || target.baseModelPath == CharacterDraft.appleFoundationPath
        if usesApple {
            backendPreference = .appleFoundation
            // Don't force a non-existent disk path into the MLX picker.
            if let path = target.baseModelPath,
               path != CharacterDraft.appleFoundationPath,
               !path.isEmpty
            {
                selectedBasePath = path
            }
        } else if let path = target.baseModelPath, !path.isEmpty,
                  path != CharacterDraft.appleFoundationPath
        {
            selectedBasePath = path
            if backendPreference == .automatic || backendPreference == .appleFoundation {
                backendPreference = .mlx
            }
        }

        if let prompt = target.systemPrompt?.trimmingCharacters(in: .whitespacesAndNewlines),
           !prompt.isEmpty
        {
            systemPrompt = prompt
        } else if !target.characterName.isEmpty {
            systemPrompt = "You are \(target.characterName). Stay in character."
        }
        messages = []
        reload()
        applyAdapterSelection(named: target.adapterName, path: target.adapterPath, characterName: target.characterName)
        let adapterNote: String
        if adapterEnabled, let path = selectedAdapterPath {
            let label = adapters.first(where: { $0.localPath == path })?.displayName
                ?? target.adapterName
                ?? URL(fileURLWithPath: path).lastPathComponent
            adapterNote = " · LoRA \(label)"
        } else {
            adapterNote = " · base model only (no LoRA pinned yet)"
        }
        statusMessage = "Bound to character “\(target.characterName)”"
            + (target.baseModelName.map { " · \($0)" } ?? "")
            + (usesApple ? " · Apple on-device" : "")
            + adapterNote
    }

    /// Prefer the character’s stored adapter; else a library adapter whose name matches.
    private func applyAdapterSelection(named: String?, path: String?, characterName: String) {
        func exists(_ p: String) -> Bool {
            FileManager.default.fileExists(atPath: p)
        }
        if let path, exists(path) {
            selectedAdapterPath = path
            adapterEnabled = true
            if !adapters.contains(where: { $0.localPath == path }) {
                // Keep even if scan missed it (reload already ran).
            }
            return
        }
        let needle = characterName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !needle.isEmpty,
           let match = adapters.first(where: {
               $0.displayName.lowercased().contains(needle)
                   || $0.directoryName.lowercased().contains(needle)
           })
        {
            selectedAdapterPath = match.localPath
            adapterEnabled = true
            return
        }
        selectedAdapterPath = nil
        adapterEnabled = false
    }

    func reload() {
        errorMessage = nil
        do {
            baseModels = try baseScanner.scan()
            let open = try Self.scanAdapters(
                at: libraryRoot.appendingPathComponent("models/adapters", isDirectory: true),
                kind: .openLora
            )
            let foundation: [ScannedAdapter]
            if featureFlags.foundationModels {
                foundation = (try? FoundationAdapterService(libraryRoot: libraryRoot).listInstalled().map {
                    ScannedAdapter(
                        directoryName: $0.id,
                        localPath: $0.directoryURL.path,
                        displayName: $0.displayName + ($0.isFake ? " (stub)" : ""),
                        hasAdapterConfig: true,
                        kind: .foundation,
                        isFake: $0.isFake
                    )
                }) ?? []
            } else {
                foundation = []
            }
            allAdapters = open + foundation
            refreshVisibleAdapters()
            if selectedBasePath == nil {
                selectedBasePath = baseModels.first?.localPath
            } else if let path = selectedBasePath,
                      !baseModels.contains(where: { $0.localPath == path })
            {
                // Keep explicit character path even if scan missed it briefly.
                if !FileManager.default.fileExists(atPath: path) {
                    selectedBasePath = baseModels.first?.localPath
                }
            }
            if let path = selectedAdapterPath,
               !adapters.contains(where: { $0.localPath == path })
            {
                selectedAdapterPath = nil
            }

            onSelectedBaseModelChanged()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Adapters shown in the picker for the active backend.
    private var allAdapters: [ScannedAdapter] = []

    private func refreshVisibleAdapters() {
        let usingApple = backendId == AppleFoundationLLMBackend.id
            || backendPreference == .appleFoundation
            || (backendPreference == .automatic && appleModelStatus == .available)
        if usingApple {
            adapters = allAdapters.filter { $0.kind == .foundation }
        } else {
            adapters = allAdapters.filter { $0.kind == .openLora }
        }
        if let path = selectedAdapterPath,
           !adapters.contains(where: { $0.localPath == path })
        {
            selectedAdapterPath = adapters.first?.localPath
        }
    }

    /// Re-probe model capability + backend when the user changes the base model picker.
    func onSelectedBaseModelChanged() {
        modelCapability = LocalModelCapabilityProbe.probe(path: selectedBasePath)
        resolveBackend()
        updateStatusBanner()
    }

    /// Re-pick backend: Apple FM (default) → MLX → echo.
    private func resolveBackend() {
        appleModelStatus = AppleFoundationModelSupport.probeStatus()
        mlxPythonAvailable = MLXGenerateBackend.isAvailable()
        mlxAvailable = mlxPythonAvailable

        if forceEcho {
            backend = EchoLLMBackend()
            backendId = backend.backendId
            usingRealGenerate = false
            refreshVisibleAdapters()
            return
        }

        switch backendPreference {
        case .echo:
            backend = EchoLLMBackend()
        case .appleFoundation:
            backend = AppleFoundationLLMBackend.makeIfAvailable() ?? EchoLLMBackend()
        case .mlx:
            // Only use MLX when weights look real; otherwise echo with message.
            if !modelCapability.isStub, let mlx = MLXGenerateBackend.makeIfAvailable() {
                backend = mlx
            } else {
                backend = EchoLLMBackend()
            }
        case .automatic:
            if let apple = AppleFoundationLLMBackend.makeIfAvailable() {
                backend = apple
            } else if !modelCapability.isStub, let mlx = MLXGenerateBackend.makeIfAvailable() {
                backend = mlx
            } else {
                backend = EchoLLMBackend()
            }
        }
        backendId = backend.backendId
        usingRealGenerate = backendId != EchoLLMBackend.id
        refreshVisibleAdapters()
    }

    private func updateStatusBanner() {
        var parts: [String] = []
        if let name = boundCharacterName {
            parts.append("Character: \(name)")
        }
        switch backendId {
        case AppleFoundationLLMBackend.id:
            parts.append("Apple on-device model (default)")
        case MLXGenerateBackend.id:
            parts.append("MLX generate")
        case EchoLLMBackend.id:
            if appleModelStatus == .available {
                parts.append("Echo — pick Automatic/Apple in backend menu")
            } else if modelCapability.isStub {
                parts.append("Echo — stub weights; Apple FM unavailable or MLX needs real weights")
            } else {
                parts.append("Echo stub")
            }
        default:
            parts.append("Backend: \(backendId)")
        }
        parts.append("Apple FM: \(appleModelStatus.rawValue)")
        statusMessage = parts.joined(separator: " · ")
    }

    /// Apple FM needs no local base path; MLX does.
    var canSend: Bool {
        let hasDraft = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard playgroundEnabled, !isGenerating, hasDraft else { return false }
        if backendId == AppleFoundationLLMBackend.id { return true }
        if backendPreference == .automatic, appleModelStatus == .available { return true }
        if backendId == MLXGenerateBackend.id { return selectedBasePath != nil }
        // Echo / other: allow without base so Apple-default path still works mid-resolve.
        return true
    }

    var canExport: Bool {
        !messages.isEmpty && messages.contains(where: { $0.role == "user" })
    }

    func applyIncomingTurn(user: String, assistant: String, nonce: String) {
        guard !nonce.isEmpty, nonce != lastIncomingChatNonce else { return }
        lastIncomingChatNonce = nonce
        let userTrim = user.trimmingCharacters(in: .whitespacesAndNewlines)
        let asstTrim = assistant.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !userTrim.isEmpty, !asstTrim.isEmpty else { return }
        if messages.last?.role == "assistant", messages.last?.content == asstTrim {
            return
        }
        messages.append(.user(userTrim))
        messages.append(.assistant(asstTrim))
        statusMessage = "Turn from agent · \(boundCharacterName ?? "Playground")"
        if speakReplies {
            speakAssistantReply(asstTrim)
        }
    }

    func send() {
        guard canSend else { return }
        modelCapability = LocalModelCapabilityProbe.probe(path: selectedBasePath)
        resolveBackend()
        let base = selectedBasePath

        let text = draft
        draft = ""
        isGenerating = true
        errorMessage = nil
        exportMessage = nil
        stopSpeaking()
        traceRecorder.enabled = PlaygroundTraceRecorder.isEnabled()

        let activeBackend = backend

        Task {
            defer { isGenerating = false }
            do {
                let formatStarted = Date()
                let usesApple = activeBackend.backendId == AppleFoundationLLMBackend.id
                var session = PlaygroundSession(
                    systemPrompt: systemPrompt,
                    messages: messages,
                    baseModelPath: base,
                    adapterPath: selectedAdapterPath,
                    adapterEnabled: adapterEnabled,
                    allowsSystemModel: usesApple
                )
                let completeStarted = Date()
                let result = try await session.send(userText: text, backend: activeBackend)
                let completeEnded = Date()
                messages = session.messages
                lastLatencyMs = result.latencyMs
                lastWasStub = result.isStub
                backendId = result.backendId
                statusMessage = result.isStub
                    ? "Echo reply (\(Int(result.latencyMs)) ms) — not a real model completion"
                    : "Real generate via \(result.backendId) (\(Int(result.latencyMs)) ms)"

                metricsStore.increment(.playgroundReply)
                OnboardingStore().markCompleted(.playgroundChat)

                let stages = PlaygroundTraceRecorder.stagesForCompletion(
                    formatStarted: formatStarted,
                    completeStarted: completeStarted,
                    completeEnded: completeEnded,
                    totalEnded: completeEnded
                )
                if speakReplies, let reply = messages.last(where: { $0.role == "assistant" })?.content {
                    speakAssistantReply(reply)
                }

                if let url = try? traceRecorder.recordTurn(
                    stages: stages,
                    backendId: result.backendId,
                    latencyMs: result.latencyMs,
                    isStub: result.isStub,
                    baseModelPath: base,
                    adapterPath: selectedAdapterPath,
                    adapterEnabled: adapterEnabled
                ) {
                    lastTracePath = url.path
                }
            } catch {
                draft = text
                errorMessage = error.localizedDescription
                if backendId == AppleFoundationLLMBackend.id {
                    statusMessage = "Apple model failed — check Apple Intelligence status."
                } else if usingRealGenerate {
                    statusMessage = "Generate failed — check MLX weights / runtime."
                }
            }
        }
    }

    func clearTranscript() {
        stopSpeaking()
        messages = []
        lastLatencyMs = nil
        lastWasStub = nil
        exportMessage = nil
        lastSpokenNote = nil
        statusMessage = "Transcript cleared."
    }

    func stopSpeaking() {
        speakGeneration += 1
        speakEndTask?.cancel()
        speakEndTask = nil
        audioPlayer?.stop()
        audioPlayer = nil
        isSpeaking = false
    }

    /// Fresh card knobs (How-fast, textures). Cached `voiceParams` go stale after Voice edits.
    private func liveVoiceParams() -> CreatureFXParams {
        if let id = boundCharacterId,
           let draft = try? CharacterLibraryStore().load(id: id)
        {
            let fresh = draft.creatureFXParams()
            voiceParams = fresh
            return fresh
        }
        return voiceParams ?? CreatureFXParams.fromPreset(.alien)
    }

    /// Speak the last assistant line with the bound character’s creature voice (or a mild default).
    func speakAssistantReply(_ raw: String) {
        let text = Self.speechText(from: raw)
        guard !text.isEmpty else { return }
        stopSpeaking()
        speakGeneration += 1
        let gen = speakGeneration
        isSpeaking = true
        lastSpokenNote = nil

        // Reload from the card so Voice-step sliders apply without rebinding.
        let params = liveVoiceParams()
        let name = boundCharacterName ?? "Playground"
        let characterId = boundCharacterId

        Task { @MainActor in
            defer {
                if gen == self.speakGeneration, self.audioPlayer == nil {
                    self.isSpeaking = false
                }
            }
            do {
                let dir: URL
                if let characterId {
                    dir = try CharacterLibraryStore().characterDirectory(id: characterId)
                } else {
                    dir = libraryRoot
                        .appendingPathComponent("diagnostics", isDirectory: true)
                        .appendingPathComponent("playground-tts", isDirectory: true)
                }
                let result = try await CreatureFXRenderer.renderSpokenPreview(
                    speechText: text,
                    params: params,
                    characterName: name,
                    outputDirectory: dir
                )
                guard gen == self.speakGeneration else { return }
                try playSpokenURL(result.audioURL, duration: result.durationSeconds, generation: gen)
                if result.usedCatalogTTS {
                    lastSpokenNote = boundCharacterName.map {
                        "Spoke as \($0) (\(params.preset.title) · \(params.preset.catalogSpeakerLabel))"
                    } ?? "Spoke reply (\(params.preset.catalogSpeakerLabel))"
                } else {
                    lastSpokenNote = result.usedSystemTTS
                        ? (boundCharacterName.map { "Spoke as \($0) (\(params.preset.title))" } ?? "Spoke reply")
                        : "Voice preview was buzz-only (system TTS failed)."
                }
            } catch {
                if gen == self.speakGeneration {
                    lastSpokenNote = "Could not speak reply: \(error.localizedDescription)"
                    isSpeaking = false
                }
            }
        }
    }

    private func playSpokenURL(_ url: URL, duration: Double, generation: Int) throws {
        let player = try AVAudioPlayer(contentsOf: url)
        player.prepareToPlay()
        player.volume = 1.0
        audioPlayer = player
        isSpeaking = true
        guard player.play() else {
            isSpeaking = false
            audioPlayer = nil
            lastSpokenNote = "Could not start audio playback."
            return
        }
        speakEndTask = Task { @MainActor in
            let ns = UInt64(max(0.05, duration + 0.08) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: ns)
            guard !Task.isCancelled, generation == self.speakGeneration else { return }
            if self.audioPlayer === player {
                self.isSpeaking = false
                self.audioPlayer = nil
            }
        }
    }

    /// Keep utterances short enough for snappy system TTS.
    static func speechText(from raw: String, limit: Int = 900) -> String {
        let collapsed = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty else { return "" }
        if collapsed.count <= limit { return collapsed }
        let idx = collapsed.index(collapsed.startIndex, offsetBy: limit)
        var prefix = String(collapsed[..<idx])
        if let space = prefix.lastIndex(of: " ") {
            prefix = String(prefix[..<space])
        }
        return prefix.trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    /// Export full conversation as JSONL dataset candidate via save panel.
    func exportTranscript(paired: Bool = false) {
        guard canExport else {
            exportMessage = "Nothing to export yet — send at least one user message."
            return
        }
        var exportMsgs: [InferenceChatMessage] = []
        let trimmed = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            exportMsgs.append(.system(trimmed))
        }
        exportMsgs.append(contentsOf: messages.filter { $0.role != "system" })

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = paired ? "playground-pairs.jsonl" : "playground-transcript.jsonl"
        panel.title = "Export transcript as dataset candidate"
        panel.message = "OpenAI-messages JSONL for re-import under Datasets."
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else {
            exportMessage = "Export cancelled."
            return
        }
        var outURL = url
        if outURL.pathExtension.lowercased() != "jsonl" {
            outURL = outURL.deletingPathExtension().appendingPathExtension("jsonl")
        }
        do {
            try TranscriptExporter.write(messages: exportMsgs, to: outURL, paired: paired)
            exportMessage = "Exported to \(outURL.path)"
        } catch {
            errorMessage = "Export failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Adapter scan

    static func scanAdapters(
        at adaptersRoot: URL,
        kind: ScannedAdapter.Kind = .openLora,
        fileManager: FileManager = .default
    ) throws -> [ScannedAdapter] {
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: adaptersRoot.path, isDirectory: &isDir),
              isDir.boolValue
        else {
            return []
        }
        let contents = try fileManager.contentsOfDirectory(
            at: adaptersRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        var results: [ScannedAdapter] = []
        for url in contents {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
            guard values?.isDirectory == true else { continue }
            let name = url.lastPathComponent
            guard LibraryPaths.validatedPathComponent(name) != nil else { continue }
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL
            let config = resolved.appendingPathComponent("adapter_config.json")
            let hasConfig = fileManager.fileExists(atPath: config.path)
            results.append(
                ScannedAdapter(
                    directoryName: name,
                    localPath: resolved.path,
                    displayName: name,
                    hasAdapterConfig: hasConfig,
                    kind: kind,
                    isFake: false
                )
            )
        }
        return results.sorted {
            $0.directoryName.localizedCaseInsensitiveCompare($1.directoryName) == .orderedAscending
        }
    }
}
