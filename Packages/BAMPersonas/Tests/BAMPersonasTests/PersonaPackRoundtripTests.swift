import XCTest
import BAMCore
import BAMModels
@testable import BAMPersonas

final class PersonaPackRoundtripTests: XCTestCase {
    func testFullPersonaPackRoundtrip() throws {
        let pair = try PersonaService.makeInMemoryForTesting()
        let service = pair.service
        let lib = pair.library
        let root = pair.libraryRoot

        // Seed library for resolution.
        let consent = DomainFixtures.goldenConsentRecord
        lib.upsert(consent: consent)
        lib.upsert(
            model: ModelRecord(
                id: DomainFixtures.baseModelId,
                sourceKey: "mlx-community/Qwen2.5-1.5B-Instruct-4bit",
                contentHash: "abc123",
                name: "Qwen fixture",
                kind: .base,
                license: "Apache-2.0",
                localPath: root.appendingPathComponent("models/base/x").path,
                metaJSON: "{}"
            )
        )

        let adapterDir = root
            .appendingPathComponent("models/adapters/\(DomainFixtures.adapterArtifactId)", isDirectory: true)
        try FileManager.default.createDirectory(at: adapterDir, withIntermediateDirectories: true)
        try Data("adapter-stub\n".utf8).write(
            to: adapterDir.appendingPathComponent("adapter_config.json")
        )
        lib.upsert(
            artifact: ArtifactRecord(
                id: DomainFixtures.adapterArtifactId,
                kind: .loraAdapter,
                baseModelId: DomainFixtures.baseModelId,
                localPath: adapterDir.path,
                createdAt: DomainFixtures.goldenCreatedAt
            )
        )

        let voiceDir = root
            .appendingPathComponent("voices/\(DomainFixtures.voiceProfileId)", isDirectory: true)
        try FileManager.default.createDirectory(at: voiceDir, withIntermediateDirectories: true)
        let refWav = voiceDir.appendingPathComponent("reference.wav")
        try Data("RIFF....WAVEfmt ".utf8).write(to: refWav)
        lib.upsert(
            voice: VoiceProfileRecord(
                id: DomainFixtures.voiceProfileId,
                engineId: "f5-tts",
                localPath: voiceDir.path,
                consentRecordId: consent.id,
                consentContentHash: consent.contentHash,
                createdAt: DomainFixtures.goldenCreatedAt
            )
        )

        let doc = DomainFixtures.fullPersona
        try service.save(document: doc, createdAt: DomainFixtures.goldenCreatedAt)

        let zipURL = root.appendingPathComponent("socrates-1.0.0.bam.persona.zip")
        let exportResult = try service.exportPack(
            personaId: doc.id,
            to: zipURL,
            baseModelLicenseText: "Apache-2.0\n",
            voiceEngineLicenseText: "F5-TTS license note\n"
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: zipURL.path))
        XCTAssertEqual(exportResult.manifest.formatVersion, 1)
        XCTAssertEqual(exportResult.manifest.personaId, doc.id)
        XCTAssertFalse(exportResult.manifest.exportAllowed) // personal_use consent
        XCTAssertNotNil(exportResult.manifest.files["persona.json"])
        XCTAssertNotNil(exportResult.manifest.files["consent/consent.json"])
        XCTAssertNotNil(exportResult.manifest.files["llm/base_ref.json"])
        XCTAssertNotNil(exportResult.manifest.files["voice/profile.json"])
        XCTAssertNotNil(exportResult.manifest.files["llm/adapter/adapter_config.json"])

        // Clear persona + voice + adapter registration, re-import.
        try service.delete(id: doc.id)
        lib.voices.removeAll()
        lib.artifacts.removeAll()
        // Keep base model so re-resolve works after import without re-seeding weights.

        let imported = try service.importPack(from: zipURL)
        XCTAssertEqual(imported.id, doc.id)
        XCTAssertEqual(imported.name, doc.name)
        XCTAssertEqual(imported.llm?.adapterArtifactId, DomainFixtures.adapterArtifactId)
        XCTAssertEqual(imported.voice?.voiceProfileId, DomainFixtures.voiceProfileId)

        // No knowledge keys on re-encode.
        let reencoded = try JSONEncoder().encode(imported)
        let obj = try JSONSerialization.jsonObject(with: reencoded) as! [String: Any]
        XCTAssertNil(obj["knowledge"])
        XCTAssertNil(obj["knowledgePackId"])

        let resolved = try service.resolve(id: imported.id)
        XCTAssertEqual(resolved.mode, .full)
        XCTAssertNotNil(resolved.voice)
        XCTAssertNotNil(resolved.adapter)
        XCTAssertNotNil(resolved.base)
    }

    func testTextOnlyPackRoundtrip() throws {
        let pair = try PersonaService.makeInMemoryForTesting()
        let service = pair.service
        let lib = pair.library
        let root = pair.libraryRoot

        lib.upsert(
            model: ModelRecord(
                id: DomainFixtures.baseModelId,
                name: "Base",
                kind: .base,
                localPath: "/tmp/base",
                metaJSON: "{}"
            )
        )
        let doc = DomainFixtures.textOnlyPersona
        try service.save(document: doc)

        let zipURL = root.appendingPathComponent("text.bam.persona.zip")
        let result = try service.exportPack(personaId: doc.id, to: zipURL)
        XCTAssertTrue(result.manifest.exportAllowed) // no consent → allowed
        XCTAssertNil(result.manifest.files["consent/consent.json"])

        try service.delete(id: doc.id)
        let imported = try service.importPack(from: zipURL)
        XCTAssertEqual(imported.inferredMode(), .textOnly)
        let resolved = try service.resolve(imported)
        XCTAssertEqual(resolved.mode, .textOnly)
    }

    func testImportRejectsTamperedHash() throws {
        let pair = try PersonaService.makeInMemoryForTesting()
        let service = pair.service
        let lib = pair.library
        let root = pair.libraryRoot

        lib.upsert(
            model: ModelRecord(
                id: DomainFixtures.baseModelId,
                name: "Base",
                kind: .base,
                localPath: "/tmp/base",
                metaJSON: "{}"
            )
        )
        try service.save(document: DomainFixtures.textOnlyPersona)
        let zipURL = root.appendingPathComponent("tamper.bam.persona.zip")
        _ = try service.exportPack(personaId: DomainFixtures.personaId, to: zipURL)

        // Unpack, mutate persona.json, repack without updating manifest.
        let tmp = root.appendingPathComponent("tamper-stage", isDirectory: true)
        try ZipArchive.extractZip(at: zipURL, to: tmp)
        let personaURL = tmp.appendingPathComponent("persona.json")
        var data = try Data(contentsOf: personaURL)
        data.append(contentsOf: "\n".utf8)
        try data.write(to: personaURL)
        let badZip = root.appendingPathComponent("tampered.zip")
        try ZipArchive.createZip(ofContentsOf: tmp, to: badZip)

        XCTAssertThrowsError(try service.importPack(from: badZip)) { error in
            let bam = error as? BAMError
            XCTAssertEqual(bam?.code, .schemaInvalid)
        }
    }

    func testZipRoundtripStoreMethod() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("bam-zip-\(UUID().uuidString)", isDirectory: true)
        let src = tmp.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: src.appendingPathComponent("a.txt"))
        try FileManager.default.createDirectory(
            at: src.appendingPathComponent("nested", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("world".utf8).write(to: src.appendingPathComponent("nested/b.txt"))

        let zip = tmp.appendingPathComponent("t.zip")
        try ZipArchive.createZip(ofContentsOf: src, to: zip)

        let dest = tmp.appendingPathComponent("out", isDirectory: true)
        try ZipArchive.extractZip(at: zip, to: dest)
        XCTAssertEqual(
            try String(contentsOf: dest.appendingPathComponent("a.txt"), encoding: .utf8),
            "hello"
        )
        XCTAssertEqual(
            try String(contentsOf: dest.appendingPathComponent("nested/b.txt"), encoding: .utf8),
            "world"
        )
    }

    func testCreateRejectsEmptyPersona() throws {
        let pair = try PersonaService.makeInMemoryForTesting()
        XCTAssertThrowsError(try pair.service.create(name: "Empty")) { error in
            XCTAssertEqual((error as? PersonaUnresolvedError)?.codes, [.emptyPersona])
        }
    }

    func testCreateAndList() throws {
        let pair = try PersonaService.makeInMemoryForTesting()
        let lib = pair.library
        lib.upsert(
            model: ModelRecord(
                id: DomainFixtures.baseModelId,
                name: "Base",
                kind: .base,
                localPath: "/tmp/base",
                metaJSON: "{}"
            )
        )
        let doc = try pair.service.create(
            name: "Guide",
            llm: PersonaLLMComponents(baseModelId: DomainFixtures.baseModelId),
            systemPrompt: "Be helpful."
        )
        let list = try pair.service.list()
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list.first?.name, "Guide")
        let resolved = try pair.service.resolve(id: doc.id)
        XCTAssertEqual(resolved.mode, .textOnly)
    }
}
