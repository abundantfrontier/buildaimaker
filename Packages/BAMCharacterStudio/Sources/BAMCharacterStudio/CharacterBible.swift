import Foundation

/// Structured character card produced from paste + tags (CS-2).
public struct CharacterBible: Codable, Equatable, Sendable {
    public var name: String
    public var species: String
    public var vibe: String
    public var traits: [String]
    public var speechRules: [String]
    public var taboos: [String]
    public var sourceNotes: String
    public var styleTags: [String]
    public var generatedAt: String
    public var generator: String
    /// Imported / authored system text. When set, Playground and mind encode use this as-is.
    public var systemPromptOverride: String?

    public init(
        name: String,
        species: String,
        vibe: String = "",
        traits: [String] = [],
        speechRules: [String] = [],
        taboos: [String] = [],
        sourceNotes: String = "",
        styleTags: [String] = [],
        generatedAt: String = ISO8601DateFormatter().string(from: Date()),
        generator: String = "template-v1",
        systemPromptOverride: String? = nil
    ) {
        self.name = name
        self.species = species
        self.vibe = vibe
        self.traits = traits
        self.speechRules = speechRules
        self.taboos = taboos
        self.sourceNotes = sourceNotes
        self.styleTags = styleTags
        self.generatedAt = generatedAt
        self.generator = generator
        self.systemPromptOverride = systemPromptOverride
    }

    /// System prompt content for training dialogues.
    public var systemPrompt: String {
        if let override = systemPromptOverride?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty
        {
            return override
        }
        var parts: [String] = [
            "You are \(name), a \(species.isEmpty ? "fictional character" : species).",
        ]
        if !vibe.isEmpty {
            parts.append("Vibe: \(vibe).")
        }
        if !traits.isEmpty {
            parts.append("Traits: \(traits.joined(separator: "; ")).")
        }
        if !speechRules.isEmpty {
            parts.append("How you talk: \(speechRules.joined(separator: " "))")
        }
        if !taboos.isEmpty {
            parts.append("Avoid: \(taboos.joined(separator: "; ")).")
        }
        parts.append("Stay in character. Do not claim to be a real human celebrity.")
        return parts.joined(separator: " ")
    }
}
