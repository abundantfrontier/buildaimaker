import BAMCore
import BAMModels
import BAMPersistence
import Foundation

/// Scoped access to a resolved dataset source file (security-scoped bookmark or plain path).
public final class ResolvedSourceAccess: @unchecked Sendable {
    public let url: URL
    private let didStartScope: Bool
    private var stopped = false

    public init(url: URL, didStartScope: Bool) {
        self.url = url
        self.didStartScope = didStartScope
    }

    public func stop() {
        guard !stopped else { return }
        stopped = true
        if didStartScope {
            url.stopAccessingSecurityScopedResource()
        }
    }

    deinit {
        stop()
    }
}

/// High-level dataset library API: list, import, validate, preview, delete.
public final class DatasetLibraryService: @unchecked Sendable {
    public let store: DatasetStore
    public let importer: DatasetImporter
    public let libraryRoot: URL
    let fileManager: FileManager

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

        let access = try resolveSourceAccess(for: dataset)
        defer { access.stop() }

        let availability = refreshAvailability(dataset: dataset, sourceFile: access.url)
        if availability == .unavailable {
            throw BAMError(
                code: .datasetInvalid,
                message: "Dataset source is unavailable (missing file). Re-import or relink."
            )
        }

        let examples = try JSONLChatParser.preview(fileURL: access.url, maxExamples: maxExamples)
        let messageCount = examples.reduce(0) { $0 + $1.messages.count }
        return DatasetPreview(
            datasetId: datasetId,
            examples: examples,
            exampleCount: examples.count,
            messageCount: messageCount,
            sourcePath: access.url.path
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
        // Copy mode only: remove library copy. Reference mode never deletes the user file.
        if dataset.importMode == .copy {
            let dir = URL(fileURLWithPath: dataset.rootPath, isDirectory: true)
            if fileManager.fileExists(atPath: dir.path) {
                try? fileManager.removeItem(at: dir)
            }
        }
    }

    // MARK: - Resolve

    /// Resolves the JSONL URL, preferring a stored security-scoped bookmark for reference imports.
    public func resolveSourceFileURL(for dataset: DatasetRecord) throws -> URL {
        try resolveSourceAccess(for: dataset).url
    }

    /// Resolves source and starts security-scoped access when needed. Caller must `stop()`.
    public func resolveSourceAccess(for dataset: DatasetRecord) throws -> ResolvedSourceAccess {
        switch dataset.importMode {
        case .copy:
            let dir = URL(fileURLWithPath: dataset.rootPath, isDirectory: true)
            let source = dir.appendingPathComponent("source.jsonl", isDirectory: false)
            if fileManager.fileExists(atPath: source.path) {
                return ResolvedSourceAccess(url: source, didStartScope: false)
            }
            if let contents = try? fileManager.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: nil
            ),
                let jsonl = contents.first(where: { $0.pathExtension.lowercased() == "jsonl" })
            {
                return ResolvedSourceAccess(url: jsonl, didStartScope: false)
            }
            return ResolvedSourceAccess(url: source, didStartScope: false)

        case .reference:
            if let bookmark = try store.bookmarkData(entityType: "dataset", entityId: dataset.id) {
                var isStale = false
                do {
                    let resolved = try URL(
                        resolvingBookmarkData: bookmark,
                        options: [.withSecurityScope],
                        relativeTo: nil,
                        bookmarkDataIsStale: &isStale
                    )
                    let started = resolved.startAccessingSecurityScopedResource()
                    if fileManager.fileExists(atPath: resolved.path) {
                        return ResolvedSourceAccess(url: resolved, didStartScope: started)
                    }
                    // Resolved but missing on disk — stop scope and fall through.
                    if started {
                        resolved.stopAccessingSecurityScopedResource()
                    }
                } catch {
                    // Bookmark unusable; fall back to stored root path.
                }
            }
            let pathURL = URL(fileURLWithPath: dataset.rootPath)
            return ResolvedSourceAccess(url: pathURL, didStartScope: false)
        }
    }

    /// Derives availability from the filesystem (and bookmark resolution), not the last stored status.
    /// Heals `.unavailable` → `.ready` when the source reappears; persists status changes.
    @discardableResult
    public func refreshAvailability(
        dataset: DatasetRecord,
        sourceFile: URL? = nil
    ) -> DatasetStatus {
        let derived = checkAvailability(dataset: dataset, sourceFile: sourceFile)
        if derived != dataset.status {
            try? store.updateStatus(datasetId: dataset.id, status: derived)
        }
        return derived
    }

    /// Pure availability probe: file exists → `.ready` (or keep `.invalid`); missing → `.unavailable`.
    public func checkAvailability(dataset: DatasetRecord, sourceFile: URL? = nil) -> DatasetStatus {
        // Invalid is a permanent content/schema state — do not auto-heal from existence alone.
        if dataset.status == .invalid {
            return .invalid
        }

        let url: URL
        if let sourceFile {
            url = sourceFile
        } else if let access = try? resolveSourceAccess(for: dataset) {
            defer { access.stop() }
            url = access.url
        } else {
            return .unavailable
        }

        var isDirectory: ObjCBool = false
        let exists = fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
        if exists, !isDirectory.boolValue {
            return .ready
        }
        return .unavailable
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
