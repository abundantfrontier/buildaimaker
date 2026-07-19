import Foundation

/// Product policy for remote / cloud training (K22).
///
/// v1 ships **local Apple Silicon only**. Real cloud/SSH is deferred until after
/// product-market fit. `ff.cloudRunner` remains off by default and must not ship
/// enabled in 1.0. Keep `RemoteRunner` + `FakeRemoteRunner` for interface stability.
public enum CloudPolicy: Sendable {
    /// Settings / debug copy shown whenever remote training is discussed.
    public static let deferredMessage = "Remote training deferred post-PMF"

    /// Stable key for the cloud runner feature flag.
    public static let featureFlagKey = FeatureFlags.Key.cloudRunner

    /// Whether product code may select a remote runner backend.
    /// Defaults to `false` via `FeatureFlags.default`.
    public static func isCloudRunnerEnabled(_ flags: FeatureFlags) -> Bool {
        flags.cloudRunner
    }

    /// Throws `BAM_CAPABILITY_UNSUPPORTED` when cloud runner is disabled (v1 default).
    public static func requireCloudRunnerEnabled(_ flags: FeatureFlags) throws {
        guard flags.cloudRunner else {
            throw BAMError(code: .capabilityUnsupported, message: deferredMessage)
        }
    }
}
