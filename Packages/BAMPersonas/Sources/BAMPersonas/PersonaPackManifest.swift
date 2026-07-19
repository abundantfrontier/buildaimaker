import BAMCore
import BAMModels
import Foundation

/// Pack Format v1 `manifest.json` (open zip+JSON, K8).
public struct PersonaPackManifest: Codable, Sendable, Equatable {
    /// Always `ProtocolVersions.personaPackFormat` (1).
    public var formatVersion: Int
    public var personaId: String
    public var personaName: String
    public var personaVersion: String
    /// Relative path → lowercase hex SHA-256 of file bytes.
    public var files: [String: String]
    /// False when consent scope is personal_use (share UX blocked; filesystem copy still works).
    public var exportAllowed: Bool
    public var createdAt: String
    /// Optional consent content hash embedded for quick binding checks.
    public var consentContentHash: String?

    public static let formatVersionV1: Int = ProtocolVersions.personaPackFormat

    public init(
        formatVersion: Int = PersonaPackManifest.formatVersionV1,
        personaId: String,
        personaName: String,
        personaVersion: String,
        files: [String: String] = [:],
        exportAllowed: Bool = true,
        createdAt: String,
        consentContentHash: String? = nil
    ) {
        self.formatVersion = formatVersion
        self.personaId = personaId
        self.personaName = personaName
        self.personaVersion = personaVersion
        self.files = files
        self.exportAllowed = exportAllowed
        self.createdAt = createdAt
        self.consentContentHash = consentContentHash
    }
}

/// Lightweight base-model reference written to `llm/base_ref.json` (weights optional).
public struct PersonaPackBaseRef: Codable, Sendable, Equatable {
    public var baseModelId: String
    public var sourceKey: String?
    public var contentHash: String?
    public var name: String?
    public var license: String?

    public init(
        baseModelId: String,
        sourceKey: String? = nil,
        contentHash: String? = nil,
        name: String? = nil,
        license: String? = nil
    ) {
        self.baseModelId = baseModelId
        self.sourceKey = sourceKey
        self.contentHash = contentHash
        self.name = name
        self.license = license
    }
}

/// Voice profile snapshot written to `voice/profile.json` (no absolute host paths).
public struct PersonaPackVoiceProfile: Codable, Sendable, Equatable {
    public var id: String
    public var engineId: String
    public var consentRecordId: String
    public var consentContentHash: String
    public var createdAt: String
    /// Relative path inside the pack (e.g. `voice/reference.wav`).
    public var referenceRelativePath: String?

    public init(
        id: String,
        engineId: String,
        consentRecordId: String,
        consentContentHash: String,
        createdAt: String,
        referenceRelativePath: String? = nil
    ) {
        self.id = id
        self.engineId = engineId
        self.consentRecordId = consentRecordId
        self.consentContentHash = consentContentHash
        self.createdAt = createdAt
        self.referenceRelativePath = referenceRelativePath
    }
}
