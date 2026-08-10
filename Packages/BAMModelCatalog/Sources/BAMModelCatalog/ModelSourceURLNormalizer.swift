import BAMCore
import Foundation

/// Parses user paste (repo id or URL) into a Hugging Face–style `sourceKey` / download plan.
public enum ModelSourceURLNormalizer: Sendable {
    public struct Resolved: Equatable, Sendable {
        /// Hub repo id `org/name` when HF-shaped; otherwise a sanitized slug for local install.
        public var sourceKey: String
        /// Optional explicit download base (for non-HF custom file trees).
        public var customResolveBaseURL: URL?
        /// Human page URL if known.
        public var pageURL: String?
        public var isHuggingFace: Bool

        public init(
            sourceKey: String,
            customResolveBaseURL: URL? = nil,
            pageURL: String? = nil,
            isHuggingFace: Bool
        ) {
            self.sourceKey = sourceKey
            self.customResolveBaseURL = customResolveBaseURL
            self.pageURL = pageURL
            self.isHuggingFace = isHuggingFace
        }
    }

    /// Accepts:
    /// - `mlx-community/Qwen2.5-1.5B-Instruct-4bit`
    /// - `https://huggingface.co/mlx-community/Qwen2.5-1.5B-Instruct-4bit`
    /// - `https://huggingface.co/mlx-community/Foo/tree/main`
    /// - `https://hf.co/org/name`
    /// - Other `https://…` roots (stored as custom resolve base; sourceKey = host+path slug)
    public static func resolve(_ raw: String) throws -> Resolved {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw BAMError(code: .schemaInvalid, message: "Empty model URL / repo id")
        }

        // Bare repo id: org/name
        if !trimmed.contains("://"), trimmed.contains("/"), !trimmed.contains(" ") {
            let parts = trimmed.split(separator: "/").map(String.init)
            guard parts.count >= 2,
                  parts.allSatisfy({ LibraryPaths.validatedPathComponent($0) != nil || !$0.isEmpty })
            else {
                throw BAMError(code: .schemaInvalid, message: "Invalid repo id “\(trimmed)”")
            }
            let key = parts.prefix(2).joined(separator: "/")
            return Resolved(
                sourceKey: key,
                pageURL: "https://huggingface.co/\(key)",
                isHuggingFace: true
            )
        }

        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else {
            // Maybe org/name with extra path junk
            if trimmed.contains("/"), !trimmed.contains(" ") {
                let cleaned = trimmed
                    .replacingOccurrences(of: "https://", with: "")
                    .replacingOccurrences(of: "http://", with: "")
                let parts = cleaned.split(separator: "/").map(String.init)
                if parts.count >= 2 {
                    let key = "\(parts[0])/\(parts[1])"
                    return Resolved(
                        sourceKey: key,
                        pageURL: "https://huggingface.co/\(key)",
                        isHuggingFace: true
                    )
                }
            }
            throw BAMError(
                code: .schemaInvalid,
                message: "Could not parse model location. Use org/name or an https URL."
            )
        }

        let host = (url.host ?? "").lowercased()
        if host == "huggingface.co" || host == "hf.co" || host == "www.huggingface.co" {
            let segments = url.pathComponents.filter { $0 != "/" }
            // path: /org/name[/tree/main[/…]]
            guard segments.count >= 2 else {
                throw BAMError(
                    code: .schemaInvalid,
                    message: "Hugging Face URL must include org/name: \(trimmed)"
                )
            }
            let org = segments[0]
            let name = segments[1]
            guard LibraryPaths.validatedPathComponent(org) != nil,
                  LibraryPaths.validatedPathComponent(name) != nil
            else {
                throw BAMError(code: .pathEscape, message: "Invalid HF path components")
            }
            let key = "\(org)/\(name)"
            return Resolved(
                sourceKey: key,
                pageURL: "https://huggingface.co/\(key)",
                isHuggingFace: true
            )
        }

        // Generic custom URL: use host + path as install key slug; download root = URL.
        var base = url
        // If pointing at a file, use parent directory as tree root.
        if !url.pathExtension.isEmpty, url.pathExtension != "" {
            base = url.deletingLastPathComponent()
        }
        let slugSource = "\(host)\(url.path)"
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .replacingOccurrences(of: "/", with: "--")
        let key = LibraryPaths.sanitizedPathComponent(
            slugSource.isEmpty ? "custom-model" : String(slugSource.prefix(120))
        )
        return Resolved(
            sourceKey: key,
            customResolveBaseURL: base,
            pageURL: trimmed,
            isHuggingFace: false
        )
    }
}
