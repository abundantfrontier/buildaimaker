import BAMCore
import Foundation
import GRDB

/// GRDB migration registry for `library.sqlite`.
///
/// Migration identifiers are sequential (`v1`, …). Product schema version is
/// `ProtocolVersions.librarySchemaVersion` (currently 1).
public enum LibraryMigrator: Sendable {
    /// Migration identifier for library schema v1.
    public static let v1MigrationName = "v1"

    /// Product-level schema version this migrator targets.
    public static var currentSchemaVersion: Int {
        ProtocolVersions.librarySchemaVersion
    }

    /// Builds a `DatabaseMigrator` with all registered library migrations.
    public static func makeMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        #if DEBUG
        // Faster iteration in debug; production uses strict forward migrations.
        migrator.eraseDatabaseOnSchemaChange = false
        #endif
        migrator.registerMigration(v1MigrationName) { db in
            try migrateV1(db)
        }
        return migrator
    }

    /// Applies migrations to an open database writer.
    /// Failures are mapped to `BAMError(code: .migrationFailed)`.
    public static func migrate(_ dbWriter: any DatabaseWriter) throws {
        try migrate(dbWriter, using: makeMigrator())
    }

    /// Applies the given migrator, mapping non-`BAMError` failures to
    /// `BAM_MIGRATION_FAILED` so callers can branch on the stable taxonomy.
    public static func migrate(_ dbWriter: any DatabaseWriter, using migrator: DatabaseMigrator) throws {
        do {
            try migrator.migrate(dbWriter)
        } catch let error as BAMError {
            throw error
        } catch {
            throw BAMError(
                code: .migrationFailed,
                message: error.localizedDescription
            )
        }
    }

    // MARK: - V1 DDL

    /// SQLite v1 tables: datasets, dataset_versions, models, artifacts, jobs,
    /// voice_profiles, consent_records, personas, bookmarks.
    public static func migrateV1(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE datasets (
              id TEXT PRIMARY KEY NOT NULL,
              name TEXT NOT NULL,
              modality TEXT NOT NULL,
              root_path TEXT NOT NULL,
              import_mode TEXT NOT NULL,
              status TEXT NOT NULL,
              created_at TEXT NOT NULL
            );

            CREATE TABLE dataset_versions (
              id TEXT PRIMARY KEY NOT NULL,
              dataset_id TEXT NOT NULL REFERENCES datasets(id),
              version INTEGER NOT NULL,
              content_hash TEXT,
              row_count INTEGER,
              meta_json TEXT NOT NULL DEFAULT '{}',
              UNIQUE(dataset_id, version)
            );

            CREATE TABLE models (
              id TEXT PRIMARY KEY NOT NULL,
              source_key TEXT,
              content_hash TEXT,
              name TEXT NOT NULL,
              kind TEXT NOT NULL,
              arch_family TEXT,
              param_count_b REAL,
              quant_bits INTEGER,
              license TEXT,
              local_path TEXT NOT NULL,
              meta_json TEXT NOT NULL DEFAULT '{}'
            );

            CREATE TABLE artifacts (
              id TEXT PRIMARY KEY NOT NULL,
              kind TEXT NOT NULL,
              job_id TEXT,
              base_model_id TEXT,
              local_path TEXT NOT NULL,
              metrics_json TEXT,
              created_at TEXT NOT NULL
            );

            CREATE TABLE jobs (
              id TEXT PRIMARY KEY NOT NULL,
              status TEXT NOT NULL,
              modality TEXT NOT NULL,
              config_json TEXT NOT NULL,
              error_code TEXT,
              error_message TEXT,
              created_at TEXT NOT NULL,
              updated_at TEXT NOT NULL
            );

            CREATE TABLE voice_profiles (
              id TEXT PRIMARY KEY NOT NULL,
              engine_id TEXT NOT NULL,
              local_path TEXT NOT NULL,
              consent_record_id TEXT NOT NULL,
              consent_content_hash TEXT NOT NULL,
              created_at TEXT NOT NULL
            );

            CREATE TABLE consent_records (
              id TEXT PRIMARY KEY NOT NULL,
              json TEXT NOT NULL,
              content_hash TEXT NOT NULL,
              created_at TEXT NOT NULL
            );

            CREATE TABLE personas (
              id TEXT PRIMARY KEY NOT NULL,
              name TEXT NOT NULL,
              version TEXT NOT NULL,
              json TEXT NOT NULL,
              created_at TEXT NOT NULL,
              updated_at TEXT NOT NULL
            );

            CREATE TABLE bookmarks (
              id TEXT PRIMARY KEY NOT NULL,
              entity_type TEXT NOT NULL,
              entity_id TEXT NOT NULL,
              bookmark_data BLOB NOT NULL
            );
            """)
    }

    /// Expected table names after migration v1.
    public static let v1TableNames: [String] = [
        "datasets",
        "dataset_versions",
        "models",
        "artifacts",
        "jobs",
        "voice_profiles",
        "consent_records",
        "personas",
        "bookmarks",
    ]
}
