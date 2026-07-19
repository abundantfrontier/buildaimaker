import Foundation

/// A single chat turn for inference / playground (OpenAI-style roles).
public struct InferenceChatMessage: Codable, Sendable, Equatable, Hashable, Identifiable {
    public var id: String
    public var role: String
    public var content: String

    public init(id: String = UUID().uuidString, role: String, content: String) {
        self.id = id
        self.role = role
        self.content = content
    }

    public static let knownRoles: Set<String> = ["system", "user", "assistant"]

    public static func system(_ content: String) -> InferenceChatMessage {
        InferenceChatMessage(role: "system", content: content)
    }

    public static func user(_ content: String) -> InferenceChatMessage {
        InferenceChatMessage(role: "user", content: content)
    }

    public static func assistant(_ content: String) -> InferenceChatMessage {
        InferenceChatMessage(role: "assistant", content: content)
    }
}

/// One exportable conversation example (OpenAI messages JSONL row shape).
public struct InferenceChatExample: Codable, Sendable, Equatable, Hashable {
    public var messages: [InferenceChatMessage]

    public init(messages: [InferenceChatMessage]) {
        self.messages = messages
    }

    /// Encode without message `id` fields (dataset-friendly OpenAI shape).
    public func datasetEncoding() -> [[String: String]] {
        messages.map { ["role": $0.role, "content": $0.content] }
    }
}
