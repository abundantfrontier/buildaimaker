import Foundation

/// Named creature voice starting points (CS-3).
public enum CreatureVoicePreset: String, CaseIterable, Identifiable, Codable, Sendable {
    case robot
    case alien
    case lagoon
    case ghost
    case beast
    case birdish
    case goblin

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .robot: return "Robot"
        case .alien: return "Alien"
        case .lagoon: return "Lagoon"
        case .ghost: return "Ghost"
        case .beast: return "Beast"
        case .birdish: return "Birdish"
        case .goblin: return "Goblin"
        }
    }

    public var teachTip: String {
        switch self {
        case .robot:
            return "Metal + bitcrush: words stay clear with a machine vibe."
        case .alien:
            return "Formant shift + shimmer: polite outsider energy."
        case .lagoon:
            return "Low-pass + wet reverb: underwater patience."
        case .ghost:
            return "Airy reverb + slight detune: unfinished business."
        case .beast:
            return "Lower pitch + grit: big chest, careful speech."
        case .birdish:
            return "Higher formants + light sparkle: bright and observant."
        case .goblin:
            return "Higher pitch + grit: mischievous and close-mic."
        }
    }

    /// Default slider positions 0...1
    public var defaultSize: Double {
        switch self {
        case .beast: return 0.15
        case .robot: return 0.45
        case .alien: return 0.55
        case .lagoon: return 0.35
        case .ghost: return 0.4
        case .birdish: return 0.75
        case .goblin: return 0.7
        }
    }

    public var defaultGrit: Double {
        switch self {
        case .robot: return 0.55
        case .beast: return 0.5
        case .goblin: return 0.45
        case .lagoon: return 0.25
        case .alien: return 0.2
        case .ghost: return 0.1
        case .birdish: return 0.15
        }
    }

    public var defaultAtmosphere: Double {
        switch self {
        case .ghost: return 0.85
        case .lagoon: return 0.75
        case .alien: return 0.45
        case .beast: return 0.35
        case .robot: return 0.25
        case .birdish: return 0.4
        case .goblin: return 0.3
        }
    }
}

/// Texture chips mixed under speech.
public enum CreatureTextureID: String, CaseIterable, Identifiable, Codable, Sendable {
    case buzzSaw
    case songbird
    case drip
    case servo

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .buzzSaw: return "Buzz saw"
        case .songbird: return "Songbird"
        case .drip: return "Drip"
        case .servo: return "Servo"
        }
    }

    public var teachTip: String {
        switch self {
        case .buzzSaw:
            return "Mechanical texture under speech; ducked so words stay clear."
        case .songbird:
            return "Nature bed—alien aviary vibes without drowning dialogue."
        case .drip:
            return "Wet cave / lagoon droplets in the background."
        case .servo:
            return "Small motor ticks—good with robots and gadgets."
        }
    }
}
