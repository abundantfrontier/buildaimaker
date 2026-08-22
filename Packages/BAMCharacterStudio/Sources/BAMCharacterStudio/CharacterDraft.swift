import Foundation

/// Species / vibe chips for step 1 of the wizard.
public enum CreatureSpeciesPreset: String, CaseIterable, Identifiable, Codable, Sendable {
    case robot
    case alien
    case lagoon
    case ghost
    case beast
    case birdish
    case goblin
    case custom

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .robot: return "Robot"
        case .alien: return "Alien"
        case .lagoon: return "Lagoon creature"
        case .ghost: return "Ghost"
        case .beast: return "Beast"
        case .birdish: return "Birdish"
        case .goblin: return "Goblin"
        case .custom: return "Custom"
        }
    }

    public var defaultSpeciesLabel: String {
        switch self {
        case .robot: return "robot"
        case .alien: return "alien visitor"
        case .lagoon: return "creature from the lagoon"
        case .ghost: return "restless ghost"
        case .beast: return "great beast"
        case .birdish: return "songbird-kin"
        case .goblin: return "goblin"
        case .custom: return "creature"
        }
    }

    public var suggestedVibe: String {
        switch self {
        case .robot: return "precise, curious about flesh-creatures"
        case .alien: return "eager, clipped sentences, asks question?"
        case .lagoon: return "wet, ancient, patient"
        case .ghost: return "wistful, unfinished business"
        case .beast: return "proud, territorial, surprisingly gentle"
        case .birdish: return "bright, observant, melodic speech"
        case .goblin: return "mischievous, greedy for shiny ideas"
        case .custom: return ""
        }
    }

    /// Maps to BAMAudioFX creature preset id.
    public var voicePresetRawValue: String {
        switch self {
        case .robot: return "robot"
        case .alien: return "alien"
        case .lagoon: return "lagoon"
        case .ghost: return "ghost"
        case .beast: return "beast"
        case .birdish: return "birdish"
        case .goblin: return "goblin"
        case .custom: return "alien"
        }
    }
}

/// In-progress character in the Create wizard (CS-1/2/3).
public struct CharacterDraft: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var speciesPreset: CreatureSpeciesPreset
    public var customSpecies: String
    public var vibe: String
    public var storyPaste: String
    public var styleTags: [StyleTag]
    public var riffCount: Int
    public var voicePreset: String
    /// "lower" or "higher" — overall speaker range. Missing on old saves.
    public var voiceRegister: String
    /// Pitch: 0 = deep/huge, 1 = high/tiny
    public var size: Double
    public var grit: Double
    public var atmosphere: Double
    /// Tone color: 0 = dark/chesty, 1 = bright/nasal
    public var formant: Double
    /// Ring-mod metallic sheen
    public var metallic: Double
    /// Vibrato / nervous tremble
    public var tremble: Double
    /// Air / breath noise
    public var breath: Double
    /// Speech rate: 0 = slow, 1 = fast
    public var speed: Double
    /// Robotic downsample / bitcrush
    public var robotize: Double
    public var textureBuzzSaw: Bool
    public var textureSongbird: Bool
    public var textureDrip: Bool
    public var textureServo: Bool
    /// Extra / full texture id list (raw `CreatureTextureID` values). Preferred over bools.
    public var textureIds: [String]
    /// 0...1 mix for each background noise. 0 / missing = off.
    public var textureLevels: [String: Double]
    public var bible: CharacterBible?
    public var examples: [DialogueExample]
    public var datasetId: String?
    public var voiceProfilePath: String?
    public var previewAudioPath: String?
    /// Selected base model library id (directory name under models/base when known).
    public var baseModelId: String?
    /// Absolute path to the chosen base model directory.
    public var baseModelPath: String?
    /// Display name of the chosen base model.
    public var baseModelName: String?
    /// Catalog / hub `sourceKey` for the chosen base model.
    public var baseModelSourceKey: String?
    /// Published LoRA / Foundation adapter library id (`models/adapters/<id>`).
    public var adapterId: String?
    /// Absolute path to the adapter directory, when known.
    public var adapterPath: String?
    /// Display name of the pinned adapter.
    public var adapterName: String?
    /// Wizard step raw value (0=meet, 1=model, 2=mind, 3=voice, 4=done). Used to resume.
    public var wizardStepRaw: Int
    /// True after user hits Finish & save.
    public var isComplete: Bool
    public var createdAt: String
    public var updatedAt: String

    public init(
        id: String = UUID().uuidString,
        name: String = "",
        speciesPreset: CreatureSpeciesPreset = .alien,
        customSpecies: String = "",
        vibe: String = CreatureSpeciesPreset.alien.suggestedVibe,
        storyPaste: String = "",
        styleTags: [StyleTag] = [],
        riffCount: Int = 2,
        voicePreset: String = CreatureSpeciesPreset.alien.voicePresetRawValue,
        voiceRegister: String = "lower",
        size: Double = 0.5,
        grit: Double = 0,
        atmosphere: Double = 0.12,
        formant: Double = 0.5,
        metallic: Double = 0,
        tremble: Double = 0.08,
        breath: Double = 0,
        speed: Double = 0.22,
        robotize: Double = 0.0,
        textureBuzzSaw: Bool = false,
        textureSongbird: Bool = false,
        textureDrip: Bool = false,
        textureServo: Bool = false,
        textureIds: [String] = ["chime", "crystal"],
        textureLevels: [String: Double] = ["chime": 0.30, "crystal": 0.18],
        bible: CharacterBible? = nil,
        examples: [DialogueExample] = [],
        datasetId: String? = nil,
        voiceProfilePath: String? = nil,
        previewAudioPath: String? = nil,
        baseModelId: String? = nil,
        baseModelPath: String? = nil,
        baseModelName: String? = nil,
        baseModelSourceKey: String? = nil,
        adapterId: String? = nil,
        adapterPath: String? = nil,
        adapterName: String? = nil,
        wizardStepRaw: Int = 0,
        isComplete: Bool = false,
        createdAt: String = ISO8601DateFormatter().string(from: Date()),
        updatedAt: String = ISO8601DateFormatter().string(from: Date())
    ) {
        self.id = id
        self.name = name
        self.speciesPreset = speciesPreset
        self.customSpecies = customSpecies
        self.vibe = vibe
        self.storyPaste = storyPaste
        self.styleTags = styleTags
        self.riffCount = riffCount
        self.voicePreset = voicePreset
        self.voiceRegister = voiceRegister
        self.size = size
        self.grit = grit
        self.atmosphere = atmosphere
        self.formant = formant
        self.metallic = metallic
        self.tremble = tremble
        self.breath = breath
        self.speed = speed
        self.robotize = robotize
        self.textureBuzzSaw = textureBuzzSaw
        self.textureSongbird = textureSongbird
        self.textureDrip = textureDrip
        self.textureServo = textureServo
        self.textureIds = textureIds
        self.textureLevels = textureLevels
        self.bible = bible
        self.examples = examples
        self.datasetId = datasetId
        self.voiceProfilePath = voiceProfilePath
        self.previewAudioPath = previewAudioPath
        self.baseModelId = baseModelId
        self.baseModelPath = baseModelPath
        self.baseModelName = baseModelName
        self.baseModelSourceKey = baseModelSourceKey
        self.adapterId = adapterId
        self.adapterPath = adapterPath
        self.adapterName = adapterName
        self.wizardStepRaw = wizardStepRaw
        self.isComplete = isComplete
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Texture chip set (string ids matching `CreatureTextureID.rawValue`).
    public var textureIdSet: Set<String> {
        get { Set(textureIds) }
        set {
            textureIds = Array(newValue).sorted()
            // Keep legacy bools in sync for older readers.
            textureBuzzSaw = newValue.contains("buzzSaw")
            textureSongbird = newValue.contains("songbird")
            textureDrip = newValue.contains("drip")
            textureServo = newValue.contains("servo")
        }
    }


    public func textureLevel(_ id: String) -> Double {
        if let v = textureLevels[id] { return min(1, max(0, v)) }
        return textureIdSet.contains(id) ? 0.4 : 0
    }

    public mutating func setTextureLevel(_ id: String, _ value: Double) {
        let v = min(1, max(0, value))
        if v < 0.02 {
            textureLevels[id] = nil
            setTexture(id, enabled: false)
        } else {
            textureLevels[id] = v
            setTexture(id, enabled: true)
        }
    }

    public mutating func setTexture(_ id: String, enabled: Bool) {
        var s = textureIdSet
        if enabled { s.insert(id) } else { s.remove(id) }
        textureIdSet = s
    }

    /// True when the draft has a base model path selected for later train/chat.
    public var hasSelectedBaseModel: Bool {
        guard let path = baseModelPath?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return false
        }
        return !path.isEmpty
    }

    /// Sentinel values for Apple’s on-device Foundation Model (not under models/base).
    public static let appleFoundationSourceKey = "apple/system-language-model"
    public static let appleFoundationPath = "system://apple-foundation"
    public static let appleFoundationDisplayName = "Apple on-device model"

    /// True when this character is bound to the system Foundation Model (not open MLX).
    public var usesAppleFoundationModel: Bool {
        if baseModelSourceKey == Self.appleFoundationSourceKey { return true }
        if baseModelPath == Self.appleFoundationPath { return true }
        if baseModelId == "apple-foundation" { return true }
        return false
    }

    public var resolvedSpecies: String {
        if speciesPreset == .custom {
            let c = customSpecies.trimmingCharacters(in: .whitespacesAndNewlines)
            return c.isEmpty ? "creature" : c
        }
        return speciesPreset.defaultSpeciesLabel
    }

    public var displayTitle: String {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return n.isEmpty ? "Untitled character" : n
    }

    enum CodingKeys: String, CodingKey {
        case id, name, speciesPreset, customSpecies, vibe, storyPaste, styleTags, riffCount
        case voicePreset, voiceRegister, size, grit, atmosphere
        case formant, metallic, tremble, breath, speed, robotize
        case textureBuzzSaw, textureSongbird, textureDrip, textureServo, textureIds, textureLevels
        case bible, examples, datasetId, voiceProfilePath, previewAudioPath
        case baseModelId, baseModelPath, baseModelName, baseModelSourceKey
        case adapterId, adapterPath, adapterName
        case wizardStepRaw, isComplete, createdAt, updatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        speciesPreset = try c.decodeIfPresent(CreatureSpeciesPreset.self, forKey: .speciesPreset) ?? .alien
        customSpecies = try c.decodeIfPresent(String.self, forKey: .customSpecies) ?? ""
        vibe = try c.decodeIfPresent(String.self, forKey: .vibe) ?? ""
        storyPaste = try c.decodeIfPresent(String.self, forKey: .storyPaste) ?? ""
        styleTags = try c.decodeIfPresent([StyleTag].self, forKey: .styleTags) ?? []
        riffCount = try c.decodeIfPresent(Int.self, forKey: .riffCount) ?? 2
        voicePreset = try c.decodeIfPresent(String.self, forKey: .voicePreset) ?? CreatureSpeciesPreset.alien.voicePresetRawValue
        voiceRegister = try c.decodeIfPresent(String.self, forKey: .voiceRegister)
            ?? (["deep", "beast", "dragon", "pirate", "wizard", "robot", "android", "lagoon", "coyote"].contains(voicePreset)
                ? "lower" : "higher")
        size = try c.decodeIfPresent(Double.self, forKey: .size) ?? 0.55
        grit = try c.decodeIfPresent(Double.self, forKey: .grit) ?? 0.22
        atmosphere = try c.decodeIfPresent(Double.self, forKey: .atmosphere) ?? 0.45
        // New speech-shaping knobs — fill from known preset defaults when missing (legacy drafts).
        let legacy = VoiceKnobDefaults.forPreset(voicePreset)
        formant = try c.decodeIfPresent(Double.self, forKey: .formant) ?? legacy.formant
        metallic = try c.decodeIfPresent(Double.self, forKey: .metallic) ?? legacy.metallic
        tremble = try c.decodeIfPresent(Double.self, forKey: .tremble) ?? legacy.tremble
        breath = try c.decodeIfPresent(Double.self, forKey: .breath) ?? legacy.breath
        speed = try c.decodeIfPresent(Double.self, forKey: .speed) ?? legacy.speed
        robotize = try c.decodeIfPresent(Double.self, forKey: .robotize) ?? legacy.robotize
        textureBuzzSaw = try c.decodeIfPresent(Bool.self, forKey: .textureBuzzSaw) ?? false
        textureSongbird = try c.decodeIfPresent(Bool.self, forKey: .textureSongbird) ?? false
        textureDrip = try c.decodeIfPresent(Bool.self, forKey: .textureDrip) ?? false
        textureServo = try c.decodeIfPresent(Bool.self, forKey: .textureServo) ?? false
        var ids = try c.decodeIfPresent([String].self, forKey: .textureIds) ?? []
        // Migrate legacy bool chips into textureIds.
        if ids.isEmpty {
            if textureBuzzSaw { ids.append("buzzSaw") }
            if textureSongbird { ids.append("songbird") }
            if textureDrip { ids.append("drip") }
            if textureServo { ids.append("servo") }
        }
        textureIds = ids
        textureLevels = try c.decodeIfPresent([String: Double].self, forKey: .textureLevels) ?? [:]
        if textureLevels.isEmpty {
            for id in ids { textureLevels[id] = 0.4 }
        }
        bible = try c.decodeIfPresent(CharacterBible.self, forKey: .bible)
        examples = try c.decodeIfPresent([DialogueExample].self, forKey: .examples) ?? []
        datasetId = try c.decodeIfPresent(String.self, forKey: .datasetId)
        voiceProfilePath = try c.decodeIfPresent(String.self, forKey: .voiceProfilePath)
        previewAudioPath = try c.decodeIfPresent(String.self, forKey: .previewAudioPath)
        baseModelId = try c.decodeIfPresent(String.self, forKey: .baseModelId)
        baseModelPath = try c.decodeIfPresent(String.self, forKey: .baseModelPath)
        baseModelName = try c.decodeIfPresent(String.self, forKey: .baseModelName)
        baseModelSourceKey = try c.decodeIfPresent(String.self, forKey: .baseModelSourceKey)
        adapterId = try c.decodeIfPresent(String.self, forKey: .adapterId)
        adapterPath = try c.decodeIfPresent(String.self, forKey: .adapterPath)
        adapterName = try c.decodeIfPresent(String.self, forKey: .adapterName)
        wizardStepRaw = try c.decodeIfPresent(Int.self, forKey: .wizardStepRaw) ?? 0
        // Older saves without isComplete: treat as complete if they had voice preview.
        if let complete = try c.decodeIfPresent(Bool.self, forKey: .isComplete) {
            isComplete = complete
        } else {
            isComplete = previewAudioPath != nil && (!examples.isEmpty || datasetId != nil)
        }
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt) ?? ISO8601DateFormatter().string(from: Date())
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt) ?? createdAt
    }

    /// In-progress if never finished, or missing mind/voice.
    public var isInProgress: Bool {
        if isComplete { return false }
        // Any saved draft without finish counts as resumable.
        return true
    }

    public var progressLabel: String {
        if isComplete { return "Complete" }
        // Prefer content over raw step so older drafts (pre-model step) still read well.
        if previewAudioPath != nil { return "In progress — almost done" }
        if !examples.isEmpty || datasetId != nil { return "In progress — Story done" }
        if hasSelectedBaseModel { return "In progress — Model picked" }
        if !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "In progress — Model"
        }
        switch wizardStepRaw {
        case 0: return "In progress — Name"
        case 1: return "In progress — Model"
        case 2: return "In progress — Story"
        case 3: return "In progress — Voice"
        case 4: return "Complete"
        default: return "In progress"
        }
    }

    /// Sensible step to reopen on (never past what's done).
    /// Steps: 0=meet, 1=model, 2=mind, 3=voice, 4=done.
    ///
    /// Finished characters still return content steps via ``editStepRaw`` so Edit
    /// can walk the wizard again instead of trapping on Done.
    public var resumeStepRaw: Int {
        if isComplete { return 4 }
        if previewAudioPath != nil { return 3 }
        if !examples.isEmpty || datasetId != nil { return 2 }
        if hasSelectedBaseModel { return 2 }
        if !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return 1 }
        return max(0, min(wizardStepRaw, 3))
    }

    /// Step to open when the user chooses **Edit** on a finished character.
    /// Prefers Voice (last creative step) so they can re-hear quickly, but any
    /// step is reachable via Back.
    public var editStepRaw: Int {
        if previewAudioPath != nil { return 3 }
        if !examples.isEmpty || datasetId != nil { return 2 }
        if hasSelectedBaseModel { return 1 }
        return 0
    }
}

/// Local defaults for voice knobs so legacy drafts migrate without depending on BAMAudioFX.
private enum VoiceKnobDefaults {
    struct Knobs {
        var formant: Double
        var metallic: Double
        var tremble: Double
        var breath: Double
        var speed: Double
        var robotize: Double
    }

    static func forPreset(_ raw: String) -> Knobs {
        switch raw {
        case "robot":
            return Knobs(formant: 0.55, metallic: 0.75, tremble: 0.08, breath: 0.08, speed: 0.5, robotize: 0.7)
        case "android":
            return Knobs(formant: 0.55, metallic: 0.55, tremble: 0.08, breath: 0.08, speed: 0.5, robotize: 0.4)
        case "alien":
            return Knobs(formant: 0.5, metallic: 0.0, tremble: 0.08, breath: 0.0, speed: 0.22, robotize: 0.0)
        case "lagoon":
            return Knobs(formant: 0.18, metallic: 0.05, tremble: 0.08, breath: 0.25, speed: 0.35, robotize: 0.0)
        case "ghost":
            return Knobs(formant: 0.35, metallic: 0.05, tremble: 0.45, breath: 0.45, speed: 0.28, robotize: 0.0)
        case "beast", "dragon":
            return Knobs(formant: 0.18, metallic: 0.05, tremble: 0.08, breath: raw == "dragon" ? 0.45 : 0.3, speed: 0.28, robotize: 0.0)
        case "birdish", "fairy":
            return Knobs(formant: 0.85, metallic: 0.05, tremble: raw == "fairy" ? 0.35 : 0.08, breath: 0.08, speed: raw == "fairy" ? 0.72 : 0.62, robotize: 0.0)
        case "goblin":
            return Knobs(formant: 0.7, metallic: 0.15, tremble: 0.25, breath: 0.08, speed: 0.62, robotize: 0.0)
        case "insect":
            return Knobs(formant: 0.85, metallic: 0.35, tremble: 0.35, breath: 0.08, speed: 0.72, robotize: 0.25)
        case "coyote":
            return Knobs(formant: 0.48, metallic: 0.05, tremble: 0.08, breath: 0.3, speed: 0.45, robotize: 0.0)
        case "wizard":
            return Knobs(formant: 0.35, metallic: 0.05, tremble: 0.08, breath: 0.2, speed: 0.28, robotize: 0.0)
        case "pirate":
            return Knobs(formant: 0.48, metallic: 0.05, tremble: 0.08, breath: 0.08, speed: 0.35, robotize: 0.0)
        case "sultry", "deep":
            return Knobs(formant: 0.40, metallic: 0.0, tremble: 0.0, breath: 0.30, speed: 0.22, robotize: 0.0)
        default:
            return Knobs(formant: 0.5, metallic: 0.1, tremble: 0.1, breath: 0.1, speed: 0.45, robotize: 0.0)
        }
    }
}
