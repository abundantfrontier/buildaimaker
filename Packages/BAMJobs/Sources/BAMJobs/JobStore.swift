import BAMCore
import BAMModels
import BAMPersistence
import Foundation
import GRDB

/// CRUD for the `jobs` table in `library.sqlite`.
public struct JobStore: Sendable {
    public let database: LibraryDatabase

    public init(database: LibraryDatabase) {
        self.database = database
    }

    // MARK: - Write

    public func insert(_ job: JobRecord) throws {
        try database.dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO jobs (
                      id, status, modality, config_json,
                      error_code, error_message, created_at, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    job.id,
                    job.status.rawValue,
                    job.modality.rawValue,
                    job.configJSON,
                    job.errorCode,
                    job.errorMessage,
                    job.createdAt,
                    job.updatedAt,
                ]
            )
        }
    }

    public func update(_ job: JobRecord) throws {
        try database.dbQueue.write { db in
            try Self.update(job, db: db)
        }
    }

    /// Applies a validated status transition and persists the row.
    ///
    /// Read-modify-write runs inside a **single** write transaction so concurrent
    /// store callers cannot TOCTOU the status edge.
    @discardableResult
    public func transition(
        id: String,
        to newStatus: JobStatus,
        errorCode: String? = nil,
        errorMessage: String? = nil,
        updatedAt: String = JobTimestamps.now()
    ) throws -> JobRecord {
        try database.dbQueue.write { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM jobs WHERE id = ?",
                arguments: [id]
            ) else {
                throw BAMError(code: .schemaInvalid, message: "Job not found: \(id)")
            }
            var job = Self.mapRow(row)
            try JobStateMachine.transition(from: job.status, to: newStatus)
            job.status = newStatus
            job.updatedAt = updatedAt
            if let errorCode {
                job.errorCode = errorCode
            }
            if let errorMessage {
                job.errorMessage = errorMessage
            }
            if newStatus == .succeeded, errorCode == nil {
                job.errorCode = nil
                job.errorMessage = nil
            }
            try Self.update(job, db: db)
            return job
        }
    }

    // MARK: - Read

    public func fetch(id: String) throws -> JobRecord? {
        try database.dbQueue.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT * FROM jobs WHERE id = ?",
                arguments: [id]
            ).map(Self.mapRow)
        }
    }

    public func fetchAll() throws -> [JobRecord] {
        try database.dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT * FROM jobs ORDER BY created_at DESC, id DESC"
            ).map(Self.mapRow)
        }
    }

    /// Jobs that still occupy the single training slot or wait for it.
    public func fetchActive() throws -> [JobRecord] {
        let statuses = JobStateMachine.activeStatuses.map(\.rawValue)
        let placeholders = statuses.map { _ in "?" }.joined(separator: ", ")
        return try database.dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM jobs
                    WHERE status IN (\(placeholders))
                    ORDER BY created_at ASC, id ASC
                    """,
                arguments: StatementArguments(statuses)
            ).map(Self.mapRow)
        }
    }

    /// Jobs currently holding the training slot (`preparing` or `running`).
    public func fetchSlotHolders() throws -> [JobRecord] {
        try fetchRecoverable()
    }

    /// Oldest queued job (FIFO).
    public func fetchNextQueued() throws -> JobRecord? {
        try database.dbQueue.read { db in
            try Row.fetchOne(
                db,
                sql: """
                    SELECT * FROM jobs
                    WHERE status = ?
                    ORDER BY created_at ASC, id ASC
                    LIMIT 1
                    """,
                arguments: [JobStatus.queued.rawValue]
            ).map(Self.mapRow)
        }
    }

    /// Jobs left in preparing/running after a crash (candidates for interrupt).
    public func fetchRecoverable() throws -> [JobRecord] {
        try database.dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM jobs
                    WHERE status IN (?, ?)
                    ORDER BY updated_at ASC
                    """,
                arguments: [JobStatus.preparing.rawValue, JobStatus.running.rawValue]
            ).map(Self.mapRow)
        }
    }

    // MARK: - Mapping / internal write

    private static func update(_ job: JobRecord, db: Database) throws {
        try db.execute(
            sql: """
                UPDATE jobs SET
                  status = ?,
                  modality = ?,
                  config_json = ?,
                  error_code = ?,
                  error_message = ?,
                  updated_at = ?
                WHERE id = ?
                """,
            arguments: [
                job.status.rawValue,
                job.modality.rawValue,
                job.configJSON,
                job.errorCode,
                job.errorMessage,
                job.updatedAt,
                job.id,
            ]
        )
    }

    private static func mapRow(_ row: Row) -> JobRecord {
        JobRecord(
            id: row["id"],
            status: JobStatus(rawValue: row["status"]) ?? .failed,
            modality: JobModality(rawValue: row["modality"]) ?? .llm,
            configJSON: row["config_json"],
            errorCode: row["error_code"],
            errorMessage: row["error_message"],
            createdAt: row["created_at"],
            updatedAt: row["updated_at"]
        )
    }
}
