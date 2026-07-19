import BAMCore
import Foundation
import GRDB

/// Opens and migrates the app library SQLite database (`library.sqlite`).
///
/// Before applying **pending** migrations on an existing on-disk file, copies the DB to
/// `library.sqlite.bak` (design: pre-migration backup of last known good schema).
/// Already-current databases are opened without rewriting `.bak`.
public final class LibraryDatabase: Sendable {
    public let dbQueue: DatabaseQueue
    public let databaseURL: URL?

    /// Opens an in-memory database and applies migrations (unit tests / ephemeral).
    public static func openInMemory() throws -> LibraryDatabase {
        let queue = try DatabaseQueue()
        try LibraryMigrator.migrate(queue)
        return LibraryDatabase(dbQueue: queue, databaseURL: nil)
    }

    /// Opens (or creates) the library database at `url`.
    ///
    /// - If the file already exists and has pending migrations, writes
    ///   `\<name\>.bak` (temp copy then replace) before migrating.
    /// - Migration failures surface as `BAMError(code: .migrationFailed)`.
    public static func open(at url: URL) throws -> LibraryDatabase {
        let fm = FileManager.default
        let parent = url.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)

        let fileExisted = fm.fileExists(atPath: url.path)
        if fileExisted {
            let pending: Bool
            do {
                pending = try hasPendingMigrations(at: url)
            } catch let error as BAMError {
                throw error
            } catch {
                throw BAMError(
                    code: .migrationFailed,
                    message: "Could not inspect library schema: \(error.localizedDescription)"
                )
            }
            if pending {
                try writePreMigrationBackup(of: url)
            }
        }

        let queue: DatabaseQueue
        do {
            queue = try DatabaseQueue(path: url.path)
        } catch {
            throw BAMError(
                code: .migrationFailed,
                message: "Could not open library database: \(error.localizedDescription)"
            )
        }

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

    // MARK: - Pre-migration backup

    /// True when registered migrations have not all been applied yet.
    public static func hasPendingMigrations(at url: URL) throws -> Bool {
        let queue = try DatabaseQueue(path: url.path)
        return try queue.read { db in
            !(try LibraryMigrator.makeMigrator().hasCompletedMigrations(db))
        }
    }

    /// Copies `url` → `url.lastPathComponent.bak` via a temp file so an existing
    /// `.bak` is only replaced after the new copy succeeds.
    public static func writePreMigrationBackup(of url: URL) throws {
        let fm = FileManager.default
        let parent = url.deletingLastPathComponent()
        let bakURL = parent.appendingPathComponent(url.lastPathComponent + ".bak")
        let tempURL = parent.appendingPathComponent(url.lastPathComponent + ".bak.tmp")

        if fm.fileExists(atPath: tempURL.path) {
            try fm.removeItem(at: tempURL)
        }
        try fm.copyItem(at: url, to: tempURL)

        // Replace previous bak only after the new backup exists.
        if fm.fileExists(atPath: bakURL.path) {
            try fm.removeItem(at: bakURL)
        }
        try fm.moveItem(at: tempURL, to: bakURL)
    }

    // MARK: - Schema inspection

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
