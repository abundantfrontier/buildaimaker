import Foundation

/// Named creature voice starting points (CS-3).
public enum CreatureVoicePreset: String, CaseIterable, Identifiable, Codable, Sendable {
    /// Soft, even read (classroom-safe). Higher / female-leaning.
    case sultry
    /// Matching low, even read. Lower / male-leaning.
    case deep
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
        case .sultry: return "Warm"
        case .deep: return "Deep"
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
        case .sultry:
            return "A soft, unhurried read. Good for poems and quiet lines."
        case .deep:
            return "A low, even read. The male match to Warm — same pace, different speaker."
        case .robot:
            return "Metal + bitcrush: words stay clear with a machine vibe."
        case .alien:
            return "Slow, clipped English with bells in the words. Curious visitor energy."
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

    /// One line for novices (no DSP jargon).
    public var plainSummary: String {
        switch self {
        case .sultry: return "Soft, unhurried, higher"
        case .deep: return "Low, even, unhurried"
        case .robot: return "Clipped, metallic, machine"
        case .alien: return "Slow, musical, clipped"
        case .lagoon: return "Low and watery"
        case .ghost: return "Airy and far away"
        case .beast: return "Deep and chesty"
        case .birdish: return "Bright and quick"
        case .goblin: return "High and raspy"
        case .dragon: return "Huge and smoky"
        case .fairy: return "Tiny and sparkling"
        case .android: return "Almost human, a bit digital"
        case .coyote: return "Dry laugh, desert grit"
        case .wizard: return "Warm and old-study"
        case .pirate: return "Gravelly swagger"
        case .insect: return "Thin, clicky speech"
        }
    }

    /// Kokoro speaker for this card. Each default id is unique so cards don't share a throat.
    public func catalogVoiceId(register: VoiceRegister) -> String {
        if register == defaultRegister {
            return defaultCatalogVoiceId
        }
        return alternateCatalogVoiceId
    }

    /// Short speaker name shown on the card (Kokoro id without prefix).
    public var catalogSpeakerLabel: String {
        let id = defaultCatalogVoiceId
        if let us = id.range(of: "_") {
            return String(id[us.upperBound...]).capitalized
        }
        return id
    }

    /// Default-register speaker (15 unique ids).
    public var defaultCatalogVoiceId: String {
        switch self {
        case .sultry: return "af_nicole"
        case .deep: return "am_michael"
        case .alien: return "am_puck"
        case .fairy: return "af_heart"
        case .birdish: return "af_aoede"
        case .insect: return "af_kore"
        case .ghost: return "bf_emma"
        case .android: return "af_alloy"
        case .robot: return "am_onyx"
        case .beast: return "am_fenrir"
        case .dragon: return "am_santa"
        case .goblin: return "am_adam"
        case .lagoon: return "am_echo"
        case .coyote: return "am_liam"
        case .wizard: return "bm_george"
        case .pirate: return "bm_fable"
        }
    }

    /// Other-register speaker (may reuse ids; default row stays unique).
    public var alternateCatalogVoiceId: String {
        switch self {
        case .sultry: return "am_michael"
        case .deep: return "af_nicole"
        case .alien: return "af_bella"
        case .fairy: return "am_puck"
        case .birdish: return "af_sky"
        case .insect: return "am_echo"
        case .ghost: return "bm_george"
        case .android: return "am_eric"
        case .robot: return "af_alloy"
        case .beast: return "am_onyx"
        case .dragon: return "am_fenrir"
        case .goblin: return "af_kore"
        case .lagoon: return "af_sarah"
        case .coyote: return "af_sarah"
        case .wizard: return "bf_emma"
        case .pirate: return "bf_isabella"
        }
    }

    public func catalogLang(register: VoiceRegister) -> String {
        let id = catalogVoiceId(register: register)
        if id.hasPrefix("bf_") || id.hasPrefix("bm_") { return "en-gb" }
        return "en-us"
    }

    /// Human-leaning: identity is source + EQ/breath, never comb/chorus.
    public var isHumanLeaning: Bool {
        switch self {
        case .sultry, .deep, .pirate, .wizard, .coyote:
            return true
        default:
            return false
        }
    }

    /// True when the creature needs a different *mouth size* (OLA formant).
    /// Cheap OLA plus a short delay is the whirly-tube / corrugated-pipe timbre.
    public var usesMouthSizeFormant: Bool {
        switch self {
        case .beast, .dragon, .fairy, .insect, .goblin, .birdish:
            return true
        default:
            return false
        }
    }

    /// Default slider positions 0...1 (wide spread so presets are obviously different).
    public var defaultSize: Double {
        switch self {
        // Near the TTS larynx. Pitch-stretching a female source is what made sultry metallic.
        case .sultry: return 0.34
        case .deep: return 0.32
        case .beast, .dragon: return 0.08
        case .robot: return 0.32
        case .android: return 0.42
        case .alien: return 0.34
        case .lagoon: return 0.28
        case .ghost, .wizard: return 0.38
        case .birdish: return 0.82
        case .fairy: return 0.92
        case .goblin: return 0.7
        case .insect: return 0.88
        case .coyote, .pirate: return 0.36
        }
    }

    /// Which system TTS body to start from (FX only finishes the character).
    public var speechVoiceHint: SpeechVoiceHint {
        switch self {
        case .sultry: return .sultry
        case .deep: return .deepMale
        case .beast, .dragon, .pirate, .wizard: return .deepMale
        case .robot, .android: return .noveltyRobot
        case .ghost: return .whisper
        case .fairy, .birdish, .insect, .goblin: return .child
        case .lagoon, .coyote, .alien: return .male
        }
    }

    /// Default Lower / Higher tessitura for this card.
    public var defaultRegister: VoiceRegister {
        switch self {
        case .sultry, .ghost, .fairy, .birdish, .goblin, .insect:
            return .higher
        case .deep, .alien, .beast, .dragon, .pirate, .wizard, .robot, .android, .lagoon, .coyote:
            return .lower
        }
    }

    public var defaultGrit: Double {
        switch self {
        case .pirate, .beast, .dragon: return 0.22
        case .goblin, .coyote: return 0.18
        case .sultry, .deep: return 0
        default: return 0.08
        }
    }

    public var defaultAtmosphere: Double {
        switch self {
        case .ghost: return 0.55
        case .lagoon, .wizard: return 0.42
        case .dragon: return 0.28
        case .sultry, .deep: return 0.04
        case .alien: return 0.12
        default: return 0.12
        }
    }

    public var defaultFormant: Double {
        switch self {
        case .beast, .dragon, .lagoon: return 0.18
        case .ghost, .wizard: return 0.35
        case .sultry, .deep: return 0.40
        case .alien: return 0.50
        case .coyote, .pirate: return 0.48
        case .robot, .android: return 0.55
        case .goblin: return 0.7
        case .birdish, .fairy, .insect: return 0.85
        }
    }

    public var defaultMetallic: Double { 0 }

    public var defaultTremble: Double {
        switch self {
        case .ghost: return 0.16
        case .alien: return 0.08
        default: return 0
        }
    }

    public var defaultBreath: Double {
        switch self {
        case .sultry, .deep: return 0.30
        case .ghost: return 0.16
        case .dragon, .beast: return 0.1
        default: return 0
        }
    }

    public var defaultSpeed: Double {
        switch self {
        case .sultry, .deep, .alien: return 0.22
        case .wizard, .ghost, .beast, .dragon: return 0.28
        case .lagoon, .pirate: return 0.35
        case .coyote: return 0.45
        case .robot, .android: return 0.5
        case .goblin, .birdish: return 0.62
        case .fairy, .insect: return 0.72
        }
    }

    public var defaultRobotize: Double { 0 }
}

/// Overall speaker range (TTS body + a mild size/formant nudge).
public enum VoiceRegister: String, CaseIterable, Identifiable, Codable, Sendable {
    case lower
    case higher

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .lower: return "Lower"
        case .higher: return "Higher"
        }
    }

    public var detail: String {
        switch self {
        case .lower: return "Deeper speaker (usually male-leaning)"
        case .higher: return "Brighter speaker (usually female-leaning)"
        }
    }

    public var sizeBias: Double {
        switch self {
        case .lower: return -0.10
        case .higher: return 0.12
        }
    }

    public var formantBias: Double {
        switch self {
        case .lower: return -0.08
        case .higher: return 0.10
        }
    }
}

/// Preferred system-TTS body so FX is not fighting a mismatched larynx.
public enum SpeechVoiceHint: String, Sendable, Codable {
    case deepMale
    case male
    case female
    case child
    case whisper
    case noveltyRobot
    case sultry

    /// `say -v` names to try, first installed wins.
    public var preferredSayNames: [String] {
        switch self {
        case .noveltyRobot:
            return ["Zarvox", "Trinoids", "Fred", "Reed"]
        case .whisper:
            return ["Whisper", "Samantha", "Kathy"]
        case .child:
            return ["Junior", "Princess", "Kathy", "Shelley"]
        case .deepMale:
            return ["Ralph", "Bruce", "Albert", "Daniel", "Alex"]
        case .male:
            return ["Alex", "Daniel", "Tom", "Fred"]
        case .female:
            return ["Samantha", "Victoria", "Karen", "Moira", "Fiona"]
        case .sultry:
            return ["Flo", "Samantha", "Victoria", "Zoe", "Allison", "Ava", "Susan", "Karen", "Moira"]
        }
    }

    var preferredNameFragments: [String] {
        preferredSayNames.map { $0.lowercased() }
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

    /// Quiet beds under speech (opt-in). Words stay louder than the layer.
    public var mixGain: Float {
        switch self {
        case .thunder, .roar: return 0.16
        case .buzzSaw, .radioStatic, .fireCrackle: return 0.12
        default: return 0.14
        }
    }
}
