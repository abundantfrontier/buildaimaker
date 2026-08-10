import Foundation

/// Identity and layout constants for the offline tiny Qwen MLX fixture (K15).
///
/// Real multi-GB MLX weights are **not** shipped; they download separately via
/// the optional HF Hub path (`ff.hfHubDownload`) or manual placement under
/// `models/base/`.
public enum FixtureModel: Sendable {
    /// Catalog / library `sourceKey` for the bundled toy model.
    public static let sourceKey = "buildaimaker/tiny-qwen-mlx-fixture"

    /// Stable directory name under `models/base/` after install.
    public static let installDirectoryName = "tiny-qwen-mlx-fixture"

    /// Stable library entity id (UUID v4) for the fixture `ModelRecord`.
    public static let stableModelID = "a0000000-0000-4000-8000-0000000000f1"

    /// Relative path under Workers (living source for workers + docs).
    public static let workersRelativePath = "Workers/fixtures/models/tiny-qwen-mlx"

    /// Resource subdirectory name under the BAMModelCatalog module bundle.
    public static let bundleResourceDirectory = "tiny-qwen-mlx"

    /// Files expected in a valid fixture layout (used by install validation).
    public static let requiredFiles: [String] = [
        "config.json",
        "tokenizer_config.json",
        "tokenizer.json",
        "WEIGHTS_NOT_INCLUDED.txt",
    ]

    /// Display name aligned with the catalog entry.
    public static let displayName = "Tiny Qwen MLX Fixture"

    /// SPDX for the stub layout (Apache-2.0, matching Qwen2.5 family policy).
    public static let license = "Apache-2.0"

    /// Architecture family token.
    public static let archFamily = "qwen2.5"
}
