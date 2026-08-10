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

    /// Failed / stub HF download must not wipe a prior good install at the same modelID.
    func testDownloadFromHubFailurePreservesExistingInstall() async throws {
        let modelID = "b0000000-0000-4000-8000-0000000000aa"
        let dest = modelsBase.appendingPathComponent(modelID, isDirectory: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let marker = dest.appendingPathComponent("marker.txt", isDirectory: false)
        try Data("keep-me".utf8).write(to: marker)

        let service = ModelInstallService(
            modelsBaseURL: modelsBase,
            fixtureSourceURL: ModelInstallService.bundledFixtureURL(),
            hfHubDownloadEnabled: true,
            tokenStore: InMemoryHFTokenStore(token: "hf_test"),
            hubClient: NoopHFHubClient()
        )

        do {
            _ = try await service.downloadFromHub(
                sourceKey: "mlx-community/Qwen2.5-0.5B-Instruct-4bit",
                modelID: modelID
            )
            XCTFail("Expected capability unsupported from Noop client")
        } catch let error as BAMError {
            XCTAssertEqual(error.code, .capabilityUnsupported)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: marker.path),
            "Prior install must survive failed downloadFromHub"
        )
        let contents = try String(contentsOf: marker, encoding: .utf8)
        XCTAssertEqual(contents, "keep-me")

        // Staging dirs must not linger under models/base.
        let children = try FileManager.default.contentsOfDirectory(
            at: modelsBase,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        XCTAssertEqual(children.map(\.lastPathComponent).sorted(), [modelID])
    }

    func testDownloadFromHubRejectsInvalidModelID() async {
        let service = ModelInstallService(
            modelsBaseURL: modelsBase,
            fixtureSourceURL: ModelInstallService.bundledFixtureURL(),
            hfHubDownloadEnabled: true,
            hubClient: NoopHFHubClient()
        )
        do {
            _ = try await service.downloadFromHub(
                sourceKey: "mlx-community/Qwen2.5-0.5B-Instruct-4bit",
                modelID: "../escape"
            )
            XCTFail("Expected path escape")
        } catch let error as BAMError {
            XCTAssertEqual(error.code, .pathEscape)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    /// Incomplete dest + overwrite:false reinstalls rather than returning a bogus success.
    func testInstallFixtureOverwriteFalseReinstallsIncompleteDest() throws {
        let incomplete = modelsBase.appendingPathComponent(
            FixtureModel.installDirectoryName,
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: incomplete, withIntermediateDirectories: true)
        // Empty dir — fails layoutLooksValid
        XCTAssertFalse(ModelInstallService.layoutLooksValid(at: incomplete))

        let service = ModelInstallService(
            modelsBaseURL: modelsBase,
            fixtureSourceURL: ModelInstallService.bundledFixtureURL()
        )
        XCTAssertFalse(service.isFixtureInstalled())

        let result = try service.installFixture(overwrite: false)
        XCTAssertFalse(result.alreadyPresent, "Incomplete dest should not report alreadyPresent")
        XCTAssertTrue(service.isFixtureInstalled())
        XCTAssertTrue(ModelInstallService.layoutLooksValid(at: service.fixtureInstallDirectory))
    }

    /// Bundled fixture must stay toy-sized (guards against accidental multi-GB weight drops).
    func testBundledFixtureStaysUnderOneMebibyte() throws {
        let root = ModelInstallService.bundledFixtureURL()
        let maxBytes = 1 * 1024 * 1024 // 1 MiB
        var total: Int64 = 0
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            XCTFail("Could not enumerate bundled fixture at \(root.path)")
            return
        }
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        XCTAssertLessThan(
            total,
            Int64(maxBytes),
            "Bundled fixture is \(total) bytes; must stay well under 1 MiB (no real MLX weights)"
        )
        // Sanity: also keep model.safetensors tiny (placeholder only).
        let weights = root.appendingPathComponent("model.safetensors")
        let weightSize = try weights.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        XCTAssertLessThan(weightSize, 4096, "model.safetensors must remain a tiny placeholder")
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

    // MARK: - Multi-model catalog install

    func testInstallDirectoryNameSlugifiesSourceKey() {
        XCTAssertEqual(
            ModelInstallService.installDirectoryName(forSourceKey: "mlx-community/Qwen2.5-0.5B-Instruct-4bit"),
            "mlx-community--Qwen2.5-0.5B-Instruct-4bit"
        )
        XCTAssertEqual(
            ModelInstallService.installDirectoryName(forSourceKey: FixtureModel.sourceKey),
            "buildaimaker--tiny-qwen-mlx-fixture"
        )
    }

    func testInstallMultipleCatalogEntriesCoexist() throws {
        let catalog = try ModelCatalog.loadBundled()
        let service = ModelInstallService(
            modelsBaseURL: modelsBase,
            fixtureSourceURL: ModelInstallService.bundledFixtureURL()
        )

        var installedPaths: [String] = []
        for entry in catalog.entries {
            let result = try service.installCatalogEntry(entry, overwrite: true)
            XCTAssertTrue(service.isInstalled(entry), "Expected \(entry.sourceKey) installed")
            XCTAssertEqual(result.modelRecord.sourceKey, entry.sourceKey)
            XCTAssertEqual(result.modelRecord.name, entry.name)
            installedPaths.append(result.modelRecord.localPath)
        }

        // Distinct destinations for each catalog row.
        XCTAssertEqual(Set(installedPaths).count, catalog.entries.count)

        let hits = try LocalModelScanner(modelsBaseURL: modelsBase).scan()
        XCTAssertEqual(hits.count, catalog.entries.count)

        // Metadata round-trip for a non-fixture dogfood stub.
        let nonFixture = try XCTUnwrap(catalog.nonFixtureEntries.first)
        let dest = service.installDirectory(for: nonFixture)
        let meta = try XCTUnwrap(ModelInstallService.installMetadata(at: dest))
        XCTAssertEqual(meta.sourceKey, nonFixture.sourceKey)
        XCTAssertEqual(meta.name, nonFixture.name)
        XCTAssertTrue(meta.dogfoodStub)

        // Fixture still valid under its stable directory.
        XCTAssertTrue(service.isFixtureInstalled())
        let fixtureMeta = ModelInstallService.installMetadata(at: service.fixtureInstallDirectory)
        XCTAssertEqual(fixtureMeta?.sourceKey, FixtureModel.sourceKey)
    }

    func testInstallCatalogEntryIdempotent() throws {
        let catalog = try ModelCatalog.loadBundled()
        let entry = try XCTUnwrap(catalog.nonFixtureEntries.first)
        let service = ModelInstallService(
            modelsBaseURL: modelsBase,
            fixtureSourceURL: ModelInstallService.bundledFixtureURL()
        )
        _ = try service.installCatalogEntry(entry)
        let second = try service.installCatalogEntry(entry, overwrite: false)
        XCTAssertTrue(second.alreadyPresent)
        XCTAssertTrue(service.isInstalled(entry))
    }
}
