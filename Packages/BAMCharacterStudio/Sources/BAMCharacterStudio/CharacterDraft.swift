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
        case .alien: return "polite outsider with strange metaphors"
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
    public var size: Double
    public var grit: Double
    public var atmosphere: Double
    public var textureBuzzSaw: Bool
    public var textureSongbird: Bool
    public var textureDrip: Bool
    public var textureServo: Bool
    public var bible: CharacterBible?
    public var examples: [DialogueExample]
    public var datasetId: String?
    public var voiceProfilePath: String?
    public var previewAudioPath: String?
    /// Wizard step raw value (0=meet, 1=mind, 2=voice, 3=done). Used to resume.
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
        size: Double = 0.5,
        grit: Double = 0.35,
        atmosphere: Double = 0.4,
        textureBuzzSaw: Bool = false,
        textureSongbird: Bool = false,
        textureDrip: Bool = false,
        textureServo: Bool = false,
        bible: CharacterBible? = nil,
        examples: [DialogueExample] = [],
        datasetId: String? = nil,
        voiceProfilePath: String? = nil,
        previewAudioPath: String? = nil,
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
        self.size = size
        self.grit = grit
        self.atmosphere = atmosphere
        self.textureBuzzSaw = textureBuzzSaw
        self.textureSongbird = textureSongbird
        self.textureDrip = textureDrip
        self.textureServo = textureServo
        self.bible = bible
        self.examples = examples
        self.datasetId = datasetId
        self.voiceProfilePath = voiceProfilePath
        self.previewAudioPath = previewAudioPath
        self.wizardStepRaw = wizardStepRaw
        self.isComplete = isComplete
        self.createdAt = createdAt
        self.updatedAt = updatedAt
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
        case voicePreset, size, grit, atmosphere
        case textureBuzzSaw, textureSongbird, textureDrip, textureServo
        case bible, examples, datasetId, voiceProfilePath, previewAudioPath
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
        size = try c.decodeIfPresent(Double.self, forKey: .size) ?? 0.5
        grit = try c.decodeIfPresent(Double.self, forKey: .grit) ?? 0.35
        atmosphere = try c.decodeIfPresent(Double.self, forKey: .atmosphere) ?? 0.4
        textureBuzzSaw = try c.decodeIfPresent(Bool.self, forKey: .textureBuzzSaw) ?? false
        textureSongbird = try c.decodeIfPresent(Bool.self, forKey: .textureSongbird) ?? false
        textureDrip = try c.decodeIfPresent(Bool.self, forKey: .textureDrip) ?? false
        textureServo = try c.decodeIfPresent(Bool.self, forKey: .textureServo) ?? false
        bible = try c.decodeIfPresent(CharacterBible.self, forKey: .bible)
        examples = try c.decodeIfPresent([DialogueExample].self, forKey: .examples) ?? []
        datasetId = try c.decodeIfPresent(String.self, forKey: .datasetId)
        voiceProfilePath = try c.decodeIfPresent(String.self, forKey: .voiceProfilePath)
        previewAudioPath = try c.decodeIfPresent(String.self, forKey: .previewAudioPath)
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
        switch wizardStepRaw {
        case 0: return "In progress — Name"
        case 1: return examples.isEmpty ? "In progress — Story" : "In progress — Story done"
        case 2: return previewAudioPath == nil ? "In progress — Voice" : "In progress — almost done"
        case 3: return "Complete"
        default: return "In progress"
        }
    }

    /// Sensible step to reopen on (never past what's done).
    public var resumeStepRaw: Int {
        if isComplete { return 3 }
        if previewAudioPath != nil { return 2 }
        if !examples.isEmpty || datasetId != nil { return 1 }
        if !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return 1 }
        return max(0, min(wizardStepRaw, 2))
    }
}
