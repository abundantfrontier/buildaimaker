import Foundation
import BAMCore

/// Phase of a Talk-mode turn (UI binding).
public enum TalkPhase: String, Sendable, Equatable, CaseIterable {
    case idle
    case requestingPermission
    case listening
    case finalizingSTT
    case generatingLLM
    case synthesizingTTS
    case playing
    case error
}

/// Stage timestamps for a single Talk turn (playground_trace style, ms).
public struct TalkStageTimestamps: Sendable, Equatable {
    public var permissionMs: Double?
    public var sttMs: Double?
    public var llmMs: Double?
    public var ttsMs: Double?
    public var totalMs: Double?

    public init(
        permissionMs: Double? = nil,
        sttMs: Double? = nil,
        llmMs: Double? = nil,
        ttsMs: Double? = nil,
        totalMs: Double? = nil
    ) {
        self.permissionMs = permissionMs
        self.sttMs = sttMs
        self.llmMs = llmMs
        self.ttsMs = ttsMs
        self.totalMs = totalMs
    }
}

/// Result of one Talk turn: STT → LLM → TTS (or early exit on barge-in / error).
public struct TalkTurnResult: Sendable, Equatable {
    public var userText: String
    public var assistantText: String
    public var stt: STTResult?
    public var llm: LLMCompletionResult?
    public var tts: TTSResult?
    public var timestamps: TalkStageTimestamps
    public var bargedIn: Bool
    public var phase: TalkPhase

    public init(
        userText: String = "",
        assistantText: String = "",
        stt: STTResult? = nil,
        llm: LLMCompletionResult? = nil,
        tts: TTSResult? = nil,
        timestamps: TalkStageTimestamps = TalkStageTimestamps(),
        bargedIn: Bool = false,
        phase: TalkPhase = .idle
    ) {
        self.userText = userText
        self.assistantText = assistantText
        self.stt = stt
        self.llm = llm
        self.tts = tts
        self.timestamps = timestamps
        self.bargedIn = bargedIn
        self.phase = phase
    }
}

/// Configuration for Talk mode coordinator.
public struct TalkCoordinatorConfig: Sendable, Equatable {
    public var language: String
    public var systemPrompt: String
    public var baseModelPath: String?
    public var adapterPath: String?
    public var adapterEnabled: Bool
    public var templateId: String
    public var voiceProfilePath: String?
    public var ttsOutputDirectory: URL?

    public init(
        language: String = "en",
        systemPrompt: String = "",
        baseModelPath: String? = nil,
        adapterPath: String? = nil,
        adapterEnabled: Bool = true,
        templateId: String = ChatPromptFormatter.chatML,
        voiceProfilePath: String? = nil,
        ttsOutputDirectory: URL? = nil
    ) {
        self.language = language
        self.systemPrompt = systemPrompt
        self.baseModelPath = baseModelPath
        self.adapterPath = adapterPath
        self.adapterEnabled = adapterEnabled
        self.templateId = templateId
        self.voiceProfilePath = voiceProfilePath
        self.ttsOutputDirectory = ttsOutputDirectory
    }
}

/// Coordinates Talk mode: permissions → STT session → LLM → TTS.
///
/// Barge-in v1: a new PTT (or explicit `bargeIn()`) stops TTS; LLM mid-gen is
/// not cancelled. Thread-safe via an actor so UI + tests can share one instance.
public actor TalkCoordinator {
    public private(set) var phase: TalkPhase = .idle
    public private(set) var messages: [InferenceChatMessage] = []
    public private(set) var lastTimestamps: TalkStageTimestamps = TalkStageTimestamps()
    public private(set) var lastError: BAMError?
    public private(set) var partialTranscript: String = ""
    public private(set) var lastTTSProgress: Double = 0

    private let stt: any STTBackend
    private let llm: any LLMBackend
    private let tts: any TTSBackend
    private let mic: any MicPermissionChecking

    private var config: TalkCoordinatorConfig
    private var activeSTT: (any STTStreamingSession)?
    private var ttsTask: Task<TTSResult, Error>?
    private var turnStartedAt: Date?

    public init(
        stt: any STTBackend,
        llm: any LLMBackend,
        tts: any TTSBackend,
        mic: any MicPermissionChecking = FakeMicPermission(),
        config: TalkCoordinatorConfig = TalkCoordinatorConfig()
    ) {
        self.stt = stt
        self.llm = llm
        self.tts = tts
        self.mic = mic
        self.config = config
    }

    public func updateConfig(_ config: TalkCoordinatorConfig) {
        self.config = config
    }

    public func clearTranscript() {
        messages = []
        lastTimestamps = TalkStageTimestamps()
        lastError = nil
        partialTranscript = ""
        lastTTSProgress = 0
        phase = .idle
    }

    // MARK: - Permission

    /// Ensure microphone is usable. Throws `BAM_TCC_MIC_DENIED` on failure.
    @discardableResult
    public func ensureMicrophonePermission() async throws -> MicPermissionStatus {
        phase = .requestingPermission
        let t0 = Date()
        var status = await mic.status()
        if status == .notDetermined {
            status = await mic.requestAccess()
        }
        let elapsed = Date().timeIntervalSince(t0) * 1000
        var ts = lastTimestamps
        ts.permissionMs = elapsed
        lastTimestamps = ts

        guard status.isUsable else {
            phase = .error
            let err = MicPermissionMessaging.error(for: status)
            lastError = err
            throw err
        }
        phase = .idle
        return status
    }

    // MARK: - Push-to-talk

    /// PTT down: barge-in any active TTS, then start STT streaming.
    public func pushToTalkBegan() async throws {
        // Barge-in: stop TTS on new PTT (design sequence note).
        await bargeIn()

        try await ensureMicrophonePermission()

        turnStartedAt = Date()
        lastError = nil
        partialTranscript = ""
        lastTTSProgress = 0
        phase = .listening

        let session = try await stt.startStreamingSession(language: config.language)
        activeSTT = session
    }

    /// Optional: UI may poll/update partials while PTT is held.
    public func refreshPartial() async {
        guard let session = activeSTT else { return }
        partialTranscript = await session.currentPartial
        // Drive fake partials when the session supports it.
        if let fake = session as? FakeSTTStreamingSession {
            await fake.emitNextPartial()
            partialTranscript = await fake.currentPartial
        }
    }

    /// PTT up: finalize STT → LLM → TTS. Returns the completed turn (or barged TTS).
    @discardableResult
    public func pushToTalkEnded() async throws -> TalkTurnResult {
        guard let session = activeSTT else {
            // No active listen — treat as no-op.
            return TalkTurnResult(phase: phase)
        }
        activeSTT = nil

        phase = .finalizingSTT
        let sttStart = Date()
        let sttResult: STTResult
        do {
            sttResult = try await session.finalize()
        } catch {
            phase = .error
            lastError = BAMError(code: .workerCrash, message: error.localizedDescription)
            throw error
        }
        let sttMs = Date().timeIntervalSince(sttStart) * 1000
        partialTranscript = sttResult.text

        let userText = sttResult.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !userText.isEmpty else {
            phase = .idle
            var empty = TalkTurnResult(
                userText: "",
                stt: sttResult,
                timestamps: TalkStageTimestamps(sttMs: sttMs),
                phase: .idle
            )
            empty.timestamps.permissionMs = lastTimestamps.permissionMs
            lastTimestamps = empty.timestamps
            return empty
        }

        messages.append(.user(userText))

        // LLM
        phase = .generatingLLM
        let llmStart = Date()
        let forCompletion = ChatPromptFormatter.messagesForCompletion(
            history: messages,
            systemOverride: config.systemPrompt.isEmpty ? nil : config.systemPrompt
        )
        let request = LLMCompletionRequest(
            messages: forCompletion,
            baseModelPath: config.baseModelPath,
            adapterPath: config.adapterPath,
            adapterEnabled: config.adapterEnabled,
            templateId: config.templateId
        )
        let llmResult: LLMCompletionResult
        do {
            llmResult = try await llm.complete(request)
        } catch {
            phase = .error
            lastError = BAMError(code: .workerCrash, message: error.localizedDescription)
            throw error
        }
        let llmMs = Date().timeIntervalSince(llmStart) * 1000
        messages.append(llmResult.assistantMessage)
        let assistantText = llmResult.assistantMessage.content

        // TTS (cancellable for barge-in)
        phase = .synthesizingTTS
        lastTTSProgress = 0
        let ttsRequest = TTSRequest(
            text: assistantText,
            voiceProfilePath: config.voiceProfilePath,
            outputDirectory: config.ttsOutputDirectory
        )

        let ttsBackend = tts
        let progressBox = ProgressBox()
        let task = Task {
            try await ttsBackend.synthesize(ttsRequest) { p in
                progressBox.value = p
            }
        }
        ttsTask = task

        let ttsStart = Date()
        let ttsResult: TTSResult
        do {
            ttsResult = try await task.value
        } catch is CancellationError {
            await tts.stop()
            let ttsMs = Date().timeIntervalSince(ttsStart) * 1000
            let total = turnStartedAt.map { Date().timeIntervalSince($0) * 1000 }
            let timestamps = TalkStageTimestamps(
                permissionMs: lastTimestamps.permissionMs,
                sttMs: sttMs,
                llmMs: llmMs,
                ttsMs: ttsMs,
                totalMs: total
            )
            lastTimestamps = timestamps
            ttsTask = nil
            phase = .idle
            return TalkTurnResult(
                userText: userText,
                assistantText: assistantText,
                stt: sttResult,
                llm: llmResult,
                tts: TTSResult(
                    backendId: tts.backendId,
                    latencyMs: ttsMs,
                    isStub: true,
                    wasCancelled: true
                ),
                timestamps: timestamps,
                bargedIn: true,
                phase: .idle
            )
        } catch {
            ttsTask = nil
            phase = .error
            lastError = BAMError(code: .workerCrash, message: error.localizedDescription)
            throw error
        }
        ttsTask = nil
        lastTTSProgress = progressBox.value
        let ttsMs = Date().timeIntervalSince(ttsStart) * 1000

        let total = turnStartedAt.map { Date().timeIntervalSince($0) * 1000 }
        let timestamps = TalkStageTimestamps(
            permissionMs: lastTimestamps.permissionMs,
            sttMs: sttMs,
            llmMs: llmMs,
            ttsMs: ttsMs,
            totalMs: total
        )
        lastTimestamps = timestamps

        let barged = ttsResult.wasCancelled
        phase = barged ? .idle : .playing
        // "playing" is UI-owned; domain returns to idle immediately after synth in coordinator.
        if !barged {
            phase = .idle
        }

        return TalkTurnResult(
            userText: userText,
            assistantText: assistantText,
            stt: sttResult,
            llm: llmResult,
            tts: ttsResult,
            timestamps: timestamps,
            bargedIn: barged,
            phase: phase
        )
    }

    /// Barge-in: cancel in-flight TTS and any active STT session.
    public func bargeIn() async {
        if let task = ttsTask {
            task.cancel()
            ttsTask = nil
        }
        await tts.stop()
        if let session = activeSTT {
            await session.cancel()
            activeSTT = nil
        }
        if phase == .synthesizingTTS || phase == .playing || phase == .listening {
            phase = .idle
        }
        lastTTSProgress = 0
    }

    /// Run a full turn with an injected user text (skips STT audio; still records STT stage as stub).
    ///
    /// Useful for unit tests that assert the LLM→TTS half without streaming.
    @discardableResult
    public func runTurn(userText: String) async throws -> TalkTurnResult {
        try await ensureMicrophonePermission()
        turnStartedAt = Date()
        lastError = nil

        let trimmed = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return TalkTurnResult(phase: .idle)
        }

        // Synthetic STT result (bypass mic capture).
        let sttResult = STTResult(
            text: trimmed,
            backendId: stt.backendId,
            latencyMs: 0,
            isStub: true,
            partials: [trimmed]
        )
        messages.append(.user(trimmed))

        phase = .generatingLLM
        let llmStart = Date()
        let forCompletion = ChatPromptFormatter.messagesForCompletion(
            history: messages,
            systemOverride: config.systemPrompt.isEmpty ? nil : config.systemPrompt
        )
        let request = LLMCompletionRequest(
            messages: forCompletion,
            baseModelPath: config.baseModelPath,
            adapterPath: config.adapterPath,
            adapterEnabled: config.adapterEnabled,
            templateId: config.templateId
        )
        let llmResult = try await llm.complete(request)
        let llmMs = Date().timeIntervalSince(llmStart) * 1000
        messages.append(llmResult.assistantMessage)

        phase = .synthesizingTTS
        let ttsStart = Date()
        let ttsResult = try await tts.synthesize(
            TTSRequest(
                text: llmResult.assistantMessage.content,
                voiceProfilePath: config.voiceProfilePath,
                outputDirectory: config.ttsOutputDirectory
            )
        )
        let ttsMs = Date().timeIntervalSince(ttsStart) * 1000
        let total = turnStartedAt.map { Date().timeIntervalSince($0) * 1000 }
        let timestamps = TalkStageTimestamps(
            permissionMs: lastTimestamps.permissionMs,
            sttMs: 0,
            llmMs: llmMs,
            ttsMs: ttsMs,
            totalMs: total
        )
        lastTimestamps = timestamps
        phase = .idle

        return TalkTurnResult(
            userText: trimmed,
            assistantText: llmResult.assistantMessage.content,
            stt: sttResult,
            llm: llmResult,
            tts: ttsResult,
            timestamps: timestamps,
            bargedIn: ttsResult.wasCancelled,
            phase: .idle
        )
    }
}

/// Tiny box so progress can cross actor/Task boundaries without capturing self.
private final class ProgressBox: @unchecked Sendable {
    var value: Double = 0
}
