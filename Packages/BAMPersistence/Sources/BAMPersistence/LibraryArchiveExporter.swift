import BAMCore
import Foundation
import GRDB

// MARK: - Options / result

/// Options for a library durability export.
///
/// By default the archive includes `library.sqlite`, config, consent, personas,
/// datasets, voices, and jobs — but **skips huge model weights**, Python envs,
/// and download cache (multi-GB). Flip `includeModelWeights` when a full offline
/// restore of base models / adapters is required.
///
/// Directory mode (`compressToZip: false`) is intended for tests/tools; the product
/// UI always writes a zip. Destination must not equal or nest under `libraryRoot`
/// (and must not be an ancestor of it).
public struct LibraryArchiveExportOptions: Sendable, Equatable {
    /// Copy `models/base` and `models/adapters` payloads (weights). Default `false`.
    public var includeModelWeights: Bool

    /// Copy `envs/python` (managed training runtimes). Default `false`.
    public var includePythonEnvs: Bool

    /// Copy `cache/downloads`. Default `false`.
    public var includeDownloadCache: Bool

    /// When `true` (default), package the staged tree as a `.zip` via `/usr/bin/ditto`.
    /// When `false`, leave a directory archive at the destination (tests/tools).
    public var compressToZip: Bool

    public init(
        includeModelWeights: Bool = false,
        includePythonEnvs: Bool = false,
        includeDownloadCache: Bool = false,
        compressToZip: Bool = true
    ) {
        self.includeModelWeights = includeModelWeights
        self.includePythonEnvs = includePythonEnvs
        self.includeDownloadCache = includeDownloadCache
        self.compressToZip = compressToZip
    }

    /// Product default: metadata + user content, no weights / envs / cache, zip output.
    public static let `default` = LibraryArchiveExportOptions()
}

/// Manifest written into every archive as `library-export-manifest.json`.
public struct LibraryArchiveManifest: Codable, Sendable, Equatable {
    public static let formatVersionV1 = 1

    public var formatVersion: Int
    public var exportedAt: String
    public var appName: String
    public var librarySchemaVersion: Int
    public var includeModelWeights: Bool
    public var includePythonEnvs: Bool
    public var includeDownloadCache: Bool
    public var includedRelativePaths: [String]
    public var skippedRelativePaths: [String]
    public var notes: [String]

    public init(
        formatVersion: Int = LibraryArchiveManifest.formatVersionV1,
        exportedAt: String,
        appName: String = AppIdentity.displayName,
        librarySchemaVersion: Int = ProtocolVersions.librarySchemaVersion,
        includeModelWeights: Bool,
        includePythonEnvs: Bool,
        includeDownloadCache: Bool,
        includedRelativePaths: [String],
        skippedRelativePaths: [String],
        notes: [String]
    ) {
        self.formatVersion = formatVersion
        self.exportedAt = exportedAt
        self.appName = appName
        self.librarySchemaVersion = librarySchemaVersion
        self.includeModelWeights = includeModelWeights
        self.includePythonEnvs = includePythonEnvs
        self.includeDownloadCache = includeDownloadCache
        self.includedRelativePaths = includedRelativePaths
        self.skippedRelativePaths = skippedRelativePaths
        self.notes = notes
    }
}

/// Outcome of a successful export.
public struct LibraryArchiveExportResult: Sendable, Equatable {
    /// Final archive path (`.zip` or directory).
    public let archiveURL: URL
    /// Relative paths that were copied into the archive.
    public let includedRelativePaths: [String]
    /// Top-level paths intentionally skipped (weights, envs, …).
    public let skippedRelativePaths: [String]
    /// Approximate total bytes written into the staging tree (pre-zip).
    public let bytesCopied: Int64
    public let manifest: LibraryArchiveManifest
}

// MARK: - Exporter

/// Exports a durability snapshot of the on-disk library.
///
/// Preferred package home: `BAMPersistence` (alongside `LibraryDatabase`).
/// UI (Settings → “Export library archive…”) calls this with a user-chosen path.
public enum LibraryArchiveExporter: Sendable {
    public static let manifestFileName = "library-export-manifest.json"
    public static let archiveRootFolderName = "BuildAIMaker-library"

    /// User-facing note shown in Settings and written into the manifest.
    public static let defaultWeightsSkipNote =
        "Model weights under models/base and models/adapters are skipped by default (often multi-GB). Enable “Include model weights” for a full offline restore."

    /// Explains how `library.sqlite` is captured under a live app process.
    public static let liveSQLiteSnapshotNote =
        "library.sqlite is captured with SQLite’s online backup API (via GRDB) so WAL contents are included in a consistent single-file snapshot."

    // MARK: Public API

    /// Export `libraryRoot` to `destinationURL`.
    ///
    /// - Parameters:
    ///   - libraryRoot: Application Support library root (or a temp fixture root in tests).
    ///   - destinationURL: Target `.zip` file URL, or directory URL when `compressToZip` is false.
    ///     Must not equal, contain, or be nested under `libraryRoot`.
    ///   - options: Inclusion / packaging options. Directory mode is for tests/tools.
    ///   - fileManager: Injectable for tests.
    ///   - now: Clock for `exportedAt` (ISO-8601).
    @discardableResult
    public static func export(
        libraryRoot: URL,
        to destinationURL: URL,
        options: LibraryArchiveExportOptions = .default,
        fileManager: FileManager = .default,
        now: Date = Date()
    ) throws -> LibraryArchiveExportResult {
        do {
            return try exportThrowing(
                libraryRoot: libraryRoot,
                to: destinationURL,
                options: options,
                fileManager: fileManager,
                now: now
            )
        } catch let error as BAMError {
            throw error
        } catch {
            throw BAMError(
                code: .exportFailed,
                message: error.localizedDescription
            )
        }
    }

    /// Convenience: export the live default library root (`LibraryPaths.libraryRoot`).
    @discardableResult
    public static func exportDefaultLibrary(
        to destinationURL: URL,
        options: LibraryArchiveExportOptions = .default,
        fileManager: FileManager = .default,
        now: Date = Date()
    ) throws -> LibraryArchiveExportResult {
        try export(
            libraryRoot: LibraryPaths.libraryRoot,
            to: destinationURL,
            options: options,
            fileManager: fileManager,
            now: now
        )
    }

    /// Default save filename suggestion for NSSavePanel (timestamped zip).
    public static func suggestedArchiveFileName(now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "BuildAIMaker-library-\(formatter.string(from: now)).zip"
    }

    // MARK: Implementation

    private static func exportThrowing(
        libraryRoot: URL,
        to destinationURL: URL,
        options: LibraryArchiveExportOptions,
        fileManager: FileManager,
        now: Date
    ) throws -> LibraryArchiveExportResult {
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: libraryRoot.path, isDirectory: &isDir), isDir.boolValue else {
            throw BAMError(
                code: .exportFailed,
                message: "Library root does not exist or is not a directory: \(libraryRoot.path)"
            )
        }

        // Resolve final archive URL early for path-overlap checks.
        let finalDestination: URL
        if options.compressToZip {
            if destinationURL.pathExtension.lowercased() == "zip" {
                finalDestination = destinationURL
            } else {
                finalDestination = destinationURL.appendingPathExtension("zip")
            }
        } else {
            finalDestination = destinationURL
        }

        try validateDestinationOutsideLibrary(
            destination: finalDestination,
            libraryRoot: libraryRoot,
            fileManager: fileManager
        )

        let workParent = fileManager.temporaryDirectory
            .appendingPathComponent("bam-library-export-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: workParent, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: workParent) }

        let stagingRoot = workParent.appendingPathComponent(archiveRootFolderName, isDirectory: true)
        try fileManager.createDirectory(at: stagingRoot, withIntermediateDirectories: true)

        var included: [String] = []
        var skipped: [String] = []
        var bytesCopied: Int64 = 0

        // library.sqlite — consistent snapshot via GRDB online backup (WAL-aware).
        let sqliteSrc = libraryRoot.appendingPathComponent("library.sqlite")
        if fileManager.fileExists(atPath: sqliteSrc.path) {
            let sqliteDest = stagingRoot.appendingPathComponent("library.sqlite")
            let size = try snapshotLibrarySQLite(
                from: sqliteSrc,
                to: sqliteDest,
                fileManager: fileManager
            )
            included.append("library.sqlite")
            bytesCopied += size
        }

        // Optional sidecar files (not required once backup API is used).
        for name in ["library.sqlite.bak", "config.json"] {
            let src = libraryRoot.appendingPathComponent(name)
            if fileManager.fileExists(atPath: src.path) {
                let dest = stagingRoot.appendingPathComponent(name)
                try copyItem(at: src, to: dest, fileManager: fileManager)
                included.append(name)
                bytesCopied += fileSize(of: dest, fileManager: fileManager)
            }
        }

        // Essential directories (metadata + user content).
        let essentialDirs = [
            "consent",
            "personas",
            "datasets",
            "voices",
            "jobs",
        ]
        for name in essentialDirs {
            let src = libraryRoot.appendingPathComponent(name, isDirectory: true)
            if fileManager.fileExists(atPath: src.path) {
                let dest = stagingRoot.appendingPathComponent(name, isDirectory: true)
                try copyItem(at: src, to: dest, fileManager: fileManager)
                included.append(name + "/")
                bytesCopied += directoryByteSize(at: dest, fileManager: fileManager)
            }
        }

        // models/ — optional weights.
        let modelsSrc = libraryRoot.appendingPathComponent("models", isDirectory: true)
        if fileManager.fileExists(atPath: modelsSrc.path) {
            if options.includeModelWeights {
                let dest = stagingRoot.appendingPathComponent("models", isDirectory: true)
                try copyItem(at: modelsSrc, to: dest, fileManager: fileManager)
                included.append("models/")
                bytesCopied += directoryByteSize(at: dest, fileManager: fileManager)
            } else {
                skipped.append("models/")
            }
        }

        // envs/python — optional, multi-GB.
        let envsSrc = libraryRoot.appendingPathComponent("envs", isDirectory: true)
        if fileManager.fileExists(atPath: envsSrc.path) {
            if options.includePythonEnvs {
                let dest = stagingRoot.appendingPathComponent("envs", isDirectory: true)
                try copyItem(at: envsSrc, to: dest, fileManager: fileManager)
                included.append("envs/")
                bytesCopied += directoryByteSize(at: dest, fileManager: fileManager)
            } else {
                skipped.append("envs/")
            }
        }

        // cache/downloads — optional.
        let cacheSrc = libraryRoot.appendingPathComponent("cache", isDirectory: true)
        if fileManager.fileExists(atPath: cacheSrc.path) {
            if options.includeDownloadCache {
                let dest = stagingRoot.appendingPathComponent("cache", isDirectory: true)
                try copyItem(at: cacheSrc, to: dest, fileManager: fileManager)
                included.append("cache/")
                bytesCopied += directoryByteSize(at: dest, fileManager: fileManager)
            } else {
                skipped.append("cache/")
            }
        }

        // Require at least the SQLite DB for a meaningful durability archive.
        let sqliteInStaging = stagingRoot.appendingPathComponent("library.sqlite")
        guard fileManager.fileExists(atPath: sqliteInStaging.path) else {
            throw BAMError(
                code: .exportFailed,
                message: "library.sqlite is missing under library root; nothing durable to export."
            )
        }

        var notes: [String] = []
        notes.append(liveSQLiteSnapshotNote)
        if !options.includeModelWeights {
            notes.append(defaultWeightsSkipNote)
        }
        if !options.includePythonEnvs {
            notes.append("Python training envs (envs/python) are skipped by default.")
        }
        if !options.includeDownloadCache {
            notes.append("Download cache is skipped by default.")
        }
        notes.append(
            "Archive is a durability snapshot; restore is offline/manual in v1 (re-place files under Application Support)."
        )

        // Include the manifest path in the recorded list before encoding.
        included.append(manifestFileName)
        let includedSorted = included.sorted()
        let skippedSorted = skipped.sorted()

        let exportedAt = iso8601UTC.string(from: now)
        let manifest = LibraryArchiveManifest(
            exportedAt: exportedAt,
            includeModelWeights: options.includeModelWeights,
            includePythonEnvs: options.includePythonEnvs,
            includeDownloadCache: options.includeDownloadCache,
            includedRelativePaths: includedSorted,
            skippedRelativePaths: skippedSorted,
            notes: notes
        )

        let manifestURL = stagingRoot.appendingPathComponent(manifestFileName)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let manifestData = try encoder.encode(manifest)
        try manifestData.write(to: manifestURL, options: .atomic)
        bytesCopied += Int64(manifestData.count)

        // Finalize: never delete the existing destination until the new artifact is fully written.
        let parent = finalDestination.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)

        if options.compressToZip {
            let tempZip = workParent.appendingPathComponent("archive-out.zip")
            if fileManager.fileExists(atPath: tempZip.path) {
                try fileManager.removeItem(at: tempZip)
            }
            try createZip(ofDirectory: stagingRoot, to: tempZip, fileManager: fileManager)
            try placeArtifactAtomically(
                newItem: tempZip,
                at: finalDestination,
                fileManager: fileManager
            )
        } else {
            try placeArtifactAtomically(
                newItem: stagingRoot,
                at: finalDestination,
                fileManager: fileManager
            )
        }

        return LibraryArchiveExportResult(
            archiveURL: finalDestination,
            includedRelativePaths: includedSorted,
            skippedRelativePaths: skippedSorted,
            bytesCopied: bytesCopied,
            manifest: manifest
        )
    }

    // MARK: - Path safety

    /// Reject destinations that would overwrite or nest under the live library root
    /// (and destinations that are ancestors of the library root, which would wipe it
    /// when replaced in directory mode).
    public static func validateDestinationOutsideLibrary(
        destination: URL,
        libraryRoot: URL,
        fileManager: FileManager = .default
    ) throws {
        let destPath = standardizedPath(destination, fileManager: fileManager)
        let rootPath = standardizedPath(libraryRoot, fileManager: fileManager)

        if destPath == rootPath {
            throw BAMError(
                code: .pathEscape,
                message: "Export destination must not be the library root itself."
            )
        }
        // Destination nested inside library (e.g. …/BuildAIMaker/backup).
        if destPath.hasPrefix(rootPath + "/") {
            throw BAMError(
                code: .pathEscape,
                message: "Export destination must not be inside the library root (\(rootPath))."
            )
        }
        // Library nested inside destination (directory replace would delete the library).
        if rootPath.hasPrefix(destPath + "/") {
            throw BAMError(
                code: .pathEscape,
                message: "Export destination must not be an ancestor of the library root."
            )
        }
    }

    private static func standardizedPath(_ url: URL, fileManager: FileManager) -> String {
        // Prefer symlink-resolved absolute path when the item exists; else standardize.
        let standardized = url.standardizedFileURL
        if fileManager.fileExists(atPath: standardized.path) {
            return standardized.resolvingSymlinksInPath().path
        }
        // Resolve parent when possible so non-existent destinations still compare fairly.
        let parent = standardized.deletingLastPathComponent()
        if fileManager.fileExists(atPath: parent.path) {
            let resolvedParent = parent.resolvingSymlinksInPath()
            return resolvedParent.appendingPathComponent(standardized.lastPathComponent).path
        }
        return standardized.path
    }

    // MARK: - SQLite snapshot

    /// Point-in-time copy of `library.sqlite` using GRDB/`sqlite3_backup_*`.
    /// Captures committed + WAL content into a single consistent destination file.
    private static func snapshotLibrarySQLite(
        from sourceURL: URL,
        to destinationURL: URL,
        fileManager: FileManager
    ) throws -> Int64 {
        let parent = destinationURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: parent.path) {
            try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        }
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }

        do {
            let source = try DatabaseQueue(path: sourceURL.path)
            let destination = try DatabaseQueue(path: destinationURL.path)
            try source.backup(to: destination)
        } catch let error as BAMError {
            throw error
        } catch {
            throw BAMError(
                code: .exportFailed,
                message: "Could not snapshot library.sqlite via online backup: \(error.localizedDescription)"
            )
        }

        return fileSize(of: destinationURL, fileManager: fileManager)
    }

    // MARK: - File helpers

    private static let iso8601UTC: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f
    }()

    private static func copyItem(at src: URL, to dest: URL, fileManager: FileManager) throws {
        let parent = dest.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: parent.path) {
            try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        }
        if fileManager.fileExists(atPath: dest.path) {
            try fileManager.removeItem(at: dest)
        }
        try fileManager.copyItem(at: src, to: dest)
    }

    /// Places a fully-written `newItem` at `destination` without deleting the previous
    /// destination first.
    ///
    /// 1. Copy/move the finished artifact to a unique sibling next to `destination`
    ///    (same volume as the user path when possible).
    /// 2. If destination exists, `FileManager.replaceItemAt` swaps it in.
    /// 3. If destination does not exist, move the sibling into place.
    ///
    /// On failure after step 1, the previous destination is left intact.
    private static func placeArtifactAtomically(
        newItem: URL,
        at destination: URL,
        fileManager: FileManager
    ) throws {
        let parent = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)

        let sibling = parent.appendingPathComponent(
            ".bam-export-tmp-\(UUID().uuidString)-\(destination.lastPathComponent)"
        )
        if fileManager.fileExists(atPath: sibling.path) {
            try fileManager.removeItem(at: sibling)
        }

        // Prefer move (same volume); fall back to copy for cross-volume temp → user disk.
        do {
            try fileManager.moveItem(at: newItem, to: sibling)
        } catch {
            try fileManager.copyItem(at: newItem, to: sibling)
            try? fileManager.removeItem(at: newItem)
        }

        defer {
            // If replace/move below fails, drop the sibling so we don't leave clutter.
            // Successful replace/move consumes `sibling`.
            if fileManager.fileExists(atPath: sibling.path) {
                try? fileManager.removeItem(at: sibling)
            }
        }

        if fileManager.fileExists(atPath: destination.path) {
            // Swaps without deleting destination first; old content only goes away on success.
            _ = try fileManager.replaceItemAt(
                destination,
                withItemAt: sibling,
                backupItemName: nil,
                options: []
            )
        } else {
            try fileManager.moveItem(at: sibling, to: destination)
        }
    }

    /// Creates a zip of `directory` (root folder name preserved via `--keepParent`) using ditto.
    ///
    /// macOS-only, no third-party zip dependency. Fails with `BAM_EXPORT_FAILED` if ditto is missing
    /// or returns a non-zero status.
    private static func createZip(
        ofDirectory directory: URL,
        to zipURL: URL,
        fileManager: FileManager
    ) throws {
        let dittoPath = "/usr/bin/ditto"
        guard fileManager.isExecutableFile(atPath: dittoPath) else {
            throw BAMError(
                code: .exportFailed,
                message: "/usr/bin/ditto is not available; cannot create zip archive."
            )
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: dittoPath)
        // -c create archive, -k PKZip, --keepParent embeds root folder name
        process.arguments = [
            "-c", "-k",
            "--keepParent",
            "--norsrc", "--noextattr",
            directory.path,
            zipURL.path,
        ]
        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = Pipe()

        try process.run()
        process.waitUntilExit()

        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        let errText = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard process.terminationStatus == 0 else {
            throw BAMError(
                code: .exportFailed,
                message: "ditto zip failed (status \(process.terminationStatus)): \(errText)"
            )
        }
        guard fileManager.fileExists(atPath: zipURL.path) else {
            throw BAMError(code: .exportFailed, message: "ditto reported success but zip is missing.")
        }
    }

    private static func fileSize(of url: URL, fileManager: FileManager) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        if let size = values?.fileSize {
            return Int64(size)
        }
        let attrs = try? fileManager.attributesOfItem(atPath: url.path)
        if let n = attrs?[.size] as? NSNumber {
            return n.int64Value
        }
        return 0
    }

    private static func directoryByteSize(at url: URL, fileManager: FileManager) -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values?.isRegularFile == true {
                total += Int64(values?.fileSize ?? 0)
            }
        }
        return total
    }
}
