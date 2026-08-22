import AVFoundation
import Foundation

/// Captures system TTS into mono float samples for creature FX.
///
/// Strategy (in order):
/// 1. `AVSpeechSynthesizer.write` (float/int16 buffers)
/// 2. macOS `/usr/bin/say -o file.aiff` then load samples
public enum SystemSpeechSynthesizer: Sendable {
    public struct SpeechAudio: Sendable {
        public var samples: [Float]
        public var sampleRate: Double

        public init(samples: [Float], sampleRate: Double) {
            self.samples = samples
            self.sampleRate = sampleRate
        }
    }

    /// Synthesize `text` into PCM samples.
    public static func synthesize(
        text: String,
        language: String = "en-US",
        rate: Float = AVSpeechUtteranceDefaultSpeechRate * 0.92,
        voiceHint: SpeechVoiceHint = .male,
        pitchMultiplier: Float = 1.0
    ) async throws -> SpeechAudio {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw CreatureFXError.emptySpeechText
        }

        let clamped = Double(max(0.28, min(0.82, rate)))
        let wpm = Int(90 + (clamped - 0.28) / 0.54 * 210)
        if let viaSay = try? await synthesizeWithSay(
            text: trimmed,
            rateWPM: wpm,
            voiceHint: voiceHint
        ) {
            return viaSay
        }

        return try await synthesizeWithAVSpeech(
            text: trimmed,
            language: language,
            rate: rate,
            voiceHint: voiceHint,
            pitchMultiplier: pitchMultiplier
        )
    }

    // MARK: - macOS `say`

    /// `/usr/bin/say -o out.aiff "…"` then decode with AVAudioFile.
    public static func synthesizeWithSay(
        text: String,
        rateWPM: Int = 175,
        voiceHint: SpeechVoiceHint = .male
    ) async throws -> SpeechAudio {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let audio = try synthesizeWithSaySync(
                        text: text,
                        rateWPM: rateWPM,
                        voiceName: resolveSayVoice(hint: voiceHint)
                    )
                    continuation.resume(returning: audio)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func synthesizeWithSaySync(
        text: String,
        rateWPM: Int,
        voiceName: String?
    ) throws -> SpeechAudio {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("bam-say-\(UUID().uuidString).aiff")
        defer { try? FileManager.default.removeItem(at: tmp) }

        var args = ["-r", String(max(90, min(320, rateWPM))), "-o", tmp.path]
        if let voiceName, !voiceName.isEmpty {
            args.insert(contentsOf: ["-v", voiceName], at: 0)
        }
        args.append(text)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = args
        process.standardError = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              FileManager.default.fileExists(atPath: tmp.path)
        else {
            throw CreatureFXError.ttsProducedNoAudio
        }
        return try loadAudioFile(url: tmp)
    }

    /// Decode any AVAudioFile-readable URL into mono float samples.
    public static func loadAudioFile(url: URL) throws -> SpeechAudio {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
        else {
            throw CreatureFXError.ttsProducedNoAudio
        }
        try file.read(into: buffer)
        let samples = extractMonoFloat(from: buffer)
        guard !samples.isEmpty else { throw CreatureFXError.ttsProducedNoAudio }
        return SpeechAudio(samples: samples, sampleRate: format.sampleRate)
    }

    // MARK: - AVSpeechSynthesizer

    public static func synthesizeWithAVSpeech(
        text: String,
        language: String,
        rate: Float,
        voiceHint: SpeechVoiceHint = .male,
        pitchMultiplier: Float = 1.0
    ) async throws -> SpeechAudio {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.main.async {
                let box = SynthesizerBox()
                box.continuation = continuation

                let utterance = AVSpeechUtterance(string: text)
                utterance.rate = min(
                    AVSpeechUtteranceMaximumSpeechRate,
                    max(AVSpeechUtteranceMinimumSpeechRate, rate)
                )
                utterance.pitchMultiplier = min(1.35, max(0.7, pitchMultiplier))
                utterance.volume = 1.0
                utterance.voice = preferredVoice(language: language, hint: voiceHint)

                box.synthesizer.write(utterance) { buffer in
                    if box.finished { return }
                    guard let pcm = buffer as? AVAudioPCMBuffer else {
                        if !box.samples.isEmpty { box.finish(throwing: nil) }
                        return
                    }
                    let n = Int(pcm.frameLength)
                    if n == 0 {
                        box.finish(throwing: nil)
                        return
                    }
                    box.sampleRate = pcm.format.sampleRate
                    let mono = extractMonoFloat(from: pcm)
                    if !mono.isEmpty {
                        box.samples.append(contentsOf: mono)
                    }
                }
            }
        }
    }

    private static func preferredVoice(
        language: String,
        hint: SpeechVoiceHint
    ) -> AVSpeechSynthesisVoice? {
        let voices = AVSpeechSynthesisVoice.speechVoices()
        let langVoices = voices.filter {
            $0.language.lowercased().hasPrefix(language.prefix(2).lowercased())
        }
        let pool = langVoices.isEmpty ? voices : langVoices
        let names = hint.preferredNameFragments
        if let named = pool.first(where: { voice in
            let n = voice.name.lowercased()
            return names.contains { n.contains($0) }
        }) {
            return named
        }
        switch hint {
        case .deepMale, .male, .noveltyRobot:
            if let male = pool.first(where: { $0.gender == .male }) { return male }
        case .female, .whisper:
            if let female = pool.first(where: { $0.gender == .female }) { return female }
        case .child:
            if let child = pool.first(where: {
                $0.name.localizedCaseInsensitiveContains("junior")
                    || $0.name.localizedCaseInsensitiveContains("princess")
                    || $0.name.localizedCaseInsensitiveContains("kathy")
            }) {
                return child
            }
            if let female = pool.first(where: { $0.gender == .female }) { return female }
        case .sultry:
            if let female = pool.first(where: { $0.gender == .female && $0.quality == .enhanced }) {
                return female
            }
            if let female = pool.first(where: { $0.gender == .female }) { return female }
        }
        return pool.first(where: { $0.quality == .enhanced }) ?? pool.first
    }

    private static let sayVoiceLock = NSLock()
    private static var cachedSayVoices: [String]?

    /// Installed `say -v` names, e.g. "Alex", "Samantha", "Zarvox".
    public static func installedSayVoiceNames() -> [String] {
        sayVoiceLock.lock()
        if let cachedSayVoices {
            sayVoiceLock.unlock()
            return cachedSayVoices
        }
        sayVoiceLock.unlock()
        let names = listSayVoices()
        sayVoiceLock.lock()
        cachedSayVoices = names
        sayVoiceLock.unlock()
        return names
    }

    public static func resolveSayVoice(hint: SpeechVoiceHint) -> String? {
        let installed = installedSayVoiceNames()
        for candidate in hint.preferredSayNames {
            if installed.contains(where: { $0.caseInsensitiveCompare(candidate) == .orderedSame }) {
                return candidate
            }
        }
        return nil
    }

    private static func listSayVoices() -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-v", "?"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let text = String(data: data, encoding: .utf8) ?? ""
            return text.split(whereSeparator: \.isNewline).compactMap { line in
                let name = line.split(separator: " ").first.map(String.init) ?? ""
                return name.isEmpty ? nil : name
            }
        } catch {
            return []
        }
    }

    /// Extract mono float samples from a PCM buffer (float32 / int16 / int32).
    public static func extractMonoFloat(from pcm: AVAudioPCMBuffer) -> [Float] {
        let n = Int(pcm.frameLength)
        guard n > 0 else { return [] }
        let channels = max(1, Int(pcm.format.channelCount))

        if let floatPlanes = pcm.floatChannelData {
            var out = [Float](repeating: 0, count: n)
            if channels <= 1 {
                for i in 0..<n { out[i] = floatPlanes[0][i] }
            } else {
                for i in 0..<n {
                    var sum: Float = 0
                    for c in 0..<channels { sum += floatPlanes[c][i] }
                    out[i] = sum / Float(channels)
                }
            }
            return out
        }

        if let int16Planes = pcm.int16ChannelData {
            var out = [Float](repeating: 0, count: n)
            let scale = 1.0 / Float(Int16.max)
            if channels <= 1 {
                for i in 0..<n { out[i] = Float(int16Planes[0][i]) * scale }
            } else {
                for i in 0..<n {
                    var sum: Float = 0
                    for c in 0..<channels {
                        sum += Float(int16Planes[c][i]) * scale
                    }
                    out[i] = sum / Float(channels)
                }
            }
            return out
        }

        if let int32Planes = pcm.int32ChannelData {
            var out = [Float](repeating: 0, count: n)
            let scale = 1.0 / Float(Int32.max)
            for i in 0..<n {
                out[i] = Float(int32Planes[0][i]) * scale
            }
            return out
        }

        return []
    }
}

private final class SynthesizerBox: @unchecked Sendable {
    let synthesizer = AVSpeechSynthesizer()
    var continuation: CheckedContinuation<SystemSpeechSynthesizer.SpeechAudio, Error>?
    var samples: [Float] = []
    var sampleRate: Double = 22_050
    var finished = false

    func finish(throwing error: Error?) {
        guard !finished else { return }
        finished = true
        if samples.isEmpty {
            continuation?.resume(throwing: error ?? CreatureFXError.ttsProducedNoAudio)
        } else {
            let trimmed = Self.trimSilence(samples)
            continuation?.resume(
                returning: SystemSpeechSynthesizer.SpeechAudio(
                    samples: trimmed.isEmpty ? samples : trimmed,
                    sampleRate: sampleRate
                )
            )
        }
        continuation = nil
    }

    private static func trimSilence(_ input: [Float], threshold: Float = 0.01) -> [Float] {
        guard let first = input.firstIndex(where: { abs($0) > threshold }),
              let last = input.lastIndex(where: { abs($0) > threshold }),
              first <= last
        else { return input }
        let pad = min(240, first)
        let start = max(0, first - pad)
        return Array(input[start...last])
    }
}

public enum CreatureFXError: Error, LocalizedError, Sendable {
    case emptySpeechText
    case ttsProducedNoAudio
    case invalidSampleRate
    case catalogUnavailable

    public var errorDescription: String? {
        switch self {
        case .emptySpeechText: return "Nothing to speak for voice preview."
        case .ttsProducedNoAudio: return "System TTS produced no audio."
        case .invalidSampleRate: return "Invalid audio sample rate."
        case .catalogUnavailable: return "Character voice catalog is not ready."
        }
    }
}
