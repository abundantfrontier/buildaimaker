import BAMCore
import BAMModels
import BAMPersistence
import Foundation
import GRDB

/// GRDB access for `datasets` / `dataset_versions` / `bookmarks`.
public final class DatasetStore: Sendable {
    public let database: LibraryDatabase

    public init(database: LibraryDatabase) {
        self.database = database
    }

    // MARK: - Read

    public func listDatasets() throws -> [DatasetRecord] {
        try database.dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, name, modality, root_path, import_mode, status, created_at
                    FROM datasets
                    ORDER BY created_at DESC, name ASC
                    """
            )
            return try rows.map(Self.dataset(from:))
        }
    }

    public func dataset(id: String) throws -> DatasetRecord? {
        try database.dbQueue.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT id, name, modality, root_path, import_mode, status, created_at
                    FROM datasets WHERE id = ?
                    """,
                arguments: [id]
            ) else { return nil }
            return try Self.dataset(from: row)
        }
    }

    public func latestVersion(datasetId: String) throws -> DatasetVersionRecord? {
        try database.dbQueue.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT id, dataset_id, version, content_hash, row_count, meta_json
                    FROM dataset_versions
                    WHERE dataset_id = ?
                    ORDER BY version DESC
                    LIMIT 1
                    """,
                arguments: [datasetId]
            ) else { return nil }
            return Self.version(from: row)
        }
    }

    public func versions(datasetId: String) throws -> [DatasetVersionRecord] {
        try database.dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, dataset_id, version, content_hash, row_count, meta_json
                    FROM dataset_versions
                    WHERE dataset_id = ?
                    ORDER BY version ASC
                    """,
                arguments: [datasetId]
            )
            return rows.map(Self.version(from:))
        }
    }

    // MARK: - Write

    public func insert(dataset: DatasetRecord, version: DatasetVersionRecord) throws {
        try database.dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO datasets (id, name, modality, root_path, import_mode, status, created_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    dataset.id,
                    dataset.name,
                    dataset.modality.rawValue,
                    dataset.rootPath,
                    dataset.importMode.rawValue,
                    dataset.status.rawValue,
                    dataset.createdAt,
                ]
            )
            try db.execute(
                sql: """
                    INSERT INTO dataset_versions (id, dataset_id, version, content_hash, row_count, meta_json)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    version.id,
                    version.datasetId,
                    version.version,
                    version.contentHash,
                    version.rowCount,
                    version.metaJSON,
                ]
            )
        }
    }

    public func updateStatus(datasetId: String, status: DatasetStatus) throws {
        try database.dbQueue.write { db in
            try db.execute(
                sql: "UPDATE datasets SET status = ? WHERE id = ?",
                arguments: [status.rawValue, datasetId]
            )
        }
    }

    public func insertBookmark(
        id: String,
        entityType: String,
        entityId: String,
        bookmarkData: Data
    ) throws {
        try database.dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO bookmarks (id, entity_type, entity_id, bookmark_data)
                    VALUES (?, ?, ?, ?)
                    """,
                arguments: [id, entityType, entityId, bookmarkData]
            )
        }
    }

    public func bookmarkData(entityType: String, entityId: String) throws -> Data? {
        try database.dbQueue.read { db in
            try Data.fetchOne(
                db,
                sql: """
                    SELECT bookmark_data FROM bookmarks
                    WHERE entity_type = ? AND entity_id = ?
                    LIMIT 1
                    """,
                arguments: [entityType, entityId]
            )
        }
    }

    public func deleteDataset(id: String) throws {
        try database.dbQueue.write { db in
            try db.execute(sql: "DELETE FROM dataset_versions WHERE dataset_id = ?", arguments: [id])
            try db.execute(
                sql: "DELETE FROM bookmarks WHERE entity_type = ? AND entity_id = ?",
                arguments: ["dataset", id]
            )
            try db.execute(sql: "DELETE FROM datasets WHERE id = ?", arguments: [id])
        }
    }

    // MARK: - Mapping

    private static func dataset(from row: Row) throws -> DatasetRecord {
        guard let modality = DatasetModality(rawValue: row["modality"]),
              let importMode = DatasetImportMode(rawValue: row["import_mode"]),
              let status = DatasetStatus(rawValue: row["status"])
        else {
            throw BAMError(
                code: .schemaInvalid,
                message: "Corrupt dataset row \(row["id"] as String? ?? "?")"
            )
        }
        return DatasetRecord(
            id: row["id"],
            name: row["name"],
            modality: modality,
            rootPath: row["root_path"],
            importMode: importMode,
            status: status,
            createdAt: row["created_at"]
        )
    }

    private static func version(from row: Row) -> DatasetVersionRecord {
        DatasetVersionRecord(
            id: row["id"],
            datasetId: row["dataset_id"],
            version: row["version"],
            contentHash: row["content_hash"],
            rowCount: row["row_count"],
            metaJSON: row["meta_json"]
        )
    }
}
