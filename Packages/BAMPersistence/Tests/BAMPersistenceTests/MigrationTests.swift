import XCTest
import GRDB
import BAMCore
import BAMPersistence

final class MigrationTests: XCTestCase {
    func testInMemoryMigrationCreatesV1Tables() throws {
        let db = try LibraryDatabase.openInMemory()
        XCTAssertTrue(try db.hasV1Schema())

        let names = try db.userTableNames()
        for expected in LibraryMigrator.v1TableNames {
            XCTAssertTrue(names.contains(expected), "missing table \(expected)")
        }
    }

    func testSchemaVersionPinnedToProtocolVersions() {
        XCTAssertEqual(LibraryMigrator.currentSchemaVersion, ProtocolVersions.librarySchemaVersion)
        XCTAssertEqual(LibraryMigrator.currentSchemaVersion, 1)
    }

    func testMigratorIsIdempotent() throws {
        let queue = try DatabaseQueue()
        try LibraryMigrator.migrate(queue)
        try LibraryMigrator.migrate(queue) // second apply is no-op

        let applied = try queue.read { db in
            try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier")
        }
        XCTAssertEqual(applied, [LibraryMigrator.v1MigrationName])
    }

    func testCanInsertIntoV1Tables() throws {
        let db = try LibraryDatabase.openInMemory()
        try db.dbQueue.write { conn in
            try conn.execute(
                sql: """
                    INSERT INTO datasets (id, name, modality, root_path, import_mode, status, created_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    "55555555-5555-4555-8555-555555555555",
                    "Voice clone refs",
                    "audio",
                    "/tmp/ds",
                    "copy",
                    "ready",
                    "2026-07-18T12:00:00Z",
                ]
            )
            try conn.execute(
                sql: """
                    INSERT INTO consent_records (id, json, content_hash, created_at)
                    VALUES (?, ?, ?, ?)
                    """,
                arguments: [
                    "00000000-0000-4000-8000-000000000001",
                    "{}",
                    "a20497efdc463ecfe6a6f9f135c11c40ee61d6cadaf5435bbbaeafb2815b6895",
                    "2026-07-18T12:00:00Z",
                ]
            )
            try conn.execute(
                sql: """
                    INSERT INTO jobs (id, status, modality, config_json, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    "22222222-2222-4222-8222-222222222222",
                    "draft",
                    "voiceClone",
                    "{\"v\":1}",
                    "2026-07-18T12:00:00Z",
                    "2026-07-18T12:00:00Z",
                ]
            )
        }

        let count: Int = try db.dbQueue.read { conn in
            try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM datasets WHERE modality = 'audio'") ?? 0
        }
        XCTAssertEqual(count, 1)
    }

    func testBackupOnlyWhenMigrationPending() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("bam-persist-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let dbURL = tmp.appendingPathComponent("library.sqlite")
        let bak = tmp.appendingPathComponent("library.sqlite.bak")

        // Create empty SQLite file with no migrations applied.
        do {
            let empty = try DatabaseQueue(path: dbURL.path)
            try empty.write { _ in /* touch */ }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: dbURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: bak.path))

        // Open applies v1 → should write pre-migration .bak of the empty DB.
        let first = try LibraryDatabase.open(at: dbURL)
        XCTAssertTrue(try first.hasV1Schema())
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: bak.path),
            "pending migration should write .bak"
        )

        // Remove bak and reopen when schema is current → must NOT rewrite .bak.
        try FileManager.default.removeItem(at: bak)
        let second = try LibraryDatabase.open(at: dbURL)
        XCTAssertTrue(try second.hasV1Schema())
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: bak.path),
            "current schema must not overwrite/create .bak on every open"
        )
    }

    func testPreMigrationBackupKeepsOldBakUntilNewCopySucceeds() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("bam-bak-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let dbURL = tmp.appendingPathComponent("library.sqlite")
        let bakURL = tmp.appendingPathComponent("library.sqlite.bak")

        try "primary-v1".write(to: dbURL, atomically: true, encoding: .utf8)
        try "old-good-bak".write(to: bakURL, atomically: true, encoding: .utf8)

        try LibraryDatabase.writePreMigrationBackup(of: dbURL)

        let bakContents = try String(contentsOf: bakURL, encoding: .utf8)
        XCTAssertEqual(bakContents, "primary-v1")
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: tmp.appendingPathComponent("library.sqlite.bak.tmp").path
            )
        )
    }

    func testMigrationFailureSurfacesBAMError() throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("boom") { _ in
            throw NSError(domain: "test", code: 42, userInfo: [
                NSLocalizedDescriptionKey: "intentional migrate failure",
            ])
        }
        let queue = try DatabaseQueue()
        XCTAssertThrowsError(try LibraryMigrator.migrate(queue, using: migrator)) { error in
            guard let bam = error as? BAMError else {
                return XCTFail("expected BAMError, got \(error)")
            }
            XCTAssertEqual(bam.code, .migrationFailed)
            XCTAssertEqual(bam.code.rawValue, "BAM_MIGRATION_FAILED")
            XCTAssertTrue(bam.message?.contains("intentional") == true)
        }
    }

    func testOpenAtPathMigratesFreshDatabase() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("bam-persist-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let dbURL = tmp.appendingPathComponent("library.sqlite")
        let bak = tmp.appendingPathComponent("library.sqlite.bak")

        // First open creates file + migrates; no prior file → no bak required.
        let first = try LibraryDatabase.open(at: dbURL)
        XCTAssertTrue(try first.hasV1Schema())
        XCTAssertFalse(FileManager.default.fileExists(atPath: bak.path))

        try first.dbQueue.write { conn in
            try conn.execute(
                sql: """
                    INSERT INTO personas (id, name, version, json, created_at, updated_at)
                    VALUES ('p1', 'n', '1.0.0', '{}', 't', 't')
                    """
            )
        }

        let second = try LibraryDatabase.open(at: dbURL)
        let name: String? = try second.dbQueue.read { conn in
            try String.fetchOne(conn, sql: "SELECT name FROM personas WHERE id = 'p1'")
        }
        XCTAssertEqual(name, "n")
    }
}
