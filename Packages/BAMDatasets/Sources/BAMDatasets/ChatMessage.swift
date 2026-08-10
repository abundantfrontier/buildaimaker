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
}

/// Detected JSONL chat format for a dataset file.
public enum DetectedChatFormat: String, Codable, Sendable, CaseIterable, Equatable {
    /// `{"messages":[{"role":"…","content":"…"}, …]}`
    case openaiMessages = "openai_messages"
    /// ShareGPT: `{"conversations":[{"from":"human","value":"…"}, …]}`
    case shareGPT = "sharegpt"
}
