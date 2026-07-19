import BAMCore
import BAMModels
import BAMPersistence
import Foundation
import GRDB

/// CRUD for the `voice_profiles` table in `library.sqlite`.
public struct VoiceProfileStore: Sendable {
    public let database: LibraryDatabase

    public init(database: LibraryDatabase) {
        self.database = database
    }

    // MARK: - Write

    public func insert(_ profile: VoiceProfileRecord) throws {
        try database.dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO voice_profiles (
                      id, engine_id, local_path, consent_record_id,
                      consent_content_hash, created_at
                    ) VALUES (?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    profile.id,
                    profile.engineId,
                    profile.localPath,
                    profile.consentRecordId,
                    profile.consentContentHash,
                    profile.createdAt,
                ]
            )
        }
    }

    /// Insert or replace (idempotent finalize after stub job success).
    public func upsert(_ profile: VoiceProfileRecord) throws {
        try database.dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO voice_profiles (
                      id, engine_id, local_path, consent_record_id,
                      consent_content_hash, created_at
                    ) VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                      engine_id = excluded.engine_id,
                      local_path = excluded.local_path,
                      consent_record_id = excluded.consent_record_id,
                      consent_content_hash = excluded.consent_content_hash,
                      created_at = excluded.created_at
                    """,
                arguments: [
                    profile.id,
                    profile.engineId,
                    profile.localPath,
                    profile.consentRecordId,
                    profile.consentContentHash,
                    profile.createdAt,
                ]
            )
        }
    }

    public func delete(id: String) throws {
        try database.dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM voice_profiles WHERE id = ?",
                arguments: [id]
            )
        }
    }

    // MARK: - Read

    public func fetch(id: String) throws -> VoiceProfileRecord? {
        try database.dbQueue.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT * FROM voice_profiles WHERE id = ?",
                arguments: [id]
            ).map(Self.mapRow)
        }
    }

    public func fetchAll() throws -> [VoiceProfileRecord] {
        try database.dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT * FROM voice_profiles ORDER BY created_at DESC, id DESC"
            ).map(Self.mapRow)
        }
    }

    // MARK: - Mapping

    private static func mapRow(_ row: Row) -> VoiceProfileRecord {
        VoiceProfileRecord(
            id: row["id"],
            engineId: row["engine_id"],
            localPath: row["local_path"],
            consentRecordId: row["consent_record_id"],
            consentContentHash: row["consent_content_hash"],
            createdAt: row["created_at"]
        )
    }
}
