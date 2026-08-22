import Foundation

/// Canonical chat turn used after import / normalization.
public struct ChatMessage: Codable, Sendable, Equatable, Hashable {
    public var role: String
    public var content: String

    public init(role: String, content: String) {
        self.role = role
        self.content = content
    }

    public static let knownRoles: Set<String> = ["system", "user", "assistant"]
}

/// One training example: ordered messages (OpenAI-style).
public struct ChatExample: Codable, Sendable, Equatable, Hashable {
    public var messages: [ChatMessage]

    public init(messages: [ChatMessage]) {
        self.messages = messages
    }

    /// First system turn, if any.
    public var systemPrompt: String? {
        messages.first(where: { $0.role == "system" })?.content
    }

    /// Last user/assistant pair for wizard preview rows.
    public var lastUserAssistant: (user: String, assistant: String)? {
        let user = messages.last(where: { $0.role == "user" })?.content
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let assistant = messages.last(where: { $0.role == "assistant" })?.content
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let user, let assistant, !user.isEmpty, !assistant.isEmpty else { return nil }
        return (user, assistant)
    }
}

/// Detected JSONL chat format for a dataset file.
public enum DetectedChatFormat: String, Codable, Sendable, CaseIterable, Equatable {
    /// `{"messages":[{"role":"…","content":"…"}, …]}`
    case openaiMessages = "openai_messages"
    /// ShareGPT: `{"conversations":[{"from":"human","value":"…"}, …]}`
    case shareGPT = "sharegpt"
}
