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
}
