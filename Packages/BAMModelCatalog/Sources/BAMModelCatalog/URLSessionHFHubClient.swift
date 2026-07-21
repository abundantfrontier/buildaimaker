import BAMCore
import Foundation

/// Real Hugging Face Hub download via `URLSession` (tree API + resolve URLs).
///
/// Downloads repo files under `destinationDirectory`. Supports optional HF token.
/// Not used by CI unit tests (they keep `NoopHFHubClient`).
public struct URLSessionHFHubClient: HFHubClient, Sendable {
    public var session: URLSession
    public var apiHost: String
    public var maxFiles: Int
    public var maxTotalBytes: Int64

    public init(
        session: URLSession = .shared,
        apiHost: String = "https://huggingface.co",
        maxFiles: Int = 400,
        maxTotalBytes: Int64 = 40 * 1024 * 1024 * 1024 // 40 GiB soft ceiling
    ) {
        self.session = session
        self.apiHost = apiHost
        self.maxFiles = maxFiles
        self.maxTotalBytes = maxTotalBytes
    }

    public func download(
        sourceKey: String,
        destinationDirectory: URL,
        token: String?
    ) async throws {
        let key = sourceKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            throw BAMError(code: .schemaInvalid, message: "Empty sourceKey for HF download")
        }

        let files = try await listFiles(repo: key, revision: "main", token: token)
        guard !files.isEmpty else {
            throw BAMError(
                code: .modelNotFound,
                message: "No files listed for \(key) on Hugging Face (empty or private without token)"
            )
        }
        if files.count > maxFiles {
            throw BAMError(
                code: .downloadFailed,
                message: "Repo \(key) has \(files.count) files (max \(maxFiles)). Use a smaller MLX snapshot."
            )
        }
        let total = files.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
        if total > maxTotalBytes {
            throw BAMError(
                code: .downloadFailed,
                message: "Repo \(key) is ~\(total / (1024 * 1024)) MB (over app ceiling). Pick a smaller quant."
            )
        }

        let fm = FileManager.default
        try fm.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)

        for file in files {
            let dest = destinationDirectory.appendingPathComponent(file.path)
            let parent = dest.deletingLastPathComponent()
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)
            try await downloadFile(
                repo: key,
                relativePath: file.path,
                destination: dest,
                token: token
            )
        }

        // Write install metadata for scanners / capability probe.
        let meta: [String: Any] = [
            "sourceKey": key,
            "source": "huggingface_hub",
            "dogfoodStub": false,
            "weightsIncluded": true,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: destinationDirectory.appendingPathComponent("bam_install.json"))
        }
    }

    // MARK: - Tree listing

    struct RemoteFile: Sendable {
        var path: String
        var size: Int64?
    }

    func listFiles(repo: String, revision: String, token: String?) async throws -> [RemoteFile] {
        try await listFilesRecursive(repo: repo, revision: revision, path: "", token: token, depth: 0)
    }

    private func listFilesRecursive(
        repo: String,
        revision: String,
        path: String,
        token: String?,
        depth: Int
    ) async throws -> [RemoteFile] {
        guard depth < 4 else { return [] }

        var urlString = "\(apiHost)/api/models/\(repo)/tree/\(revision)"
        if !path.isEmpty {
            let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
            urlString += "/\(encoded)"
        }
        guard let url = URL(string: urlString) else {
            throw BAMError(code: .schemaInvalid, message: "Bad tree URL for \(repo)")
        }

        var request = URLRequest(url: url)
        request.setValue("BuildAIMaker/1.0 (hf-hub-client)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 60

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw BAMError(
                code: .downloadFailed,
                message: "HF tree list failed for \(repo): \(error.localizedDescription)"
            )
        }
        guard let http = response as? HTTPURLResponse else {
            throw BAMError(code: .downloadFailed, message: "HF tree: invalid response")
        }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8)?.prefix(240) ?? ""
            throw BAMError(
                code: .downloadFailed,
                message: "HF tree HTTP \(http.statusCode) for \(repo): \(body)"
            )
        }

        guard let arr = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw BAMError(code: .schemaInvalid, message: "HF tree JSON invalid for \(repo)")
        }

        var files: [RemoteFile] = []
        for obj in arr {
            let type = (obj["type"] as? String) ?? ""
            let p = (obj["path"] as? String) ?? ""
            guard !p.isEmpty else { continue }
            // Skip git internals
            if p.hasPrefix(".git") { continue }
            if type == "directory" {
                let nested = try await listFilesRecursive(
                    repo: repo,
                    revision: revision,
                    path: p,
                    token: token,
                    depth: depth + 1
                )
                files.append(contentsOf: nested)
            } else if type == "file" {
                let size: Int64?
                if let s = obj["size"] as? Int64 {
                    size = s
                } else if let s = obj["size"] as? Int {
                    size = Int64(s)
                } else {
                    size = nil
                }
                files.append(RemoteFile(path: p, size: size))
            }
        }
        return files
    }

    private func downloadFile(
        repo: String,
        relativePath: String,
        destination: URL,
        token: String?
    ) async throws {
        let encodedPath = relativePath
            .split(separator: "/")
            .map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
            .joined(separator: "/")
        let urlString = "\(apiHost)/\(repo)/resolve/main/\(encodedPath)"
        guard let url = URL(string: urlString) else {
            throw BAMError(code: .schemaInvalid, message: "Bad resolve URL for \(relativePath)")
        }

        var request = URLRequest(url: url)
        request.setValue("BuildAIMaker/1.0 (hf-hub-client)", forHTTPHeaderField: "User-Agent")
        if let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        // Follow redirects to CDN.
        request.timeoutInterval = 600

        let (tempURL, response): (URL, URLResponse)
        do {
            (tempURL, response) = try await session.download(for: request)
        } catch {
            throw BAMError(
                code: .downloadFailed,
                message: "Download failed \(relativePath): \(error.localizedDescription)"
            )
        }
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw BAMError(
                code: .downloadFailed,
                message: "Download HTTP \(code) for \(relativePath)"
            )
        }

        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.moveItem(at: tempURL, to: destination)
    }
}
