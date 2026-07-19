import XCTest
import BAMModels

final class ConsentHashTests: XCTestCase {
    func testGoldenConsentContentHash() throws {
        let record = DomainFixtures.goldenConsentRecord
        let computed = try record.computeContentHash()
        XCTAssertEqual(
            computed,
            DomainFixtures.goldenConsentContentHash,
            "Canonical contentHash drifted — encoder or fixture changed"
        )
        XCTAssertTrue(try record.verifyContentHash())
    }

    func testGoldenCanonicalJSONBytes() throws {
        let record = DomainFixtures.goldenConsentRecord
        let data = try record.canonicalJSONBytes()
        let json = String(data: data, encoding: .utf8)!
        // No insignificant whitespace, no trailing newline.
        XCTAssertFalse(json.contains(": "))
        XCTAssertFalse(json.contains(", "))
        XCTAssertFalse(json.hasSuffix("\n"))
        // Keys sorted; appVersion first among hash fields.
        XCTAssertTrue(json.hasPrefix("{\"appVersion\":"))
        // jurisdictionNote omitted when nil.
        XCTAssertFalse(json.contains("jurisdictionNote"))
        // statements order preserved.
        XCTAssertTrue(json.contains(
            "\"statements\":[\"I have the right to use this voice for the selected scope.\",\"I will not use this to commit fraud or illegal impersonation.\"]"
        ))
    }

    func testWithComputedContentHash() throws {
        var blank = DomainFixtures.goldenConsentRecord
        blank.contentHash = ""
        let filled = try blank.withComputedContentHash()
        XCTAssertEqual(filled.contentHash, DomainFixtures.goldenConsentContentHash)
    }

    func testNormalizeHashPrefix() {
        let hex = DomainFixtures.goldenConsentContentHash
        XCTAssertEqual(ConsentRecord.normalizeHash("sha256:\(hex)"), hex)
        XCTAssertEqual(ConsentRecord.normalizeHash("SHA256:\(hex.uppercased())"), hex)
        XCTAssertEqual(ConsentRecord.normalizeHash(hex.uppercased()), hex)
    }

    func testJurisdictionNoteIncludedWhenPresent() throws {
        var record = DomainFixtures.goldenConsentRecord
        record.jurisdictionNote = "US-CA"
        record.contentHash = try record.computeContentHash()
        let json = String(data: try record.canonicalJSONBytes(), encoding: .utf8)!
        XCTAssertTrue(json.contains("\"jurisdictionNote\":\"US-CA\""))
        // Hash must differ from golden when note present.
        XCTAssertNotEqual(try record.computeContentHash(), DomainFixtures.goldenConsentContentHash)
    }

    func testUnknownKeysRejected() {
        XCTAssertThrowsError(
            try ConsentCanonicalJSON.serialize(["id": "x", "evil": 1])
        ) { error in
            guard case ConsentHashError.unknownKeys(let keys) = error else {
                return XCTFail("expected unknownKeys, got \(error)")
            }
            XCTAssertEqual(keys, ["evil"])
        }
    }

    func testCodableRoundTrip() throws {
        let original = DomainFixtures.goldenConsentRecord
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ConsentRecord.self, from: data)
        XCTAssertEqual(decoded, original)
        // Optional omit: nil jurisdictionNote not present as null in compact encoding
        // when using our encode(to:) — verify recompute still matches.
        XCTAssertEqual(try decoded.computeContentHash(), DomainFixtures.goldenConsentContentHash)
    }

    func testSubjectTypeAndScopeRawValues() {
        XCTAssertEqual(ConsentSubjectType.self_.rawValue, "self")
        XCTAssertEqual(ConsentSubjectType.thirdParty.rawValue, "third_party")
        XCTAssertEqual(ConsentSubjectType.syntheticOrPublicDomain.rawValue, "synthetic_or_public_domain")
        XCTAssertEqual(ConsentScope.personalUse.rawValue, "personal_use")
        XCTAssertEqual(ConsentScope.shareableExport.rawValue, "shareable_export")
        XCTAssertEqual(ConsentScope.researchOnly.rawValue, "research_only")
    }
}
