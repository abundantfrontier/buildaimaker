import XCTest
import BAMCore

final class FeatureFlagsTests: XCTestCase {
    func testDefaultFlagsAreAllOff() {
        let flags = FeatureFlags.default
        for key in FeatureFlags.Key.allCases {
            XCTAssertFalse(flags.isEnabled(key), "\(key.rawValue) should default off")
        }
    }

    func testLibraryRootUsesApplicationSupport() {
        let root = LibraryPaths.libraryRoot
        XCTAssertTrue(root.path.contains("Application Support"))
        XCTAssertTrue(root.path.hasSuffix("BuildAIMaker") || root.lastPathComponent == "BuildAIMaker")
    }

    func testProtocolVersionsPinned() {
        XCTAssertEqual(ProtocolVersions.runnerProtocolVersion, 1)
        XCTAssertEqual(ProtocolVersions.personaPackFormat, 1)
        XCTAssertEqual(ProtocolVersions.librarySchemaVersion, 1)
    }

    func testPathComponentValidation() {
        XCTAssertEqual(LibraryPaths.validatedPathComponent("abc-123"), "abc-123")
        XCTAssertNil(LibraryPaths.validatedPathComponent(""))
        XCTAssertNil(LibraryPaths.validatedPathComponent(".."))
        XCTAssertNil(LibraryPaths.validatedPathComponent("a/b"))
        XCTAssertNil(LibraryPaths.validatedPathComponent("a\\b"))
        XCTAssertEqual(LibraryPaths.sanitizedPathComponent("../escape"), "_invalid")
        XCTAssertEqual(
            LibraryPaths.datasetDirectory(id: "ok-id").lastPathComponent,
            "ok-id"
        )
        XCTAssertEqual(
            LibraryPaths.datasetDirectory(id: "../x").lastPathComponent,
            "_invalid"
        )
    }
}
