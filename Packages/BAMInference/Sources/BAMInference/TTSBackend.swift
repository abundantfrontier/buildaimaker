import Foundation

/// Request for text-to-speech synthesis.
public struct TTSRequest: Sendable, Equatable {
    public var text: String
    /// Absolute path to a voice profile directory (F5-TTS artifact), if any.
    public var voiceProfilePath: String?
    /// Optional directory for written audio files (defaults to temp).
    public var outputDirectory: URL?

    public init(
        text: String,
        voiceProfilePath: String? = nil,
        outputDirectory: URL? = nil
    ) {
        self.text = text
        self.voiceProfilePath = voiceProfilePath
        self.outputDirectory = outputDirectory
    }
}

/// Result of a TTS synthesize call.
public struct TTSResult: Sendable, Equatable {
    /// Path to written audio (WAV) when produced; nil for pure no-op stubs.
    public var audioURL: URL?
    public var backendId: String
    public var latencyMs: Double
    public var isStub: Bool
    /// True when synthesis was stopped mid-flight (barge-in).
    public var wasCancelled: Bool
    /// Optional diagnostic (sample rate, bytes written, …).
    public var detail: String?

    public init(
        audioURL: URL? = nil,
        backendId: String,
        latencyMs: Double = 0,
        isStub: Bool = false,
        wasCancelled: Bool = false,
        detail: String? = nil
    ) {
        self.audioURL = audioURL
        self.backendId = backendId
        self.latencyMs = latencyMs
        self.isStub = isStub
        self.wasCancelled = wasCancelled
        self.detail = detail
    }
}

/// Progress callback for TTS (0…1). Called on cooperative backends.
public typealias TTSProgressHandler = @Sendable (Double) -> Void

/// Composable text-to-speech backend (K17). Talk mode primary consumer.
public protocol TTSBackend: Sendable {
    /// Stable backend identifier (e.g. `fake-tts`, `f5-tts`).
    var backendId: String { get }

    /// Synthesize speech for `request`. Honour `Task` cancellation for barge-in.
    func synthesize(
        _ request: TTSRequest,
        progress: TTSProgressHandler?
    ) async throws -> TTSResult

    /// Cooperative stop for barge-in (v1: new PTT stops TTS).
    ///
    /// Default implementations may rely solely on task cancellation; this method
    /// allows backends that hold external processes to tear down eagerly.
    func stop() async
}

extension TTSBackend {
    /// Convenience without progress.
    public func synthesize(_ request: TTSRequest) async throws -> TTSResult {
        try await synthesize(request, progress: nil)
    }
}
