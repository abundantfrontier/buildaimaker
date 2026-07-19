import Foundation

/// One supported base model listed in the living catalog (`Catalog/models.json`).
public struct CatalogEntry: Codable, Sendable, Equatable, Identifiable {
    /// Hugging Face / MLX hub id (e.g. `mlx-community/Qwen2.5-1.5B-Instruct-4bit`).
    public var sourceKey: String
    public var name: String
    /// Architecture family token (e.g. `qwen2.5`).
    public var archFamily: String
    /// Parameter count in billions.
    public var paramCountB: Double
    public var quantBits: Int
    /// Suggested minimum unified memory (GB) for comfortable use.
    public var minRamGB: Int
    public var chatTemplateId: String
    /// SPDX license identifier (e.g. `Apache-2.0`).
    public var license: String
    /// Weight layout / runtime format (`mlx`, `hf`, …).
    public var format: String

    public var id: String { sourceKey }

    public init(
        sourceKey: String,
        name: String,
        archFamily: String,
        paramCountB: Double,
        quantBits: Int,
        minRamGB: Int,
        chatTemplateId: String,
        license: String,
        format: String = "mlx"
    ) {
        self.sourceKey = sourceKey
        self.name = name
        self.archFamily = archFamily
        self.paramCountB = paramCountB
        self.quantBits = quantBits
        self.minRamGB = minRamGB
        self.chatTemplateId = chatTemplateId
        self.license = license
        self.format = format
    }
}

/// Root document for the living model catalog JSON.
public struct CatalogDocument: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var models: [CatalogEntry]

    public init(schemaVersion: Int = 1, models: [CatalogEntry]) {
        self.schemaVersion = schemaVersion
        self.models = models
    }
}
