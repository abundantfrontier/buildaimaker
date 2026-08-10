import XCTest
import BAMCore
import BAMModels
@testable import BAMPersonas

final class PersonaResolverTests: XCTestCase {
    private func makeLibrary(
        withBase: Bool = true,
        withAdapter: Bool = true,
        withVoice: Bool = true,
        consentOK: Bool = true,
        adapterBaseMismatch: Bool = false
    ) -> InMemoryPersonaLibrary {
        let lib = InMemoryPersonaLibrary()
        if withBase {
            lib.upsert(
                model: ModelRecord(
                    id: DomainFixtures.baseModelId,
                    sourceKey: "fixture/base",
                    name: "Base",
                    kind: .base,
                    localPath: "/tmp/base",
                    metaJSON: "{}"
                )
            )
        }
        if withAdapter {
            lib.upsert(
                artifact: ArtifactRecord(
                    id: DomainFixtures.adapterArtifactId,
                    kind: .loraAdapter,
                    baseModelId: adapterBaseMismatch
                        ? "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
                        : DomainFixtures.baseModelId,
                    localPath: "/tmp/adapter",
                    createdAt: DomainFixtures.goldenCreatedAt
                )
            )
        }
        let consent = DomainFixtures.goldenConsentRecord
        if withVoice {
            lib.upsert(consent: consent)
            var hash = consent.contentHash
            if !consentOK {
                hash = "deadbeef"
            }
            lib.upsert(
                voice: VoiceProfileRecord(
                    id: DomainFixtures.voiceProfileId,
                    engineId: "f5-tts",
                    localPath: "/tmp/voice",
                    consentRecordId: consent.id,
                    consentContentHash: hash,
                    createdAt: DomainFixtures.goldenCreatedAt
                )
            )
        }
        return lib
    }

    func testResolveFullMode() throws {
        let lib = makeLibrary()
        let resolved = try PersonaResolver.resolve(DomainFixtures.fullPersona, library: lib)
        XCTAssertEqual(resolved.mode, .full)
        XCTAssertEqual(resolved.base?.id, DomainFixtures.baseModelId)
        XCTAssertEqual(resolved.adapter?.id, DomainFixtures.adapterArtifactId)
        XCTAssertEqual(resolved.voice?.id, DomainFixtures.voiceProfileId)
        XCTAssertTrue(resolved.warnings.isEmpty)
        XCTAssertEqual(resolved.systemPrompt, DomainFixtures.fullPersona.systemPrompt)
        XCTAssertEqual(resolved.sampling?.temperature, 0.7)
    }

    func testResolveTextOnlyMode() throws {
        let lib = makeLibrary(withAdapter: false, withVoice: false)
        let resolved = try PersonaResolver.resolve(DomainFixtures.textOnlyPersona, library: lib)
        XCTAssertEqual(resolved.mode, .textOnly)
        XCTAssertNotNil(resolved.base)
        XCTAssertNil(resolved.adapter)
        XCTAssertNil(resolved.voice)
        XCTAssertTrue(resolved.warnings.isEmpty)
    }

    func testResolveVoicePreviewMode() throws {
        let lib = makeLibrary(withBase: false, withAdapter: false)
        let resolved = try PersonaResolver.resolve(
            DomainFixtures.voicePreviewPersona,
            library: lib
        )
        XCTAssertEqual(resolved.mode, .voicePreview)
        XCTAssertNil(resolved.base)
        XCTAssertNotNil(resolved.voice)
        XCTAssertTrue(resolved.warnings.contains(.voicePreviewNoLLM))
    }

    func testEmptyPersonaThrowsEMPTY_PERSONA() {
        let lib = makeLibrary()
        let empty = PersonaDocument(id: "x", name: "Empty", version: "0.0.1")
        XCTAssertThrowsError(try PersonaResolver.resolve(empty, library: lib)) { error in
            let unresolved = error as? PersonaUnresolvedError
            XCTAssertEqual(unresolved?.codes, [.emptyPersona])
            XCTAssertEqual(unresolved?.bamError.code, .emptyPersona)
        }
    }

    func testMissingBase() {
        let lib = makeLibrary(withBase: false, withVoice: false)
        XCTAssertThrowsError(
            try PersonaResolver.resolve(DomainFixtures.textOnlyPersona, library: lib)
        ) { error in
            let unresolved = error as? PersonaUnresolvedError
            XCTAssertEqual(unresolved?.codes, [.missingBase])
        }
    }

    func testMissingAdapter() {
        let lib = makeLibrary(withAdapter: false, withVoice: false)
        let doc = DomainFixtures.fullPersona
        // full has voice too — strip voice so only adapter+base errors matter for adapter
        var llmOnly = doc
        llmOnly.voice = nil
        XCTAssertThrowsError(try PersonaResolver.resolve(llmOnly, library: lib)) { error in
            let unresolved = error as? PersonaUnresolvedError
            XCTAssertTrue(unresolved?.codes.contains(.missingAdapter) == true)
        }
    }

    func testAdapterBaseMismatch() {
        let lib = makeLibrary(withVoice: false, adapterBaseMismatch: true)
        var doc = DomainFixtures.fullPersona
        doc.voice = nil
        XCTAssertThrowsError(try PersonaResolver.resolve(doc, library: lib)) { error in
            let unresolved = error as? PersonaUnresolvedError
            XCTAssertTrue(unresolved?.codes.contains(.adapterBaseMismatch) == true)
        }
    }

    func testMissingVoice() {
        let lib = makeLibrary(withBase: false, withAdapter: false, withVoice: false)
        XCTAssertThrowsError(
            try PersonaResolver.resolve(DomainFixtures.voicePreviewPersona, library: lib)
        ) { error in
            let unresolved = error as? PersonaUnresolvedError
            XCTAssertEqual(unresolved?.codes, [.missingVoice])
        }
    }

    func testConsentTamper() {
        let lib = makeLibrary(withBase: false, withAdapter: false, consentOK: false)
        XCTAssertThrowsError(
            try PersonaResolver.resolve(DomainFixtures.voicePreviewPersona, library: lib)
        ) { error in
            let unresolved = error as? PersonaUnresolvedError
            XCTAssertEqual(unresolved?.codes, [.consentTamper])
            XCTAssertEqual(unresolved?.bamError.code, .consentTamper)
        }
    }

    func testKnowledgeKeysYieldIgnoredKnowledgeWarning() throws {
        let lib = makeLibrary(withAdapter: false, withVoice: false)
        let json = """
        {
          "id": "\(DomainFixtures.personaId)",
          "name": "Socrates",
          "version": "1.0.0",
          "formatVersion": 1,
          "llm": { "baseModelId": "\(DomainFixtures.baseModelId)" },
          "knowledgePackId": "should-be-ignored"
        }
        """.data(using: .utf8)!

        let resolved = try PersonaResolver.resolve(jsonData: json, library: lib)
        XCTAssertEqual(resolved.mode, .textOnly)
        XCTAssertTrue(resolved.warnings.contains(.ignoredKnowledge))
        // Document itself must not re-encode knowledge keys.
        let reencoded = try JSONEncoder().encode(resolved.document)
        let obj = try JSONSerialization.jsonObject(with: reencoded) as! [String: Any]
        XCTAssertNil(obj["knowledgePackId"])
    }

    func testRawJSONContainsKnowledgeKeys() {
        let with = #"{"id":"x","name":"n","version":"1","formatVersion":1,"knowledge":{}}"#
            .data(using: .utf8)!
        let without = #"{"id":"x","name":"n","version":"1","formatVersion":1}"#
            .data(using: .utf8)!
        XCTAssertTrue(PersonaResolver.rawJSONContainsKnowledgeKeys(with))
        XCTAssertFalse(PersonaResolver.rawJSONContainsKnowledgeKeys(without))
    }
}
