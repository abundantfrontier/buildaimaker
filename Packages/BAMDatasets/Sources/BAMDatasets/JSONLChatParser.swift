import BAMCore
import Foundation

/// Parses and validates ShareGPT / OpenAI-messages JSONL chat datasets.
public enum JSONLChatParser: Sendable {
    /// Maximum issues collected before stopping early (keeps UI/error payloads bounded).
    public static let maxIssues = 50

    // MARK: - Public API

    /// Validates a JSONL file without loading every example into memory.
    public static func validate(fileURL: URL) throws -> DatasetValidationResult {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return DatasetValidationResult(
                isValid: false,
                format: nil,
                rowCount: 0,
                issues: [
                    DatasetValidationIssue(
                        line: nil,
                        message: "File not found: \(fileURL.path)"
                    ),
                ]
            )
        }

        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        var issues: [DatasetValidationIssue] = []
        var rowCount = 0
        var detectedFormat: DetectedChatFormat?
        var lineNumber = 0
        var nonEmptyLines = 0

        while true {
            guard let lineData = try readLine(from: handle) else { break }
            lineNumber += 1

            let trimmed = String(data: lineData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if trimmed.isEmpty { continue }
            nonEmptyLines += 1

            if issues.count >= maxIssues { continue }

            switch parseRow(trimmed, line: lineNumber) {
            case .success(let example, let format):
                if let detectedFormat, detectedFormat != format {
                    issues.append(
                        DatasetValidationIssue(
                            line: lineNumber,
                            message:
                                "Mixed formats: expected \(detectedFormat.rawValue), found \(format.rawValue). Use one format per file."
                        )
                    )
                    continue
                }
                if detectedFormat == nil {
                    detectedFormat = format
                }
                if example.messages.isEmpty {
                    issues.append(
                        DatasetValidationIssue(
                            line: lineNumber,
                            message: "Row has an empty messages/conversations list."
                        )
                    )
                    continue
                }
                rowCount += 1
            case .failure(let issue):
                issues.append(issue)
            }
        }

        if nonEmptyLines == 0 {
            issues.append(
                DatasetValidationIssue(
                    line: nil,
                    message: "File is empty or contains only blank lines. Expected JSONL chat rows."
                )
            )
        }

        if rowCount == 0, issues.isEmpty {
            issues.append(
                DatasetValidationIssue(
                    line: nil,
                    message: "No valid chat rows found."
                )
            )
        }

        let isValid = issues.isEmpty && rowCount > 0
        return DatasetValidationResult(
            isValid: isValid,
            format: detectedFormat,
            rowCount: rowCount,
            issues: issues
        )
    }

    /// Validates UTF-8 string content (tests / in-memory fixtures).
    public static func validate(contents: String) -> DatasetValidationResult {
        var issues: [DatasetValidationIssue] = []
        var rowCount = 0
        var detectedFormat: DetectedChatFormat?
        var nonEmptyLines = 0

        let lines = contents.split(separator: "\n", omittingEmptySubsequences: false)
        for (index, lineSub) in lines.enumerated() {
            let lineNumber = index + 1
            let trimmed = lineSub.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            nonEmptyLines += 1
            if issues.count >= maxIssues { continue }

            switch parseRow(String(trimmed), line: lineNumber) {
            case .success(let example, let format):
                if let detectedFormat, detectedFormat != format {
                    issues.append(
                        DatasetValidationIssue(
                            line: lineNumber,
                            message:
                                "Mixed formats: expected \(detectedFormat.rawValue), found \(format.rawValue). Use one format per file."
                        )
                    )
                    continue
                }
                if detectedFormat == nil {
                    detectedFormat = format
                }
                if example.messages.isEmpty {
                    issues.append(
                        DatasetValidationIssue(
                            line: lineNumber,
                            message: "Row has an empty messages/conversations list."
                        )
                    )
                    continue
                }
                rowCount += 1
            case .failure(let issue):
                issues.append(issue)
            }
        }

        if nonEmptyLines == 0 {
            issues.append(
                DatasetValidationIssue(
                    line: nil,
                    message: "File is empty or contains only blank lines. Expected JSONL chat rows."
                )
            )
        }

        if rowCount == 0, issues.isEmpty {
            issues.append(
                DatasetValidationIssue(
                    line: nil,
                    message: "No valid chat rows found."
                )
            )
        }

        return DatasetValidationResult(
            isValid: issues.isEmpty && rowCount > 0,
            format: detectedFormat,
            rowCount: rowCount,
            issues: issues
        )
    }

    /// Reads the first `maxExamples` valid chat examples for preview.
    public static func preview(fileURL: URL, maxExamples: Int = 5) throws -> [ChatExample] {
        precondition(maxExamples > 0)
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        var examples: [ChatExample] = []
        var lineNumber = 0

        while examples.count < maxExamples {
            guard let lineData = try readLine(from: handle) else { break }
            lineNumber += 1
            let trimmed = String(data: lineData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if trimmed.isEmpty { continue }

            if case .success(let example, _) = parseRow(trimmed, line: lineNumber),
               !example.messages.isEmpty
            {
                examples.append(example)
            }
        }
        return examples
    }

    /// Reads the first `maxExamples` valid chat examples from string content.
    public static func preview(contents: String, maxExamples: Int = 5) -> [ChatExample] {
        precondition(maxExamples > 0)
        var examples: [ChatExample] = []
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: false)
        for (index, lineSub) in lines.enumerated() where examples.count < maxExamples {
            let trimmed = lineSub.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            if case .success(let example, _) = parseRow(String(trimmed), line: index + 1),
               !example.messages.isEmpty
            {
                examples.append(example)
            }
        }
        return examples
    }

    // MARK: - Row parsing

    private enum RowParseResult {
        case success(ChatExample, DetectedChatFormat)
        case failure(DatasetValidationIssue)
    }

    private static func parseRow(_ line: String, line lineNumber: Int) -> RowParseResult {
        guard let data = line.data(using: .utf8) else {
            return .failure(
                DatasetValidationIssue(
                    line: lineNumber,
                    message: "Line is not valid UTF-8."
                )
            )
        }

        let object: [String: Any]
        do {
            let json = try JSONSerialization.jsonObject(with: data)
            guard let dict = json as? [String: Any] else {
                return .failure(
                    DatasetValidationIssue(
                        line: lineNumber,
                        message: "Expected a JSON object per line, got \(typeName(json))."
                    )
                )
            }
            object = dict
        } catch {
            return .failure(
                DatasetValidationIssue(
                    line: lineNumber,
                    message: "Invalid JSON: \(error.localizedDescription)"
                )
            )
        }

        if object["messages"] != nil {
            return parseOpenAIMessages(object, line: lineNumber)
        }
        if object["conversations"] != nil || object["conversation"] != nil {
            return parseShareGPT(object, line: lineNumber)
        }

        return .failure(
            DatasetValidationIssue(
                line: lineNumber,
                message:
                    "Unrecognized chat format. Expected OpenAI `messages` or ShareGPT `conversations`."
            )
        )
    }

    private static func parseOpenAIMessages(
        _ object: [String: Any],
        line lineNumber: Int
    ) -> RowParseResult {
        guard let rawMessages = object["messages"] as? [[String: Any]] else {
            return .failure(
                DatasetValidationIssue(
                    line: lineNumber,
                    message: "`messages` must be an array of objects with `role` and `content`."
                )
            )
        }

        var messages: [ChatMessage] = []
        for (idx, raw) in rawMessages.enumerated() {
            guard let role = raw["role"] as? String, !role.isEmpty else {
                return .failure(
                    DatasetValidationIssue(
                        line: lineNumber,
                        message: "messages[\(idx)]: missing or empty `role`."
                    )
                )
            }
            let normalizedRole = role.lowercased()
            guard ChatMessage.knownRoles.contains(normalizedRole) else {
                return .failure(
                    DatasetValidationIssue(
                        line: lineNumber,
                        message:
                            "messages[\(idx)]: unknown role \"\(role)\". Expected system, user, or assistant."
                    )
                )
            }
            guard let content = stringContent(raw["content"]) else {
                return .failure(
                    DatasetValidationIssue(
                        line: lineNumber,
                        message: "messages[\(idx)]: missing or non-string `content`."
                    )
                )
            }
            messages.append(ChatMessage(role: normalizedRole, content: content))
        }

        return .success(ChatExample(messages: messages), .openaiMessages)
    }

    private static func parseShareGPT(
        _ object: [String: Any],
        line lineNumber: Int
    ) -> RowParseResult {
        let rawList: [[String: Any]]
        if let conversations = object["conversations"] as? [[String: Any]] {
            rawList = conversations
        } else if let conversation = object["conversation"] as? [[String: Any]] {
            rawList = conversation
        } else {
            return .failure(
                DatasetValidationIssue(
                    line: lineNumber,
                    message:
                        "`conversations` must be an array of objects with `from`/`value` (ShareGPT)."
                )
            )
        }

        var messages: [ChatMessage] = []
        for (idx, raw) in rawList.enumerated() {
            let from = (raw["from"] as? String) ?? (raw["role"] as? String)
            guard let from, !from.isEmpty else {
                return .failure(
                    DatasetValidationIssue(
                        line: lineNumber,
                        message: "conversations[\(idx)]: missing `from` (speaker)."
                    )
                )
            }
            guard let role = mapShareGPTSpeaker(from) else {
                return .failure(
                    DatasetValidationIssue(
                        line: lineNumber,
                        message:
                            "conversations[\(idx)]: unknown speaker \"\(from)\". Expected human/user, gpt/assistant, or system."
                    )
                )
            }
            let value = raw["value"] ?? raw["content"]
            guard let content = stringContent(value) else {
                return .failure(
                    DatasetValidationIssue(
                        line: lineNumber,
                        message: "conversations[\(idx)]: missing or non-string `value`."
                    )
                )
            }
            messages.append(ChatMessage(role: role, content: content))
        }

        return .success(ChatExample(messages: messages), .shareGPT)
    }

    private static func mapShareGPTSpeaker(_ raw: String) -> String? {
        switch raw.lowercased() {
        case "human", "user":
            return "user"
        case "gpt", "chatgpt", "bing", "assistant", "bot", "gpt-4", "gpt4":
            return "assistant"
        case "system":
            return "system"
        default:
            return nil
        }
    }

    private static func stringContent(_ value: Any?) -> String? {
        guard let value else { return nil }
        if let s = value as? String { return s }
        if let n = value as? NSNumber { return n.stringValue }
        return nil
    }

    private static func typeName(_ value: Any) -> String {
        switch value {
        case is [Any]: return "array"
        case is String: return "string"
        case is NSNumber: return "number"
        case is NSNull: return "null"
        default: return String(describing: type(of: value))
        }
    }

    // MARK: - Line reader

    /// Reads one LF/CRLF-terminated line (without the terminator). Returns nil at EOF with no data.
    private static func readLine(from handle: FileHandle) throws -> Data? {
        var buffer = Data()
        while true {
            let chunk = try handle.read(upToCount: 1)
            guard let chunk, !chunk.isEmpty else {
                return buffer.isEmpty ? nil : buffer
            }
            if chunk[0] == 0x0A { // \n
                // Drop trailing \r if present (CRLF).
                if buffer.last == 0x0D {
                    buffer.removeLast()
                }
                return buffer
            }
            buffer.append(chunk)
        }
    }
}
