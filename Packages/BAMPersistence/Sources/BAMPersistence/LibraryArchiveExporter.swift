import BAMCore
import Foundation

// MARK: - Options / result

/// Options for a library durability export.
///
/// By default the archive includes `library.sqlite`, config, consent, personas,
/// datasets, voices, and jobs — but **skips huge model weights**, Python envs,
/// and download cache (multi-GB). Flip `includeModelWeights` when a full offline
/// restore of base models / adapters is required.
public struct LibraryArchiveExportOptions: Sendable, Equatable {
    /// Copy `models/base` and `models/adapters` payloads (weights). Default `false`.
    public var includeModelWeights: Bool

    /// Copy `envs/python` (managed training runtimes). Default `false`.
    public var includePythonEnvs: Bool

    /// Copy `cache/downloads`. Default `false`.
    public var includeDownloadCache: Bool

    /// When `true` (default), package the staged tree as a `.zip` via `/usr/bin/ditto`.
    /// When `false`, leave a directory archive at the destination.
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
    /// Approximate total bytes copied into the staging tree (pre-zip).
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

    // MARK: Public API

    /// Export `libraryRoot` to `destinationURL`.
    ///
    /// - Parameters:
    ///   - libraryRoot: Application Support library root (or a temp fixture root in tests).
    ///   - destinationURL: Target `.zip` file URL, or directory URL when `compressToZip` is false.
    ///   - options: Inclusion / packaging options.
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

        let workParent = fileManager.temporaryDirectory
            .appendingPathComponent("bam-library-export-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: workParent, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: workParent) }

        let stagingRoot = workParent.appendingPathComponent(archiveRootFolderName, isDirectory: true)
        try fileManager.createDirectory(at: stagingRoot, withIntermediateDirectories: true)

        var included: [String] = []
        var skipped: [String] = []
        var bytesCopied: Int64 = 0

        // Always-attempted top-level files.
        for name in ["library.sqlite", "library.sqlite.bak", "config.json"] {
            let src = libraryRoot.appendingPathComponent(name)
            if fileManager.fileExists(atPath: src.path) {
                let dest = stagingRoot.appendingPathComponent(name)
                try copyItem(at: src, to: dest, fileManager: fileManager)
                included.append(name)
                bytesCopied += fileSize(of: src, fileManager: fileManager)
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
                bytesCopied += directoryByteSize(at: src, fileManager: fileManager)
            }
        }

        // models/ — optional weights.
        let modelsSrc = libraryRoot.appendingPathComponent("models", isDirectory: true)
        if fileManager.fileExists(atPath: modelsSrc.path) {
            if options.includeModelWeights {
                let dest = stagingRoot.appendingPathComponent("models", isDirectory: true)
                try copyItem(at: modelsSrc, to: dest, fileManager: fileManager)
                included.append("models/")
                bytesCopied += directoryByteSize(at: modelsSrc, fileManager: fileManager)
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
                bytesCopied += directoryByteSize(at: envsSrc, fileManager: fileManager)
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
                bytesCopied += directoryByteSize(at: cacheSrc, fileManager: fileManager)
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

        let exportedAt = iso8601UTC.string(from: now)
        let manifest = LibraryArchiveManifest(
            exportedAt: exportedAt,
            includeModelWeights: options.includeModelWeights,
            includePythonEnvs: options.includePythonEnvs,
            includeDownloadCache: options.includeDownloadCache,
            includedRelativePaths: included.sorted(),
            skippedRelativePaths: skipped.sorted(),
            notes: notes
        )

        let manifestURL = stagingRoot.appendingPathComponent(manifestFileName)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let manifestData = try encoder.encode(manifest)
        try manifestData.write(to: manifestURL, options: .atomic)
        included.append(manifestFileName)
        bytesCopied += Int64(manifestData.count)

        // Finalize destination.
        let parent = destinationURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)

        if options.compressToZip {
            let zipURL: URL
            if destinationURL.pathExtension.lowercased() == "zip" {
                zipURL = destinationURL
            } else {
                zipURL = destinationURL.appendingPathExtension("zip")
            }
            try writeZipReplacing(from: stagingRoot, to: zipURL, workParent: workParent, fileManager: fileManager)
            return LibraryArchiveExportResult(
                archiveURL: zipURL,
                includedRelativePaths: included.sorted(),
                skippedRelativePaths: skipped.sorted(),
                bytesCopied: bytesCopied,
                manifest: manifest
            )
        } else {
            try replaceItem(at: destinationURL, with: stagingRoot, fileManager: fileManager)
            // stagingRoot was moved; avoid defer removing it (already moved out of workParent
            // only if destination is outside workParent — replaceItem moves/copies carefully).
            return LibraryArchiveExportResult(
                archiveURL: destinationURL,
                includedRelativePaths: included.sorted(),
                skippedRelativePaths: skipped.sorted(),
                bytesCopied: bytesCopied,
                manifest: manifest
            )
        }
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

    /// Atomically replace `destination` with contents of `source` (directory).
    private static func replaceItem(at destination: URL, with source: URL, fileManager: FileManager) throws {
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: source, to: destination)
    }

    private static func writeZipReplacing(
        from stagingRoot: URL,
        to zipURL: URL,
        workParent: URL,
        fileManager: FileManager
    ) throws {
        let tempZip = workParent.appendingPathComponent("archive-out.zip")
        if fileManager.fileExists(atPath: tempZip.path) {
            try fileManager.removeItem(at: tempZip)
        }

        try createZip(ofDirectory: stagingRoot, to: tempZip)

        if fileManager.fileExists(atPath: zipURL.path) {
            try fileManager.removeItem(at: zipURL)
        }
        try fileManager.createDirectory(
            at: zipURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fileManager.moveItem(at: tempZip, to: zipURL)
    }

    /// Creates a zip of `directory` (contents include the root folder name) using `/usr/bin/ditto`.
    ///
    /// macOS-only, no third-party zip dependency. Fails with `BAM_EXPORT_FAILED` if ditto is missing
    /// or returns a non-zero status.
    private static func createZip(ofDirectory directory: URL, to zipURL: URL) throws {
        let ditto = URL(fileURLWithPath: "/usr/bin/ditto")
        guard FileManager.default.isExecutableFile(atPath: ditto.path) else {
            throw BAMError(
                code: .exportFailed,
                message: "/usr/bin/ditto is not available; cannot create zip archive."
            )
        }

        let process = Process()
        process.executableURL = ditto
        // -c create archive, -k PKZip, --norsrc/--noextattr keep archive portable
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
        guard FileManager.default.fileExists(atPath: zipURL.path) else {
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
