import Foundation

/// File pin: relative path + lowercase hex SHA-256.
public struct RuntimePinFile: Codable, Sendable, Equatable, Hashable {
    public var relativePath: String
    public var sha256: String

    public init(relativePath: String, sha256: String) {
        self.relativePath = relativePath
        self.sha256 = sha256.lowercased()
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        relativePath = try c.decode(String.self, forKey: .relativePath)
        sha256 = try c.decode(String.self, forKey: .sha256).lowercased()
    }
}

/// Named entry module pin (e.g. `llm_worker.main`).
public struct RuntimePinEntry: Codable, Sendable, Equatable, Hashable {
    public var id: String
    public var relativePath: String
    public var sha256: String

    public init(id: String, relativePath: String, sha256: String) {
        self.id = id
        self.relativePath = relativePath
        self.sha256 = sha256.lowercased()
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        relativePath = try c.decode(String.self, forKey: .relativePath)
        sha256 = try c.decode(String.self, forKey: .sha256).lowercased()
    }
}

/// Decoded `runtime-pins.json` (L2 integrity).
///
/// TeamID is **never** applied to venv/CPython — only lock + entry hashes and
/// interpreter path allowlisting under the managed env root.
public struct RuntimePins: Codable, Sendable, Equatable {
    public var version: Int
    public var appVersion: String
    public var sizeBudgetBytes: Int64?
    public var sizeBudgetLabel: String?
    public var lockfile: RuntimePinFile
    public var interpreterRelativePath: String
    public var entries: [RuntimePinEntry]

    public init(
        version: Int = 1,
        appVersion: String,
        sizeBudgetBytes: Int64? = nil,
        sizeBudgetLabel: String? = nil,
        lockfile: RuntimePinFile,
        interpreterRelativePath: String,
        entries: [RuntimePinEntry]
    ) {
        self.version = version
        self.appVersion = appVersion
        self.sizeBudgetBytes = sizeBudgetBytes
        self.sizeBudgetLabel = sizeBudgetLabel
        self.lockfile = lockfile
        self.interpreterRelativePath = interpreterRelativePath
        self.entries = entries
    }

    /// Default size budget used by progress UI when pins omit an explicit value (8 GiB).
    public static let defaultSizeBudgetBytes: Int64 = 8 * 1024 * 1024 * 1024

    public var effectiveSizeBudgetBytes: Int64 {
        sizeBudgetBytes ?? Self.defaultSizeBudgetBytes
    }

    public var effectiveSizeBudgetLabel: String {
        sizeBudgetLabel ?? "3–8 GB"
    }

    public static func load(from url: URL) throws -> RuntimePins {
        let data = try Data(contentsOf: url)
        return try decode(data)
    }

    public static func decode(_ data: Data) throws -> RuntimePins {
        let decoder = JSONDecoder()
        let pins = try decoder.decode(RuntimePins.self, from: data)
        guard pins.version == 1 else {
            throw BAMError(
                code: .runtimeIntegrity,
                message: "unsupported runtime-pins version \(pins.version)"
            )
        }
        guard !pins.entries.isEmpty else {
            throw BAMError(
                code: .runtimeIntegrity,
                message: "runtime-pins entries must be non-empty"
            )
        }
        return pins
    }
}
