import BAMCore
import Foundation

/// Optional Hugging Face Hub download client.
///
/// Production will stream repo files into `models/base/`; CI and unit tests use
/// `NoopHFHubClient` / never call this path with `ff.hfHubDownload` off.
public protocol HFHubClient: Sendable {
    /// Downloads a catalog model identified by `sourceKey` into `destinationDirectory`.
    ///
    /// - Parameters:
    ///   - sourceKey: HF repo id (e.g. `mlx-community/Qwen2.5-1.5B-Instruct-4bit`).
    ///   - destinationDirectory: Absolute path under `models/base/<id>/`.
    ///   - token: Optional HF access token from `HFTokenStore`.
    func download(
        sourceKey: String,
        destinationDirectory: URL,
        token: String?
    ) async throws
}

/// Default client: refuses network. Real HF integration lands when dogfood needs it.
///
/// Always throws `BAM_CAPABILITY_UNSUPPORTED` so enabling the flag without a
/// concrete client cannot accidentally hit the network in CI.
public struct NoopHFHubClient: HFHubClient {
    public init() {}

    public func download(
        sourceKey: String,
        destinationDirectory: URL,
        token: String?
    ) async throws {
        throw BAMError(
            code: .capabilityUnsupported,
            message: "HF Hub download client not implemented yet (sourceKey=\(sourceKey)). Use offline fixture install."
        )
    }
}
