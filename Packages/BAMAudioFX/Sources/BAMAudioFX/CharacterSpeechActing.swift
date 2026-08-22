import Foundation

extension CreatureVoicePreset {
    /// Short in-character line for Hear (not the bible / lore dump).
    public func spokenPreviewLine(characterName: String, species: String = "") -> String {
        _ = species
        let name = characterName.trimmingCharacters(in: .whitespacesAndNewlines)
        let who = name.isEmpty ? "I" : name
        switch self {
        case .sultry:
            return "Hello. I'm \(who). I'll read this softly, and I won't rush."
        case .deep:
            return "Hello. I'm \(who). I'll read this low and even, and I won't rush."
        case .robot:
            return "Designation \(who). Systems nominal. State your request."
        case .android:
            return "I am \(who). Almost human. Close enough for conversation."
        case .alien:
            return "I am \(who). Slow words. You understand, question?"
        case .lagoon:
            return "I am \(who). The water is patient. So am I."
        case .ghost:
            return "I was \(who). I still am, if you don't look too hard."
        case .beast:
            return "I am \(who). I will not eat you. I already had lunch."
        case .birdish:
            return "Oh! I'm \(who). Did you see that? Say it again, I like voices."
        case .goblin:
            return "Heh. Name's \(who). Don't blink. I already took something."
        case .dragon:
            return "I am \(who). Speak well. I have a long memory and a short temper."
        case .fairy:
            return "Hi! I'm \(who)! That sparkle was me. Ask me anything. Quickly."
        case .coyote:
            return "I'm \(who). Dry country, dry jokes. You walking, or talking?"
        case .wizard:
            return "I am \(who). Sit. The kettle is on, and the book is older than your map."
        case .pirate:
            return "Name's \(who). Buy the next round and I might tell you the true story."
        case .insect:
            return "We are \(who). Many legs. One thought. Do not swat."
        }
    }

    /// True when a mind line is short and spoken, not a lore card.
    public static func isSpeakableCharacterLine(_ raw: String) -> Bool {
        !looksLikeLoreDump(raw)
    }

    /// Lore / bible text should never be read aloud as if it were dialogue.
    public static func looksLikeLoreDump(_ raw: String) -> Bool {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return true }
        let lower = t.lowercased()
        if lower.contains("background story") { return true }
        if lower.contains("fictional lore") { return true }
        if t.contains("**") && t.count > 80 { return true }
        if t.filter({ $0.isNewline }).count >= 3 { return true }
        return false
    }

    /// Kokoro delivery speed for this role (1.0 = neutral).
    public var catalogActingSpeed: Double {
        switch self {
        case .sultry, .deep, .alien: return 0.80
        case .wizard, .ghost: return 0.86
        case .beast, .dragon, .lagoon: return 0.88
        case .pirate: return 0.92
        case .robot, .android: return 0.98
        case .coyote: return 1.00
        case .goblin: return 1.08
        case .birdish, .fairy, .insect: return 1.14
        }
    }
}

extension CreatureFXParams {
    /// Background noises that are actually turned up (0 = omit).
    public var resolvedTextureLevels: [(CreatureTextureID, Double)] {
        if !textureMix.isEmpty {
            return CreatureTextureID.allCases.compactMap { id in
                let level = min(1, max(0, textureMix[id.rawValue] ?? 0))
                return level > 0.02 ? (id, level) : nil
            }
        }
        return textures.map { ($0, 1.0) }
    }

    /// Role sets the center (Alien default stays the slow Rocky read).
    /// How-fast is a real change around that center, not a ±4% nudge.
    public var catalogActingDeliverySpeed: Double {
        let center = preset.catalogActingSpeed
        let delta = speed - preset.defaultSpeed
        return min(1.32, max(0.58, center + delta * 0.85))
    }

    /// Catalog pitch: 0.5 = unchanged. Ends are a small lift/drop, not chipmunk.
    public var catalogPitchRate: Double {
        1.0 + (size - 0.5) * 0.28
    }
}

extension CreatureFXRenderer {
    /// Cheap room (public so slider FX can call it).
    public static func applyCatalogRoom(_ samples: inout [Float], amount: Double, sampleRate: Double) {
        guard amount > 0.02, sampleRate > 0 else { return }
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

    /// Fold a noise into the voice itself (AM + envelope-locked add). Not a ducked bed.
    public static func imprintTextureOnVoice(
        speech: [Float],
        texture: [Float],
        id: CreatureTextureID,
        level: Double,
        sampleRate: Double
    ) -> [Float] {
        let amt = Float(min(1, max(0, level)))
        guard amt > 0.02, !speech.isEmpty, sampleRate > 0 else { return speech }
        let n = min(speech.count, texture.count)
        var shaped = Array(texture.prefix(n))
        switch id {
        case .thunder, .roar:
            lowpass(&shaped, hz: 160, sampleRate: sampleRate)
        case .windHowl, .fireCrackle:
            lowpass(&shaped, hz: 900, sampleRate: sampleRate)
        case .buzzSaw, .radioStatic:
            lowpass(&shaped, hz: 1400, sampleRate: sampleRate)
        default:
            break
        }
        var peak: Float = 1e-5
        for s in shaped { peak = max(peak, abs(s)) }
        let inv = 1 / peak
        for i in shaped.indices { shaped[i] *= inv }

        let rumble: Bool
        switch id {
        case .thunder, .roar, .windHowl, .buzzSaw, .fireCrackle: rumble = true
        default: rumble = false
        }
        let imprint = rumble ? amt * 0.85 : amt * 0.28
        let add = rumble ? amt * 0.42 : amt * 0.55
        var env: Float = 0
        let follow: Float = rumble ? 0.018 : 0.06
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let x = speech[i]
            env += follow * (abs(x) - env)
            let gate = min(1, env * 4.5)
            var color = shaped[i]
            if id == .thunder || id == .roar {
                let t = Double(i) / sampleRate
                let sub = Float(sin(2 * .pi * 36 * t) * 0.65 + sin(2 * .pi * 54 * t) * 0.35)
                color = color * 0.55 + sub * 0.45
            }
            out[i] = x * (1 + color * imprint * (0.35 + 0.65 * gate)) + color * add * gate
        }
        return out
    }

    private static func lowpass(_ samples: inout [Float], hz: Double, sampleRate: Double) {
        let freq = min(max(hz, 1), sampleRate * 0.45)
        let a = Float(1 - exp(-2 * Double.pi * freq / sampleRate))
        var y: Float = 0
        for i in samples.indices {
            y += a * (samples[i] - y)
            samples[i] = y
        }
    }
}

extension CreatureVoicePreset {
    public static func fromCatalogVoiceId(_ id: String) -> CreatureVoicePreset? {
        if let hit = allCases.first(where: { $0.defaultCatalogVoiceId == id }) {
            return hit
        }
        return allCases.first(where: { $0.alternateCatalogVoiceId == id })
    }

    public static func inferCharacterName(from text: String) -> String {
        let t = text.replacingOccurrences(of: "*", with: "")
        for marker in ["I am ", "I'm ", "I was ", "Name's ", "Designation "] {
            if let r = t.range(of: marker, options: .caseInsensitive) {
                let rest = t[r.upperBound...]
                let token = rest.split(whereSeparator: { !$0.isLetter && $0 != "-" && $0 != "'" }).first
                if let token {
                    let name = String(token)
                    if name.count >= 2, name.lowercased() != "a" { return name }
                }
            }
        }
        return ""
    }
}

extension CreatureFXRenderer {
    /// Slider FX on a catalog speaker. Neutral (0 or 0.5) = no processing.
    public static func applyCatalogSliderFX(
        _ samples: inout [Float],
        params: CreatureFXParams,
        sampleRate: Double
    ) {
        guard !samples.isEmpty else { return }
        let pitch = params.catalogPitchRate
        if abs(pitch - 1) > 0.03 {
            samples = resample(samples, from: 1.0, to: 1.0 / pitch)
        }
        if abs(params.formant - 0.5) > 0.04 {
            applyFormant(&samples, formant: params.formant)
        }
        if params.grit > 0.04 { applyGrit(&samples, grit: params.grit) }
        if params.metallic > 0.04 {
            applyMetallic(&samples, amount: params.metallic, sampleRate: sampleRate)
        }
        if params.robotize > 0.04 {
            applyRobotize(&samples, amount: params.robotize, sampleRate: sampleRate)
        }
        if params.tremble > 0.04 {
            applyTremble(&samples, amount: params.tremble, sampleRate: sampleRate)
        }
        if params.breath > 0.04 {
            applyIntimateBreath(&samples, amount: params.breath, sampleRate: sampleRate)
        }
        if params.atmosphere > 0.04 {
            applyCatalogRoom(&samples, amount: params.atmosphere, sampleRate: sampleRate)
        }
        applyLoudnessMatch(&samples, size: 0.5, formant: 0.5)
    }

    /// Same as slider FX (name used by older call sites).
    public static func applyCatalogActing(
        _ samples: inout [Float],
        params: CreatureFXParams,
        sampleRate: Double
    ) {
        applyCatalogSliderFX(&samples, params: params, sampleRate: sampleRate)
    }

    /// Acting on a real catalog speaker. No chorus/comb on human roles.
    public static func applyCatalogActingLegacy(
        _ samples: inout [Float],
        params: CreatureFXParams,
        sampleRate: Double
    ) {
        applyCatalogSliderFX(&samples, params: params, sampleRate: sampleRate)
    }
}
