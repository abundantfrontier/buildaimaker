import Foundation

/// User-facing creature voice parameters (0...1 sliders + textures).
public struct CreatureFXParams: Codable, Equatable, Sendable {
    public var preset: CreatureVoicePreset
    /// 0 = huge/low, 1 = tiny/high
    public var size: Double
    /// Distortion / bitcrush intensity
    public var grit: Double
    /// Reverb / wetness
    public var atmosphere: Double
    public var textures: Set<CreatureTextureID>

    public init(
        preset: CreatureVoicePreset = .alien,
        size: Double = 0.5,
        grit: Double = 0.35,
        atmosphere: Double = 0.4,
        textures: Set<CreatureTextureID> = []
    ) {
        self.preset = preset
        self.size = min(1, max(0, size))
        self.grit = min(1, max(0, grit))
        self.atmosphere = min(1, max(0, atmosphere))
        self.textures = textures
    }

    public static func fromPreset(_ preset: CreatureVoicePreset) -> CreatureFXParams {
        CreatureFXParams(
            preset: preset,
            size: preset.defaultSize,
            grit: preset.defaultGrit,
            atmosphere: preset.defaultAtmosphere,
            textures: defaultTextures(for: preset)
        )
    }

    public static func defaultTextures(for preset: CreatureVoicePreset) -> Set<CreatureTextureID> {
        switch preset {
        case .robot: return [.servo]
        case .alien: return []
        case .lagoon: return [.drip]
        case .ghost: return []
        case .beast: return []
        case .birdish: return [.songbird]
        case .goblin: return []
        }
    }

    /// Pitch rate for AVAudioUnitTimePitch-ish mapping (0.5...2.0).
    public var pitchRate: Double {
        // size 0 → ~0.7 (low), size 1 → ~1.45 (high)
        0.7 + size * 0.75
    }

    public var sizeLabel: String {
        if size < 0.33 { return "Bigger / lower" }
        if size > 0.66 { return "Smaller / higher" }
        return "Mid size"
    }

    public var gritLabel: String {
        if grit < 0.25 { return "Clean" }
        if grit > 0.65 { return "Heavy grit" }
        return "Some grit"
    }

    public var atmosphereLabel: String {
        if atmosphere < 0.25 { return "Dry" }
        if atmosphere > 0.7 { return "Very wet / spacious" }
        return "Some space"
    }
}
