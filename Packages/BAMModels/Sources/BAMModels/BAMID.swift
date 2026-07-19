import Foundation

/// UUID v4 string helpers for library entity primary keys (K19).
public enum BAMID: Sendable {
    /// Generates a new UUID v4 string (Foundation `UUID` is RFC 4122 version 4).
    public static func generate() -> String {
        UUID().uuidString.lowercased()
    }

    /// Returns true if `raw` is a well-formed UUID string (any version/variant).
    public static func isValid(_ raw: String) -> Bool {
        UUID(uuidString: raw) != nil
    }

    /// Normalizes a valid UUID string to lowercase; returns `nil` if invalid.
    public static func normalize(_ raw: String) -> String? {
        guard let uuid = UUID(uuidString: raw) else { return nil }
        return uuid.uuidString.lowercased()
    }
}
