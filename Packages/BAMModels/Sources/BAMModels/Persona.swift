import Foundation

/// Resolved playground mode after persona component resolution.
public enum PersonaMode: String, Codable, Sendable, CaseIterable, Equatable {
    /// LLM + voice — Text + Talk.
    case full
    /// LLM only — Text mode; Talk disabled or system-voice banner.
    case textOnly
    /// Voice only — TTS sample; chat disabled.
    case voicePreview
}

/// LLM component refs on a persona (ids only; no knowledge-pack keys in v1).
public struct PersonaLLMComponents: Codable, Sendable, Equatable {
    public var baseModelId: String?
    public var adapterArtifactId: String?

    public init(baseModelId: String? = nil, adapterArtifactId: String? = nil) {
        self.baseModelId = baseModelId
        self.adapterArtifactId = adapterArtifactId
    }

    public var hasLLM: Bool {
        baseModelId != nil || adapterArtifactId != nil
    }
}

/// Voice component refs on a persona.
public struct PersonaVoiceComponents: Codable, Sendable, Equatable {
    public var voiceProfileId: String?

    public init(voiceProfileId: String? = nil) {
        self.voiceProfileId = voiceProfileId
    }

    public var hasVoice: Bool {
        voiceProfileId != nil
    }
}

/// Sampling knobs stored with a persona (optional).
public struct PersonaSampling: Codable, Sendable, Equatable {
    public var temperature: Double?
    public var topP: Double?
    public var maxTokens: Int?

    public init(temperature: Double? = nil, topP: Double? = nil, maxTokens: Int? = nil) {
        self.temperature = temperature
        self.topP = topP
        self.maxTokens = maxTokens
    }
}

/// Canonical nested persona document (pack `persona.json` / SQLite `personas.json` body).
///
/// Knowledge / RAG pack keys are intentionally absent from this schema (K26).
/// Unknown keys are ignored by `JSONDecoder` defaults at import time.
public struct PersonaDocument: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    /// Semver string (e.g. `"1.0.0"`).
    public var version: String
    /// Pack format version; pinned to `ProtocolVersions.personaPackFormat` (= 1).
    public var formatVersion: Int
    public var llm: PersonaLLMComponents?
    public var voice: PersonaVoiceComponents?
    public var systemPrompt: String?
    public var sampling: PersonaSampling?

    public static let formatVersionV1: Int = 1

    public init(
        id: String,
        name: String,
        version: String,
        formatVersion: Int = PersonaDocument.formatVersionV1,
        llm: PersonaLLMComponents? = nil,
        voice: PersonaVoiceComponents? = nil,
        systemPrompt: String? = nil,
        sampling: PersonaSampling? = nil
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.formatVersion = formatVersion
        self.llm = llm
        self.voice = voice
        self.systemPrompt = systemPrompt
        self.sampling = sampling
    }

    /// Infers `PersonaMode` from component presence (resolution without library lookup).
    public func inferredMode() -> PersonaMode? {
        let hasLLM = llm?.hasLLM == true
        let hasVoice = voice?.hasVoice == true
        if !hasLLM && !hasVoice { return nil }
        if hasLLM && hasVoice { return .full }
        if hasLLM { return .textOnly }
        return .voicePreview
    }
}
