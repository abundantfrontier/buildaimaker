import BAMCore
import BAMModels
import BAMPersistence
import Foundation
import GRDB

/// GRDB access for the `personas` table (`json` holds full `PersonaDocument`).
public final class PersonaStore: Sendable {
    public let database: LibraryDatabase

    public init(database: LibraryDatabase) {
        self.database = database
    }

    // MARK: - Write

    public func upsert(_ record: PersonaIndexRecord) throws {
        try database.dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO personas (
                      id, name, version, json, created_at, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                      name = excluded.name,
                      version = excluded.version,
                      json = excluded.json,
                      updated_at = excluded.updated_at
                    """,
                arguments: [
                    record.id,
                    record.name,
                    record.version,
                    record.json,
                    record.createdAt,
                    record.updatedAt,
                ]
            )
        }
    }

    public func delete(id: String) throws {
        try database.dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM personas WHERE id = ?",
                arguments: [id]
            )
        }
    }

    // MARK: - Read

    public func fetch(id: String) throws -> PersonaIndexRecord? {
        try database.dbQueue.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT * FROM personas WHERE id = ?",
                arguments: [id]
            ).map(Self.mapRow)
        }
    }

    public func fetchAll() throws -> [PersonaIndexRecord] {
        try database.dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT * FROM personas ORDER BY updated_at DESC, name ASC"
            ).map(Self.mapRow)
        }
    }

    public func fetchDocument(id: String) throws -> PersonaDocument? {
        guard let row = try fetch(id: id) else { return nil }
        guard let data = row.json.data(using: .utf8) else {
            throw BAMError(code: .schemaInvalid, message: "Persona JSON is not UTF-8")
        }
        return try JSONDecoder().decode(PersonaDocument.self, from: data)
    }

    // MARK: - Mapping

    private static func mapRow(_ row: Row) -> PersonaIndexRecord {
        PersonaIndexRecord(
            id: row["id"],
            name: row["name"],
            version: row["version"],
            json: row["json"],
            createdAt: row["created_at"],
            updatedAt: row["updated_at"]
        )
    }
}

extension PersonaIndexRecord {
    /// Decodes the nested `PersonaDocument` from the `json` column.
    public func decodedDocument() throws -> PersonaDocument {
        guard let data = json.data(using: .utf8) else {
            throw BAMError(code: .schemaInvalid, message: "Persona JSON is not UTF-8")
        }
        return try JSONDecoder().decode(PersonaDocument.self, from: data)
    }
}
