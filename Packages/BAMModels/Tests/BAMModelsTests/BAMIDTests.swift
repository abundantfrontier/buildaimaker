import XCTest
import BAMModels

final class BAMIDTests: XCTestCase {
    func testGenerateIsValidUUIDV4Shape() {
        let id = BAMID.generate()
        XCTAssertTrue(BAMID.isValid(id))
        XCTAssertEqual(id, id.lowercased())
        // UUID string form: 8-4-4-4-12
        let parts = id.split(separator: "-")
        XCTAssertEqual(parts.count, 5)
        // Version nibble of UUID v4 is '4' at the start of the third group.
        XCTAssertTrue(parts[2].hasPrefix("4"))
    }

    func testNormalizeAndInvalid() {
        XCTAssertEqual(
            BAMID.normalize("AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"),
            "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        )
        XCTAssertNil(BAMID.normalize("not-a-uuid"))
        XCTAssertFalse(BAMID.isValid(""))
    }
}
