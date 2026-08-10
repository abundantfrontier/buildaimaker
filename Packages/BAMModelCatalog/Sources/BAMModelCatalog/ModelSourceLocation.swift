import Foundation

/// Popular remote locations (and custom) where base models can be discovered.
public enum ModelSourceLocation: String, CaseIterable, Identifiable, Codable, Sendable {
    /// Hugging Face Hub, MLX-tagged models (broad search).
    case huggingFaceMLX
    /// HF author `mlx-community` (most common MLX Instruct builds).
    case mlxCommunity
    /// HF author `mlx-community` + Qwen family bias in query.
    case qwenMLX
    /// User-supplied HF repo id or URL (Hugging Face, or other resolve-compatible URL).
    case custom

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .huggingFaceMLX: return "Hugging Face (MLX)"
        case .mlxCommunity: return "mlx-community"
        case .qwenMLX: return "Qwen MLX (popular)"
        case .custom: return "Custom URL / repo"
        }
    }

    public var subtitle: String {
        switch self {
        case .huggingFaceMLX:
            return "Search models tagged mlx on huggingface.co"
        case .mlxCommunity:
            return "Author filter: mlx-community (recommended for Apple Silicon)"
        case .qwenMLX:
            return "Popular Qwen2.5 Instruct 4-bit MLX builds"
        case .custom:
            return "Paste a HF repo id (org/name) or full https URL"
        }
    }

    public var systemImage: String {
        switch self {
        case .huggingFaceMLX: return "globe"
        case .mlxCommunity: return "cpu"
        case .qwenMLX: return "sparkles"
        case .custom: return "link"
        }
    }

    /// Whether this location uses live search vs paste-only.
    public var supportsSearch: Bool {
        switch self {
        case .custom: return false
        default: return true
        }
    }

    /// Default search query when the user opens this location.
    /// Empty = list top downloads for that location (widest results).
    public var defaultQuery: String {
        switch self {
        case .huggingFaceMLX: return ""
        case .mlxCommunity: return ""
        case .qwenMLX: return "Qwen"
        case .custom: return ""
        }
    }

    /// Page size for live HF listing.
    public var preferredPageSize: Int { 100 }
}

/// One remote model listing from a source search (or custom resolve).
public struct ModelRemoteListing: Identifiable, Equatable, Sendable, Codable {
    /// Hub repo id, e.g. `mlx-community/Qwen2.5-1.5B-Instruct-4bit`.
    public var sourceKey: String
    public var name: String
    public var author: String?
    public var downloads: Int?
    public var likes: Int?
    public var tags: [String]
    public var pipelineTag: String?
    /// Absolute page URL when known.
    public var pageURL: String?
    public var sourceLocation: ModelSourceLocation

    public var id: String { sourceKey }

    public init(
        sourceKey: String,
        name: String,
        author: String? = nil,
        downloads: Int? = nil,
        likes: Int? = nil,
        tags: [String] = [],
        pipelineTag: String? = nil,
        pageURL: String? = nil,
        sourceLocation: ModelSourceLocation = .huggingFaceMLX
    ) {
        self.sourceKey = sourceKey
        self.name = name
        self.author = author
        self.downloads = downloads
        self.likes = likes
        self.tags = tags
        self.pipelineTag = pipelineTag
        self.pageURL = pageURL
        self.sourceLocation = sourceLocation
    }

    public var displayAuthor: String {
        if let author, !author.isEmpty { return author }
        if let slash = sourceKey.firstIndex(of: "/") {
            return String(sourceKey[..<slash])
        }
        return "—"
    }
}

/// Curated popular picks shown without a network call (offline-friendly bootstrap).
public enum ModelSourcePopularPicks: Sendable {
    public static let listings: [ModelRemoteListing] = [
        ModelRemoteListing(
            sourceKey: "mlx-community/Qwen2.5-0.5B-Instruct-4bit",
            name: "Qwen2.5 Instruct 0.5B (4-bit)",
            author: "mlx-community",
            tags: ["mlx", "qwen2.5", "4bit"],
            pageURL: "https://huggingface.co/mlx-community/Qwen2.5-0.5B-Instruct-4bit",
            sourceLocation: .qwenMLX
        ),
        ModelRemoteListing(
            sourceKey: "mlx-community/Qwen2.5-1.5B-Instruct-4bit",
            name: "Qwen2.5 Instruct 1.5B (4-bit)",
            author: "mlx-community",
            tags: ["mlx", "qwen2.5", "4bit"],
            pageURL: "https://huggingface.co/mlx-community/Qwen2.5-1.5B-Instruct-4bit",
            sourceLocation: .qwenMLX
        ),
        ModelRemoteListing(
            sourceKey: "mlx-community/Qwen2.5-3B-Instruct-4bit",
            name: "Qwen2.5 Instruct 3B (4-bit)",
            author: "mlx-community",
            tags: ["mlx", "qwen2.5", "4bit"],
            pageURL: "https://huggingface.co/mlx-community/Qwen2.5-3B-Instruct-4bit",
            sourceLocation: .qwenMLX
        ),
        ModelRemoteListing(
            sourceKey: "mlx-community/Llama-3.2-1B-Instruct-4bit",
            name: "Llama 3.2 1B Instruct (4-bit)",
            author: "mlx-community",
            tags: ["mlx", "llama", "4bit"],
            pageURL: "https://huggingface.co/mlx-community/Llama-3.2-1B-Instruct-4bit",
            sourceLocation: .mlxCommunity
        ),
        ModelRemoteListing(
            sourceKey: "mlx-community/Phi-3.5-mini-instruct-4bit",
            name: "Phi-3.5 mini Instruct (4-bit)",
            author: "mlx-community",
            tags: ["mlx", "phi", "4bit"],
            pageURL: "https://huggingface.co/mlx-community/Phi-3.5-mini-instruct-4bit",
            sourceLocation: .mlxCommunity
        ),
    ]
}
