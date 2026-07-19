import XCTest
import BAMConsent
import BAMCore
import BAMModels
import BAMPersistence
import GRDB
@testable import BAMPersonas

/// Product-path regression: pack re-import must not abort when consent id already exists.
final class PersonaPackProductImportTests: XCTestCase {
    func testVoicePackReimportWithExistingConsentViaPersistForImport() throws {
        let db = try LibraryDatabase.openInMemory()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bam-persona-product-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let consentDir = root.appendingPathComponent("consent", isDirectory: true)
        try FileManager.default.createDirectory(at: consentDir, withIntermediateDirectories: true)
        let consentStore = ConsentStore(
            database: db,
            consentDirectory: consentDir,
            writeJSONFiles: true
        )
        let consentService = ConsentService(store: consentStore)

        // Pre-seed consent (same as cloning a voice before export).
        let consent = DomainFixtures.goldenConsentRecord
        _ = try consentService.persist(consent)

        let grdbLib = GRDBPersonaLibrary(
            database: db,
            consentLoader: { id in try consentService.fetch(id: id) }
        )
        try grdbLib.upsertModel(
            ModelRecord(
                id: DomainFixtures.baseModelId,
                sourceKey: "fixture/base",
                name: "Base",
                kind: .base,
                localPath: root.appendingPathComponent("models/base/x").path,
                metaJSON: "{}"
            )
        )

        let adapterDir = root
            .appendingPathComponent(
                "models/adapters/\(DomainFixtures.adapterArtifactId)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: adapterDir, withIntermediateDirectories: true)
        try Data("adapter\n".utf8).write(
            to: adapterDir.appendingPathComponent("adapter_config.json")
        )
        try grdbLib.upsertArtifact(
            ArtifactRecord(
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
        try Data("RIFF....WAVEfmt ".utf8).write(
            to: voiceDir.appendingPathComponent("reference.wav")
        )
        let voiceStore = VoiceProfileStoreShim(database: db)
        let voice = VoiceProfileRecord(
            id: DomainFixtures.voiceProfileId,
            engineId: "f5-tts",
            localPath: voiceDir.path,
            consentRecordId: consent.id,
            consentContentHash: consent.contentHash,
            createdAt: DomainFixtures.goldenCreatedAt
        )
        try voiceStore.upsert(voice)

        let personaStore = PersonaStore(database: db)
        let service = PersonaService(
            store: personaStore,
            library: grdbLib,
            libraryRoot: root,
            consentPersister: { record in
                // Product wiring (PersonasViewModel.makeDefault).
                _ = try consentService.persistForImport(record)
            },
            voicePersister: { profile in
                try voiceStore.upsert(profile)
            }
        )

        try service.save(document: DomainFixtures.fullPersona)
        let zipURL = root.appendingPathComponent("socrates.bam.persona.zip")
        _ = try service.exportPack(personaId: DomainFixtures.personaId, to: zipURL)

        // Same-machine re-import: consent id already in library.sqlite.
        // Old path used append-only persist → unique constraint abort.
        let imported = try service.importPack(from: zipURL, replaceExisting: true)
        XCTAssertEqual(imported.id, DomainFixtures.personaId)

        let resolved = try service.resolve(id: imported.id)
        XCTAssertEqual(resolved.mode, .full)
        XCTAssertEqual(try consentService.listAll().count, 1)
        XCTAssertNotNil(try consentService.fetch(id: consent.id))
    }

    func testImportFailsWhenExistingConsentHashConflicts() throws {
        let db = try LibraryDatabase.openInMemory()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bam-persona-conflict-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let consentStore = ConsentStore(
            database: db,
            consentDirectory: root.appendingPathComponent("consent"),
            writeJSONFiles: false
        )
        let consentService = ConsentService(store: consentStore)
        let consent = DomainFixtures.goldenConsentRecord
        _ = try consentService.persist(consent)

        let grdbLib = GRDBPersonaLibrary(
            database: db,
            consentLoader: { id in try consentService.fetch(id: id) }
        )
        try grdbLib.upsertModel(
            ModelRecord(
                id: DomainFixtures.baseModelId,
                name: "Base",
                kind: .base,
                localPath: "/tmp/base",
                metaJSON: "{}"
            )
        )

        let voiceStore = VoiceProfileStoreShim(database: db)
        try voiceStore.upsert(
            VoiceProfileRecord(
                id: DomainFixtures.voiceProfileId,
                engineId: "f5-tts",
                localPath: root.appendingPathComponent("voices/v").path,
                consentRecordId: consent.id,
                consentContentHash: consent.contentHash,
                createdAt: DomainFixtures.goldenCreatedAt
            )
        )

        let service = PersonaService(
            store: PersonaStore(database: db),
            library: grdbLib,
            libraryRoot: root,
            consentPersister: { record in
                _ = try consentService.persistForImport(record)
            },
            voicePersister: { profile in
                try voiceStore.upsert(profile)
            }
        )

        // Export voice-preview pack with the golden consent, then replace library consent
        // body with a different hash under the same id by using a separate export library.
        // Simpler: build pack with golden consent, then change stored consent after export.
        try service.save(document: DomainFixtures.voicePreviewPersona)
        let zipURL = root.appendingPathComponent("voice.bam.persona.zip")
        _ = try service.exportPack(personaId: DomainFixtures.personaId, to: zipURL)

        // Overwrite stored consent with a different binding (same id, new hash) via replace.
        var other = DomainFixtures.goldenConsentRecord
        other.subjectDisplayName = "Different"
        other = try other.withComputedContentHash()
        _ = try consentStore.saveReplacing(other)

        XCTAssertThrowsError(try service.importPack(from: zipURL)) { error in
            let bam = error as? BAMError
            XCTAssertEqual(bam?.code, .consentTamper)
        }
    }
}

// Minimal voice_profiles upsert without depending on BAMRunnersVoice.
private struct VoiceProfileStoreShim {
    let database: LibraryDatabase

    func upsert(_ profile: VoiceProfileRecord) throws {
        try database.dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO voice_profiles (
                      id, engine_id, local_path, consent_record_id,
                      consent_content_hash, created_at
                    ) VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                      engine_id = excluded.engine_id,
                      local_path = excluded.local_path,
                      consent_record_id = excluded.consent_record_id,
                      consent_content_hash = excluded.consent_content_hash,
                      created_at = excluded.created_at
                    """,
                arguments: [
                    profile.id,
                    profile.engineId,
                    profile.localPath,
                    profile.consentRecordId,
                    profile.consentContentHash,
                    profile.createdAt,
                ]
            )
        }
    }
}
