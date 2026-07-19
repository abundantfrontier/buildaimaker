import BAMCore
import Foundation
import GRDB

/// Opens and migrates the app library SQLite database (`library.sqlite`).
///
/// Before each migrate on an existing on-disk file, copies the DB to
/// `library.sqlite.bak` (design: pre-migration backup).
public final class LibraryDatabase: Sendable {
    public let dbQueue: DatabaseQueue
    public let databaseURL: URL?

    /// Opens an in-memory database and applies migrations (unit tests / ephemeral).
    public static func openInMemory() throws -> LibraryDatabase {
        let queue = try DatabaseQueue()
        try LibraryMigrator.migrate(queue)
        return LibraryDatabase(dbQueue: queue, databaseURL: nil)
    }

    /// Opens (or creates) the library database at `url`, backs up if present, migrates.
    public static func open(at url: URL) throws -> LibraryDatabase {
        let fm = FileManager.default
        let parent = url.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)

        if fm.fileExists(atPath: url.path) {
            // Design: copy `library.sqlite` → `library.sqlite.bak` before migrate.
            let backupURL = parent.appendingPathComponent(url.lastPathComponent + ".bak")
            if fm.fileExists(atPath: backupURL.path) {
                try fm.removeItem(at: backupURL)
            }
            try fm.copyItem(at: url, to: backupURL)
        }

        let queue = try DatabaseQueue(path: url.path)
        try LibraryMigrator.migrate(queue)
        return LibraryDatabase(dbQueue: queue, databaseURL: url)
    }

    /// Opens the default library database under `LibraryPaths.libraryDatabase`.
    public static func openDefault() throws -> LibraryDatabase {
        try open(at: LibraryPaths.libraryDatabase)
    }

    private init(dbQueue: DatabaseQueue, databaseURL: URL?) {
        self.dbQueue = dbQueue
        self.databaseURL = databaseURL
    }

    /// Returns user-table names currently present (excludes `grdb_migrations`).
    public func userTableNames() throws -> [String] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT name FROM sqlite_master
                    WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'grdb_%'
                    ORDER BY name
                    """
            )
            return rows.map { $0["name"] as String }
        }
    }

    /// True when all v1 tables exist.
    public func hasV1Schema() throws -> Bool {
        let names = Set(try userTableNames())
        return Set(LibraryMigrator.v1TableNames).isSubset(of: names)
    }
}
