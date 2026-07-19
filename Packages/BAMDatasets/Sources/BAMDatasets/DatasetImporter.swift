import BAMCore
import BAMModels
import CryptoKit
import Foundation

/// Parameters for importing a text chat JSONL dataset.
public struct DatasetImportRequest: Sendable, Equatable {
    public var sourceURL: URL
    public var name: String
    public var importMode: DatasetImportMode
    /// Optional override for tests; defaults to `LibraryPaths.libraryRoot`.
    public var libraryRoot: URL?

    public init(
        sourceURL: URL,
        name: String,
        importMode: DatasetImportMode = .copy,
        libraryRoot: URL? = nil
    ) {
        self.sourceURL = sourceURL
        self.name = name
        self.importMode = importMode
        self.libraryRoot = libraryRoot
    }
}

/// Successful import: library records + resolved on-disk path of the JSONL source.
public struct DatasetImportResult: Sendable, Equatable {
    public var dataset: DatasetRecord
    public var version: DatasetVersionRecord
    /// Absolute path to the JSONL file used for training/preview.
    public var sourceFilePath: String
    public var validation: DatasetValidationResult

    public init(
        dataset: DatasetRecord,
        version: DatasetVersionRecord,
        sourceFilePath: String,
        validation: DatasetValidationResult
    ) {
        self.dataset = dataset
        self.version = version
        self.sourceFilePath = sourceFilePath
        self.validation = validation
    }
}

/// Imports ShareGPT / OpenAI-messages JSONL into the app library (copy or reference).
public struct DatasetImporter: @unchecked Sendable {
    public let store: DatasetStore
    /// Not Sendable in the SDK; treat as effectively immutable for our use.
    public let fileManager: FileManager

    public init(store: DatasetStore, fileManager: FileManager = .default) {
        self.store = store
        self.fileManager = fileManager
    }

    /// Validates then imports. Throws `BAMError` with `datasetInvalid` when validation fails.
    ///
    /// Atomicity:
    /// - Copy: filesystem writes cleaned up if DB insert fails.
    /// - DB: dataset + version + bookmark land in one transaction (or none).
    public func importDataset(_ request: DatasetImportRequest) throws -> DatasetImportResult {
        let name = request.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw BAMError(code: .datasetInvalid, message: "Dataset name is required.")
        }

        let sourceURL = request.sourceURL.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory) else {
            throw BAMError(
                code: .datasetInvalid,
                message: "Source file not found: \(sourceURL.path)"
            )
        }
        if isDirectory.boolValue {
            throw BAMError(
                code: .datasetInvalid,
                message: "Source path is a directory; expected a JSONL file: \(sourceURL.path)"
            )
        }

        let validation = try JSONLChatParser.validate(fileURL: sourceURL)
        guard validation.isValid else {
            if let aggregated = validation.aggregatedError {
                throw aggregated
            }
            throw BAMError(code: .datasetInvalid, message: "Dataset validation failed.")
        }

        let datasetId = BAMID.generate()
        let versionId = BAMID.generate()
        let createdAt = Self.iso8601Now()
        let libraryRoot = request.libraryRoot ?? LibraryPaths.libraryRoot
        let datasetsRoot = libraryRoot.appendingPathComponent("datasets", isDirectory: true)

        let contentHash = try Self.sha256Hex(of: sourceURL)
        let meta = DatasetVersionMeta(
            format: validation.format?.rawValue ?? "unknown",
            sourceFileName: sourceURL.lastPathComponent
        )
        let metaJSON = try meta.jsonString()

        // Ensure parent exists before copy; safe even on failure (empty dir ok).
        try fileManager.createDirectory(at: datasetsRoot, withIntermediateDirectories: true)

        var rootPath: String
        var sourceFilePath: String
        var bookmarkInsert: DatasetBookmarkInsert?
        /// Copy-mode directory removed if DB insert fails after files were written.
        var copiedDatasetDir: URL?

        do {
            switch request.importMode {
            case .copy:
                let datasetDir = datasetsRoot.appendingPathComponent(
                    LibraryPaths.sanitizedPathComponent(datasetId),
                    isDirectory: true
                )
                try fileManager.createDirectory(at: datasetDir, withIntermediateDirectories: true)
                copiedDatasetDir = datasetDir
                let dest = datasetDir.appendingPathComponent("source.jsonl", isDirectory: false)
                if fileManager.fileExists(atPath: dest.path) {
                    try fileManager.removeItem(at: dest)
                }
                try fileManager.copyItem(at: sourceURL, to: dest)
                try Self.excludeFromBackup(dest)
                try Self.excludeFromBackup(datasetDir)
                rootPath = datasetDir.path
                sourceFilePath = dest.path

            case .reference:
                rootPath = sourceURL.path
                sourceFilePath = sourceURL.path
                // Best-effort security-scoped bookmark (may fail outside sandbox — still import).
                if let data = try? sourceURL.bookmarkData(
                    options: [.withSecurityScope],
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                ) {
                    bookmarkInsert = DatasetBookmarkInsert(
                        id: BAMID.generate(),
                        entityType: "dataset",
                        entityId: datasetId,
                        data: data
                    )
                }
            }

            let dataset = DatasetRecord(
                id: datasetId,
                name: name,
                modality: .text,
                rootPath: rootPath,
                importMode: request.importMode,
                status: .ready,
                createdAt: createdAt
            )
            let version = DatasetVersionRecord(
                id: versionId,
                datasetId: datasetId,
                version: 1,
                contentHash: contentHash,
                rowCount: validation.rowCount,
                metaJSON: metaJSON
            )

            // Single transaction: dataset + version + optional bookmark.
            try store.insert(dataset: dataset, version: version, bookmark: bookmarkInsert)
            copiedDatasetDir = nil // success — do not clean up

            return DatasetImportResult(
                dataset: dataset,
                version: version,
                sourceFilePath: sourceFilePath,
                validation: validation
            )
        } catch {
            if let dir = copiedDatasetDir, fileManager.fileExists(atPath: dir.path) {
                try? fileManager.removeItem(at: dir)
            }
            throw error
        }
    }

    // MARK: - Helpers

    public static func iso8601Now(date: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    public static func sha256Hex(of fileURL: URL) throws -> String {
        let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func excludeFromBackup(_ url: URL) throws {
        var mutable = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try mutable.setResourceValues(values)
    }
}

/// Stored in `dataset_versions.meta_json`.
public struct DatasetVersionMeta: Codable, Sendable, Equatable {
    public var format: String
    public var sourceFileName: String

    public init(format: String, sourceFileName: String) {
        self.format = format
        self.sourceFileName = sourceFileName
    }

    public func jsonString() throws -> String {
        let data = try JSONEncoder().encode(self)
        guard let s = String(data: data, encoding: .utf8) else {
            throw BAMError(code: .datasetInvalid, message: "Could not encode version meta JSON.")
        }
        return s
    }

    public static func parse(_ json: String) -> DatasetVersionMeta? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(DatasetVersionMeta.self, from: data)
    }
}
