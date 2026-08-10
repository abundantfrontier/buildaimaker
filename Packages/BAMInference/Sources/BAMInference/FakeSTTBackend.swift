import Foundation

/// CI-safe STT that returns fixed text — no microphone, no models.
///
/// Used in unit tests and when a real STT engine is unavailable.
public struct FakeSTTBackend: STTBackend, Sendable {
    public static let id = "fake-stt"

    public var backendId: String { Self.id }

    /// Deterministic transcript returned on finalize.
    public var fixedTranscript: String
    /// Optional simulated wall time before finalize returns.
    public var simulatedLatencyMs: Double
    /// Partials emitted before finalize (for UI plumbing tests).
    public var partials: [String]

    public init(
        fixedTranscript: String = "Hello from Talk mode",
        simulatedLatencyMs: Double = 0,
        partials: [String] = ["Hello", "Hello from", "Hello from Talk mode"]
    ) {
        self.fixedTranscript = fixedTranscript
        self.simulatedLatencyMs = simulatedLatencyMs
        self.partials = partials
    }

    public func startStreamingSession(language: String) async throws -> any STTStreamingSession {
        FakeSTTStreamingSession(
            fixedTranscript: fixedTranscript,
            simulatedLatencyMs: simulatedLatencyMs,
            partials: partials,
            language: language,
            backendId: backendId
        )
    }
}

/// In-memory streaming session for `FakeSTTBackend`.
public actor FakeSTTStreamingSession: STTStreamingSession {
    private let fixedTranscript: String
    private let simulatedLatencyMs: Double
    private let seedPartials: [String]
    private let language: String
    private let backendId: String
    private var cancelled = false
    private var partialIndex = 0
    private var lastPartial = ""
    private let start = Date()

    public init(
        fixedTranscript: String,
        simulatedLatencyMs: Double,
        partials: [String],
        language: String,
        backendId: String
    ) {
        self.fixedTranscript = fixedTranscript
        self.simulatedLatencyMs = simulatedLatencyMs
        self.seedPartials = partials
        self.language = language
        self.backendId = backendId
    }

    public var currentPartial: String {
        lastPartial
    }

    /// Advance to the next canned partial (tests / UI demo without real audio).
    public func emitNextPartial() {
        guard !cancelled else { return }
        if partialIndex < seedPartials.count {
            lastPartial = seedPartials[partialIndex]
            partialIndex += 1
        } else {
            lastPartial = fixedTranscript
        }
    }

    public func finalize() async throws -> STTResult {
        guard !cancelled else {
            throw CancellationError()
        }
        // Emit remaining partials so `partials` in the result is useful.
        var captured = seedPartials
        if captured.isEmpty {
            captured = [fixedTranscript]
        }
        lastPartial = fixedTranscript

        if simulatedLatencyMs > 0 {
            let ns = UInt64(simulatedLatencyMs * 1_000_000)
            try await Task.sleep(nanoseconds: ns)
        }
        try Task.checkCancellation()
        guard !cancelled else {
            throw CancellationError()
        }

        let elapsed = Date().timeIntervalSince(start) * 1000
        return STTResult(
            text: fixedTranscript,
            backendId: backendId,
            latencyMs: max(elapsed, simulatedLatencyMs),
            isStub: true,
            partials: captured
        )
    }

    public func cancel() async {
        cancelled = true
    }
}
