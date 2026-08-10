import BAMCore
import BAMModels
import BAMPersistence
import Foundation
import GRDB

/// `PersonaLibraryLookup` backed by `library.sqlite` tables.
public struct GRDBPersonaLibrary: PersonaLibraryLookup, Sendable {
    public let database: LibraryDatabase
    /// Optional external consent loader (preferred when ConsentStore verifies hashes).
    private let consentLoader: (@Sendable (String) throws -> ConsentRecord?)?

    public init(
        database: LibraryDatabase,
        consentLoader: (@Sendable (String) throws -> ConsentRecord?)? = nil
    ) {
        self.database = database
        self.consentLoader = consentLoader
    }

    public func model(id: String) throws -> ModelRecord? {
        try database.dbQueue.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM models WHERE id = ?",
                arguments: [id]
            ) else { return nil }
            return ModelRecord(
                id: row["id"],
                sourceKey: row["source_key"],
                contentHash: row["content_hash"],
                name: row["name"],
                kind: ModelKind(rawValue: row["kind"]) ?? .base,
                archFamily: row["arch_family"],
                paramCountB: row["param_count_b"],
                quantBits: row["quant_bits"],
                license: row["license"],
                localPath: row["local_path"],
                metaJSON: row["meta_json"] ?? "{}"
            )
        }
    }

    public func artifact(id: String) throws -> ArtifactRecord? {
        try database.dbQueue.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM artifacts WHERE id = ?",
                arguments: [id]
            ) else { return nil }
            return ArtifactRecord(
                id: row["id"],
                kind: ArtifactKind(rawValue: row["kind"]) ?? .loraAdapter,
                jobId: row["job_id"],
                baseModelId: row["base_model_id"],
                localPath: row["local_path"],
                metricsJSON: row["metrics_json"],
                createdAt: row["created_at"]
            )
        }
    }

    public func voiceProfile(id: String) throws -> VoiceProfileRecord? {
        try database.dbQueue.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM voice_profiles WHERE id = ?",
                arguments: [id]
            ) else { return nil }
            return VoiceProfileRecord(
                id: row["id"],
                engineId: row["engine_id"],
                localPath: row["local_path"],
                consentRecordId: row["consent_record_id"],
                consentContentHash: row["consent_content_hash"],
                createdAt: row["created_at"]
            )
        }
    }

    public func consent(id: String) throws -> ConsentRecord? {
        if let consentLoader {
            return try consentLoader(id)
        }
        return try database.dbQueue.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT json FROM consent_records WHERE id = ?",
                arguments: [id]
            ) else { return nil }
            let json: String = row["json"]
            guard let data = json.data(using: .utf8) else { return nil }
            return try JSONDecoder().decode(ConsentRecord.self, from: data)
        }
    }

    // MARK: - Helpers used by product service / tests

    public func upsertModel(_ model: ModelRecord) throws {
        try database.dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO models (
                      id, source_key, content_hash, name, kind, arch_family,
                      param_count_b, quant_bits, license, local_path, meta_json
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                      source_key = excluded.source_key,
                      content_hash = excluded.content_hash,
                      name = excluded.name,
                      kind = excluded.kind,
                      arch_family = excluded.arch_family,
                      param_count_b = excluded.param_count_b,
                      quant_bits = excluded.quant_bits,
                      license = excluded.license,
                      local_path = excluded.local_path,
                      meta_json = excluded.meta_json
                    """,
                arguments: [
                    model.id,
                    model.sourceKey,
                    model.contentHash,
                    model.name,
                    model.kind.rawValue,
                    model.archFamily,
                    model.paramCountB,
                    model.quantBits,
                    model.license,
                    model.localPath,
                    model.metaJSON,
                ]
            )
        }
    }

    public func upsertArtifact(_ artifact: ArtifactRecord) throws {
        try database.dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO artifacts (
                      id, kind, job_id, base_model_id, local_path, metrics_json, created_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                      kind = excluded.kind,
                      job_id = excluded.job_id,
                      base_model_id = excluded.base_model_id,
                      local_path = excluded.local_path,
                      metrics_json = excluded.metrics_json,
                      created_at = excluded.created_at
                    """,
                arguments: [
                    artifact.id,
                    artifact.kind.rawValue,
                    artifact.jobId,
                    artifact.baseModelId,
                    artifact.localPath,
                    artifact.metricsJSON,
                    artifact.createdAt,
                ]
            )
        }
    }
}
