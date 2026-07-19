import Foundation

/// Canonical attestation statement texts for ConsentRecord v1 (design doc).
public enum ConsentStatements: Sendable {
    /// Primary rights statement (always required).
    public static let rightToUse =
        "I have the right to use this voice for the selected scope."

    /// Anti-fraud / illegal impersonation statement (always required).
    public static let noFraud =
        "I will not use this to commit fraud or illegal impersonation."

    /// Default ordered statement list used when building a record.
    public static let defaults: [String] = [rightToUse, noFraud]

    /// Secondary confirmation label for `third_party` subject type (UI gate only; not hashed).
    public static let thirdPartySecondaryConfirm =
        "I confirm I have explicit permission from the named person to clone their voice."
}
