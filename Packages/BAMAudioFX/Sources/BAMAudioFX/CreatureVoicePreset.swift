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
    case dragon
    case fairy
    case android
    case coyote
    case wizard
    case pirate
    case insect

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
        case .dragon: return "Dragon"
        case .fairy: return "Fairy"
        case .android: return "Android"
        case .coyote: return "Coyote"
        case .wizard: return "Wizard"
        case .pirate: return "Pirate"
        case .insect: return "Insect"
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
        case .dragon:
            return "Deep heat + rumble: prideful, smoky consonants."
        case .fairy:
            return "Tiny and bright: bells under quick, curious speech."
        case .android:
            return "Cleaner robot: subtle glitch + soft servo, almost human."
        case .coyote:
            return "Desert laugh-edge: dry grit, a little wind."
        case .wizard:
            return "Ancient study: warm room tone + crystal shimmer."
        case .pirate:
            return "Salt and swagger: gravelly mid grit, rope-creak texture."
        case .insect:
            return "Clicky carapace: high ticks under thin speech."
        }
    }

    /// Default slider positions 0...1 (wide spread so presets are obviously different).
    public var defaultSize: Double {
        switch self {
        case .beast, .dragon: return 0.08
        case .robot: return 0.32
        case .android: return 0.42
        case .alien: return 0.58
        case .lagoon: return 0.28
        case .ghost, .wizard: return 0.38
        case .birdish: return 0.82
        case .fairy: return 0.92
        case .goblin: return 0.7
        case .insect: return 0.88
        case .coyote, .pirate: return 0.36
        }
    }

    public var defaultGrit: Double {
        switch self {
        case .robot: return 0.55
        case .beast, .dragon, .pirate: return 0.52
        case .goblin, .coyote: return 0.45
        case .android: return 0.28
        case .lagoon: return 0.25
        case .alien, .insect: return 0.22
        case .ghost, .fairy, .wizard: return 0.12
        case .birdish: return 0.15
        }
    }

    public var defaultAtmosphere: Double {
        switch self {
        case .ghost: return 0.85
        case .lagoon, .wizard: return 0.75
        case .dragon: return 0.55
        case .alien, .fairy: return 0.45
        case .beast, .coyote: return 0.35
        case .robot, .android, .insect: return 0.25
        case .birdish: return 0.4
        case .goblin, .pirate: return 0.3
        }
    }

    public var defaultFormant: Double {
        switch self {
        case .beast, .dragon, .lagoon: return 0.18
        case .ghost, .wizard: return 0.35
        case .alien, .coyote, .pirate: return 0.48
        case .robot, .android: return 0.55
        case .goblin: return 0.7
        case .birdish, .fairy, .insect: return 0.85
        }
    }

    public var defaultMetallic: Double {
        switch self {
        case .robot: return 0.75
        case .android: return 0.55
        case .insect: return 0.35
        case .alien: return 0.25
        case .goblin: return 0.15
        default: return 0.05
        }
    }

    public var defaultTremble: Double {
        switch self {
        case .ghost: return 0.45
        case .fairy, .insect: return 0.35
        case .alien: return 0.2
        case .goblin: return 0.25
        default: return 0.08
        }
    }

    public var defaultBreath: Double {
        switch self {
        case .ghost, .dragon: return 0.45
        case .beast, .coyote: return 0.3
        case .lagoon: return 0.25
        case .wizard: return 0.2
        default: return 0.08
        }
    }

    public var defaultSpeed: Double {
        switch self {
        case .wizard, .ghost, .beast, .dragon: return 0.28
        case .lagoon, .pirate: return 0.35
        case .alien, .coyote: return 0.45
        case .robot, .android: return 0.5
        case .goblin, .birdish: return 0.62
        case .fairy, .insect: return 0.72
        }
    }

    public var defaultRobotize: Double {
        switch self {
        case .robot: return 0.7
        case .android: return 0.4
        case .insect: return 0.25
        default: return 0.0
        }
    }
}

/// Texture chips mixed under speech (creature SFX beds).
public enum CreatureTextureID: String, CaseIterable, Identifiable, Codable, Sendable {
    case buzzSaw
    case songbird
    case drip
    case servo
    case thunder
    case radioStatic
    case crystal
    case windHowl
    case glitch
    case bubble
    case chime
    case roar
    case insectClick
    case ropeCreak
    case fireCrackle

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .buzzSaw: return "Buzz saw"
        case .songbird: return "Songbird"
        case .drip: return "Drip"
        case .servo: return "Servo"
        case .thunder: return "Thunder"
        case .radioStatic: return "Radio static"
        case .crystal: return "Crystal"
        case .windHowl: return "Wind"
        case .glitch: return "Glitch"
        case .bubble: return "Bubbles"
        case .chime: return "Chimes"
        case .roar: return "Roar bed"
        case .insectClick: return "Insect click"
        case .ropeCreak: return "Rope creak"
        case .fireCrackle: return "Fire crackle"
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
        case .thunder:
            return "Distant rumble—dragons, storms, big arrivals."
        case .radioStatic:
            return "Shortwave hash—broken translator, spaceship radio."
        case .crystal:
            return "Shimmering glass tones—magic, fairies, weird tech."
        case .windHowl:
            return "Dry wind bed—deserts, ghosts on the moor."
        case .glitch:
            return "Digital stutters—androids dropping packets."
        case .bubble:
            return "Underwater fizz—lagoon creatures mid-sentence."
        case .chime:
            return "Soft bells—fairy courts and polite wizards."
        case .roar:
            return "Low growl bed under speech—beasts with manners."
        case .insectClick:
            return "Chitin ticks—hive minds and nervous bugs."
        case .ropeCreak:
            return "Ship timber and rope—pirates, docks, old wood."
        case .fireCrackle:
            return "Campfire spit—dragons, hearths, dramatic monologues."
        }
    }

    /// How loud this bed is relative to speech (tuned so textures are obvious).
    public var mixGain: Float {
        switch self {
        case .buzzSaw: return 0.42
        case .songbird: return 0.38
        case .drip: return 0.48
        case .servo: return 0.40
        case .thunder: return 0.55
        case .radioStatic: return 0.40
        case .crystal: return 0.48
        case .windHowl: return 0.42
        case .glitch: return 0.45
        case .bubble: return 0.50
        case .chime: return 0.46
        case .roar: return 0.50
        case .insectClick: return 0.44
        case .ropeCreak: return 0.42
        case .fireCrackle: return 0.46
        }
    }
}
