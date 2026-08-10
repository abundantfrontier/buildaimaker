import Foundation

/// Resolves Talk-mode STT / TTS backends (CI-safe fakes by default).
public enum TalkBackendFactory: Sendable {
    /// Default STT: fake fixed-transcript (real whisper/MLX-Whisper later).
    public static func makeSTT(forceFake: Bool = true) -> any STTBackend {
        // v1 ships fake STT for CI safety; forceFake kept for API symmetry.
        _ = forceFake
        return FakeSTTBackend()
    }

    /// Default TTS: fake silent WAV with progress (F5 path later via voice profile).
    public static func makeTTS(
        forceFake: Bool = true,
        writeSilentWav: Bool = true
    ) -> any TTSBackend {
        _ = forceFake
        return FakeTTSBackend(writeSilentWav: writeSilentWav)
    }

    /// Bundle of CI-safe backends + authorized mic for unit tests.
    public static func makeFakeStack(
        fixedTranscript: String = "Hello from Talk mode",
        llm: (any LLMBackend)? = nil
    ) -> (
        stt: any STTBackend,
        llm: any LLMBackend,
        tts: any TTSBackend,
        mic: any MicPermissionChecking
    ) {
        (
            FakeSTTBackend(fixedTranscript: fixedTranscript),
            llm ?? EchoLLMBackend(),
            FakeTTSBackend(writeSilentWav: true, simulatedLatencyMs: 0),
            FakeMicPermission(current: .authorized)
        )
    }
}
