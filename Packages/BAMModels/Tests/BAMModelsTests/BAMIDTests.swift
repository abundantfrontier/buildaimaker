import XCTest
import BAMModels

final class BAMIDTests: XCTestCase {
    func testGenerateIsValidUUIDV4Shape() {
        let id = BAMID.generate()
        XCTAssertTrue(BAMID.isValid(id))
        XCTAssertTrue(BAMID.isUUIDV4(id))
        XCTAssertEqual(id, id.lowercased())
        // UUID string form: 8-4-4-4-12
        let parts = id.split(separator: "-")
        XCTAssertEqual(parts.count, 5)
        // Version nibble of UUID v4 is '4' at the start of the third group.
        XCTAssertTrue(parts[2].hasPrefix("4"))
    }

    func testNormalizeAcceptsV4Only() {
        // Valid v4 (version=4, variant in 8..b).
        XCTAssertEqual(
            BAMID.normalize("aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"),
            "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
        )
        // UUID v1-shaped (version nibble 1) must be rejected for K19.
        XCTAssertNil(BAMID.normalize("aaaaaaaa-bbbb-1ccc-8ddd-eeeeeeeeeeee"))
        XCTAssertFalse(BAMID.isValid("aaaaaaaa-bbbb-1ccc-8ddd-eeeeeeeeeeee"))
        XCTAssertNil(BAMID.normalize("not-a-uuid"))
        XCTAssertFalse(BAMID.isValid(""))
    }
}
