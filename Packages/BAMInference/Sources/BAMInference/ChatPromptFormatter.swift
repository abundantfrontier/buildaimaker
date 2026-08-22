import Foundation

/// Formats ordered chat messages into a single prompt string for LLM backends.
///
/// Canonical roles are `system` / `user` / `assistant`. Formatting is shared by
/// the echo stub and any real mlx-lm generate path so unit tests pin behavior.
public enum ChatPromptFormatter: Sendable {
    public static let chatML = "chatml"
    public static let plain = "plain"

    /// Renders messages with ChatML-style markers (Qwen2.5 / ChatML family).
    ///
    /// When the last role is `user`, appends an open assistant turn so generate
    /// backends continue naturally.
    public static func formatChatML(_ messages: [InferenceChatMessage]) -> String {
        var parts: [String] = []
        for message in messages {
            parts.append("<|im_start|>\(message.role)\n\(message.content)<|im_end|>")
        }
        if let last = messages.last, last.role == "user" {
            parts.append("<|im_start|>assistant\n")
        }
        return parts.joined(separator: "\n")
    }

    /// Plain multi-line format used by the CI-safe echo backend and diagnostics.
    ///
    /// Shape:
    /// ```
    /// system: …
    /// user: …
    /// assistant: …
    /// ```
    public static func formatPlain(_ messages: [InferenceChatMessage]) -> String {
        messages.map { "\($0.role): \($0.content)" }.joined(separator: "\n")
    }

    /// Dispatch by template id; unknown ids fall back to ChatML.
    public static func format(templateId: String, messages: [InferenceChatMessage]) -> String {
        switch templateId {
        case plain:
            return formatPlain(messages)
        case chatML, "qwen2.5-instruct", "chatml-generic":
            return formatChatML(messages)
        default:
            return formatChatML(messages)
        }
    }

    /// Extracts the system prompt (first `system` message), or `nil`.
    public static func systemPrompt(from messages: [InferenceChatMessage]) -> String? {
        messages.first(where: { $0.role == "system" })?.content
    }

    /// Last user message content, if any.
    public static func lastUserMessage(from messages: [InferenceChatMessage]) -> String? {
        messages.last(where: { $0.role == "user" })?.content
    }

    /// Messages used for a completion turn: optional system override + history
    /// (excluding any trailing empty user placeholder).
    public static func messagesForCompletion(
        history: [InferenceChatMessage],
        systemOverride: String?
    ) -> [InferenceChatMessage] {
        var out: [InferenceChatMessage] = []
        if let override = systemOverride?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty
        {
            out.append(.system(override))
            // Drop prior system turns so override wins.
            out.append(contentsOf: history.filter { $0.role != "system" })
        } else {
            out = history
        }
        return out
    }

    /// OpenAI-style `{role, content}` rows for mlx-lm / Gemma `apply_chat_template`.
    ///
    /// Keeps the system card and the newest turns. Drops the oldest user/assistant
    /// pairs when the packed text would overflow `maxContentChars` (KV-cache cap
    /// for laptop generate — not the model's theoretical context).
    public static func messagesForMLXChat(
        _ messages: [InferenceChatMessage],
        maxContentChars: Int = 12_000
    ) -> [[String: String]] {
        var system: String?
        var rest: [InferenceChatMessage] = []
        for message in messages {
            let content = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { continue }
            switch message.role {
            case "system":
                if system == nil { system = content }
            case "user", "assistant":
                rest.append(InferenceChatMessage(role: message.role, content: content))
            default:
                continue
            }
        }
        func pack() -> [[String: String]] {
            var rows: [[String: String]] = []
            if let system {
                rows.append(["role": "system", "content": system])
            }
            for message in rest {
                rows.append(["role": message.role, "content": message.content])
            }
            return rows
        }
        func packedChars(_ rows: [[String: String]]) -> Int {
            rows.reduce(0) { $0 + ($1["content"]?.count ?? 0) }
        }
        var rows = pack()
        while packedChars(rows) > maxContentChars, rest.count > 1 {
            rest.removeFirst()
            if rest.first?.role == "assistant" {
                rest.removeFirst()
            }
            rows = pack()
        }
        return rows
    }
}
