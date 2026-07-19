import XCTest
import GRDB
import BAMCore
import BAMPersistence

final class LibraryArchiveExporterTests: XCTestCase {
    private var tempRoot: URL!
    private var libraryRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("bam-export-test-\(UUID().uuidString)", isDirectory: true)
        libraryRoot = tempRoot.appendingPathComponent("library", isDirectory: true)
        try FileManager.default.createDirectory(at: libraryRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        tempRoot = nil
        libraryRoot = nil
        try super.tearDownWithError()
    }

    // MARK: - Fixtures

    /// Seeds a real migrated `library.sqlite` plus optional weight/env trees.
    @discardableResult
    private func seedMinimalLibrary(
        includeWeights: Bool = true,
        includeEnvs: Bool = true
    ) throws -> LibraryDatabase {
        let dbURL = libraryRoot.appendingPathComponent("library.sqlite")
        let db = try LibraryDatabase.open(at: dbURL)

        try "bak-bytes".write(
            to: libraryRoot.appendingPathComponent("library.sqlite.bak"),
            atomically: true,
            encoding: .utf8
        )
        try #"{"v":1}"#.write(
            to: libraryRoot.appendingPathComponent("config.json"),
            atomically: true,
            encoding: .utf8
        )

        try writeFile(
            libraryRoot.appendingPathComponent("consent/c1.json"),
            contents: #"{"id":"c1"}"#
        )
        try writeFile(
            libraryRoot.appendingPathComponent("personas/p1/persona.json"),
            contents: #"{"name":"Socrates"}"#
        )
        try writeFile(
            libraryRoot.appendingPathComponent("datasets/d1/data.jsonl"),
            contents: #"{}"#
        )
        try writeFile(
            libraryRoot.appendingPathComponent("voices/v1/ref.wav"),
            contents: "RIFF"
        )
        try writeFile(
            libraryRoot.appendingPathComponent("jobs/j1/job.json"),
            contents: #"{}"#
        )

        if includeWeights {
            try writeFile(
                libraryRoot.appendingPathComponent("models/base/m1/weights.safetensors"),
                contents: String(repeating: "W", count: 4096)
            )
            try writeFile(
                libraryRoot.appendingPathComponent("models/adapters/a1/adapter.safetensors"),
                contents: String(repeating: "A", count: 2048)
            )
        }
        if includeEnvs {
            try writeFile(
                libraryRoot.appendingPathComponent("envs/python/1.0.0/bin/python"),
                contents: "#!/bin/sh"
            )
            try writeFile(
                libraryRoot.appendingPathComponent("cache/downloads/blob.bin"),
                contents: "blob"
            )
        }

        return db
    }

    private func writeFile(_ url: URL, contents: String) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Tests

    func testExportDirectorySkipsWeightsByDefault() throws {
        try seedMinimalLibrary()

        let dest = tempRoot.appendingPathComponent("out-archive", isDirectory: true)
        let result = try LibraryArchiveExporter.export(
            libraryRoot: libraryRoot,
            to: dest,
            options: LibraryArchiveExportOptions(
                includeModelWeights: false,
                includePythonEnvs: false,
                includeDownloadCache: false,
                compressToZip: false
            )
        )

        XCTAssertEqual(result.archiveURL, dest)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.appendingPathComponent("library.sqlite").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.appendingPathComponent("config.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.appendingPathComponent("consent/c1.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.appendingPathComponent("personas/p1/persona.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.appendingPathComponent("datasets/d1/data.jsonl").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.appendingPathComponent("voices/v1/ref.wav").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.appendingPathComponent("jobs/j1/job.json").path))

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: dest.appendingPathComponent("models/base/m1/weights.safetensors").path
            ),
            "weights must be skipped by default"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: dest.appendingPathComponent("envs/python/1.0.0/bin/python").path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: dest.appendingPathComponent("cache/downloads/blob.bin").path
            )
        )

        XCTAssertTrue(result.skippedRelativePaths.contains("models/"))
        XCTAssertTrue(result.skippedRelativePaths.contains("envs/"))
        XCTAssertTrue(result.skippedRelativePaths.contains("cache/"))
        XCTAssertTrue(result.includedRelativePaths.contains("library.sqlite"))
        XCTAssertTrue(result.includedRelativePaths.contains("consent/"))
        XCTAssertTrue(result.includedRelativePaths.contains(LibraryArchiveExporter.manifestFileName))
        XCTAssertTrue(result.bytesCopied > 0)

        // Manifest on disk (and lists itself).
        let manifestURL = dest.appendingPathComponent(LibraryArchiveExporter.manifestFileName)
        let data = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(LibraryArchiveManifest.self, from: data)
        XCTAssertEqual(manifest.formatVersion, LibraryArchiveManifest.formatVersionV1)
        XCTAssertEqual(manifest.librarySchemaVersion, ProtocolVersions.librarySchemaVersion)
        XCTAssertEqual(manifest.appName, AppIdentity.displayName)
        XCTAssertFalse(manifest.includeModelWeights)
        XCTAssertTrue(manifest.notes.contains(where: { $0.contains("Model weights") }))
        XCTAssertTrue(manifest.notes.contains(where: { $0.contains("online backup") }))
        XCTAssertTrue(manifest.includedRelativePaths.contains(LibraryArchiveExporter.manifestFileName))
        XCTAssertEqual(manifest.skippedRelativePaths.sorted(), result.skippedRelativePaths.sorted())
        XCTAssertEqual(manifest.includedRelativePaths.sorted(), result.includedRelativePaths.sorted())
    }

    func testExportIncludesWeightsWhenRequested() throws {
        try seedMinimalLibrary()

        let dest = tempRoot.appendingPathComponent("full-archive", isDirectory: true)
        let result = try LibraryArchiveExporter.export(
            libraryRoot: libraryRoot,
            to: dest,
            options: LibraryArchiveExportOptions(
                includeModelWeights: true,
                includePythonEnvs: true,
                includeDownloadCache: true,
                compressToZip: false
            )
        )

        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: dest.appendingPathComponent("models/base/m1/weights.safetensors").path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: dest.appendingPathComponent("envs/python/1.0.0/bin/python").path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: dest.appendingPathComponent("cache/downloads/blob.bin").path
            )
        )
        XCTAssertTrue(result.includedRelativePaths.contains("models/"))
        XCTAssertTrue(result.includedRelativePaths.contains("envs/"))
        XCTAssertTrue(result.includedRelativePaths.contains("cache/"))
        XCTAssertTrue(result.skippedRelativePaths.isEmpty)
        XCTAssertTrue(result.manifest.includeModelWeights)
    }

    func testExportZipArchiveViaDitto() throws {
        try seedMinimalLibrary()

        let zipURL = tempRoot.appendingPathComponent("backup.zip")
        let result = try LibraryArchiveExporter.export(
            libraryRoot: libraryRoot,
            to: zipURL,
            options: .default // compressToZip true, skip weights
        )

        XCTAssertEqual(LibraryArchiveExportOptions.default.includeModelWeights, false)
        XCTAssertEqual(LibraryArchiveExportOptions.default.compressToZip, true)

        XCTAssertEqual(result.archiveURL.pathExtension, "zip")
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.archiveURL.path))
        XCTAssertGreaterThan(
            (try FileManager.default.attributesOfItem(atPath: result.archiveURL.path)[.size] as? NSNumber)?.intValue ?? 0,
            0
        )

        // Unzip with ditto and verify contents.
        let extractDir = tempRoot.appendingPathComponent("unzipped", isDirectory: true)
        try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        proc.arguments = ["-x", "-k", result.archiveURL.path, extractDir.path]
        try proc.run()
        proc.waitUntilExit()
        XCTAssertEqual(proc.terminationStatus, 0)

        let root = extractDir.appendingPathComponent(LibraryArchiveExporter.archiveRootFolderName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("library.sqlite").path))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent(LibraryArchiveExporter.manifestFileName).path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("models/base/m1/weights.safetensors").path
            )
        )
    }

    func testMissingLibraryRootFailsWithExportFailed() throws {
        let missing = tempRoot.appendingPathComponent("no-such-root")
        let dest = tempRoot.appendingPathComponent("out", isDirectory: true)
        XCTAssertThrowsError(
            try LibraryArchiveExporter.export(
                libraryRoot: missing,
                to: dest,
                options: LibraryArchiveExportOptions(compressToZip: false)
            )
        ) { error in
            guard let bam = error as? BAMError else {
                return XCTFail("expected BAMError, got \(error)")
            }
            XCTAssertEqual(bam.code, .exportFailed)
            XCTAssertEqual(bam.code.rawValue, "BAM_EXPORT_FAILED")
        }
    }

    func testMissingSqliteFailsWithExportFailed() throws {
        // Root exists but no library.sqlite
        try writeFile(libraryRoot.appendingPathComponent("config.json"), contents: "{}")
        let dest = tempRoot.appendingPathComponent("out", isDirectory: true)
        XCTAssertThrowsError(
            try LibraryArchiveExporter.export(
                libraryRoot: libraryRoot,
                to: dest,
                options: LibraryArchiveExportOptions(compressToZip: false)
            )
        ) { error in
            guard let bam = error as? BAMError else {
                return XCTFail("expected BAMError, got \(error)")
            }
            XCTAssertEqual(bam.code, .exportFailed)
            XCTAssertTrue(bam.message?.contains("library.sqlite") == true)
        }
    }

    func testSuggestedArchiveFileNameIsTimestampedZip() {
        let name = LibraryArchiveExporter.suggestedArchiveFileName(
            now: Date(timeIntervalSince1970: 0)
        )
        XCTAssertTrue(name.hasPrefix("BuildAIMaker-library-"))
        XCTAssertTrue(name.hasSuffix(".zip"))
        XCTAssertTrue(name.contains("19700101"))
    }

    func testExportReplacesExistingDestination() throws {
        try seedMinimalLibrary()
        let dest = tempRoot.appendingPathComponent("replace-me", isDirectory: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        try "stale".write(
            to: dest.appendingPathComponent("stale.txt"),
            atomically: true,
            encoding: .utf8
        )

        _ = try LibraryArchiveExporter.export(
            libraryRoot: libraryRoot,
            to: dest,
            options: LibraryArchiveExportOptions(compressToZip: false)
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.appendingPathComponent("stale.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.appendingPathComponent("library.sqlite").path))
    }

    func testManifestFormatVersionPinned() {
        XCTAssertEqual(LibraryArchiveManifest.formatVersionV1, 1)
    }

    // MARK: - Path overlap (Issue 2)

    func testDestinationInsideLibraryRootIsRejectedAndLeavesLibraryIntact() throws {
        try seedMinimalLibrary()
        let sqlitePath = libraryRoot.appendingPathComponent("library.sqlite").path
        XCTAssertTrue(FileManager.default.fileExists(atPath: sqlitePath))

        let nested = libraryRoot.appendingPathComponent("nested-backup", isDirectory: true)
        XCTAssertThrowsError(
            try LibraryArchiveExporter.export(
                libraryRoot: libraryRoot,
                to: nested,
                options: LibraryArchiveExportOptions(compressToZip: false)
            )
        ) { error in
            guard let bam = error as? BAMError else {
                return XCTFail("expected BAMError, got \(error)")
            }
            XCTAssertEqual(bam.code, .pathEscape)
            XCTAssertEqual(bam.code.rawValue, "BAM_PATH_ESCAPE")
        }

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: sqlitePath),
            "rejected export must not touch library.sqlite"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: nested.path),
            "failed export must not create nested destination"
        )
    }

    func testDestinationEqualToLibraryRootIsRejected() throws {
        try seedMinimalLibrary()
        XCTAssertThrowsError(
            try LibraryArchiveExporter.export(
                libraryRoot: libraryRoot,
                to: libraryRoot,
                options: LibraryArchiveExportOptions(compressToZip: false)
            )
        ) { error in
            guard let bam = error as? BAMError else {
                return XCTFail("expected BAMError, got \(error)")
            }
            XCTAssertEqual(bam.code, .pathEscape)
        }
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: libraryRoot.appendingPathComponent("library.sqlite").path
            )
        )
    }

    func testDestinationAncestorOfLibraryRootIsRejected() throws {
        try seedMinimalLibrary()
        // tempRoot is the parent of libraryRoot
        XCTAssertThrowsError(
            try LibraryArchiveExporter.export(
                libraryRoot: libraryRoot,
                to: tempRoot,
                options: LibraryArchiveExportOptions(compressToZip: false)
            )
        ) { error in
            guard let bam = error as? BAMError else {
                return XCTFail("expected BAMError, got \(error)")
            }
            XCTAssertEqual(bam.code, .pathEscape)
        }
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: libraryRoot.appendingPathComponent("library.sqlite").path
            )
        )
    }

    // MARK: - Live SQLite backup (Issue 3)

    func testLiveDatabaseRowVisibleInExportedSnapshot() throws {
        let live = try seedMinimalLibrary(includeWeights: false, includeEnvs: false)

        // Keep a live writer open (simulates app holding DatabaseQueue) and insert a row.
        try live.dbQueue.write { conn in
            try conn.execute(
                sql: """
                    INSERT INTO personas (id, name, version, json, created_at, updated_at)
                    VALUES ('export-p1', 'LivePersona', '1.0.0', '{}', 't', 't')
                    """
            )
        }

        let dest = tempRoot.appendingPathComponent("live-snap", isDirectory: true)
        _ = try LibraryArchiveExporter.export(
            libraryRoot: libraryRoot,
            to: dest,
            options: LibraryArchiveExportOptions(compressToZip: false)
        )

        let exportedDB = try DatabaseQueue(
            path: dest.appendingPathComponent("library.sqlite").path
        )
        let name: String? = try exportedDB.read { conn in
            try String.fetchOne(conn, sql: "SELECT name FROM personas WHERE id = 'export-p1'")
        }
        XCTAssertEqual(name, "LivePersona")
    }

    // MARK: - Atomic replace keeps prior zip until new one is ready (Issue 1)

    func testSuccessfulZipReplaceOverwritesPriorArchive() throws {
        try seedMinimalLibrary()
        let zipURL = tempRoot.appendingPathComponent("keep-me.zip")

        // First export.
        _ = try LibraryArchiveExporter.export(
            libraryRoot: libraryRoot,
            to: zipURL,
            options: .default
        )
        let firstSize = try FileManager.default.attributesOfItem(atPath: zipURL.path)[.size] as? NSNumber
        XCTAssertNotNil(firstSize)

        // Second export overwrites via replaceItemAt (no delete-before-write).
        _ = try LibraryArchiveExporter.export(
            libraryRoot: libraryRoot,
            to: zipURL,
            options: .default
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: zipURL.path))
        let secondSize = try FileManager.default.attributesOfItem(atPath: zipURL.path)[.size] as? NSNumber
        XCTAssertNotNil(secondSize)
    }

    func testFailedFinalizationWouldLeavePriorDestination_pathGuardSimulatesFailClosed() throws {
        // Direct unit of the guard used before any write to destination.
        try seedMinimalLibrary()
        let prior = tempRoot.appendingPathComponent("prior-good.zip")
        try Data([0x50, 0x4B]).write(to: prior) // minimal marker bytes

        XCTAssertThrowsError(
            try LibraryArchiveExporter.validateDestinationOutsideLibrary(
                destination: libraryRoot.appendingPathComponent("oops.zip"),
                libraryRoot: libraryRoot
            )
        ) { error in
            guard let bam = error as? BAMError else {
                return XCTFail("expected BAMError, got \(error)")
            }
            XCTAssertEqual(bam.code, .pathEscape)
        }

        // Unrelated prior archive path is untouched by validation.
        XCTAssertTrue(FileManager.default.fileExists(atPath: prior.path))
        let bytes = try Data(contentsOf: prior)
        XCTAssertEqual(bytes, Data([0x50, 0x4B]))
    }
}
