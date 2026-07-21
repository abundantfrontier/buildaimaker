import Foundation

/// Renders a short creature voice preview WAV using synthesis + FX (CS-3).
///
/// Preferred path: **system TTS → creature FX** so the preview speaks a line.
/// Fallback: speech-like buzz + textures when TTS is unavailable.
public enum CreatureFXRenderer {
    public struct RenderResult: Sendable {
        public var audioURL: URL
        public var profileURL: URL
        public var durationSeconds: Double
        /// True when system TTS provided the speech carrier.
        public var usedSystemTTS: Bool
        /// Line that was spoken (if any).
        public var spokenText: String?

        public init(
            audioURL: URL,
            profileURL: URL,
            durationSeconds: Double,
            usedSystemTTS: Bool = false,
            spokenText: String? = nil
        ) {
            self.audioURL = audioURL
            self.profileURL = profileURL
            self.durationSeconds = durationSeconds
            self.usedSystemTTS = usedSystemTTS
            self.spokenText = spokenText
        }
    }

    /// Engine id stored on voice profiles for buzz-only pipeline.
    public static let engineId = "creature-fx-v1"
    /// Engine id when system TTS is the speech source.
    public static let spokenEngineId = "creature-fx-tts-v1"

    /// Render **spoken** preview: system TTS of `speechText`, then creature FX.
    ///
    /// Falls back to buzz synthesis if TTS fails.
    public static func renderSpokenPreview(
        speechText: String,
        params: CreatureFXParams,
        characterName: String,
        outputDirectory: URL,
        fileManager: FileManager = .default
    ) async throws -> RenderResult {
        try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let targetRate: Double = 24_000
        let trimmed = speechText.trimmingCharacters(in: .whitespacesAndNewlines)

        if !trimmed.isEmpty,
           let speech = try? await SystemSpeechSynthesizer.synthesize(text: trimmed)
        {
            var samples = resample(speech.samples, from: speech.sampleRate, to: targetRate)
            // Size slider → pitch via resampling (higher size → higher pitch → shorter).
            samples = resample(samples, from: 1.0, to: 1.0 / params.pitchRate)
            applyGrit(&samples, grit: params.grit)
            applyAtmosphere(&samples, amount: params.atmosphere, sampleRate: targetRate)

            var mix = samples
            for texture in params.textures {
                let bed = synthesizeTexture(
                    texture,
                    sampleCount: mix.count,
                    sampleRate: targetRate
                )
                mix = mixLayers(speech: mix, texture: bed, textureGain: 0.18)
            }
            normalize(&mix, peak: 0.89)

            return try writeResult(
                samples: mix,
                sampleRate: targetRate,
                params: params,
                characterName: characterName,
                outputDirectory: outputDirectory,
                engineId: spokenEngineId,
                usedSystemTTS: true,
                spokenText: trimmed,
                fileManager: fileManager
            )
        }

        // Fallback buzz path.
        return try renderPreview(
            params: params,
            characterName: characterName,
            outputDirectory: outputDirectory,
            fileManager: fileManager
        )
    }

    /// Render buzz-only preview into `outputDirectory` (created if needed).
    public static func renderPreview(
        params: CreatureFXParams,
        characterName: String,
        outputDirectory: URL,
        fileManager: FileManager = .default
    ) throws -> RenderResult {
        try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let sampleRate: Double = 24_000
        let duration: Double = 1.6
        let n = Int(sampleRate * duration)

        var speech = synthesizeSpeechLike(
            sampleCount: n,
            sampleRate: sampleRate,
            pitchRate: params.pitchRate,
            grit: params.grit
        )
        applyAtmosphere(&speech, amount: params.atmosphere, sampleRate: sampleRate)

        var mix = speech
        for texture in params.textures {
            let bed = synthesizeTexture(
                texture,
                sampleCount: n,
                sampleRate: sampleRate
            )
            // Duck texture under speech envelope.
            mix = mixLayers(speech: mix, texture: bed, textureGain: 0.22)
        }

        normalize(&mix, peak: 0.89)

        return try writeResult(
            samples: mix,
            sampleRate: sampleRate,
            params: params,
            characterName: characterName,
            outputDirectory: outputDirectory,
            engineId: engineId,
            usedSystemTTS: false,
            spokenText: nil,
            fileManager: fileManager
        )
    }

    private static func writeResult(
        samples: [Float],
        sampleRate: Double,
        params: CreatureFXParams,
        characterName: String,
        outputDirectory: URL,
        engineId: String,
        usedSystemTTS: Bool,
        spokenText: String?,
        fileManager: FileManager
    ) throws -> RenderResult {
        let audioURL = outputDirectory.appendingPathComponent("preview.wav")
        try writeWAV(samples: samples, sampleRate: sampleRate, url: audioURL)

        var profile: [String: Any] = [
            "engineId": engineId,
            "schemaVersion": 1,
            "characterName": characterName,
            "preset": params.preset.rawValue,
            "size": params.size,
            "grit": params.grit,
            "atmosphere": params.atmosphere,
            "textures": params.textures.map(\.rawValue).sorted(),
            "usedSystemTTS": usedSystemTTS,
            "teachTips": [
                params.preset.teachTip,
                "Size: \(params.sizeLabel)",
                "Grit: \(params.gritLabel)",
                "Atmosphere: \(params.atmosphereLabel)",
                usedSystemTTS
                    ? "Speech from system TTS, then creature FX."
                    : "Buzz carrier (TTS unavailable).",
            ],
            "previewFile": "preview.wav",
        ]
        if let spokenText {
            profile["spokenText"] = spokenText
        }
        let profileURL = outputDirectory.appendingPathComponent("voice_profile.json")
        let data = try JSONSerialization.data(withJSONObject: profile, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: profileURL, options: .atomic)

        let duration = sampleRate > 0 ? Double(samples.count) / sampleRate : 0
        return RenderResult(
            audioURL: audioURL,
            profileURL: profileURL,
            durationSeconds: duration,
            usedSystemTTS: usedSystemTTS,
            spokenText: spokenText
        )
    }

    // MARK: - Sample processing

    /// Linear resample. `to/from` as rates, or pass relative factors (from: 1, to: factor).
    public static func resample(_ input: [Float], from: Double, to: Double) -> [Float] {
        guard !input.isEmpty, from > 0, to > 0 else { return input }
        if abs(from - to) < 1e-6 { return input }
        let ratio = from / to
        let outCount = max(1, Int(Double(input.count) / ratio))
        var out = [Float](repeating: 0, count: outCount)
        for i in 0..<outCount {
            let src = Double(i) * ratio
            let i0 = Int(src)
            let i1 = min(i0 + 1, input.count - 1)
            let frac = Float(src - Double(i0))
            let a = input[min(i0, input.count - 1)]
            let b = input[i1]
            out[i] = a * (1 - frac) + b * frac
        }
        return out
    }

    public static func applyGrit(_ samples: inout [Float], grit: Double) {
        guard grit > 0.02 else { return }
        let drive = 1 + grit * 6
        for i in 0..<samples.count {
            var sample = Float(tanh(Double(samples[i]) * drive))
            if grit > 0.4 {
                let steps = max(4, Int(32 - grit * 28))
                sample = Float(Int(sample * Float(steps))) / Float(steps)
            }
            samples[i] = sample
        }
    }

    // MARK: - Synthesis

    /// Formant-ish buzz that suggests speech without a TTS engine.
    private static func synthesizeSpeechLike(
        sampleCount: Int,
        sampleRate: Double,
        pitchRate: Double,
        grit: Double
    ) -> [Float] {
        let f0 = 110.0 * pitchRate
        var out = [Float](repeating: 0, count: sampleCount)
        // Simple syllable envelope: 4 pulses.
        let syllable = sampleCount / 4
        for i in 0..<sampleCount {
            let t = Double(i) / sampleRate
            let syl = i / max(syllable, 1)
            let local = Double(i % max(syllable, 1)) / Double(max(syllable, 1))
            let env = Float(sin(min(1, local * 1.2) * .pi)) * (syl % 2 == 0 ? 1.0 : 0.75)
            // Harmonic stack
            var s = 0.0
            for h in 1...5 {
                let amp = 1.0 / Double(h)
                s += amp * sin(2 * .pi * f0 * Double(h) * t)
            }
            // Mild noise for consonants
            let noise = (Double.random(in: -1...1)) * (0.08 + grit * 0.25)
            var sample = Float(s * 0.2 + noise) * env
            // Grit: soft clip
            if grit > 0.05 {
                let drive = 1 + grit * 6
                sample = Float(tanh(Double(sample) * drive))
            }
            // Bitcrush-ish
            if grit > 0.4 {
                let steps = max(4, Int(32 - grit * 28))
                sample = Float(Int(sample * Float(steps))) / Float(steps)
            }
            out[i] = sample
        }
        return out
    }

    private static func synthesizeTexture(
        _ id: CreatureTextureID,
        sampleCount: Int,
        sampleRate: Double
    ) -> [Float] {
        var out = [Float](repeating: 0, count: sampleCount)
        switch id {
        case .buzzSaw:
            let f = 85.0
            for i in 0..<sampleCount {
                let t = Double(i) / sampleRate
                let phase = t * f
                let saw = 2 * (phase - floor(phase + 0.5))
                out[i] = Float(saw * 0.35)
            }
        case .songbird:
            for i in 0..<sampleCount {
                let t = Double(i) / sampleRate
                let chirp = sin(2 * .pi * (1800 + 400 * sin(2 * .pi * 6 * t)) * t)
                let gate = sin(2 * .pi * 3 * t) > 0.3 ? 1.0 : 0.0
                out[i] = Float(chirp * 0.2 * gate)
            }
        case .drip:
            let period = Int(sampleRate * 0.45)
            for i in 0..<sampleCount {
                let m = i % max(period, 1)
                if m < Int(sampleRate * 0.02) {
                    let local = Double(m) / sampleRate
                    out[i] = Float(sin(2 * .pi * 1200 * local) * exp(-local * 80) * 0.5)
                }
            }
        case .servo:
            for i in 0..<sampleCount {
                let t = Double(i) / sampleRate
                let tick = sin(2 * .pi * 40 * t) > 0.92 ? 1.0 : 0.0
                let whine = sin(2 * .pi * 900 * t) * 0.08
                out[i] = Float(tick * 0.25 + whine)
            }
        }
        return out
    }

    private static func applyAtmosphere(_ samples: inout [Float], amount: Double, sampleRate: Double) {
        guard amount > 0.02 else { return }
        // Cheap comb / reverb-ish: decaying echoes
        let delays = [0.03, 0.07, 0.11].map { Int($0 * sampleRate) }
        let wet = Float(amount * 0.45)
        var wetBuf = samples
        for d in delays {
            guard d > 0, d < samples.count else { continue }
            for i in d..<samples.count {
                wetBuf[i] += samples[i - d] * wet / Float(delays.count)
            }
        }
        let dry = Float(1 - amount * 0.35)
        for i in 0..<samples.count {
            samples[i] = samples[i] * dry + wetBuf[i] * wet
        }
    }

    private static func mixLayers(speech: [Float], texture: [Float], textureGain: Float) -> [Float] {
        let n = min(speech.count, texture.count)
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let env = min(1, abs(speech[i]) * 4) // crude speech detect
            let duck = 1 - env * 0.75
            out[i] = speech[i] + texture[i] * textureGain * Float(duck)
        }
        return out
    }

    private static func normalize(_ samples: inout [Float], peak: Float) {
        let maxAbs = samples.map { abs($0) }.max() ?? 1
        guard maxAbs > 1e-6 else { return }
        let g = peak / maxAbs
        for i in 0..<samples.count {
            samples[i] *= g
        }
    }

    private static func writeWAV(samples: [Float], sampleRate: Double, url: URL) throws {
        // Manual PCM16 mono WAV — avoids AVAudioFile quirks in unit-test hosts.
        var pcm = [Int16](repeating: 0, count: samples.count)
        for i in 0..<samples.count {
            let clipped = max(-1 as Float, min(1, samples[i]))
            pcm[i] = Int16(clipped * Float(Int16.max))
        }
        let dataSize = pcm.count * MemoryLayout<Int16>.size
        var data = Data()
        data.reserveCapacity(44 + dataSize)

        func appendASCII(_ s: String) {
            data.append(contentsOf: s.utf8)
        }
        func appendU32(_ v: UInt32) {
            var le = v.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }
        func appendU16(_ v: UInt16) {
            var le = v.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }

        appendASCII("RIFF")
        appendU32(UInt32(36 + dataSize))
        appendASCII("WAVE")
        appendASCII("fmt ")
        appendU32(16)
        appendU16(1)
        appendU16(1)
        appendU32(UInt32(sampleRate))
        appendU32(UInt32(sampleRate) * 2)
        appendU16(2)
        appendU16(16)
        appendASCII("data")
        appendU32(UInt32(dataSize))
        for s in pcm {
            var le = s.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try data.write(to: url, options: .atomic)
    }
}
