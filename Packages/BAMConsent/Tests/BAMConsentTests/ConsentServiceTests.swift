import XCTest
import BAMCore
import BAMModels
import BAMPersistence
@testable import BAMConsent

final class ConsentServiceTests: XCTestCase {
    // MARK: - Golden hash vector (shared with BAMModels)

    func testPersistGoldenFixtureMatchesDomainHash() throws {
        let service = try ConsentService.makeInMemory(writeJSONFiles: false)
        let saved = try service.persist(DomainFixtures.goldenConsentRecord)

        XCTAssertEqual(saved.contentHash, DomainFixtures.goldenConsentContentHash)
        XCTAssertEqual(try saved.computeContentHash(), DomainFixtures.goldenConsentContentHash)
        XCTAssertTrue(try saved.verifyContentHash())

        let loaded = try service.fetchAndVerify(id: DomainFixtures.consentRecordId)
        XCTAssertEqual(loaded, DomainFixtures.goldenConsentRecord)
        XCTAssertEqual(loaded.contentHash, DomainFixtures.goldenConsentContentHash)
    }

    func testCreateFromDraftReproducesGoldenHashWithFixedClock() throws {
        let service = try ConsentService.makeInMemory(
            writeJSONFiles: false,
            appVersion: DomainFixtures.goldenAppVersion,
            idGenerator: { DomainFixtures.consentRecordId },
            nowISO8601: { DomainFixtures.goldenCreatedAt }
        )

        var draft = ConsentDraft(
            subjectType: .self_,
            subjectDisplayName: "Test Subject",
            attestorUserLabel: "test-user",
            scope: .personalUse,
            statementTexts: ConsentStatements.defaults
        )
        draft.acceptedStatements = draft.acceptedStatements.map { _ in true }

        let record = try service.create(from: draft)
        XCTAssertEqual(record.id, DomainFixtures.consentRecordId)
        XCTAssertEqual(record.contentHash, DomainFixtures.goldenConsentContentHash)
        XCTAssertEqual(record, DomainFixtures.goldenConsentRecord)
    }

    func testCreateRejectsThirdPartyWithoutSecondaryConfirm() throws {
        let service = try ConsentService.makeInMemory(writeJSONFiles: false)
        var draft = ConsentDraft(
            subjectType: .thirdParty,
            subjectDisplayName: "Alice",
            attestorUserLabel: "bob",
            thirdPartySecondaryConfirmed: false
        )
        draft.acceptedStatements = draft.acceptedStatements.map { _ in true }

        XCTAssertThrowsError(try service.create(from: draft)) { error in
            XCTAssertEqual(error as? ConsentValidationError, .thirdPartySecondaryConfirmRequired)
        }
        XCTAssertTrue(try service.listAll().isEmpty)
    }

    func testCreateRejectsThirdPartyWithoutSubjectName() throws {
        let service = try ConsentService.makeInMemory(writeJSONFiles: false)
        var draft = ConsentDraft(
            subjectType: .thirdParty,
            subjectDisplayName: "   ",
            attestorUserLabel: "bob",
            thirdPartySecondaryConfirmed: true
        )
        draft.acceptedStatements = draft.acceptedStatements.map { _ in true }

        XCTAssertThrowsError(try service.create(from: draft)) { error in
            XCTAssertEqual(error as? ConsentValidationError, .missingSubjectDisplayName)
        }
    }

    func testCreateThirdPartySucceedsWithTypedFields() throws {
        let service = try ConsentService.makeInMemory(writeJSONFiles: false)
        var draft = ConsentDraft(
            subjectType: .thirdParty,
            subjectDisplayName: "Alice Example",
            attestorUserLabel: "bob",
            scope: .researchOnly,
            thirdPartySecondaryConfirmed: true
        )
        draft.acceptedStatements = draft.acceptedStatements.map { _ in true }

        let record = try service.create(from: draft)
        XCTAssertEqual(record.subjectType, .thirdParty)
        XCTAssertEqual(record.subjectDisplayName, "Alice Example")
        XCTAssertEqual(record.scope, .researchOnly)
        XCTAssertFalse(record.contentHash.isEmpty)
        XCTAssertTrue(try record.verifyContentHash())
        XCTAssertTrue(
            try service.isValidBinding(id: record.id, expectedHash: "sha256:\(record.contentHash)")
        )
    }

    func testPersistRejectsTamperedHash() throws {
        let service = try ConsentService.makeInMemory(writeJSONFiles: false)
        var bad = DomainFixtures.goldenConsentRecord
        bad.contentHash = "deadbeef"

        XCTAssertThrowsError(try service.persist(bad)) { error in
            let bam = error as? BAMError
            XCTAssertEqual(bam?.code, .consentTamper)
        }
    }

    func testFetchAndVerifyDetectsJSONTamper() throws {
        let db = try LibraryDatabase.openInMemory()
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("bam-consent-tamper-\(UUID().uuidString)", isDirectory: true)
        let store = ConsentStore(database: db, consentDirectory: tmp, writeJSONFiles: false)
        let service = ConsentService(store: store)

        _ = try service.persist(DomainFixtures.goldenConsentRecord)

        // Corrupt stored JSON while leaving hash column unchanged.
        try db.dbQueue.write { conn in
            try conn.execute(
                sql: """
                    UPDATE consent_records
                    SET json = ?
                    WHERE id = ?
                    """,
                arguments: [
                    "{\"id\":\"\(DomainFixtures.consentRecordId)\",\"schemaVersion\":1,\"createdAt\":\"\(DomainFixtures.goldenCreatedAt)\",\"subjectType\":\"self\",\"subjectDisplayName\":\"TAMPERED\",\"attestorUserLabel\":\"test-user\",\"scope\":\"personal_use\",\"statements\":[\"I have the right to use this voice for the selected scope.\",\"I will not use this to commit fraud or illegal impersonation.\"],\"attestedAt\":\"\(DomainFixtures.goldenCreatedAt)\",\"appVersion\":\"0.1.0\",\"retention\":\"until_user_deletes\",\"contentHash\":\"\(DomainFixtures.goldenConsentContentHash)\"}",
                    DomainFixtures.consentRecordId,
                ]
            )
        }

        XCTAssertThrowsError(try service.fetchAndVerify(id: DomainFixtures.consentRecordId)) { error in
            let bam = error as? BAMError
            XCTAssertEqual(bam?.code, .consentTamper)
        }
    }

    func testWritesOptionalJSONUnderConsentDirectory() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("bam-consent-json-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let service = try ConsentService.makeInMemory(
            writeJSONFiles: true,
            consentDirectory: tmp,
            appVersion: DomainFixtures.goldenAppVersion,
            idGenerator: { DomainFixtures.consentRecordId },
            nowISO8601: { DomainFixtures.goldenCreatedAt }
        )

        var draft = ConsentDraft(
            subjectType: .self_,
            subjectDisplayName: "Test Subject",
            attestorUserLabel: "test-user"
        )
        draft.acceptedStatements = draft.acceptedStatements.map { _ in true }
        _ = try service.create(from: draft)

        let fileURL = tmp.appendingPathComponent("\(DomainFixtures.consentRecordId).json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

        let data = try Data(contentsOf: fileURL)
        let decoded = try JSONDecoder().decode(ConsentRecord.self, from: data)
        XCTAssertEqual(decoded.contentHash, DomainFixtures.goldenConsentContentHash)
        XCTAssertTrue(try decoded.verifyContentHash())
    }

    func testListAllReturnsPersistedRows() throws {
        let service = try ConsentService.makeInMemory(writeJSONFiles: false)
        _ = try service.persist(DomainFixtures.goldenConsentRecord)
        let rows = try service.listAll()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].id, DomainFixtures.consentRecordId)
        XCTAssertEqual(rows[0].contentHash, DomainFixtures.goldenConsentContentHash)
    }

    func testCurrentTimestampStripsFractionalSeconds() {
        // Fixed date: 2026-07-18 12:00:00 UTC
        var components = DateComponents()
        components.year = 2026
        components.month = 7
        components.day = 18
        components.hour = 12
        components.minute = 0
        components.second = 0
        components.timeZone = TimeZone(secondsFromGMT: 0)
        let date = Calendar(identifier: .gregorian).date(from: components)!
        let stamp = ConsentService.currentTimestamp(date: date)
        XCTAssertEqual(stamp, "2026-07-18T12:00:00Z")
    }
}
