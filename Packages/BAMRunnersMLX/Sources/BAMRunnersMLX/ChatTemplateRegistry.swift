import Foundation

/// Applies model-specific chat templates at job materialization time.
///
/// Canonical on-disk training rows stay OpenAI-style `messages[]`; templates
/// produce a parallel `text` field (and optional `templated.jsonl`) for workers
/// that consume single-string sequences.
public enum ChatTemplateRegistry: Sendable {
    public static let qwen25Instruct = "qwen2.5-instruct"
    public static let chatMLGeneric = "chatml-generic"

    public static let knownTemplateIds: Set<String> = [
        qwen25Instruct,
        chatMLGeneric,
    ]

    /// Renders one chat example into a single training string for the given template.
    ///
    /// Unknown template ids fall back to ChatML-generic (still valid text).
    public static func apply(templateId: String, example: ChatExampleLike) -> String {
        switch templateId {
        case qwen25Instruct, chatMLGeneric:
            return renderChatML(example: example)
        default:
            return renderChatML(example: example)
        }
    }

    /// Whether `templateId` is a first-class registry entry (vs fallback).
    public static func isKnown(_ templateId: String) -> Bool {
        knownTemplateIds.contains(templateId)
    }

    // MARK: - ChatML (Qwen2.5 Instruct family)

    /// ChatML-style rendering used by `qwen2.5-instruct` and `chatml-generic`.
    public static func renderChatML(example: ChatExampleLike) -> String {
        var parts: [String] = []
        for message in example.messages {
            let role = message.role
            let content = message.content
            parts.append("<|im_start|>\(role)\n\(content)<|im_end|>")
        }
        // Training targets usually continue as assistant; leave generation open when last role is user.
        if let last = example.messages.last, last.role == "user" {
            parts.append("<|im_start|>assistant\n")
        }
        return parts.joined(separator: "\n")
    }
}

/// Minimal message shape so the registry does not hard-depend on BAMDatasets.
public struct ChatMessageLike: Sendable, Equatable {
    public var role: String
    public var content: String

    public init(role: String, content: String) {
        self.role = role
        self.content = content
    }
}

/// Minimal example shape for template application.
public struct ChatExampleLike: Sendable, Equatable {
    public var messages: [ChatMessageLike]

    public init(messages: [ChatMessageLike]) {
        self.messages = messages
    }
}
