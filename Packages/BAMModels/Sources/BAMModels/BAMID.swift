import Foundation

/// UUID v4 string helpers for library entity primary keys (K19).
public enum BAMID: Sendable {
    /// Generates a new UUID v4 string (Foundation `UUID` is RFC 4122 version 4).
    public static func generate() -> String {
        UUID().uuidString.lowercased()
    }

    /// Returns true if `raw` is a well-formed **UUID v4** string (RFC 4122 version + variant).
    ///
    /// Shape-only parsing is not enough: non-v4 UUIDs that `Foundation.UUID` accepts
    /// are rejected so library IDs stay on the K19 v4 policy.
    public static func isValid(_ raw: String) -> Bool {
        isUUIDV4(raw)
    }

    /// Normalizes a valid UUID **v4** string to lowercase; returns `nil` if invalid or not v4.
    public static func normalize(_ raw: String) -> String? {
        guard isUUIDV4(raw), let uuid = UUID(uuidString: raw) else { return nil }
        return uuid.uuidString.lowercased()
    }

    /// True when `raw` parses as UUID and has version nibble `4` and RFC 4122 variant.
    public static func isUUIDV4(_ raw: String) -> Bool {
        guard UUID(uuidString: raw) != nil else { return false }
        // Use the original hyphenated form when present; Foundation accepts both cases.
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let parts = normalized.split(separator: "-")
        guard parts.count == 5 else { return false }
        // Version: first char of third group must be '4'.
        guard parts[2].first == "4" else { return false }
        // Variant: first char of fourth group in {8,9,a,b}.
        guard let variant = parts[3].first else { return false }
        return "89ab".contains(variant)
    }
}
