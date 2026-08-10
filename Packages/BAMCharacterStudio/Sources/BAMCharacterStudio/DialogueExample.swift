import Foundation

/// One previewable training exchange (maps to OpenAI messages JSONL).
public struct DialogueExample: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var user: String
    public var assistant: String

    public init(id: String = UUID().uuidString, user: String, assistant: String) {
        self.id = id
        self.user = user
        self.assistant = assistant
    }
}

/// Result of building a mind corpus from paste + tags.
public struct CorpusBuildResult: Equatable, Sendable {
    public var bible: CharacterBible
    public var examples: [DialogueExample]
    /// UTF-8 OpenAI-messages JSONL.
    public var jsonl: String
    public var rowCount: Int

    public init(bible: CharacterBible, examples: [DialogueExample], jsonl: String) {
        self.bible = bible
        self.examples = examples
        self.jsonl = jsonl
        self.rowCount = examples.count
    }
}
