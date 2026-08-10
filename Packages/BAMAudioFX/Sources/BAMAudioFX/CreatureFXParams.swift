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
        textures: Set<CreatureTextureID> = []
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
    }

    public static func fromPreset(_ preset: CreatureVoicePreset) -> CreatureFXParams {
        CreatureFXParams(
            preset: preset,
            size: preset.defaultSize,
            grit: preset.defaultGrit,
            atmosphere: preset.defaultAtmosphere,
            formant: preset.defaultFormant,
            metallic: preset.defaultMetallic,
            tremble: preset.defaultTremble,
            breath: preset.defaultBreath,
            speed: preset.defaultSpeed,
            robotize: preset.defaultRobotize,
            textures: defaultTextures(for: preset)
        )
    }

    public static func defaultTextures(for preset: CreatureVoicePreset) -> Set<CreatureTextureID> {
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
        }
    }

    /// Pitch ratio applied to speech (lower = deeper). Wide range so presets differ.
    /// size 0 → ~0.48 (very deep), size 1 → ~2.05 (chipmunk-high)
    public var pitchRate: Double {
        0.48 + size * 1.57
    }

    /// TTS utterance rate hint (AVSpeech scale-ish + say -r mapping).
    public var speechRateFactor: Float {
        // 0 → ~0.32 (slow), 0.45 → mid, 1 → ~0.78 (fast clipped)
        Float(0.32 + speed * 0.46)
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
