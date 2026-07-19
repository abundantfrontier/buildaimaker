import BAMCore
import BAMModels
import BAMPersistence
import Foundation

/// Creates, validates, hashes, and persists voice-cloning consent attestations.
public final class ConsentService: Sendable {
    private let store: ConsentStore
    private let appVersion: String
    private let idGenerator: @Sendable () -> String
    private let nowISO8601: @Sendable () -> String

    public init(
        store: ConsentStore,
        appVersion: String = ConsentService.defaultAppVersion,
        idGenerator: @escaping @Sendable () -> String = { BAMID.generate() },
        nowISO8601: @escaping @Sendable () -> String = { ConsentService.currentTimestamp() }
    ) {
        self.store = store
        self.appVersion = appVersion
        self.idGenerator = idGenerator
        self.nowISO8601 = nowISO8601
    }

    /// Product app version stamped onto new consent records.
    public static let defaultAppVersion = "0.1.0"

    /// Builds a service over an in-memory library DB (unit tests).
    public static func makeInMemory(
        writeJSONFiles: Bool = false,
        consentDirectory: URL? = nil,
        appVersion: String = ConsentService.defaultAppVersion,
        idGenerator: @escaping @Sendable () -> String = { BAMID.generate() },
        nowISO8601: @escaping @Sendable () -> String = { ConsentService.currentTimestamp() }
    ) throws -> ConsentService {
        let db = try LibraryDatabase.openInMemory()
        let dir = consentDirectory
            ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("bam-consent-\(UUID().uuidString)", isDirectory: true)
        let store = ConsentStore(
            database: db,
            consentDirectory: dir,
            writeJSONFiles: writeJSONFiles
        )
        return ConsentService(
            store: store,
            appVersion: appVersion,
            idGenerator: idGenerator,
            nowISO8601: nowISO8601
        )
    }

    // MARK: - Create

    /// Validates `draft`, builds a `ConsentRecord` with canonical `contentHash`, and persists it.
    @discardableResult
    public func create(from draft: ConsentDraft) throws -> ConsentRecord {
        try ConsentValidator.validate(draft)

        let timestamp = nowISO8601()
        let id = idGenerator()
        let name = draft.subjectDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let attestor = draft.attestorUserLabel.trimmingCharacters(in: .whitespacesAndNewlines)

        var record = ConsentRecord(
            id: id,
            schemaVersion: ConsentRecord.schemaVersionV1,
            createdAt: timestamp,
            subjectType: draft.subjectType,
            subjectDisplayName: name,
            attestorUserLabel: attestor,
            scope: draft.scope,
            statements: draft.selectedStatements,
            attestedAt: timestamp,
            appVersion: appVersion,
            jurisdictionNote: draft.jurisdictionNote,
            retention: ConsentRecord.defaultRetention,
            contentHash: ""
        )
        record = try record.withComputedContentHash()
        try store.save(record)
        return record
    }

    /// Persists an already-built record after policy + hash checks (append-only insert).
    ///
    /// Secondary third-party confirmation is UI-only and is **not** re-checked here.
    /// Record policy still requires non-empty `subjectDisplayName` / attestor / statements
    /// so import paths cannot store empty third_party names.
    ///
    /// - Parameter skipPolicyCheck: When `true`, only hash integrity is checked (test fixtures
    ///   that intentionally stress store edges). Product callers must leave this `false`.
    @discardableResult
    public func persist(
        _ record: ConsentRecord,
        skipPolicyCheck: Bool = false
    ) throws -> ConsentRecord {
        if !skipPolicyCheck {
            try ConsentValidator.validateRecordPolicy(record)
        }
        let ready: ConsentRecord
        if record.contentHash.isEmpty {
            ready = try record.withComputedContentHash()
        } else {
            ready = record
            guard try ready.verifyContentHash() else {
                throw BAMError(
                    code: .consentTamper,
                    message: "contentHash does not match canonical serialization"
                )
            }
        }
        try store.save(ready)
        return ready
    }

    // MARK: - Read

    /// Verified fetch (default product path). Returns `nil` when missing; throws on tamper.
    public func fetch(id: String) throws -> ConsentRecord? {
        guard try store.fetchIndex(id: id) != nil else { return nil }
        return try store.fetchAndVerify(id: id)
    }

    /// Decodes without hash verification. Prefer `fetch` / `fetchAndVerify` for binding.
    public func fetchUnverified(id: String) throws -> ConsentRecord? {
        try store.fetchUnverified(id: id)
    }

    public func fetchAndVerify(id: String) throws -> ConsentRecord {
        try store.fetchAndVerify(id: id)
    }

    public func listAll() throws -> [ConsentIndexRecord] {
        try store.listAll()
    }

    /// True when a stored record exists, verifies, and matches `expectedHash`.
    /// Throws on missing/tampered rows; returns `false` when verify succeeds but hash differs.
    public func isValidBinding(id: String, expectedHash: String) throws -> Bool {
        let record = try store.fetchAndVerify(id: id)
        return ConsentRecord.normalizeHash(record.contentHash)
            == ConsentRecord.normalizeHash(expectedHash)
    }

    // MARK: - Time

    /// ISO-8601 UTC timestamp without fractional seconds (`2026-07-18T12:00:00Z`).
    public static func currentTimestamp(date: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        // Strip fractional seconds if present for stable hash-friendly stamps.
        let full = formatter.string(from: date)
        if let dot = full.firstIndex(of: ".") {
            // e.g. 2026-07-18T12:00:00.123Z → 2026-07-18T12:00:00Z
            let prefix = full[..<dot]
            return String(prefix) + "Z"
        }
        return full
    }
}
