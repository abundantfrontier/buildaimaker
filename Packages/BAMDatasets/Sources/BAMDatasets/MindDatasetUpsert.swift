import BAMCore
import BAMModels
import CryptoKit
import Foundation

/// How mind JSONL maps onto library datasets (anti-duplication).
public enum MindIdentityPolicy: String, Codable, Sendable, CaseIterable {
    /// Reuse `existingDatasetId` when present; else create once and keep that id.
    case mergeByStableId
    /// If content hash matches latest version of existing id (or any name match), skip write.
    case mergeByContentHash
    /// Always create a new dataset id (legacy spammy behavior — discouraged).
    case alwaysCreate
    /// Require existing id; rewrite content + new version.
    case replaceExisting
}

public struct MindUpsertResult: Sendable, Equatable {
    public var datasetId: String
    public var versionId: String
    public var created: Bool
    public var unchanged: Bool
    public var contentHash: String
    public var rowCount: Int
    public var name: String

    public init(
        datasetId: String,
        versionId: String,
        created: Bool,
        unchanged: Bool,
        contentHash: String,
        rowCount: Int,
        name: String
    ) {
        self.datasetId = datasetId
        self.versionId = versionId
        self.created = created
        self.unchanged = unchanged
        self.contentHash = contentHash
        self.rowCount = rowCount
        self.name = name
    }
}

extension DatasetLibraryService {
    /// Import or update a mind JSONL dataset using an explicit identity policy.
    ///
    /// - Parameters:
    ///   - jsonl: OpenAI-messages JSONL body.
    ///   - name: Display name (e.g. "Robby mind").
    ///   - existingDatasetId: Character’s current `datasetId` when known.
    ///   - policy: merge / create / replace semantics.
    public func upsertMindJSONL(
        jsonl: String,
        name: String,
        existingDatasetId: String?,
        policy: MindIdentityPolicy
    ) throws -> MindUpsertResult {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw BAMError(code: .datasetInvalid, message: "Mind dataset name is required.")
        }
        let body = jsonl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else {
            throw BAMError(code: .datasetInvalid, message: "Mind JSONL is empty.")
        }

        let validation = validate(contents: body.hasSuffix("\n") ? body : body + "\n")
        guard validation.isValid else {
            throw validation.aggregatedError
                ?? BAMError(code: .datasetInvalid, message: "Mind JSONL validation failed.")
        }

        let tmp = fileManager.temporaryDirectory
            .appendingPathComponent("bam-mind-\(UUID().uuidString).jsonl")
        let payload = body.hasSuffix("\n") ? body : body + "\n"
        try payload.data(using: .utf8)!.write(to: tmp, options: .atomic)
        defer { try? fileManager.removeItem(at: tmp) }

        let contentHash = try DatasetImporter.sha256Hex(of: tmp)

        switch policy {
        case .alwaysCreate:
            let result = try importDataset(sourceURL: tmp, name: trimmedName, importMode: .copy)
            return MindUpsertResult(
                datasetId: result.dataset.id,
                versionId: result.version.id,
                created: true,
                unchanged: false,
                contentHash: contentHash,
                rowCount: result.version.rowCount ?? validation.rowCount,
                name: trimmedName
            )

        case .mergeByStableId, .replaceExisting, .mergeByContentHash:
            if let existingId = existingDatasetId,
               let existing = try dataset(id: existingId)
            {
                if policy == .mergeByContentHash || policy == .mergeByStableId {
                    if let latest = try latestVersion(datasetId: existingId),
                       latest.contentHash == contentHash
                    {
                        return MindUpsertResult(
                            datasetId: existingId,
                            versionId: latest.id,
                            created: false,
                            unchanged: true,
                            contentHash: contentHash,
                            rowCount: latest.rowCount ?? validation.rowCount,
                            name: existing.name
                        )
                    }
                }
                if policy == .replaceExisting || policy == .mergeByStableId
                    || policy == .mergeByContentHash
                {
                    let version = try replaceCopyContent(
                        datasetId: existingId,
                        sourceURL: tmp,
                        name: trimmedName
                    )
                    return MindUpsertResult(
                        datasetId: existingId,
                        versionId: version.id,
                        created: false,
                        unchanged: false,
                        contentHash: contentHash,
                        rowCount: version.rowCount ?? validation.rowCount,
                        name: trimmedName
                    )
                }
            }

            if policy == .replaceExisting {
                throw BAMError(
                    code: .datasetInvalid,
                    message: "replaceExisting requires an existing dataset id on the character."
                )
            }

            // No stable id yet — create once.
            let result = try importDataset(sourceURL: tmp, name: trimmedName, importMode: .copy)
            return MindUpsertResult(
                datasetId: result.dataset.id,
                versionId: result.version.id,
                created: true,
                unchanged: false,
                contentHash: contentHash,
                rowCount: result.version.rowCount ?? validation.rowCount,
                name: trimmedName
            )
        }
    }

    /// Overwrite `source.jsonl` for a copy-mode dataset and append a version row.
    public func replaceCopyContent(
        datasetId: String,
        sourceURL: URL,
        name: String? = nil
    ) throws -> DatasetVersionRecord {
        guard let dataset = try dataset(id: datasetId) else {
            throw BAMError(code: .datasetInvalid, message: "Dataset not found: \(datasetId)")
        }
        guard dataset.importMode == .copy else {
            throw BAMError(
                code: .datasetInvalid,
                message: "In-place replace only supported for copy-mode datasets."
            )
        }

        let validation = try JSONLChatParser.validate(fileURL: sourceURL)
        guard validation.isValid else {
            throw validation.aggregatedError
                ?? BAMError(code: .datasetInvalid, message: "Dataset validation failed.")
        }

        let dir = URL(fileURLWithPath: dataset.rootPath, isDirectory: true)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent("source.jsonl", isDirectory: false)
        if fileManager.fileExists(atPath: dest.path) {
            try fileManager.removeItem(at: dest)
        }
        try fileManager.copyItem(at: sourceURL, to: dest)

        let contentHash = try DatasetImporter.sha256Hex(of: dest)
        let nextVersion = (try latestVersion(datasetId: datasetId)?.version ?? 0) + 1
        let meta = DatasetVersionMeta(
            format: validation.format?.rawValue ?? "unknown",
            sourceFileName: "source.jsonl"
        )
        let version = DatasetVersionRecord(
            id: BAMID.generate(),
            datasetId: datasetId,
            version: nextVersion,
            contentHash: contentHash,
            rowCount: validation.rowCount,
            metaJSON: try meta.jsonString()
        )
        try store.insertVersion(version)
        if let name, !name.isEmpty, name != dataset.name {
            try store.updateName(datasetId: datasetId, name: name)
        }
        try store.updateStatus(datasetId: datasetId, status: .ready)
        return version
    }
}
