import Foundation

/// Stable error-code namespace for BuildAIMaker.
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
    case downloadFailed = "BAM_DOWNLOAD_FAILED"
    case consentRequired = "BAM_CONSENT_REQUIRED"
    case consentTamper = "BAM_CONSENT_TAMPER"
    case personaUnresolved = "BAM_PERSONA_UNRESOLVED"
    case tccMicDenied = "BAM_TCC_MIC_DENIED"
    case capabilityUnsupported = "BAM_CAPABILITY_UNSUPPORTED"
    case licenseBlock = "BAM_LICENSE_BLOCK"
    case migrationFailed = "BAM_MIGRATION_FAILED"
    case unknownKey = "BAM_UNKNOWN_KEY"
    case schemaInvalid = "BAM_SCHEMA_INVALID"
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
