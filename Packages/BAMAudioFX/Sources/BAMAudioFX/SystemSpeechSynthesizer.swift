import AVFoundation
import Foundation

/// Captures system TTS (AVSpeechSynthesizer) into mono float samples for creature FX.
public enum SystemSpeechSynthesizer: Sendable {
    public struct SpeechAudio: Sendable {
        public var samples: [Float]
        public var sampleRate: Double

        public init(samples: [Float], sampleRate: Double) {
            self.samples = samples
            self.sampleRate = sampleRate
        }
    }

    /// Synthesize `text` offline into PCM samples via `AVSpeechSynthesizer.write`.
    public static func synthesize(
        text: String,
        language: String = "en-US",
        rate: Float = AVSpeechUtteranceDefaultSpeechRate
    ) async throws -> SpeechAudio {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw CreatureFXError.emptySpeechText
        }

        return try await withCheckedThrowingContinuation { continuation in
            // AVSpeechSynthesizer must be retained until write completes.
            let box = SynthesizerBox()
            box.continuation = continuation

            let utterance = AVSpeechUtterance(string: trimmed)
            utterance.rate = min(
                AVSpeechUtteranceMaximumSpeechRate,
                max(AVSpeechUtteranceMinimumSpeechRate, rate)
            )
            utterance.pitchMultiplier = 1.0
            if let voice = AVSpeechSynthesisVoice(language: language) {
                utterance.voice = voice
            } else if let any = AVSpeechSynthesisVoice.speechVoices().first {
                utterance.voice = any
            }

            // BufferCallback takes non-optional AVAudioBuffer; frameLength 0 signals completion.
            box.synthesizer.write(utterance) { buffer in
                if box.finished { return }
                guard let pcm = buffer as? AVAudioPCMBuffer else {
                    box.finish(throwing: CreatureFXError.ttsProducedNoAudio)
                    return
                }
                let n = Int(pcm.frameLength)
                if n == 0 {
                    box.finish(throwing: nil)
                    return
                }
                guard let channel = pcm.floatChannelData?[0] else { return }
                box.sampleRate = pcm.format.sampleRate
                box.samples.reserveCapacity(box.samples.count + n)
                for i in 0..<n {
                    box.samples.append(channel[i])
                }
            }
        }
    }
}

/// Holds synthesizer + continuation for the write callback lifetime.
private final class SynthesizerBox: @unchecked Sendable {
    let synthesizer = AVSpeechSynthesizer()
    var continuation: CheckedContinuation<SystemSpeechSynthesizer.SpeechAudio, Error>?
    var samples: [Float] = []
    var sampleRate: Double = 22_050
    var finished = false

    func finish(throwing error: Error?) {
        guard !finished else { return }
        finished = true
        if let error, samples.isEmpty {
            continuation?.resume(throwing: error)
        } else if samples.isEmpty {
            continuation?.resume(throwing: CreatureFXError.ttsProducedNoAudio)
        } else {
            continuation?.resume(
                returning: SystemSpeechSynthesizer.SpeechAudio(
                    samples: samples,
                    sampleRate: sampleRate
                )
            )
        }
        continuation = nil
    }
}

public enum CreatureFXError: Error, LocalizedError, Sendable {
    case emptySpeechText
    case ttsProducedNoAudio
    case invalidSampleRate

    public var errorDescription: String? {
        switch self {
        case .emptySpeechText: return "Nothing to speak for voice preview."
        case .ttsProducedNoAudio: return "System TTS produced no audio."
        case .invalidSampleRate: return "Invalid audio sample rate."
        }
    }
}
