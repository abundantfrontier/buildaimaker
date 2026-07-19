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

    func testDomainErrorCodesPresent() {
        XCTAssertEqual(BAMErrorCode.personaUnresolved.rawValue, "BAM_PERSONA_UNRESOLVED")
        XCTAssertEqual(BAMErrorCode.tccMicDenied.rawValue, "BAM_TCC_MIC_DENIED")
        XCTAssertEqual(BAMErrorCode.capabilityUnsupported.rawValue, "BAM_CAPABILITY_UNSUPPORTED")
        XCTAssertEqual(BAMErrorCode.licenseBlock.rawValue, "BAM_LICENSE_BLOCK")
        XCTAssertEqual(BAMErrorCode.migrationFailed.rawValue, "BAM_MIGRATION_FAILED")
        XCTAssertEqual(BAMErrorCode.schemaInvalid.rawValue, "BAM_SCHEMA_INVALID")
        XCTAssertEqual(BAMErrorCode.downloadFailed.rawValue, "BAM_DOWNLOAD_FAILED")
        XCTAssertTrue(BAMErrorCode.allCases.count >= 20)
    }

    func testHFHubDownloadDefaultsOff() {
        XCTAssertFalse(FeatureFlags.default.hfHubDownload)
        XCTAssertFalse(FeatureFlags.default.isEnabled(.hfHubDownload))
        XCTAssertEqual(FeatureFlags.Key.hfHubDownload.rawValue, "ff.hfHubDownload")
    }
}
