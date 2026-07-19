import Foundation

/// Exports a playground transcript as OpenAI-messages JSONL dataset candidate.
///
/// Each line is:
/// ```json
/// {"messages":[{"role":"system","content":"…"},{"role":"user","content":"…"},{"role":"assistant","content":"…"}]}
/// ```
/// Suitable for re-import via `BAMDatasets.JSONLChatParser`.
public enum TranscriptExporter: Sendable {
    /// Builds one `ChatExample`-shaped dict from ordered messages (ids stripped).
    public static func exampleDictionary(from messages: [InferenceChatMessage]) -> [String: Any] {
        [
            "messages": messages.map { ["role": $0.role, "content": $0.content] },
        ]
    }

    /// Serializes messages to a single JSONL line (UTF-8, no pretty print).
    public static func jsonlLine(from messages: [InferenceChatMessage]) throws -> String {
        let obj = exampleDictionary(from: messages)
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
        guard let line = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        return line
    }

    /// Full multi-turn transcript as a **single** JSONL row (one conversation).
    public static func exportConversationJSONL(messages: [InferenceChatMessage]) throws -> String {
        try jsonlLine(from: messages) + "\n"
    }

    /// Splits the transcript into user→assistant pairs (optional system on each).
    ///
    /// Useful when the playground has many turns and the user wants multiple
    /// training rows. System messages at the head are attached to every pair.
    public static func exportPairedJSONL(messages: [InferenceChatMessage]) throws -> String {
        let systemMessages = messages.filter { $0.role == "system" }
        let dialogue = messages.filter { $0.role != "system" }

        var lines: [String] = []
        var i = 0
        while i < dialogue.count {
            if dialogue[i].role == "user" {
                var pair: [InferenceChatMessage] = systemMessages
                pair.append(dialogue[i])
                if i + 1 < dialogue.count, dialogue[i + 1].role == "assistant" {
                    pair.append(dialogue[i + 1])
                    i += 2
                } else {
                    i += 1
                }
                lines.append(try jsonlLine(from: pair))
            } else {
                // Skip orphan assistant / unknown roles.
                i += 1
            }
        }
        return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }

    /// Writes JSONL to `url` (overwrites). Creates intermediate directories.
    public static func write(
        messages: [InferenceChatMessage],
        to url: URL,
        paired: Bool = false,
        fileManager: FileManager = .default
    ) throws {
        let dir = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        let body = try paired
            ? exportPairedJSONL(messages: messages)
            : exportConversationJSONL(messages: messages)
        try Data(body.utf8).write(to: url, options: .atomic)
    }
}
