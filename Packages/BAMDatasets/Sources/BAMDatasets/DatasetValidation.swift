import BAMCore
import Foundation

/// Actionable row-level validation issue for dataset import.
public struct DatasetValidationIssue: Sendable, Equatable, Identifiable {
    public var id: String { "L\(line.map(String.init) ?? "?"):\(message)" }

    /// 1-based line number in the source JSONL, when known.
    public let line: Int?
    /// Stable product error code (typically `BAM_DATASET_INVALID`).
    public let code: BAMErrorCode
    /// Human-readable, actionable detail.
    public let message: String

    public init(line: Int?, code: BAMErrorCode = .datasetInvalid, message: String) {
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
}
