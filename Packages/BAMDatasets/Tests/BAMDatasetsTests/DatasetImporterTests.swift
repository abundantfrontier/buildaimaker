import XCTest
import BAMCore
import BAMModels
import BAMDatasets
import BAMPersistence

final class DatasetImporterTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("BAMDatasetsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
    }

    func testCopyImportWritesUnderLibraryRoot() throws {
        let service = try DatasetLibraryService.openInMemoryForTesting(libraryRoot: tempRoot)
        let source = try copyFixture("valid_openai_messages.jsonl")

        let result = try service.importDataset(
            sourceURL: source,
            name: "OpenAI sample",
            importMode: .copy
        )

        XCTAssertEqual(result.dataset.name, "OpenAI sample")
        XCTAssertEqual(result.dataset.modality, .text)
        XCTAssertEqual(result.dataset.importMode, .copy)
        XCTAssertEqual(result.dataset.status, .ready)
        XCTAssertEqual(result.version.rowCount, 2)
        XCTAssertNotNil(result.version.contentHash)
        XCTAssertFalse(result.version.contentHash!.isEmpty)
        XCTAssertTrue(result.sourceFilePath.hasSuffix("source.jsonl"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.sourceFilePath))
        XCTAssertTrue(result.dataset.rootPath.contains(tempRoot.path))
        XCTAssertTrue(BAMID.isValid(result.dataset.id))
        XCTAssertTrue(BAMID.isValid(result.version.id))

        let listed = try service.listDatasets()
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed[0].id, result.dataset.id)

        let meta = DatasetVersionMeta.parse(result.version.metaJSON)
        XCTAssertEqual(meta?.format, DetectedChatFormat.openaiMessages.rawValue)
    }

    func testReferenceImportKeepsSourcePath() throws {
        let service = try DatasetLibraryService.openInMemoryForTesting(libraryRoot: tempRoot)
        let source = try copyFixture("valid_sharegpt.jsonl")

        let result = try service.importDataset(
            sourceURL: source,
            name: "ShareGPT sample",
            importMode: .reference
        )

        XCTAssertEqual(result.dataset.importMode, .reference)
        XCTAssertEqual(result.dataset.rootPath, source.path)
        XCTAssertEqual(result.sourceFilePath, source.path)
        XCTAssertEqual(result.validation.format, .shareGPT)
        XCTAssertEqual(result.version.rowCount, 2)
    }

    func testReferenceImportPersistsBookmarkWhenAvailable() throws {
        let service = try DatasetLibraryService.openInMemoryForTesting(libraryRoot: tempRoot)
        let source = try copyFixture("valid_openai_messages.jsonl")
        let result = try service.importDataset(
            sourceURL: source,
            name: "Ref bookmark",
            importMode: .reference
        )

        // Bookmark creation is best-effort; when present it must round-trip.
        let bookmark = try service.store.bookmarkData(
            entityType: "dataset",
            entityId: result.dataset.id
        )
        if let bookmark {
            XCTAssertFalse(bookmark.isEmpty)
            let access = try service.resolveSourceAccess(for: result.dataset)
            defer { access.stop() }
            XCTAssertTrue(FileManager.default.fileExists(atPath: access.url.path))
        } else {
            // Outside sandbox bookmark may fail; resolve still falls back to rootPath.
            let access = try service.resolveSourceAccess(for: result.dataset)
            defer { access.stop() }
            XCTAssertEqual(access.url.path, source.path)
        }
    }

    func testImportRejectsInvalidJSONL() throws {
        let service = try DatasetLibraryService.openInMemoryForTesting(libraryRoot: tempRoot)
        let source = try copyFixture("invalid_bad_role.jsonl")

        XCTAssertThrowsError(
            try service.importDataset(sourceURL: source, name: "Bad", importMode: .copy)
        ) { error in
            let bam = error as? BAMError
            XCTAssertEqual(bam?.code, .datasetInvalid)
            XCTAssertTrue(bam?.message?.contains("unknown role") == true)
        }

        XCTAssertTrue(try service.listDatasets().isEmpty)
    }

    func testImportRejectsEmptyName() throws {
        let service = try DatasetLibraryService.openInMemoryForTesting(libraryRoot: tempRoot)
        let source = try copyFixture("valid_openai_messages.jsonl")

        XCTAssertThrowsError(
            try service.importDataset(sourceURL: source, name: "   ", importMode: .copy)
        ) { error in
            XCTAssertEqual((error as? BAMError)?.code, .datasetInvalid)
        }
    }

    func testImportRejectsDirectorySource() throws {
        let service = try DatasetLibraryService.openInMemoryForTesting(libraryRoot: tempRoot)
        let dir = tempRoot.appendingPathComponent("not-a-file", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        XCTAssertThrowsError(
            try service.importDataset(sourceURL: dir, name: "Dir", importMode: .copy)
        ) { error in
            let bam = error as? BAMError
            XCTAssertEqual(bam?.code, .datasetInvalid)
            XCTAssertTrue(bam?.message?.lowercased().contains("directory") == true)
        }
        XCTAssertTrue(try service.listDatasets().isEmpty)
        // No orphan dataset dirs under library root.
        let datasetsDir = tempRoot.appendingPathComponent("datasets", isDirectory: true)
        let children = (try? FileManager.default.contentsOfDirectory(
            at: datasetsDir,
            includingPropertiesForKeys: nil
        )) ?? []
        XCTAssertTrue(children.isEmpty)
    }

    func testPreviewAfterCopyImport() throws {
        let service = try DatasetLibraryService.openInMemoryForTesting(libraryRoot: tempRoot)
        let source = try copyFixture("valid_openai_messages.jsonl")
        let imported = try service.importDataset(
            sourceURL: source,
            name: "Preview me",
            importMode: .copy
        )

        let preview = try service.preview(datasetId: imported.dataset.id, maxExamples: 5)
        XCTAssertEqual(preview.exampleCount, 2)
        XCTAssertGreaterThanOrEqual(preview.messageCount, 5)
        XCTAssertEqual(preview.examples[0].messages[0].role, "system")

        let messages = try service.previewMessages(datasetId: imported.dataset.id, maxMessages: 3)
        XCTAssertEqual(messages.count, 3)
        XCTAssertEqual(messages[0].content, "You are a helpful assistant.")
    }

    func testDeleteCopyRemovesFiles() throws {
        let service = try DatasetLibraryService.openInMemoryForTesting(libraryRoot: tempRoot)
        let source = try copyFixture("valid_openai_messages.jsonl")
        let imported = try service.importDataset(
            sourceURL: source,
            name: "To delete",
            importMode: .copy
        )
        let root = imported.dataset.rootPath
        XCTAssertTrue(FileManager.default.fileExists(atPath: root))

        try service.deleteDataset(id: imported.dataset.id)
        XCTAssertTrue(try service.listDatasets().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root))
    }

    func testDeleteReferencePreservesSourceFile() throws {
        let service = try DatasetLibraryService.openInMemoryForTesting(libraryRoot: tempRoot)
        let source = try copyFixture("valid_sharegpt.jsonl")
        let imported = try service.importDataset(
            sourceURL: source,
            name: "Ref keep source",
            importMode: .reference
        )

        try service.deleteDataset(id: imported.dataset.id)
        XCTAssertTrue(try service.listDatasets().isEmpty)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: source.path),
            "Reference delete must not remove the user file"
        )
    }

    func testReferenceMissingSourceMarksUnavailableThenHeals() throws {
        let service = try DatasetLibraryService.openInMemoryForTesting(libraryRoot: tempRoot)
        let source = try copyFixture("valid_openai_messages.jsonl")
        let imported = try service.importDataset(
            sourceURL: source,
            name: "Ref lifecycle",
            importMode: .reference
        )

        // Remove source → unavailable.
        try FileManager.default.removeItem(at: source)
        XCTAssertEqual(
            service.checkAvailability(dataset: imported.dataset),
            .unavailable
        )
        XCTAssertThrowsError(try service.preview(datasetId: imported.dataset.id)) { error in
            XCTAssertEqual((error as? BAMError)?.code, .datasetInvalid)
        }
        let afterMiss = try service.dataset(id: imported.dataset.id)
        XCTAssertEqual(afterMiss?.status, .unavailable)

        // Restore source at same path → heal to ready + preview works.
        try FileManager.default.copyItem(at: try fixtureURL("valid_openai_messages.jsonl"), to: source)
        // Reload record with unavailable status from DB.
        let stale = try XCTUnwrap(service.dataset(id: imported.dataset.id))
        XCTAssertEqual(stale.status, .unavailable)
        let healed = service.refreshAvailability(dataset: stale)
        XCTAssertEqual(healed, .ready)
        let preview = try service.preview(datasetId: imported.dataset.id, maxExamples: 1)
        XCTAssertEqual(preview.exampleCount, 1)
        let afterHeal = try service.dataset(id: imported.dataset.id)
        XCTAssertEqual(afterHeal?.status, .ready)
    }

    func testValidateAPI() throws {
        let service = try DatasetLibraryService.openInMemoryForTesting(libraryRoot: tempRoot)
        let good = try copyFixture("valid_sharegpt.jsonl")
        let bad = try copyFixture("invalid_not_json.jsonl")

        let ok = try service.validate(fileURL: good)
        XCTAssertTrue(ok.isValid)

        let fail = try service.validate(fileURL: bad)
        XCTAssertFalse(fail.isValid)
        XCTAssertEqual(fail.issues[0].code, .datasetInvalid)
    }

    func testStoreInsertDatasetVersionBookmarkIsAtomic() throws {
        let db = try LibraryDatabase.openInMemory()
        let store = DatasetStore(database: db)
        let datasetId = BAMID.generate()
        let dataset = DatasetRecord(
            id: datasetId,
            name: "Atomic",
            modality: .text,
            rootPath: "/tmp/x.jsonl",
            importMode: .reference,
            status: .ready,
            createdAt: DatasetImporter.iso8601Now()
        )
        let version = DatasetVersionRecord(
            id: BAMID.generate(),
            datasetId: datasetId,
            version: 1,
            contentHash: "abc",
            rowCount: 1,
            metaJSON: "{}"
        )
        let bookmark = DatasetBookmarkInsert(
            id: BAMID.generate(),
            entityType: "dataset",
            entityId: datasetId,
            data: Data("bookmark-bytes".utf8)
        )
        try store.insert(dataset: dataset, version: version, bookmark: bookmark)

        XCTAssertNotNil(try store.dataset(id: datasetId))
        XCTAssertNotNil(try store.latestVersion(datasetId: datasetId))
        let data = try store.bookmarkData(entityType: "dataset", entityId: datasetId)
        XCTAssertEqual(data, Data("bookmark-bytes".utf8))
    }

    // MARK: - Helpers

    private func copyFixture(_ name: String) throws -> URL {
        let src = try fixtureURL(name)
        let dest = tempRoot.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.copyItem(at: src, to: dest)
        return dest
    }

    private func fixtureURL(_ name: String) throws -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")
            ?? Bundle.module.url(forResource: base, withExtension: ext, subdirectory: "Fixtures")
            ?? Bundle.module.url(forResource: base, withExtension: ext)
        guard let url else {
            throw BAMError(code: .datasetInvalid, message: "missing fixture \(name)")
        }
        return url
    }
}
