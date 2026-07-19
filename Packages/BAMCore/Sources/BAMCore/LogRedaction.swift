import Foundation

/// Redacts dataset sample / training text from default logs.
///
/// Controlled by `BAM_REDACT_SAMPLES` (default **on** when unset or `1`).
/// Set `BAM_REDACT_SAMPLES=0` only for explicit debug of sample payloads.
///
/// Workers and the supervisor must never emit full dataset rows at info level
/// in default product configuration (security controls matrix).
public enum LogRedaction: Sendable {
    public static let placeholder = "[REDACTED_SAMPLE]"

    /// Keys / markers that usually precede free-text sample payloads.
    public static let sampleMarkers: [String] = [
        "sample:",
        "sample=",
        "samples:",
        "example:",
        "example=",
        "prompt:",
        "prompt=",
        "completion:",
        "completion=",
        "content:",
        "\"content\":",
        "\"text\":",
        "user:",
        "assistant:",
        "system:",
        "training sample",
        "dataset row",
        "jsonl:",
    ]

    /// Whether redaction is active for the given environment.
    ///
    /// - `nil` / empty / `1` / `true` → enabled (product default)
    /// - `0` / `false` / `off` → disabled
    public static func isEnabled(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        guard let raw = environment[LibraryPaths.EnvironmentKey.redactSamples] else {
            return true
        }
        let v = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if v.isEmpty { return true }
        switch v {
        case "0", "false", "no", "off":
            return false
        default:
            return true
        }
    }

    /// Heuristic: message looks like it embeds dataset / chat sample text.
    public static func looksLikeSamplePayload(_ message: String) -> Bool {
        let lower = message.lowercased()

        // JSON conversation fragments common in JSONL dumps.
        if lower.contains("\"role\"") && lower.contains("\"content\"") {
            return true
        }
        if lower.contains("\"messages\"") && lower.contains("\"content\"") {
            return true
        }

        for marker in sampleMarkers {
            if lower.contains(marker) {
                // Avoid false positives on short operational logs like "sampleGenerationCount=3".
                if marker == "sample:" || marker == "sample=" || marker.hasPrefix("sample") {
                    // "sampleGenerationCount" / "sample gens" are metrics — allow unless long.
                    if lower.contains("samplegeneration") || lower.contains("sample gen") {
                        continue
                    }
                }
                return true
            }
        }

        // Long lines that look like raw JSONL records (sharegpt / openai messages).
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count >= 240,
           trimmed.hasPrefix("{"),
           (trimmed.contains("\"conversations\"")
               || trimmed.contains("\"messages\"")
               || trimmed.contains("\"text\""))
        {
            return true
        }

        return false
    }

    /// Redact a single log message for default product logging.
    ///
    /// - Parameters:
    ///   - message: Raw log text (may contain sample payloads).
    ///   - level: Protocol log level (`debug`, `info`, `warn`, `error`). Debug is still
    ///     redacted when redaction is enabled — use `BAM_REDACT_SAMPLES=0` to inspect samples.
    ///   - environment: Process env (tests inject).
    public static func redactMessage(
        _ message: String,
        level: String = "info",
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        _ = level
        guard isEnabled(environment: environment) else { return message }
        guard looksLikeSamplePayload(message) else {
            // Still scrub inline quoted content after known keys without full-line match.
            return scrubInlinePayloads(message)
        }
        return redactMatchedMessage(message)
    }

    /// Convenience: redact only when enabled; identity otherwise.
    public static func redactForDefaultLog(
        _ message: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        redactMessage(message, level: "info", environment: environment)
    }

    // MARK: - Private

    private static func redactMatchedMessage(_ message: String) -> String {
        // Preserve a short operational prefix before the first sample marker.
        let lower = message.lowercased()
        var cutIndex: String.Index?
        for marker in sampleMarkers {
            if let r = lower.range(of: marker) {
                if cutIndex == nil || r.lowerBound < cutIndex! {
                    cutIndex = r.lowerBound
                }
            }
        }
        if let cut = cutIndex, cut > message.startIndex {
            let prefix = message[..<cut].trimmingCharacters(in: .whitespaces)
            if !prefix.isEmpty, prefix.count <= 120 {
                return "\(prefix) \(placeholder)"
            }
        }
        return placeholder
    }

    /// Light scrub for messages that mix metrics with a single quoted payload.
    private static func scrubInlinePayloads(_ message: String) -> String {
        var result = message
        // content="...." or text='....' longer than 40 chars
        let patterns = [
            #"content\s*=\s*\"[^\"]{40,}\""#,
            #"content\s*=\s*'[^']{40,}'"#,
            #"text\s*=\s*\"[^\"]{40,}\""#,
            #"prompt\s*=\s*\"[^\"]{40,}\""#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                continue
            }
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = regex.stringByReplacingMatches(
                in: result,
                options: [],
                range: range,
                withTemplate: "content=\(placeholder)"
            )
        }
        return result
    }
}
