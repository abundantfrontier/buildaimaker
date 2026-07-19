import Foundation

/// Dataset import mode (copy into library vs security-scoped reference).
public enum DatasetImportMode: String, Codable, Sendable, CaseIterable, Equatable {
    case copy
    case reference
}

/// Dataset availability status.
public enum DatasetStatus: String, Codable, Sendable, CaseIterable, Equatable {
    case ready
    case importing
    case unavailable
    case invalid
}

/// Model kind stored in the `models` table.
public enum ModelKind: String, Codable, Sendable, CaseIterable, Equatable {
    case base
    case adapterPlaceholder = "adapter_placeholder"
}

/// Artifact kind stored in the `artifacts` table.
public enum ArtifactKind: String, Codable, Sendable, CaseIterable, Equatable {
    case loraAdapter = "lora_adapter"
    case voiceProfile = "voice_profile"
}

// MARK: - SQLite v1 row shapes (Codable; GRDB FetchableRecord arrives with repositories)

/// Lightweight domain row shapes mirroring SQLite v1 (fixtures / export / future repos).
public struct DatasetRecord: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var modality: DatasetModality
    public var rootPath: String
    public var importMode: DatasetImportMode
    public var status: DatasetStatus
    public var createdAt: String

    public init(
        id: String,
        name: String,
        modality: DatasetModality,
        rootPath: String,
        importMode: DatasetImportMode,
        status: DatasetStatus,
        createdAt: String
    ) {
        self.id = id
        self.name = name
        self.modality = modality
        self.rootPath = rootPath
        self.importMode = importMode
        self.status = status
        self.createdAt = createdAt
    }
}

public struct DatasetVersionRecord: Codable, Sendable, Equatable {
    public var id: String
    public var datasetId: String
    public var version: Int
    public var contentHash: String?
    public var rowCount: Int?
    public var metaJSON: String

    public init(
        id: String,
        datasetId: String,
        version: Int,
        contentHash: String? = nil,
        rowCount: Int? = nil,
        metaJSON: String = "{}"
    ) {
        self.id = id
        self.datasetId = datasetId
        self.version = version
        self.contentHash = contentHash
        self.rowCount = rowCount
        self.metaJSON = metaJSON
    }
}

public struct ModelRecord: Codable, Sendable, Equatable {
    public var id: String
    public var sourceKey: String?
    public var contentHash: String?
    public var name: String
    public var kind: ModelKind
    public var archFamily: String?
    public var paramCountB: Double?
    public var quantBits: Int?
    public var license: String?
    public var localPath: String
    public var metaJSON: String

    public init(
        id: String,
        sourceKey: String? = nil,
        contentHash: String? = nil,
        name: String,
        kind: ModelKind,
        archFamily: String? = nil,
        paramCountB: Double? = nil,
        quantBits: Int? = nil,
        license: String? = nil,
        localPath: String,
        metaJSON: String = "{}"
    ) {
        self.id = id
        self.sourceKey = sourceKey
        self.contentHash = contentHash
        self.name = name
        self.kind = kind
        self.archFamily = archFamily
        self.paramCountB = paramCountB
        self.quantBits = quantBits
        self.license = license
        self.localPath = localPath
        self.metaJSON = metaJSON
    }
}

public struct ArtifactRecord: Codable, Sendable, Equatable {
    public var id: String
    public var kind: ArtifactKind
    public var jobId: String?
    public var baseModelId: String?
    public var localPath: String
    public var metricsJSON: String?
    public var createdAt: String

    public init(
        id: String,
        kind: ArtifactKind,
        jobId: String? = nil,
        baseModelId: String? = nil,
        localPath: String,
        metricsJSON: String? = nil,
        createdAt: String
    ) {
        self.id = id
        self.kind = kind
        self.jobId = jobId
        self.baseModelId = baseModelId
        self.localPath = localPath
        self.metricsJSON = metricsJSON
        self.createdAt = createdAt
    }
}

public struct JobRecord: Codable, Sendable, Equatable {
    public var id: String
    public var status: JobStatus
    public var modality: JobModality
    public var configJSON: String
    public var errorCode: String?
    public var errorMessage: String?
    public var createdAt: String
    public var updatedAt: String

    public init(
        id: String,
        status: JobStatus,
        modality: JobModality,
        configJSON: String,
        errorCode: String? = nil,
        errorMessage: String? = nil,
        createdAt: String,
        updatedAt: String
    ) {
        self.id = id
        self.status = status
        self.modality = modality
        self.configJSON = configJSON
        self.errorCode = errorCode
        self.errorMessage = errorMessage
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct VoiceProfileRecord: Codable, Sendable, Equatable {
    public var id: String
    public var engineId: String
    public var localPath: String
    public var consentRecordId: String
    public var consentContentHash: String
    public var createdAt: String

    public init(
        id: String,
        engineId: String,
        localPath: String,
        consentRecordId: String,
        consentContentHash: String,
        createdAt: String
    ) {
        self.id = id
        self.engineId = engineId
        self.localPath = localPath
        self.consentRecordId = consentRecordId
        self.consentContentHash = consentContentHash
        self.createdAt = createdAt
    }
}

/// SQLite index row for a consent document (`json` holds full `ConsentRecord` encoding).
public struct ConsentIndexRecord: Codable, Sendable, Equatable {
    public var id: String
    public var json: String
    public var contentHash: String
    public var createdAt: String

    public init(id: String, json: String, contentHash: String, createdAt: String) {
        self.id = id
        self.json = json
        self.contentHash = contentHash
        self.createdAt = createdAt
    }
}

/// SQLite index row for a persona (`json` holds full `PersonaDocument` encoding).
public struct PersonaIndexRecord: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var version: String
    public var json: String
    public var createdAt: String
    public var updatedAt: String

    public init(
        id: String,
        name: String,
        version: String,
        json: String,
        createdAt: String,
        updatedAt: String
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.json = json
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct BookmarkRecord: Codable, Sendable, Equatable {
    public var id: String
    public var entityType: String
    public var entityId: String
    /// Security-scoped bookmark blob (base64 when JSON-encoded for fixtures).
    public var bookmarkDataBase64: String

    public init(id: String, entityType: String, entityId: String, bookmarkDataBase64: String) {
        self.id = id
        self.entityType = entityType
        self.entityId = entityId
        self.bookmarkDataBase64 = bookmarkDataBase64
    }
}
