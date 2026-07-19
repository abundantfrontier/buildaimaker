import BAMCore
import Foundation

/// Actionable row-level validation issue for dataset import.
public struct DatasetValidationIssue: Sendable, Equatable, Identifiable {
    /// Stable unique id for SwiftUI lists (never derived only from message text).
    public let id: String
    /// 1-based line number in the source JSONL, when known.
    public let line: Int?
    /// Stable product error code (typically `BAM_DATASET_INVALID`).
    public let code: BAMErrorCode
    /// Human-readable, actionable detail.
    public let message: String

    public init(
        line: Int?,
        code: BAMErrorCode = .datasetInvalid,
        message: String,
        id: String = UUID().uuidString
    ) {
        self.id = id
        self.line = line
        self.code = code
        self.message = message
    }

    /// Convenience `BAMError` for throw sites that only need the first issue.
    public var asBAMError: BAMError {
        let prefix = line.map { "line \($0): " } ?? ""
        return BAMError(code: code, message: prefix + message)
    }
}

/// Result of validating a text-chat JSONL file.
public struct DatasetValidationResult: Sendable, Equatable {
    public let isValid: Bool
    public let format: DetectedChatFormat?
    public let rowCount: Int
    public let issues: [DatasetValidationIssue]

    public init(
        isValid: Bool,
        format: DetectedChatFormat?,
        rowCount: Int,
        issues: [DatasetValidationIssue]
    ) {
        self.isValid = isValid
        self.format = format
        self.rowCount = rowCount
        self.issues = issues
    }

    /// First issue as a `BAMError`, if any.
    public var firstError: BAMError? {
        issues.first?.asBAMError
    }

    /// Aggregated multi-issue message for API throw sites (bounded).
    public var aggregatedError: BAMError? {
        guard !issues.isEmpty else { return nil }
        if issues.count == 1 { return issues[0].asBAMError }
        let parts = issues.prefix(5).map { issue -> String in
            let line = issue.line.map { "line \($0): " } ?? ""
            return line + issue.message
        }
        let suffix = issues.count > 5 ? " (+\(issues.count - 5) more)" : ""
        return BAMError(
            code: .datasetInvalid,
            message: parts.joined(separator: "; ") + suffix
        )
    }
}
