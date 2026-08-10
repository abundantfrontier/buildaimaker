import BAMCore
import Foundation

/// One page of remote model search results.
public struct ModelSearchPage: Sendable, Equatable {
    public var listings: [ModelRemoteListing]
    /// True when the hub likely has more rows (page filled to limit).
    public var hasMore: Bool
    /// Offset used for this page (for Load more = skip + listings.count).
    public var skip: Int
    public var limit: Int

    public init(
        listings: [ModelRemoteListing],
        hasMore: Bool,
        skip: Int = 0,
        limit: Int = 100
    ) {
        self.listings = listings
        self.hasMore = hasMore
        self.skip = skip
        self.limit = limit
    }
}

/// Searches remote model hubs for listings the user can install.
public protocol ModelSourceSearchClient: Sendable {
    func search(
        location: ModelSourceLocation,
        query: String,
        limit: Int,
        skip: Int,
        token: String?
    ) async throws -> ModelSearchPage
}

/// Offline / unit-test client: curated picks filtered by query.
public struct StaticModelSourceSearchClient: ModelSourceSearchClient {
    public var listings: [ModelRemoteListing]

    public init(listings: [ModelRemoteListing] = ModelSourcePopularPicks.listings) {
        self.listings = listings
    }

    public func search(
        location: ModelSourceLocation,
        query: String,
        limit: Int,
        skip: Int,
        token: String?
    ) async throws -> ModelSearchPage {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var rows = listings
        switch location {
        case .mlxCommunity, .qwenMLX:
            rows = rows.filter { $0.author == "mlx-community" || $0.sourceKey.hasPrefix("mlx-community/") }
        case .huggingFaceMLX, .custom:
            break
        }
        if !q.isEmpty {
            rows = rows.filter {
                $0.sourceKey.lowercased().contains(q)
                    || $0.name.lowercased().contains(q)
                    || $0.tags.contains(where: { $0.lowercased().contains(q) })
            }
        }
        if location == .qwenMLX {
            rows = rows.filter {
                $0.sourceKey.localizedCaseInsensitiveContains("qwen")
                    || $0.name.localizedCaseInsensitiveContains("qwen")
            }
        }
        let pageSize = max(1, limit)
        let start = max(0, skip)
        let slice = Array(rows.dropFirst(start).prefix(pageSize))
        return ModelSearchPage(
            listings: slice,
            hasMore: start + slice.count < rows.count,
            skip: start,
            limit: pageSize
        )
    }
}

/// Live Hugging Face Hub model search (`/api/models`).
///
/// Supports `limit` + `skip` pagination. Empty queries list top downloads for the
/// selected location (not a tiny curated set).
public struct HuggingFaceModelSourceSearchClient: ModelSourceSearchClient {
    public var session: URLSession
    public var apiBaseURL: URL
    /// HF caps around 100 per request in practice; we clamp to this.
    public var maxPageSize: Int

    public init(
        session: URLSession = .shared,
        apiBaseURL: URL = URL(string: "https://huggingface.co/api/models")!,
        maxPageSize: Int = 100
    ) {
        self.session = session
        self.apiBaseURL = apiBaseURL
        self.maxPageSize = maxPageSize
    }

    public func search(
        location: ModelSourceLocation,
        query: String,
        limit: Int,
        skip: Int,
        token: String?
    ) async throws -> ModelSearchPage {
        let pageSize = min(max(limit, 1), maxPageSize)
        let offset = max(0, skip)

        var components = URLComponents(url: apiBaseURL, resolvingAgainstBaseURL: false)!
        var items: [URLQueryItem] = [
            URLQueryItem(name: "limit", value: String(pageSize)),
            URLQueryItem(name: "skip", value: String(offset)),
            URLQueryItem(name: "sort", value: "downloads"),
            URLQueryItem(name: "direction", value: "-1"),
            URLQueryItem(name: "full", value: "false"),
            URLQueryItem(name: "config", value: "false"),
        ]

        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        switch location {
        case .huggingFaceMLX:
            // Broad MLX tag; empty query = top MLX models by downloads.
            items.append(URLQueryItem(name: "filter", value: "mlx"))
            if !q.isEmpty {
                items.append(URLQueryItem(name: "search", value: q))
            }
        case .mlxCommunity:
            items.append(URLQueryItem(name: "author", value: "mlx-community"))
            if !q.isEmpty {
                items.append(URLQueryItem(name: "search", value: q))
            }
        case .qwenMLX:
            items.append(URLQueryItem(name: "author", value: "mlx-community"))
            // Keep a light bias toward Qwen when the field is empty.
            items.append(URLQueryItem(name: "search", value: q.isEmpty ? "Qwen" : q))
        case .custom:
            items.append(URLQueryItem(name: "filter", value: "mlx"))
            if !q.isEmpty {
                items.append(URLQueryItem(name: "search", value: q))
            }
        }

        components.queryItems = items
        guard let url = components.url else {
            throw BAMError(code: .schemaInvalid, message: "Could not build HF search URL")
        }

        var request = URLRequest(url: url)
        request.setValue("BuildAIMaker/1.0 (model-source-connector)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 45

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw BAMError(
                code: .downloadFailed,
                message: "HF search network error: \(error.localizedDescription)"
            )
        }

        guard let http = response as? HTTPURLResponse else {
            throw BAMError(code: .downloadFailed, message: "HF search: invalid response")
        }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8)?.prefix(200) ?? ""
            throw BAMError(
                code: .downloadFailed,
                message: "HF search failed (HTTP \(http.statusCode)): \(body)"
            )
        }

        let listings = try Self.decodeListings(data: data, location: location)
        // Full page ⇒ more may exist; Link: rel=next is another signal.
        let linkHeader = http.value(forHTTPHeaderField: "Link") ?? ""
        let hasLinkNext = linkHeader.contains("rel=\"next\"")
        let hasMore = listings.count >= pageSize || hasLinkNext

        return ModelSearchPage(
            listings: listings,
            hasMore: hasMore && !listings.isEmpty,
            skip: offset,
            limit: pageSize
        )
    }

    /// Pure decode helper for unit tests (no network).
    public static func decodeListings(
        data: Data,
        location: ModelSourceLocation
    ) throws -> [ModelRemoteListing] {
        guard let arr = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw BAMError(code: .schemaInvalid, message: "HF search JSON was not an array")
        }
        var out: [ModelRemoteListing] = []
        for obj in arr {
            let id = (obj["modelId"] as? String) ?? (obj["id"] as? String) ?? ""
            guard !id.isEmpty else { continue }
            let name = (obj["id"] as? String) ?? id
            let author: String?
            if let slash = id.firstIndex(of: "/") {
                author = String(id[..<slash])
            } else {
                author = obj["author"] as? String
            }
            let downloads = intValue(obj["downloads"])
            let likes = intValue(obj["likes"])
            let tags = (obj["tags"] as? [String]) ?? []
            let pipeline = obj["pipeline_tag"] as? String
            out.append(
                ModelRemoteListing(
                    sourceKey: id,
                    name: name.split(separator: "/").last.map(String.init) ?? name,
                    author: author,
                    downloads: downloads,
                    likes: likes,
                    tags: tags,
                    pipelineTag: pipeline,
                    pageURL: "https://huggingface.co/\(id)",
                    sourceLocation: location
                )
            )
        }
        return out
    }

    private static func intValue(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let d = any as? Double { return Int(d) }
        if let n = any as? NSNumber { return n.intValue }
        return nil
    }
}
