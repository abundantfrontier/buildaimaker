import BAMCore
import BAMModels
import BAMPersistence
import Foundation

/// High-level dataset library API: list, import, validate, preview, delete.
public final class DatasetLibraryService: @unchecked Sendable {
    public let store: DatasetStore
    public let importer: DatasetImporter
    public let libraryRoot: URL
    private let fileManager: FileManager

    public init(
        database: LibraryDatabase,
        libraryRoot: URL = LibraryPaths.libraryRoot,
        fileManager: FileManager = .default
    ) {
        self.store = DatasetStore(database: database)
        self.importer = DatasetImporter(store: store, fileManager: fileManager)
        self.libraryRoot = libraryRoot
        self.fileManager = fileManager
    }

    /// Opens the default library DB under Application Support and ensures directories exist.
    public static func openDefault() throws -> DatasetLibraryService {
        let root = LibraryPaths.libraryRoot
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: LibraryPaths.datasets,
            withIntermediateDirectories: true
        )
        let db = try LibraryDatabase.openDefault()
        return DatasetLibraryService(database: db, libraryRoot: root)
    }

    /// In-memory DB + temporary library root (unit tests).
    public static func openInMemoryForTesting(
        libraryRoot: URL,
        fileManager: FileManager = .default
    ) throws -> DatasetLibraryService {
        try fileManager.createDirectory(at: libraryRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(
            at: libraryRoot.appendingPathComponent("datasets", isDirectory: true),
            withIntermediateDirectories: true
        )
        let db = try LibraryDatabase.openInMemory()
        return DatasetLibraryService(
            database: db,
            libraryRoot: libraryRoot,
            fileManager: fileManager
        )
    }

    // MARK: - List / get

    public func listDatasets() throws -> [DatasetRecord] {
        try store.listDatasets()
    }

    public func dataset(id: String) throws -> DatasetRecord? {
        try store.dataset(id: id)
    }

    public func latestVersion(datasetId: String) throws -> DatasetVersionRecord? {
        try store.latestVersion(datasetId: datasetId)
    }

    // MARK: - Validate

    public func validate(fileURL: URL) throws -> DatasetValidationResult {
        try JSONLChatParser.validate(fileURL: fileURL)
    }

    public func validate(contents: String) -> DatasetValidationResult {
        JSONLChatParser.validate(contents: contents)
    }

    // MARK: - Import

    public func importDataset(
        sourceURL: URL,
        name: String,
        importMode: DatasetImportMode = .copy
    ) throws -> DatasetImportResult {
        try importer.importDataset(
            DatasetImportRequest(
                sourceURL: sourceURL,
                name: name,
                importMode: importMode,
                libraryRoot: libraryRoot
            )
        )
    }

    // MARK: - Preview

    /// Returns the first `maxExamples` chat examples (each may contain multiple messages).
    public func preview(datasetId: String, maxExamples: Int = 5) throws -> DatasetPreview {
        guard let dataset = try store.dataset(id: datasetId) else {
            throw BAMError(code: .datasetInvalid, message: "Dataset not found: \(datasetId)")
        }
        let fileURL = try resolveSourceFileURL(for: dataset)
        let availability = checkAvailability(dataset: dataset, sourceFile: fileURL)
        if availability == .unavailable {
            try? store.updateStatus(datasetId: datasetId, status: .unavailable)
            throw BAMError(
                code: .datasetInvalid,
                message: "Dataset source is unavailable (missing file). Re-import or relink."
            )
        }
        let examples = try JSONLChatParser.preview(fileURL: fileURL, maxExamples: maxExamples)
        // Flatten message count for UI summary.
        let messageCount = examples.reduce(0) { $0 + $1.messages.count }
        return DatasetPreview(
            datasetId: datasetId,
            examples: examples,
            exampleCount: examples.count,
            messageCount: messageCount,
            sourcePath: fileURL.path
        )
    }

    /// Preview first N messages flattened across examples (stops once enough messages collected).
    public func previewMessages(datasetId: String, maxMessages: Int = 20) throws -> [ChatMessage] {
        let preview = try preview(datasetId: datasetId, maxExamples: max(1, maxMessages))
        var out: [ChatMessage] = []
        for example in preview.examples {
            for message in example.messages {
                out.append(message)
                if out.count >= maxMessages { return out }
            }
        }
        return out
    }

    // MARK: - Delete

    public func deleteDataset(id: String) throws {
        guard let dataset = try store.dataset(id: id) else { return }
        try store.deleteDataset(id: id)
        if dataset.importMode == .copy {
            let dir = URL(fileURLWithPath: dataset.rootPath, isDirectory: true)
            if fileManager.fileExists(atPath: dir.path) {
                try? fileManager.removeItem(at: dir)
            }
        }
    }

    // MARK: - Resolve

    /// Absolute URL of the JSONL used for training/preview.
    public func resolveSourceFileURL(for dataset: DatasetRecord) throws -> URL {
        switch dataset.importMode {
        case .copy:
            let dir = URL(fileURLWithPath: dataset.rootPath, isDirectory: true)
            let source = dir.appendingPathComponent("source.jsonl", isDirectory: false)
            if fileManager.fileExists(atPath: source.path) {
                return source
            }
            // Fallback: first *.jsonl in directory.
            if let contents = try? fileManager.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: nil
            ) {
                if let jsonl = contents.first(where: { $0.pathExtension.lowercased() == "jsonl" }) {
                    return jsonl
                }
            }
            return source
        case .reference:
            return URL(fileURLWithPath: dataset.rootPath)
        }
    }

    public func checkAvailability(dataset: DatasetRecord, sourceFile: URL? = nil) -> DatasetStatus {
        let url: URL
        if let sourceFile {
            url = sourceFile
        } else if let resolved = try? resolveSourceFileURL(for: dataset) {
            url = resolved
        } else {
            return .unavailable
        }
        return fileManager.fileExists(atPath: url.path) ? dataset.status : .unavailable
    }
}

/// Preview payload for UI.
public struct DatasetPreview: Sendable, Equatable {
    public var datasetId: String
    public var examples: [ChatExample]
    public var exampleCount: Int
    public var messageCount: Int
    public var sourcePath: String

    public init(
        datasetId: String,
        examples: [ChatExample],
        exampleCount: Int,
        messageCount: Int,
        sourcePath: String
    ) {
        self.datasetId = datasetId
        self.examples = examples
        self.exampleCount = exampleCount
        self.messageCount = messageCount
        self.sourcePath = sourcePath
    }
}
