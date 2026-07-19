import AppKit
import Foundation
import SwiftUI
import BAMCore
import BAMInference
import BAMModelCatalog

/// Talk mode: push-to-talk STT → LLM → TTS with barge-in and TCC messaging.
@MainActor
final class TalkViewModel: ObservableObject {
    enum PaneMode: String, CaseIterable, Identifiable {
        case text
        case talk
        var id: String { rawValue }
        var title: String {
            switch self {
            case .text: return "Text"
            case .talk: return "Talk"
            }
        }
    }

    @Published private(set) var baseModels: [ScannedLocalModel] = []
    @Published private(set) var adapters: [ScannedAdapter] = []
    @Published var selectedBasePath: String?
    @Published var selectedAdapterPath: String?
    @Published var adapterEnabled: Bool = true
    @Published var systemPrompt: String = "You are a helpful assistant."
    @Published private(set) var messages: [InferenceChatMessage] = []
    @Published private(set) var phase: TalkPhase = .idle
    @Published private(set) var partialTranscript: String = ""
    @Published private(set) var isPTTDown = false
    @Published private(set) var isBusy = false
    @Published var statusMessage: String?
    @Published var errorMessage: String?
    @Published var tccDenied = false
    @Published private(set) var lastTimestamps: TalkStageTimestamps = TalkStageTimestamps()
    @Published private(set) var sttBackendId: String = FakeSTTBackend.id
    @Published private(set) var ttsBackendId: String = FakeTTSBackend.id
    @Published private(set) var llmBackendId: String = "echo"
    @Published private(set) var talkEnabled: Bool = FeatureFlags.default.talkMode
    @Published private(set) var lastTTSProgress: Double = 0

    private let libraryRoot: URL
    private let featureFlags: FeatureFlags
    private let coordinator: TalkCoordinator
    private let baseScanner: LocalModelScanner
    private var partialTimer: Timer?

    init(
        libraryRoot: URL = LibraryPaths.libraryRoot,
        featureFlags: FeatureFlags = .default,
        coordinator: TalkCoordinator? = nil
    ) {
        self.libraryRoot = libraryRoot
        self.featureFlags = featureFlags
        self.talkEnabled = featureFlags.talkMode

        if let coordinator {
            self.coordinator = coordinator
        } else {
            let llm = LLMBackendFactory.makeDefault(forceEcho: false)
            let stt = TalkBackendFactory.makeSTT()
            let tts = TalkBackendFactory.makeTTS()
            let mic = SystemMicPermission()
            self.coordinator = TalkCoordinator(
                stt: stt,
                llm: llm,
                tts: tts,
                mic: mic,
                config: TalkCoordinatorConfig(
                    systemPrompt: "You are a helpful assistant.",
                    baseModelPath: nil
                )
            )
            self.llmBackendId = llm.backendId
            self.sttBackendId = stt.backendId
            self.ttsBackendId = tts.backendId
        }

        self.baseScanner = LocalModelScanner(
            modelsBaseURL: libraryRoot.appendingPathComponent("models/base", isDirectory: true)
        )
    }

    func bootstrap() {
        reload()
    }

    func reload() {
        errorMessage = nil
        tccDenied = false
        do {
            baseModels = try baseScanner.scan()
            adapters = try PlaygroundViewModel.scanAdapters(
                at: libraryRoot.appendingPathComponent("models/adapters", isDirectory: true)
            )
            if selectedBasePath == nil {
                selectedBasePath = baseModels.first?.localPath
            } else if let path = selectedBasePath,
                      !baseModels.contains(where: { $0.localPath == path })
            {
                selectedBasePath = baseModels.first?.localPath
            }
            if let path = selectedAdapterPath,
               !adapters.contains(where: { $0.localPath == path })
            {
                selectedAdapterPath = nil
            }
            if !talkEnabled {
                statusMessage = "ff.talkMode is off — Talk pane is disabled."
            } else if baseModels.isEmpty {
                statusMessage = "Install a base model (Models → Install fixture model) for Talk replies."
            } else {
                statusMessage =
                    "Hold Push-to-talk to speak. Release to run STT→LLM→TTS. New PTT barges in (stops TTS)."
            }
            syncCoordinatorConfig()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    var canPTT: Bool {
        talkEnabled && !isBusy && selectedBasePath != nil
    }

    var phaseLabel: String {
        switch phase {
        case .idle: return "Idle"
        case .requestingPermission: return "Requesting mic…"
        case .listening: return "Listening…"
        case .finalizingSTT: return "Transcribing…"
        case .generatingLLM: return "Thinking…"
        case .synthesizingTTS: return "Speaking…"
        case .playing: return "Playing…"
        case .error: return "Error"
        }
    }

    // MARK: - Push-to-talk

    func pttDown() {
        guard canPTT || isPTTDown else { return }
        isPTTDown = true
        errorMessage = nil
        tccDenied = false
        syncCoordinatorConfig()

        Task {
            do {
                try await coordinator.pushToTalkBegan()
                await refreshFromCoordinator()
                startPartialPolling()
            } catch let error as BAMError where error.code == .tccMicDenied {
                isPTTDown = false
                tccDenied = true
                errorMessage = MicPermissionMessaging.userMessage(for: .denied)
                await refreshFromCoordinator()
            } catch {
                isPTTDown = false
                errorMessage = error.localizedDescription
                await refreshFromCoordinator()
            }
        }
    }

    func pttUp() {
        guard isPTTDown else { return }
        isPTTDown = false
        stopPartialPolling()
        isBusy = true

        Task {
            defer { isBusy = false }
            do {
                let turn = try await coordinator.pushToTalkEnded()
                messages = await coordinator.messages
                lastTimestamps = turn.timestamps
                lastTTSProgress = turn.tts?.wasCancelled == true ? 0 : 1
                if turn.bargedIn {
                    statusMessage = "Barge-in: TTS stopped."
                } else if turn.userText.isEmpty {
                    statusMessage = "No speech detected."
                } else {
                    let sttMs = Int(turn.timestamps.sttMs ?? 0)
                    let llmMs = Int(turn.timestamps.llmMs ?? 0)
                    let ttsMs = Int(turn.timestamps.ttsMs ?? 0)
                    statusMessage =
                        "Turn ok — STT \(sttMs) ms · LLM \(llmMs) ms · TTS \(ttsMs) ms"
                }
                await refreshFromCoordinator()
            } catch let error as BAMError where error.code == .tccMicDenied {
                tccDenied = true
                errorMessage = MicPermissionMessaging.deniedMessage
                await refreshFromCoordinator()
            } catch is CancellationError {
                statusMessage = "Turn cancelled (barge-in)."
                await refreshFromCoordinator()
            } catch {
                errorMessage = error.localizedDescription
                await refreshFromCoordinator()
            }
        }
    }

    func clearTranscript() {
        Task {
            await coordinator.clearTranscript()
            messages = []
            partialTranscript = ""
            lastTimestamps = TalkStageTimestamps()
            lastTTSProgress = 0
            statusMessage = "Transcript cleared."
            errorMessage = nil
            tccDenied = false
            phase = .idle
        }
    }

    func openMicrophoneSettings() {
        NSWorkspace.shared.open(MicPermissionMessaging.systemSettingsMicrophoneURL)
    }

    // MARK: - Internals

    private func syncCoordinatorConfig() {
        let config = TalkCoordinatorConfig(
            language: "en",
            systemPrompt: systemPrompt,
            baseModelPath: selectedBasePath,
            adapterPath: selectedAdapterPath,
            adapterEnabled: adapterEnabled
        )
        Task {
            await coordinator.updateConfig(config)
        }
    }

    private func refreshFromCoordinator() async {
        phase = await coordinator.phase
        partialTranscript = await coordinator.partialTranscript
        messages = await coordinator.messages
        lastTimestamps = await coordinator.lastTimestamps
        lastTTSProgress = await coordinator.lastTTSProgress
    }

    private func startPartialPolling() {
        stopPartialPolling()
        partialTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await self.coordinator.refreshPartial()
                await self.refreshFromCoordinator()
            }
        }
    }

    private func stopPartialPolling() {
        partialTimer?.invalidate()
        partialTimer = nil
    }
}
