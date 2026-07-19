import BAMCore
import Foundation

/// Fatal codes produced by the persona resolution algorithm (design: resolvePersona).
public enum PersonaResolutionCode: String, Codable, Sendable, CaseIterable, Equatable {
    /// No LLM and no voice components.
    case emptyPersona = "EMPTY_PERSONA"
    /// Adapter id present but artifact missing from library.
    case missingAdapter = "MISSING_ADAPTER"
    /// Adapter's `baseModelId` disagrees with persona LLM base.
    case adapterBaseMismatch = "ADAPTER_BASE_MISMATCH"
    /// Base model id present but model missing from library.
    case missingBase = "MISSING_BASE"
    /// Voice profile id present but profile missing.
    case missingVoice = "MISSING_VOICE"
    /// Voice profile consent hash fails verification.
    case consentTamper = "CONSENT_TAMPER"
}

/// Non-fatal warnings attached to a successful `ResolvedPersona`.
public enum PersonaResolutionWarning: String, Codable, Sendable, CaseIterable, Equatable {
    /// Voice-only persona — chat disabled in playground routing.
    case voicePreviewNoLLM = "VOICE_PREVIEW_NO_LLM"
    /// Knowledge/RAG keys present on raw import JSON; ignored in v1 (K26).
    case ignoredKnowledge = "IGNORED_KNOWLEDGE"
}

/// Thrown when resolution fails with one or more fatal codes.
public struct PersonaUnresolvedError: Error, Sendable, Equatable {
    public var codes: [PersonaResolutionCode]
    public var messages: [String]

    public init(codes: [PersonaResolutionCode], messages: [String] = []) {
        self.codes = codes
        self.messages = messages
    }

    public var bamError: BAMError {
        if codes.contains(.emptyPersona) {
            return BAMError(
                code: .emptyPersona,
                message: messages.first ?? "Persona has no LLM or voice components"
            )
        }
        if codes.contains(.consentTamper) {
            return BAMError(
                code: .consentTamper,
                message: messages.first ?? "Voice consent hash verification failed"
            )
        }
        if codes.contains(.missingBase) || codes.contains(.missingAdapter) {
            return BAMError(
                code: .modelNotFound,
                message: messages.first ?? codes.map(\.rawValue).joined(separator: ",")
            )
        }
        return BAMError(
            code: .personaUnresolved,
            message: messages.isEmpty
                ? codes.map(\.rawValue).joined(separator: ",")
                : messages.joined(separator: "; ")
        )
    }
}

extension PersonaUnresolvedError: LocalizedError {
    public var errorDescription: String? {
        bamError.errorDescription
    }
}
