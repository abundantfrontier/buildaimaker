import Foundation

/// User-facing creature voice parameters (0...1 sliders + textures).
///
/// These shape the **spoken line** (TTS carrier), not only background beds.
public struct CreatureFXParams: Codable, Equatable, Sendable {
    public var preset: CreatureVoicePreset
    /// 0 = deep / huge, 1 = high / tiny (primary pitch)
    public var size: Double
    /// Distortion / bitcrush intensity
    public var grit: Double
    /// Reverb / wetness / space
    public var atmosphere: Double
    /// 0 = dark/chesty formant, 1 = bright/nasal/heady
    public var formant: Double
    /// Ring-mod / metallic sheen (robots, androids)
    public var metallic: Double
    /// Vibrato / nervous tremble
    public var tremble: Double
    /// Air / breath noise mixed with speech
    public var breath: Double
    /// Speech rate: 0 = slow, 1 = fast (drives TTS rate + mild time-stretch)
    public var speed: Double
    /// Extra robotic downsample (0…1)
    public var robotize: Double
    public var textures: Set<CreatureTextureID>
    /// 0...1 mix per texture id. Missing / 0 = off.
    public var textureMix: [String: Double]
    /// Lower / higher speaker range (TTS body + mild size/formant).
    public var register: VoiceRegister

    public init(
        preset: CreatureVoicePreset = .alien,
        size: Double = 0.5,
        grit: Double = 0.35,
        atmosphere: Double = 0.4,
        formant: Double = 0.5,
        metallic: Double = 0.0,
        tremble: Double = 0.0,
        breath: Double = 0.0,
        speed: Double = 0.45,
        robotize: Double = 0.0,
        textures: Set<CreatureTextureID> = [],
        register: VoiceRegister = .higher,
        textureMix: [String: Double] = [:]
    ) {
        self.preset = preset
        self.size = clamp01(size)
        self.grit = clamp01(grit)
        self.atmosphere = clamp01(atmosphere)
        self.formant = clamp01(formant)
        self.metallic = clamp01(metallic)
        self.tremble = clamp01(tremble)
        self.breath = clamp01(breath)
        self.speed = clamp01(speed)
        self.robotize = clamp01(robotize)
        self.textures = textures
        self.register = register
        self.textureMix = textureMix
    }

    public static func fromPreset(
        _ preset: CreatureVoicePreset,
        register: VoiceRegister? = nil
    ) -> CreatureFXParams {
        let reg = register ?? preset.defaultRegister
        // Most cards start neutral so sliders are opt-in. Alien is the
        // chord-friend starting mix (slow + light tremble + chimes in the voice).
        if preset == .alien {
            return CreatureFXParams(
                preset: preset,
                size: 0.5,
                grit: 0,
                atmosphere: preset.defaultAtmosphere,
                formant: 0.5,
                metallic: 0,
                tremble: preset.defaultTremble,
                breath: 0,
                speed: preset.defaultSpeed,
                robotize: 0,
                textures: defaultTextures(for: preset),
                register: reg,
                textureMix: defaultTextureMix(for: preset)
            )
        }
        return CreatureFXParams(
            preset: preset,
            size: 0.5,
            grit: 0,
            atmosphere: 0,
            formant: 0.5,
            metallic: 0,
            tremble: 0,
            breath: 0,
            speed: 0.5,
            robotize: 0,
            textures: defaultTextures(for: preset),
            register: reg
        )
    }

    /// Presets no longer dump SFX beds under every line. Alien imprints chimes.
    public static func defaultTextures(for preset: CreatureVoicePreset) -> Set<CreatureTextureID> {
        switch preset {
        case .alien: return [.chime, .crystal]
        default: return []
        }
    }

    /// Mix levels for preset-owned textures (0 = omit).
    public static func defaultTextureMix(for preset: CreatureVoicePreset) -> [String: Double] {
        switch preset {
        case .alien:
            return [
                CreatureTextureID.chime.rawValue: 0.30,
                CreatureTextureID.crystal.rawValue: 0.18,
            ]
        default:
            return [:]
        }
    }

    /// Old preset → bed mapping (strip on load so existing characters lose the noise stack).
    public static func legacyDefaultTextures(for preset: CreatureVoicePreset) -> Set<CreatureTextureID> {
        switch preset {
        case .robot: return [.servo, .buzzSaw]
        case .alien: return [.radioStatic]
        case .lagoon: return [.drip, .bubble]
        case .ghost: return [.windHowl]
        case .beast: return [.roar]
        case .birdish: return [.songbird]
        case .goblin: return [.glitch]
        case .dragon: return [.roar, .fireCrackle, .thunder]
        case .fairy: return [.chime, .crystal]
        case .android: return [.servo, .glitch]
        case .coyote: return [.windHowl]
        case .wizard: return [.crystal, .chime]
        case .pirate: return [.ropeCreak]
        case .insect: return [.insectClick]
        case .sultry, .deep: return []
        }
    }

    /// TTS body after applying Lower / Higher.
    public var resolvedSpeechHint: SpeechVoiceHint {
        switch register {
        case .lower:
            switch preset.speechVoiceHint {
            case .noveltyRobot: return .noveltyRobot
            case .whisper: return .whisper
            default: return .deepMale
            }
        case .higher:
            switch preset.speechVoiceHint {
            case .noveltyRobot: return .female
            case .sultry: return .sultry
            case .child: return .child
            default: return .female
            }
        }
    }

    /// Pitch ratio applied to speech (lower = deeper).
    /// Human-leaning stays near the TTS larynx; creatures get a wide stretch.
    public var pitchRate: Double {
        if preset.isHumanLeaning {
            return 0.88 + size * 0.28
        }
        return 0.48 + size * 1.57
    }

    /// Nudge the *source* TTS toward the body before FX (0.75…1.25).
    public var ttsPitchMultiplier: Float {
        Float(0.75 + size * 0.5)
    }

    /// Formant scale independent of pitch: 0 → 0.72 (large body), 1 → 1.38 (tiny).
    public var formantRatio: Double {
        0.72 + formant * 0.66
    }

    /// TTS utterance rate hint (AVSpeech scale-ish + say -r mapping).
    public var speechRateFactor: Float {
        // 0 → ~0.32 (slow), 0.45 → mid, 1 → ~0.78 (fast clipped)
        var r = 0.32 + speed * 0.46
        if preset == .sultry || preset == .deep || preset == .alien { r *= 0.78 }
        return Float(r)
    }

    /// Kokoro speaker for this preset + register.
    public var catalogVoiceId: String {
        preset.catalogVoiceId(register: register)
    }

    public var catalogLang: String {
        preset.catalogLang(register: register)
    }

    /// Kokoro speed (0.75…1.20). Identity lives in the speaker, not time-stretch.
    public var catalogSpeed: Double {
        0.75 + speed * 0.45
    }

    public var sizeLabel: String {
        if size < 0.25 { return "Deep / huge" }
        if size < 0.45 { return "Lower" }
        if size > 0.75 { return "Very high / tiny" }
        if size > 0.55 { return "Higher" }
        return "Mid pitch"
    }

    public var gritLabel: String {
        if grit < 0.2 { return "Clean" }
        if grit > 0.7 { return "Heavy grit" }
        return "Some grit"
    }

    public var atmosphereLabel: String {
        if atmosphere < 0.2 { return "Dry / close" }
        if atmosphere > 0.7 { return "Huge space" }
        return "Some space"
    }

    public var formantLabel: String {
        if formant < 0.3 { return "Dark / chesty" }
        if formant > 0.7 { return "Bright / nasal" }
        return "Neutral tone"
    }

    public var metallicLabel: String {
        if metallic < 0.15 { return "Organic" }
        if metallic > 0.6 { return "Very metallic" }
        return "Some metal"
    }

    public var trembleLabel: String {
        if tremble < 0.15 { return "Steady" }
        if tremble > 0.6 { return "Heavy tremble" }
        return "Slight shake"
    }

    public var breathLabel: String {
        if breath < 0.15 { return "Clear" }
        if breath > 0.6 { return "Very breathy" }
        return "Some air"
    }

    public var speedLabel: String {
        if speed < 0.3 { return "Slow / deliberate" }
        if speed > 0.7 { return "Fast / clipped" }
        return "Natural pace"
    }

    public var robotizeLabel: String {
        if robotize < 0.15 { return "Smooth" }
        if robotize > 0.6 { return "Hard robot" }
        return "Light robot"
    }
}

private func clamp01(_ v: Double) -> Double {
    min(1, max(0, v))
}
