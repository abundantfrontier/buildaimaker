import CryptoKit
import Foundation

/// Subject of a voice-consent attestation.
public enum ConsentSubjectType: String, Codable, Sendable, CaseIterable, Equatable {
    case self_ = "self"
    case thirdParty = "third_party"
    case syntheticOrPublicDomain = "synthetic_or_public_domain"
}

/// Allowed use scope for consented voice material.
public enum ConsentScope: String, Codable, Sendable, CaseIterable, Equatable {
    case personalUse = "personal_use"
    case shareableExport = "shareable_export"
    case researchOnly = "research_only"
}

/// Voice cloning consent record bound by id + content hash into every voice profile/export (K11).
///
/// `contentHash` is SHA-256 of the canonical JSON serialization of all fields except itself.
public struct ConsentRecord: Codable, Sendable, Equatable {
    public var id: String
    public var schemaVersion: Int
    public var createdAt: String
    public var subjectType: ConsentSubjectType
    public var subjectDisplayName: String
    public var attestorUserLabel: String
    public var scope: ConsentScope
    /// Order is semantic — preserved for hashing and display.
    public var statements: [String]
    public var attestedAt: String
    public var appVersion: String
    /// Optional free text; omitted from JSON when nil.
    public var jurisdictionNote: String?
    public var retention: String
    /// Lowercase hex SHA-256 (optionally stored with `sha256:` prefix).
    public var contentHash: String

    /// Allowed keys on a ConsentRecord hash input (unknown keys rejected before hash).
    public static let allowedHashKeys: Set<String> = [
        "id",
        "schemaVersion",
        "createdAt",
        "subjectType",
        "subjectDisplayName",
        "attestorUserLabel",
        "scope",
        "statements",
        "attestedAt",
        "appVersion",
        "jurisdictionNote",
        "retention",
    ]

    public static let schemaVersionV1: Int = 1
    public static let defaultRetention = "until_user_deletes"

    public init(
        id: String,
        schemaVersion: Int = ConsentRecord.schemaVersionV1,
        createdAt: String,
        subjectType: ConsentSubjectType,
        subjectDisplayName: String,
        attestorUserLabel: String,
        scope: ConsentScope,
        statements: [String],
        attestedAt: String,
        appVersion: String,
        jurisdictionNote: String? = nil,
        retention: String = ConsentRecord.defaultRetention,
        contentHash: String = ""
    ) {
        self.id = id
        self.schemaVersion = schemaVersion
        self.createdAt = createdAt
        self.subjectType = subjectType
        self.subjectDisplayName = subjectDisplayName
        self.attestorUserLabel = attestorUserLabel
        self.scope = scope
        self.statements = statements
        self.attestedAt = attestedAt
        self.appVersion = appVersion
        self.jurisdictionNote = jurisdictionNote
        self.retention = retention
        self.contentHash = contentHash
    }

    enum CodingKeys: String, CodingKey {
        case id
        case schemaVersion
        case createdAt
        case subjectType
        case subjectDisplayName
        case attestorUserLabel
        case scope
        case statements
        case attestedAt
        case appVersion
        case jurisdictionNote
        case retention
        case contentHash
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        createdAt = try c.decode(String.self, forKey: .createdAt)
        subjectType = try c.decode(ConsentSubjectType.self, forKey: .subjectType)
        subjectDisplayName = try c.decode(String.self, forKey: .subjectDisplayName)
        attestorUserLabel = try c.decode(String.self, forKey: .attestorUserLabel)
        scope = try c.decode(ConsentScope.self, forKey: .scope)
        statements = try c.decode([String].self, forKey: .statements)
        attestedAt = try c.decode(String.self, forKey: .attestedAt)
        appVersion = try c.decode(String.self, forKey: .appVersion)
        jurisdictionNote = try c.decodeIfPresent(String.self, forKey: .jurisdictionNote)
        retention = try c.decode(String.self, forKey: .retention)
        contentHash = try c.decode(String.self, forKey: .contentHash)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(subjectType, forKey: .subjectType)
        try c.encode(subjectDisplayName, forKey: .subjectDisplayName)
        try c.encode(attestorUserLabel, forKey: .attestorUserLabel)
        try c.encode(scope, forKey: .scope)
        try c.encode(statements, forKey: .statements)
        try c.encode(attestedAt, forKey: .attestedAt)
        try c.encode(appVersion, forKey: .appVersion)
        if let jurisdictionNote {
            try c.encode(jurisdictionNote, forKey: .jurisdictionNote)
        }
        try c.encode(retention, forKey: .retention)
        try c.encode(contentHash, forKey: .contentHash)
    }
}

// MARK: - Canonical contentHash

public enum ConsentHashError: Error, Equatable, Sendable {
    case unknownKeys([String])
    case serializationFailed
}

extension ConsentRecord {
    /// Strips an optional `sha256:` prefix and lowercases for comparison.
    public static func normalizeHash(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("sha256:") {
            return String(trimmed.dropFirst("sha256:".count)).lowercased()
        }
        return trimmed.lowercased()
    }

    /// Builds the hash-input object (all fields except `contentHash`).
    /// Optional `jurisdictionNote` is omitted when nil or empty.
    public func hashInputDictionary() -> [String: Any] {
        var dict: [String: Any] = [
            "id": id,
            "schemaVersion": schemaVersion,
            "createdAt": createdAt,
            "subjectType": subjectType.rawValue,
            "subjectDisplayName": subjectDisplayName,
            "attestorUserLabel": attestorUserLabel,
            "scope": scope.rawValue,
            "statements": statements,
            "attestedAt": attestedAt,
            "appVersion": appVersion,
            "retention": retention,
        ]
        if let note = jurisdictionNote, !note.isEmpty {
            dict["jurisdictionNote"] = note
        }
        return dict
    }

    /// Canonical UTF-8 JSON for hashing (sorted keys, no insignificant whitespace).
    public func canonicalJSONBytes() throws -> Data {
        try ConsentCanonicalJSON.serialize(hashInputDictionary())
    }

    /// Computes lowercase hex SHA-256 of the canonical hash input.
    public func computeContentHash() throws -> String {
        let data = try canonicalJSONBytes()
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Returns a copy with `contentHash` set to the freshly computed value.
    public func withComputedContentHash() throws -> ConsentRecord {
        var copy = self
        copy.contentHash = try computeContentHash()
        return copy
    }

    /// True when stored `contentHash` matches the recomputed canonical hash.
    public func verifyContentHash() throws -> Bool {
        Self.normalizeHash(contentHash) == (try computeContentHash())
    }
}

/// Normative canonical JSON serializer for ConsentRecord contentHash (v1).
///
/// Rules (design doc):
/// - Allowed keys only; unknown keys rejected before hash
/// - Object keys sorted lexicographically by Unicode code point
/// - No insignificant whitespace
/// - No trailing newline
/// - `null` never emitted for optional fields (omit instead)
/// - Array element order preserved
public enum ConsentCanonicalJSON: Sendable {
    /// Serializes `object` (hash input) to canonical UTF-8 JSON bytes.
    public static func serialize(_ object: [String: Any]) throws -> Data {
        let unknown = object.keys.filter { !ConsentRecord.allowedHashKeys.contains($0) }.sorted()
        if !unknown.isEmpty {
            throw ConsentHashError.unknownKeys(unknown)
        }
        let json = try encodeValue(object)
        guard let data = json.data(using: .utf8) else {
            throw ConsentHashError.serializationFailed
        }
        return data
    }

    private static func encodeValue(_ value: Any) throws -> String {
        switch value {
        case let s as String:
            return encodeString(s)
        case let i as Int:
            return String(i)
        case let i as Int64:
            return String(i)
        case let n as NSNumber:
            // Bool is bridged as NSNumber; reject non-int numerics for hash form.
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                throw ConsentHashError.serializationFailed
            }
            // Prefer integer form when possible.
            if CFNumberIsFloatType(n) {
                throw ConsentHashError.serializationFailed
            }
            return n.stringValue
        case let arr as [Any]:
            let parts = try arr.map { try encodeValue($0) }
            return "[" + parts.joined(separator: ",") + "]"
        case let arr as [String]:
            let parts = arr.map { encodeString($0) }
            return "[" + parts.joined(separator: ",") + "]"
        case let dict as [String: Any]:
            // Lexicographic order by Unicode code point (Swift String comparable).
            let sortedKeys = dict.keys.sorted()
            var parts: [String] = []
            parts.reserveCapacity(sortedKeys.count)
            for key in sortedKeys {
                guard let v = dict[key] else { continue }
                parts.append(encodeString(key) + ":" + (try encodeValue(v)))
            }
            return "{" + parts.joined(separator: ",") + "}"
        default:
            throw ConsentHashError.serializationFailed
        }
    }

    /// RFC 8259 string escaping.
    private static func encodeString(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar.value {
            case 0x22: out += "\\\"" // "
            case 0x5C: out += "\\\\" // \
            case 0x08: out += "\\b"
            case 0x0C: out += "\\f"
            case 0x0A: out += "\\n"
            case 0x0D: out += "\\r"
            case 0x09: out += "\\t"
            case 0x00 ..< 0x20:
                out += String(format: "\\u%04x", scalar.value)
            default:
                out.unicodeScalars.append(scalar)
            }
        }
        out += "\""
        return out
    }
}
