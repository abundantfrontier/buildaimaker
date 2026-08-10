import Foundation

/// Result of a speech-to-text finalize (or one-shot transcribe).
public struct STTResult: Sendable, Equatable {
    public var text: String
    public var backendId: String
    /// Wall-clock latency in milliseconds (best-effort).
    public var latencyMs: Double
    /// True for stub/fake paths (CI-safe).
    public var isStub: Bool
    /// Optional partials captured during the streaming session.
    public var partials: [String]

    public init(
        text: String,
        backendId: String,
        latencyMs: Double = 0,
        isStub: Bool = false,
        partials: [String] = []
    ) {
        self.text = text
        self.backendId = backendId
        self.latencyMs = latencyMs
        self.isStub = isStub
        self.partials = partials
    }
}

/// Active streaming STT session (PTT hold).
///
/// Design sequence: `startStreamingSession` → partial transcripts → `finalize` on release.
public protocol STTStreamingSession: Sendable {
    /// Latest partial transcript (empty until first partial).
    var currentPartial: String { get async }
    /// Finalizes the utterance and returns the full transcript.
    func finalize() async throws -> STTResult
    /// Abandons the session without a final transcript.
    func cancel() async
}

/// Composable speech-to-text backend (K17). Talk mode primary consumer.
public protocol STTBackend: Sendable {
    /// Stable backend identifier (e.g. `fake-stt`, `whisper-cpp`).
    var backendId: String { get }

    /// Begin a streaming capture session for push-to-talk.
    ///
    /// - Parameter language: BCP-47-ish language hint (`en`, `en-US`, …).
    func startStreamingSession(language: String) async throws -> any STTStreamingSession
}
