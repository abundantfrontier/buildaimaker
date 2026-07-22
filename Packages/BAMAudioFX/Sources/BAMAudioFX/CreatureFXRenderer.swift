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

        if !trimmed.isEmpty {
            do {
                let speech = try await SystemSpeechSynthesizer.synthesize(
                    text: trimmed,
                    rate: params.speechRateFactor
                )
                guard !speech.samples.isEmpty, speech.sampleRate > 0 else {
                    throw CreatureFXError.ttsProducedNoAudio
                }

                var samples = resample(speech.samples, from: speech.sampleRate, to: targetRate)

                // Strong character chain — presets must sound obviously different.
                applyCharacterVoice(&samples, params: params, sampleRate: targetRate)

                var mix = samples
                // Leave headroom so texture beds stay audible after normalize.
                if !params.textures.isEmpty {
                    for i in mix.indices { mix[i] *= 0.72 }
                }
                for texture in params.textures {
                    let bed = synthesizeTexture(
                        texture,
                        sampleCount: mix.count,
                        sampleRate: targetRate
                    )
                    mix = mixLayers(
                        speech: mix,
                        texture: bed,
                        textureGain: texture.mixGain,
                        duckAmount: 0.35
                    )
                }
                normalize(&mix, peak: 0.92)

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
            } catch {
                // Fall through to buzz; caller can still play something.
            }
        }

        // Fallback buzz path (no words).
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
        if !params.textures.isEmpty {
            for i in mix.indices { mix[i] *= 0.72 }
        }
        for texture in params.textures {
            let bed = synthesizeTexture(
                texture,
                sampleCount: n,
                sampleRate: sampleRate
            )
            mix = mixLayers(
                speech: mix,
                texture: bed,
                textureGain: texture.mixGain,
                duckAmount: 0.35
            )
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
        // Unique name each render so AVAudioPlayer never caches an old buzz file.
        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        let audioURL = outputDirectory.appendingPathComponent("preview-\(stamp).wav")
        try writeWAV(samples: samples, sampleRate: sampleRate, url: audioURL)
        // Also refresh stable name for anything that still points at preview.wav.
        let stable = outputDirectory.appendingPathComponent("preview.wav")
        if fileManager.fileExists(atPath: stable.path) {
            try? fileManager.removeItem(at: stable)
        }
        try? fileManager.copyItem(at: audioURL, to: stable)

        var profile: [String: Any] = [
            "engineId": engineId,
            "schemaVersion": 2,
            "characterName": characterName,
            "preset": params.preset.rawValue,
            "size": params.size,
            "grit": params.grit,
            "atmosphere": params.atmosphere,
            "formant": params.formant,
            "metallic": params.metallic,
            "tremble": params.tremble,
            "breath": params.breath,
            "speed": params.speed,
            "robotize": params.robotize,
            "pitchRate": params.pitchRate,
            "textures": params.textures.map(\.rawValue).sorted(),
            "usedSystemTTS": usedSystemTTS,
            "teachTips": [
                params.preset.teachTip,
                "Pitch: \(params.sizeLabel)",
                "Tone: \(params.formantLabel)",
                "Metal: \(params.metallicLabel)",
                "Robot: \(params.robotizeLabel)",
                "Grit: \(params.gritLabel)",
                "Speed: \(params.speedLabel)",
                "Space: \(params.atmosphereLabel)",
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

    /// Full spoken-character processing (pitch, formant, metal, robot, tremble, breath, space).
    public static func applyCharacterVoice(
        _ samples: inout [Float],
        params: CreatureFXParams,
        sampleRate: Double
    ) {
        guard !samples.isEmpty else { return }

        // 1) Pitch (deep ↔ high) — wide range so deep beast ≠ high fairy.
        let pitch = max(0.45, min(2.15, params.pitchRate))
        samples = resample(samples, from: 1.0, to: 1.0 / pitch)

        // 2) Formant / tone color (dark ↔ bright).
        applyFormant(&samples, formant: params.formant)

        // 3) Metallic ring modulation.
        applyMetallic(&samples, amount: params.metallic, sampleRate: sampleRate)

        // 4) Robotize: downsample + crush.
        applyRobotize(&samples, amount: params.robotize, sampleRate: sampleRate)

        // 5) Grit / distortion.
        applyGrit(&samples, grit: params.grit)

        // 6) Tremble (AM vibrato).
        applyTremble(&samples, amount: params.tremble, sampleRate: sampleRate)

        // 7) Breath / air noise.
        applyBreath(&samples, amount: params.breath)

        // 8) Atmosphere / space last.
        applyAtmosphere(&samples, amount: params.atmosphere, sampleRate: sampleRate)

        // Preset-specific accent (extra identity on top of sliders).
        applyPresetAccent(&samples, preset: params.preset, sampleRate: sampleRate)
    }

    /// Spectral tilt: low formant = lowpass emphasis, high = highpass + presence.
    public static func applyFormant(_ samples: inout [Float], formant: Double) {
        let f = min(1, max(0, formant))
        if f < 0.48 {
            // Dark: one-pole lowpass (stronger when f→0).
            let strength = (0.48 - f) / 0.48
            let alpha = Float(0.08 + (1 - strength) * 0.35)
            var y: Float = 0
            for i in 0..<samples.count {
                y += alpha * (samples[i] - y)
                samples[i] = y * (1.15 - Float(strength) * 0.2)
            }
        } else if f > 0.52 {
            // Bright: high-shelf via difference of original and heavy lowpass.
            let strength = (f - 0.52) / 0.48
            let alpha: Float = 0.12
            var y: Float = 0
            for i in 0..<samples.count {
                let x = samples[i]
                y += alpha * (x - y)
                let high = x - y
                samples[i] = x * (1 - Float(strength) * 0.25) + high * (1 + Float(strength) * 1.6)
            }
        }
    }

    public static func applyMetallic(_ samples: inout [Float], amount: Double, sampleRate: Double) {
        guard amount > 0.03 else { return }
        let wet = Float(min(1, amount * 1.15))
        let carrierHz = 160.0 + amount * 280.0
        for i in 0..<samples.count {
            let t = Double(i) / sampleRate
            let carrier = sin(2 * .pi * carrierHz * t)
            // Second partial for harsher chrome.
            let carrier2 = sin(2 * .pi * carrierHz * 1.5 * t)
            let ring = samples[i] * Float(carrier * 0.7 + carrier2 * 0.3)
            samples[i] = samples[i] * (1 - wet * 0.75) + ring * wet
        }
    }

    public static func applyRobotize(_ samples: inout [Float], amount: Double, sampleRate: Double) {
        guard amount > 0.04, samples.count > 4 else { return }
        // Hold-sample downsample — stronger hold = more "machine".
        let hold = max(2, Int(2 + amount * 28))
        var i = 0
        while i < samples.count {
            let v = samples[i]
            let end = min(samples.count, i + hold)
            for j in i..<end { samples[j] = v }
            i = end
        }
        // Extra quantize
        let steps = max(4, Int(40 - amount * 36))
        for j in 0..<samples.count {
            samples[j] = Float(Int(samples[j] * Float(steps))) / Float(steps)
        }
        // Mild AM buzz for vocoder-ish identity.
        let buzzHz = 55.0 + amount * 40.0
        let buzzWet = Float(amount * 0.35)
        for j in 0..<samples.count {
            let t = Double(j) / sampleRate
            let buzz = Float(0.55 + 0.45 * sin(2 * .pi * buzzHz * t))
            samples[j] *= (1 - buzzWet) + buzz * buzzWet
        }
    }

    public static func applyTremble(_ samples: inout [Float], amount: Double, sampleRate: Double) {
        guard amount > 0.03 else { return }
        let depth = Float(amount * 0.45)
        let rate = 4.5 + amount * 6.0
        for i in 0..<samples.count {
            let t = Double(i) / sampleRate
            let mod = 1 + depth * Float(sin(2 * .pi * rate * t))
            samples[i] *= mod
        }
    }

    public static func applyBreath(_ samples: inout [Float], amount: Double) {
        guard amount > 0.03 else { return }
        let wet = Float(amount * 0.35)
        for i in 0..<samples.count {
            let noise = Float.random(in: -1...1)
            let env = min(1, abs(samples[i]) * 2.5 + 0.15)
            samples[i] = samples[i] * (1 - wet * 0.3) + noise * wet * env
        }
    }

    /// Extra signature so robot vs alien vs ghost is obvious even with default sliders.
    public static func applyPresetAccent(
        _ samples: inout [Float],
        preset: CreatureVoicePreset,
        sampleRate: Double
    ) {
        switch preset {
        case .robot, .android:
            applyRobotize(&samples, amount: preset == .robot ? 0.35 : 0.18, sampleRate: sampleRate)
            applyMetallic(&samples, amount: preset == .robot ? 0.25 : 0.15, sampleRate: sampleRate)
        case .alien:
            // Slight dual-delay phasing
            applyDetuneChorus(&samples, amount: 0.35, sampleRate: sampleRate)
        case .lagoon:
            applyFormant(&samples, formant: 0.15)
            applyAtmosphere(&samples, amount: 0.35, sampleRate: sampleRate)
        case .ghost:
            applyDetuneChorus(&samples, amount: 0.5, sampleRate: sampleRate)
            applyAtmosphere(&samples, amount: 0.4, sampleRate: sampleRate)
            applyTremble(&samples, amount: 0.2, sampleRate: sampleRate)
        case .beast, .dragon:
            // Already deep via size; add harmonic grit
            applyGrit(&samples, grit: 0.25)
        case .birdish, .fairy, .insect:
            applyFormant(&samples, formant: 0.9)
        case .goblin:
            applyFormant(&samples, formant: 0.75)
            applyGrit(&samples, grit: 0.2)
        case .coyote:
            applyGrit(&samples, grit: 0.18)
            applyBreath(&samples, amount: 0.2)
        case .wizard:
            applyAtmosphere(&samples, amount: 0.3, sampleRate: sampleRate)
            applyFormant(&samples, formant: 0.35)
        case .pirate:
            applyGrit(&samples, grit: 0.28)
            applyFormant(&samples, formant: 0.4)
        }
    }

    /// Cheap chorus/detune for alien/ghost identity.
    public static func applyDetuneChorus(
        _ samples: inout [Float],
        amount: Double,
        sampleRate: Double
    ) {
        guard amount > 0.05, samples.count > 16 else { return }
        let delay = max(1, Int(0.012 * sampleRate))
        let wet = Float(amount * 0.45)
        var out = samples
        for i in delay..<samples.count {
            let mod = 1 + 0.003 * sin(2 * .pi * 1.7 * Double(i) / sampleRate)
            let src = Double(i) - Double(delay) * mod
            let i0 = max(0, min(samples.count - 1, Int(src)))
            out[i] = samples[i] * (1 - wet) + samples[i0] * wet
        }
        samples = out
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
            // Loud mid saw + octave — obviously mechanical.
            for i in 0..<sampleCount {
                let t = Double(i) / sampleRate
                let phase = t * 95
                let saw = 2 * (phase - floor(phase + 0.5))
                let harsh = sin(2 * .pi * 190 * t)
                out[i] = Float(saw * 0.55 + harsh * 0.2)
            }
        case .songbird:
            for i in 0..<sampleCount {
                let t = Double(i) / sampleRate
                let f = 2200 + 700 * sin(2 * .pi * 8 * t)
                let chirp = sin(2 * .pi * f * t)
                let gate = sin(2 * .pi * 4.5 * t) > 0.15 ? 1.0 : 0.0
                out[i] = Float(chirp * 0.55 * gate)
            }
        case .drip:
            let period = Int(sampleRate * 0.32)
            for i in 0..<sampleCount {
                let m = i % max(period, 1)
                if m < Int(sampleRate * 0.04) {
                    let local = Double(m) / sampleRate
                    out[i] = Float(sin(2 * .pi * 1400 * local) * exp(-local * 60) * 0.95)
                }
            }
        case .servo:
            for i in 0..<sampleCount {
                let t = Double(i) / sampleRate
                let tick = sin(2 * .pi * 18 * t) > 0.88 ? 1.0 : 0.0
                let whine = sin(2 * .pi * 1100 * t) * 0.22
                out[i] = Float(tick * 0.55 + whine)
            }
        case .thunder:
            // Deep, obvious booms every ~0.7s + continuous sub rumble.
            for i in 0..<sampleCount {
                let t = Double(i) / sampleRate
                let cycle = fmod(t, 0.75)
                let boom = sin(2 * .pi * 32 * t) * exp(-cycle * 4.5)
                let body = sin(2 * .pi * 48 * t) * 0.7 * boom
                let rumble = sin(2 * .pi * 28 * t) * 0.25
                let crack = cycle < 0.02 ? Double.random(in: -1...1) * 0.35 : 0
                out[i] = Float((boom + body + rumble + crack) * 0.85)
            }
        case .radioStatic:
            for i in 0..<sampleCount {
                let t = Double(i) / sampleRate
                let noise = Double.random(in: -1...1)
                let gate = sin(2 * .pi * 9 * t) > 0.2 ? 1.0 : 0.25
                let heterodyne = sin(2 * .pi * 2800 * t) * sin(2 * .pi * 17 * t)
                out[i] = Float((noise * 0.45 + heterodyne * 0.2) * gate)
            }
        case .crystal:
            // Bright, sparkly, high — opposite of thunder.
            for i in 0..<sampleCount {
                let t = Double(i) / sampleRate
                let spark = fmod(t * 6.5, 1.0)
                let env = exp(-spark * 8)
                let a = sin(2 * .pi * 1760 * t)
                let b = sin(2 * .pi * 2630 * t + 0.5)
                let c = sin(2 * .pi * 3520 * t * 1.003)
                let d = sin(2 * .pi * 5280 * t) * 0.4
                out[i] = Float((a + 0.7 * b + 0.45 * c + d) * 0.22 * (0.35 + 0.65 * env))
            }
        case .windHowl:
            for i in 0..<sampleCount {
                let t = Double(i) / sampleRate
                let noise = Double.random(in: -1...1)
                let whoosh = noise * (0.55 + 0.45 * sin(2 * .pi * 0.4 * t))
                let howl = sin(2 * .pi * (220 + 80 * sin(2 * .pi * 0.25 * t)) * t) * 0.35
                out[i] = Float(whoosh * 0.4 + howl * 0.55)
            }
        case .glitch:
            for i in 0..<sampleCount {
                let t = Double(i) / sampleRate
                let slice = Int(t * 50) % 6
                let noise = Double.random(in: -1...1)
                let blip = (slice == 0 || slice == 3) ? sin(2 * .pi * 1800 * t) : 0
                let stutter = slice == 1 ? noise : noise * 0.08
                let drop = slice == 4 ? sin(2 * .pi * 90 * t) * 0.8 : 0
                out[i] = Float(blip * 0.45 + stutter * 0.4 + drop * 0.35)
            }
        case .bubble:
            let period = Int(sampleRate * 0.16)
            for i in 0..<sampleCount {
                let m = i % max(period, 1)
                if m < Int(sampleRate * 0.05) {
                    let local = Double(m) / sampleRate
                    let f = 500 + Double((i / max(period, 1)) % 9) * 110
                    out[i] = Float(sin(2 * .pi * f * local) * exp(-local * 40) * 0.85)
                }
            }
        case .chime:
            for i in 0..<sampleCount {
                let t = Double(i) / sampleRate
                let hit = fmod(t, 0.42)
                let env = exp(-hit * 5)
                let partials =
                    sin(2 * .pi * 1046 * t)
                    + 0.6 * sin(2 * .pi * 1568 * t)
                    + 0.35 * sin(2 * .pi * 2093 * t)
                    + 0.2 * sin(2 * .pi * 3136 * t)
                out[i] = Float(partials * 0.28 * env)
            }
        case .roar:
            for i in 0..<sampleCount {
                let t = Double(i) / sampleRate
                let noise = Double.random(in: -1...1)
                let growl = sin(2 * .pi * 65 * t) * 0.7 + sin(2 * .pi * 98 * t) * 0.45
                let breath = noise * 0.28 * (0.5 + 0.5 * sin(2 * .pi * 2.2 * t))
                out[i] = Float((growl + breath) * 0.65)
            }
        case .insectClick:
            for i in 0..<sampleCount {
                let t = Double(i) / sampleRate
                let clickTrain = sin(2 * .pi * 22 * t) > 0.93
                let click = clickTrain ? Double.random(in: -1...1) : 0
                let wing = sin(2 * .pi * 280 * t) * 0.12
                let buzz = sin(2 * .pi * 1900 * t) * 0.08 * (clickTrain ? 1 : 0.3)
                out[i] = Float(click * 0.55 + wing + buzz)
            }
        case .ropeCreak:
            for i in 0..<sampleCount {
                let t = Double(i) / sampleRate
                let creak = sin(2 * .pi * (100 + 45 * sin(2 * .pi * 1.6 * t)) * t)
                let noise = Double.random(in: -1...1) * 0.15
                let gate = 0.35 + 0.65 * max(0, sin(2 * .pi * 1.1 * t))
                out[i] = Float((creak * 0.45 + noise) * gate)
            }
        case .fireCrackle:
            for i in 0..<sampleCount {
                let pop = Double.random(in: 0...1) > 0.985 ? Double.random(in: -1...1) : 0
                let hiss = Double.random(in: -1...1) * 0.14
                let low = sin(2 * .pi * 85 * Double(i) / sampleRate) * 0.12
                out[i] = Float(pop * 0.7 + hiss + low)
            }
        }
        // Ensure each bed has usable peak so quiet synthesis still competes after mix.
        normalize(&out, peak: 0.95)
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

    /// Mix texture under speech. `duckAmount` 0 = full texture always; 1 = fully mute under speech.
    private static func mixLayers(
        speech: [Float],
        texture: [Float],
        textureGain: Float,
        duckAmount: Float = 0.35
    ) -> [Float] {
        let n = min(speech.count, texture.count)
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let env = min(1 as Float, abs(speech[i]) * 3.5)
            // Keep at least (1 - duckAmount) of the texture even during loud speech.
            let duck = 1 - env * duckAmount
            out[i] = speech[i] + texture[i] * textureGain * duck
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
