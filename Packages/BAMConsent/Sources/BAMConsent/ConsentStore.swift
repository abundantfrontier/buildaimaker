import BAMCore
import BAMModels
import BAMPersistence
import Foundation
import GRDB

/// Persists `ConsentRecord` rows to GRDB `consent_records` and optional JSON under `consent/`.
public final class ConsentStore: Sendable {
    private let database: LibraryDatabase
    private let consentDirectory: URL
    private let writeJSONFiles: Bool

    public init(
        database: LibraryDatabase,
        consentDirectory: URL,
        writeJSONFiles: Bool = true
    ) {
        self.database = database
        self.consentDirectory = consentDirectory
        self.writeJSONFiles = writeJSONFiles
    }

    /// Default store: library DB + `LibraryPaths.consent`.
    public static func openDefault() throws -> ConsentStore {
        let db = try LibraryDatabase.openDefault()
        return ConsentStore(
            database: db,
            consentDirectory: LibraryPaths.consent,
            writeJSONFiles: true
        )
    }

    // MARK: - Write

    /// Inserts a consent record. Fails if `id` already exists (append-only for product create).
    ///
    /// Caller must supply a hashed, policy-valid record. Does not upsert.
    @discardableResult
    public func save(_ record: ConsentRecord) throws -> ConsentIndexRecord {
        try insert(record, replaceExisting: false)
    }

    /// Inserts or replaces a consent row. Reserved for admin/import/repair paths only.
    @discardableResult
    public func saveReplacing(_ record: ConsentRecord) throws -> ConsentIndexRecord {
        try insert(record, replaceExisting: true)
    }

    private func insert(_ record: ConsentRecord, replaceExisting: Bool) throws -> ConsentIndexRecord {
        guard try record.verifyContentHash() else {
            throw BAMError(
                code: .consentTamper,
                message: "contentHash does not match canonical serialization"
            )
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let jsonData = try encoder.encode(record)
        guard let jsonString = String(data: jsonData, encoding: .utf8) else {
            throw BAMError(code: .schemaInvalid, message: "Could not encode ConsentRecord JSON")
        }

        let normalizedHash = ConsentRecord.normalizeHash(record.contentHash)
        let index = ConsentIndexRecord(
            id: record.id,
            json: jsonString,
            contentHash: normalizedHash,
            createdAt: record.createdAt
        )

        do {
            try database.dbQueue.write { db in
                if replaceExisting {
                    try db.execute(
                        sql: """
                            INSERT INTO consent_records (id, json, content_hash, created_at)
                            VALUES (?, ?, ?, ?)
                            ON CONFLICT(id) DO UPDATE SET
                              json = excluded.json,
                              content_hash = excluded.content_hash,
                              created_at = excluded.created_at
                            """,
                        arguments: [index.id, index.json, index.contentHash, index.createdAt]
                    )
                } else {
                    // Fail on duplicate id — consent rows are binding evidence (append-only).
                    try db.execute(
                        sql: """
                            INSERT INTO consent_records (id, json, content_hash, created_at)
                            VALUES (?, ?, ?, ?)
                            """,
                        arguments: [index.id, index.json, index.contentHash, index.createdAt]
                    )
                }
            }
        } catch let error as BAMError {
            throw error
        } catch {
            // SQLite unique constraint / GRDB DatabaseError
            if let dbError = error as? DatabaseError, dbError.resultCode == .SQLITE_CONSTRAINT {
                throw BAMError(
                    code: .schemaInvalid,
                    message: "Consent record already exists: \(record.id)"
                )
            }
            throw BAMError(
                code: .schemaInvalid,
                message: "Could not save consent record: \(error.localizedDescription)"
            )
        }

        if writeJSONFiles {
            try writeJSONFile(record: record, jsonData: jsonData)
        }

        return index
    }

    // MARK: - Read

    /// Decodes a stored record **without** verifying the content hash.
    /// Prefer `fetchAndVerify` for product binding paths.
    public func fetchUnverified(id: String) throws -> ConsentRecord? {
        let row: ConsentIndexRecord? = try database.dbQueue.read { db in
            try ConsentIndexRecord.fetchOne(db, id: id)
        }
        guard let row else { return nil }
        return try decodeRecord(from: row)
    }

    public func fetchIndex(id: String) throws -> ConsentIndexRecord? {
        try database.dbQueue.read { db in
            try ConsentIndexRecord.fetchOne(db, id: id)
        }
    }

    public func listAll() throws -> [ConsentIndexRecord] {
        try database.dbQueue.read { db in
            try ConsentIndexRecord.fetchAll(db)
        }
    }

    /// Loads record, verifies recomputed hash, and cross-checks denormalized `content_hash` column.
    public func fetchAndVerify(id: String) throws -> ConsentRecord {
        let row: ConsentIndexRecord? = try database.dbQueue.read { db in
            try ConsentIndexRecord.fetchOne(db, id: id)
        }
        guard let row else {
            throw BAMError(code: .consentRequired, message: "Consent record not found: \(id)")
        }
        let record = try decodeRecord(from: row)
        guard try record.verifyContentHash() else {
            throw BAMError(code: .consentTamper, message: "Consent contentHash mismatch for \(id)")
        }
        let columnHash = ConsentRecord.normalizeHash(row.contentHash)
        let bodyHash = ConsentRecord.normalizeHash(record.contentHash)
        guard columnHash == bodyHash else {
            throw BAMError(
                code: .consentTamper,
                message: "Consent content_hash column desync for \(id)"
            )
        }
        return record
    }

    // MARK: - JSON files

    public func jsonFileURL(for id: String) -> URL {
        let component = LibraryPaths.sanitizedPathComponent(id) + ".json"
        return consentDirectory.appendingPathComponent(component, isDirectory: false)
    }

    private func writeJSONFile(record: ConsentRecord, jsonData: Data) throws {
        let fm = FileManager.default
        try fm.createDirectory(
            at: consentDirectory,
            withIntermediateDirectories: true
        )
        let url = jsonFileURL(for: record.id)
        try jsonData.write(to: url, options: [.atomic])
    }

    private func decodeRecord(from index: ConsentIndexRecord) throws -> ConsentRecord {
        guard let data = index.json.data(using: .utf8) else {
            throw BAMError(code: .schemaInvalid, message: "Consent JSON is not UTF-8")
        }
        do {
            return try JSONDecoder().decode(ConsentRecord.self, from: data)
        } catch {
            throw BAMError(
                code: .schemaInvalid,
                message: "Consent JSON decode failed: \(error.localizedDescription)"
            )
        }
    }
}

// MARK: - GRDB row mapping

extension ConsentIndexRecord: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "consent_records"

    public enum Columns {
        public static let id = Column("id")
        public static let json = Column("json")
        public static let contentHash = Column("content_hash")
        public static let createdAt = Column("created_at")
    }

    public init(row: Row) {
        self.init(
            id: row[Columns.id],
            json: row[Columns.json],
            contentHash: row[Columns.contentHash],
            createdAt: row[Columns.createdAt]
        )
    }

    public func encode(to container: inout PersistenceContainer) {
        container[Columns.id] = id
        container[Columns.json] = json
        container[Columns.contentHash] = contentHash
        container[Columns.createdAt] = createdAt
    }

    public static func fetchOne(_ db: Database, id: String) throws -> ConsentIndexRecord? {
        try ConsentIndexRecord
            .filter(Columns.id == id)
            .fetchOne(db)
    }

    public static func fetchAll(_ db: Database) throws -> [ConsentIndexRecord] {
        try ConsentIndexRecord
            .order(Columns.createdAt.desc)
            .fetchAll(db)
    }
}

// MARK: - Display helpers

extension ConsentIndexRecord {
    /// Best-effort decode of the stored JSON for list/detail UI.
    public func decodedRecord() -> ConsentRecord? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ConsentRecord.self, from: data)
    }
}
