import Foundation

/// CI-safe TTS: writes a short silent WAV (or no-op) and reports progress.
///
/// Honour `Task` cancellation and `stop()` for barge-in testing.
public final class FakeTTSBackend: TTSBackend, @unchecked Sendable {
    public static let id = "fake-tts"

    public var backendId: String { Self.id }

    /// When true, write a minimal silent WAV under temp / request output dir.
    public var writeSilentWav: Bool
    /// Simulated synthesis duration for progress + barge-in races (ms).
    public var simulatedLatencyMs: Double
    /// Sample count for silent WAV (16-bit mono 16 kHz).
    public var silentSampleCount: Int

    private let lock = NSLock()
    private var stopped = false

    public init(
        writeSilentWav: Bool = true,
        simulatedLatencyMs: Double = 0,
        silentSampleCount: Int = 1600
    ) {
        self.writeSilentWav = writeSilentWav
        self.simulatedLatencyMs = simulatedLatencyMs
        self.silentSampleCount = max(1, silentSampleCount)
    }

    public func synthesize(
        _ request: TTSRequest,
        progress: TTSProgressHandler?
    ) async throws -> TTSResult {
        let start = Date()
        resetStopped()

        let trimmed = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            progress?(1)
            return TTSResult(
                audioURL: nil,
                backendId: backendId,
                latencyMs: 0,
                isStub: true,
                wasCancelled: false,
                detail: "empty text"
            )
        }

        // Multi-step progress so barge-in can interrupt mid-synthesis.
        let steps = max(1, Int(simulatedLatencyMs / 20))
        if simulatedLatencyMs > 0 {
            for i in 0..<steps {
                try Task.checkCancellation()
                if isStopped() {
                    progress?(Double(i) / Double(steps))
                    return cancelledResult(start: start, progress: Double(i) / Double(steps))
                }
                let ns = UInt64((simulatedLatencyMs / Double(steps)) * 1_000_000)
                try await Task.sleep(nanoseconds: ns)
                progress?(Double(i + 1) / Double(steps))
            }
        } else {
            progress?(0.5)
            try Task.checkCancellation()
            if isStopped() {
                return cancelledResult(start: start, progress: 0.5)
            }
            progress?(1)
        }

        try Task.checkCancellation()
        if isStopped() {
            return cancelledResult(start: start, progress: 1)
        }

        var audioURL: URL?
        var detail = "noop"
        if writeSilentWav {
            let dir = request.outputDirectory
                ?? FileManager.default.temporaryDirectory
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("fake-tts-\(UUID().uuidString).wav")
            try Self.writeSilentWAV(to: url, sampleCount: silentSampleCount)
            audioURL = url
            detail = "silent-wav samples=\(silentSampleCount)"
        }

        let elapsed = Date().timeIntervalSince(start) * 1000
        return TTSResult(
            audioURL: audioURL,
            backendId: backendId,
            latencyMs: max(elapsed, simulatedLatencyMs),
            isStub: true,
            wasCancelled: false,
            detail: detail
        )
    }

    public func stop() async {
        lock.lock()
        stopped = true
        lock.unlock()
    }

    // MARK: - Helpers

    private func resetStopped() {
        lock.lock()
        stopped = false
        lock.unlock()
    }

    private func isStopped() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    private func cancelledResult(start: Date, progress: Double) -> TTSResult {
        let elapsed = Date().timeIntervalSince(start) * 1000
        return TTSResult(
            audioURL: nil,
            backendId: backendId,
            latencyMs: elapsed,
            isStub: true,
            wasCancelled: true,
            detail: "cancelled at progress=\(String(format: "%.2f", progress))"
        )
    }

    /// Minimal 16-bit PCM mono 16 kHz silent WAV.
    public static func writeSilentWAV(to url: URL, sampleCount: Int) throws {
        let numChannels: UInt16 = 1
        let sampleRate: UInt32 = 16_000
        let bitsPerSample: UInt16 = 16
        let byteRate = sampleRate * UInt32(numChannels) * UInt32(bitsPerSample / 8)
        let blockAlign = numChannels * (bitsPerSample / 8)
        let dataSize = UInt32(sampleCount) * UInt32(blockAlign)

        var data = Data()
        func appendASCII(_ s: String) {
            data.append(contentsOf: s.utf8)
        }
        func appendU16(_ v: UInt16) {
            var le = v.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }
        func appendU32(_ v: UInt32) {
            var le = v.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }

        appendASCII("RIFF")
        appendU32(36 + dataSize)
        appendASCII("WAVE")
        appendASCII("fmt ")
        appendU32(16) // PCM chunk size
        appendU16(1) // PCM format
        appendU16(numChannels)
        appendU32(sampleRate)
        appendU32(byteRate)
        appendU16(blockAlign)
        appendU16(bitsPerSample)
        appendASCII("data")
        appendU32(dataSize)
        data.append(Data(count: Int(dataSize))) // silence

        try data.write(to: url, options: .atomic)
    }
}
