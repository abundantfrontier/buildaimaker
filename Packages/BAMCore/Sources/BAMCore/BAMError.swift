import Foundation

/// Stable error-code namespace for BuildAIMaker.
/// Full domain models and localized messages land in later PRs; this is a light stub.
public enum BAMErrorCode: String, Codable, Sendable, CaseIterable {
    case pathEscape = "BAM_PATH_ESCAPE"
    case runtimeIntegrity = "BAM_RUNTIME_INTEGRITY"
    case protocolMismatch = "BAM_PROTOCOL_MISMATCH"
    case emptyPersona = "BAM_EMPTY_PERSONA"
    case workerCrash = "BAM_WORKER_CRASH"
    case workerHung = "BAM_WORKER_HUNG"
    case cancelled = "BAM_CANCELLED"
    case oomSoft = "BAM_OOM_SOFT"
    case preflightMemory = "BAM_PREFLIGHT_MEMORY"
    case datasetInvalid = "BAM_DATASET_INVALID"
    case modelNotFound = "BAM_MODEL_NOT_FOUND"
    case consentRequired = "BAM_CONSENT_REQUIRED"
    case consentTamper = "BAM_CONSENT_TAMPER"
}

/// Lightweight error carrying a stable code plus optional detail.
public struct BAMError: Error, Sendable, Equatable {
    public let code: BAMErrorCode
    public let message: String?

    public init(code: BAMErrorCode, message: String? = nil) {
        self.code = code
        self.message = message
    }
}

extension BAMError: LocalizedError {
    public var errorDescription: String? {
        if let message, !message.isEmpty {
            return "\(code.rawValue): \(message)"
        }
        return code.rawValue
    }
}
