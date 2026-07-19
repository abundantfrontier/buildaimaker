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
    /// When true, this is the offline bundled toy fixture (not real train weights).
    public var isFixture: Bool

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
        format: String = "mlx",
        isFixture: Bool = false
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
        self.isFixture = isFixture
    }

    private enum CodingKeys: String, CodingKey {
        case sourceKey, name, archFamily, paramCountB, quantBits
        case minRamGB, chatTemplateId, license, format, isFixture
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sourceKey = try c.decode(String.self, forKey: .sourceKey)
        name = try c.decode(String.self, forKey: .name)
        archFamily = try c.decode(String.self, forKey: .archFamily)
        paramCountB = try c.decode(Double.self, forKey: .paramCountB)
        quantBits = try c.decode(Int.self, forKey: .quantBits)
        minRamGB = try c.decode(Int.self, forKey: .minRamGB)
        chatTemplateId = try c.decode(String.self, forKey: .chatTemplateId)
        license = try c.decode(String.self, forKey: .license)
        format = try c.decodeIfPresent(String.self, forKey: .format) ?? "mlx"
        isFixture = try c.decodeIfPresent(Bool.self, forKey: .isFixture) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(sourceKey, forKey: .sourceKey)
        try c.encode(name, forKey: .name)
        try c.encode(archFamily, forKey: .archFamily)
        try c.encode(paramCountB, forKey: .paramCountB)
        try c.encode(quantBits, forKey: .quantBits)
        try c.encode(minRamGB, forKey: .minRamGB)
        try c.encode(chatTemplateId, forKey: .chatTemplateId)
        try c.encode(license, forKey: .license)
        try c.encode(format, forKey: .format)
        if isFixture {
            try c.encode(true, forKey: .isFixture)
        }
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
