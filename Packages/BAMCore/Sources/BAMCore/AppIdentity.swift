import Foundation

/// App-level identity constants shared across packages.
public enum AppIdentity: Sendable {
    public static let displayName = "BuildAIMaker"
    public static let bundleIDPlaceholder = "com.buildaimaker.app"

    /// Minimum recommended unified memory (GB) per product policy.
    public static let minimumUnifiedMemoryGB: Int = 16
}
