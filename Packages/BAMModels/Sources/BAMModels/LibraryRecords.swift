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

/// Lightweight domain row shapes mirroring SQLite v1 (Codable for fixtures / export).
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
