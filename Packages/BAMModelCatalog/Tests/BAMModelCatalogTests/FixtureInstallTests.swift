import XCTest
import BAMCore
import BAMModels
@testable import BAMModelCatalog

/// Offline fixture install path only — **no network**.
final class FixtureInstallTests: XCTestCase {
    private var tempRoot: URL!
    private var modelsBase: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("bam-fixture-install-\(UUID().uuidString)", isDirectory: true)
        modelsBase = tempRoot.appendingPathComponent("models/base", isDirectory: true)
        try FileManager.default.createDirectory(at: modelsBase, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
    }

    func testBundledFixtureLayoutIsValid() {
        let url = ModelInstallService.bundledFixtureURL()
        XCTAssertTrue(
            ModelInstallService.layoutLooksValid(at: url),
            "Bundled fixture missing at \(url.path)"
        )
        for name in FixtureModel.requiredFiles {
            let file = url.appendingPathComponent(name)
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: file.path),
                "Missing \(name) in bundled fixture"
            )
        }
    }

    func testWorkersFixtureMatchesBundledWhenPresent() throws {
        guard let workers = ModelInstallService.workersFixtureURL() else {
            // When tests run outside a full checkout this is optional.
            throw XCTSkip("Workers/fixtures/models/tiny-qwen-mlx not found from test path")
        }
        XCTAssertTrue(ModelInstallService.layoutLooksValid(at: workers))

        let bundled = ModelInstallService.bundledFixtureURL()
        for name in FixtureModel.requiredFiles {
            let w = try Data(contentsOf: workers.appendingPathComponent(name))
            let b = try Data(contentsOf: bundled.appendingPathComponent(name))
            XCTAssertEqual(w, b, "Workers fixture \(name) must match bundled resource")
        }
    }

    func testInstallFixtureCopiesIntoModelsBase() throws {
        let service = ModelInstallService(
            modelsBaseURL: modelsBase,
            fixtureSourceURL: ModelInstallService.bundledFixtureURL(),
            hfHubDownloadEnabled: false
        )

        XCTAssertFalse(service.isFixtureInstalled())

        let result = try service.installFixture()
        XCTAssertFalse(result.alreadyPresent)
        XCTAssertTrue(service.isFixtureInstalled())
        XCTAssertEqual(result.modelRecord.sourceKey, FixtureModel.sourceKey)
        XCTAssertEqual(result.modelRecord.id, FixtureModel.stableModelID)
        XCTAssertEqual(result.modelRecord.kind, .base)
        XCTAssertEqual(result.modelRecord.license, FixtureModel.license)
        XCTAssertTrue(result.modelRecord.localPath.hasPrefix(modelsBase.path))
        XCTAssertTrue(result.modelRecord.localPath.hasSuffix(FixtureModel.installDirectoryName))

        // Required files on disk.
        let dest = service.fixtureInstallDirectory
        XCTAssertTrue(ModelInstallService.layoutLooksValid(at: dest))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: dest.appendingPathComponent("config.json").path
            )
        )

        // Scanner discovers the install.
        let scanner = LocalModelScanner(modelsBaseURL: modelsBase)
        let hits = try scanner.scan()
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].directoryName, FixtureModel.installDirectoryName)
        XCTAssertTrue(hits[0].hasConfigJSON)
    }

    func testInstallFixtureIdempotentOverwrite() throws {
        let service = ModelInstallService(
            modelsBaseURL: modelsBase,
            fixtureSourceURL: ModelInstallService.bundledFixtureURL()
        )
        _ = try service.installFixture()
        let second = try service.installFixture(overwrite: true)
        XCTAssertTrue(second.alreadyPresent)
        XCTAssertTrue(service.isFixtureInstalled())

        let noOverwrite = try service.installFixture(overwrite: false)
        XCTAssertTrue(noOverwrite.alreadyPresent)
        XCTAssertEqual(noOverwrite.modelRecord.sourceKey, FixtureModel.sourceKey)
    }

    func testInstallFixtureMissingSourceThrows() {
        let missing = tempRoot.appendingPathComponent("no-such-fixture", isDirectory: true)
        let service = ModelInstallService(
            modelsBaseURL: modelsBase,
            fixtureSourceURL: missing
        )
        XCTAssertThrowsError(try service.installFixture()) { error in
            let bam = error as? BAMError
            XCTAssertEqual(bam?.code, .modelNotFound)
        }
    }

    func testDownloadFromHubDisabledByDefault() async {
        let service = ModelInstallService(
            modelsBaseURL: modelsBase,
            fixtureSourceURL: ModelInstallService.bundledFixtureURL(),
            hfHubDownloadEnabled: false
        )
        do {
            _ = try await service.downloadFromHub(sourceKey: "mlx-community/Qwen2.5-0.5B-Instruct-4bit")
            XCTFail("Expected capability unsupported when HF flag is off")
        } catch let error as BAMError {
            XCTAssertEqual(error.code, .capabilityUnsupported)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testDownloadFromHubEnabledUsesNoopClient() async {
        let service = ModelInstallService(
            modelsBaseURL: modelsBase,
            fixtureSourceURL: ModelInstallService.bundledFixtureURL(),
            hfHubDownloadEnabled: true,
            tokenStore: InMemoryHFTokenStore(token: "hf_test"),
            hubClient: NoopHFHubClient()
        )
        do {
            _ = try await service.downloadFromHub(sourceKey: "mlx-community/Qwen2.5-0.5B-Instruct-4bit")
            XCTFail("Noop client must not succeed")
        } catch let error as BAMError {
            XCTAssertEqual(error.code, .capabilityUnsupported)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testInMemoryTokenStoreRoundTrip() throws {
        let store = InMemoryHFTokenStore()
        XCTAssertNil(try store.loadToken())
        try store.saveToken("  hf_abc  ")
        XCTAssertEqual(try store.loadToken(), "hf_abc")
        try store.saveToken(nil)
        XCTAssertNil(try store.loadToken())
        try store.saveToken("")
        XCTAssertNil(try store.loadToken())
    }

    func testCatalogIncludesFixtureEntry() throws {
        let catalog = try ModelCatalog.loadBundled()
        let fixture = try XCTUnwrap(catalog.fixtureEntry)
        XCTAssertTrue(fixture.isFixture)
        XCTAssertEqual(fixture.sourceKey, FixtureModel.sourceKey)
        XCTAssertEqual(fixture.license, "Apache-2.0")
        XCTAssertEqual(fixture.chatTemplateId, "qwen2.5-instruct")
        XCTAssertEqual(catalog.nonFixtureEntries.count, 3)
        XCTAssertEqual(catalog.entries.count, 4)
    }

    func testFixtureStableIDIsUUIDV4() {
        XCTAssertTrue(BAMID.isUUIDV4(FixtureModel.stableModelID))
    }
}
