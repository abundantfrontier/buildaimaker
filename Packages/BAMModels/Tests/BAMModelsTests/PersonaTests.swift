import XCTest
import BAMCore
import BAMModels

final class PersonaTests: XCTestCase {
    func testFullPersonaModeAndRoundTrip() throws {
        let p = DomainFixtures.fullPersona
        XCTAssertEqual(p.inferredMode(), .full)
        XCTAssertEqual(p.formatVersion, 1)
        XCTAssertNotNil(p.llm?.adapterArtifactId)
        XCTAssertNotNil(p.voice?.voiceProfileId)

        let data = try JSONEncoder().encode(p)
        let decoded = try JSONDecoder().decode(PersonaDocument.self, from: data)
        XCTAssertEqual(decoded, p)

        // No knowledge-pack keys in encoded JSON.
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertNil(obj["knowledge"])
        XCTAssertNil(obj["knowledgePackId"])
        XCTAssertNil(obj["knowledgePacks"])
    }

    func testFormatVersionPinnedToProtocolVersions() {
        XCTAssertEqual(PersonaDocument.formatVersionV1, ProtocolVersions.personaPackFormat)
        XCTAssertEqual(DomainFixtures.fullPersona.formatVersion, ProtocolVersions.personaPackFormat)
    }

    func testDecodeIgnoresUnknownKnowledgeKeys() throws {
        // K26: import ignores knowledge / RAG keys; they must not break Codable
        // and must not reappear on re-encode. (IGNORED_KNOWLEDGE warning is PR-Persona.)
        let json = """
        {
          "id": "77777777-7777-4777-8777-777777777777",
          "name": "Socrates",
          "version": "1.0.0",
          "formatVersion": 1,
          "llm": { "baseModelId": "33333333-3333-4333-8333-333333333333" },
          "systemPrompt": "You are Socrates.",
          "knowledgePackId": "should-be-ignored",
          "knowledgePacks": [{ "id": "k1" }],
          "knowledge": { "enabled": true }
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(PersonaDocument.self, from: json)
        XCTAssertEqual(decoded.name, "Socrates")
        XCTAssertEqual(decoded.llm?.baseModelId, DomainFixtures.baseModelId)
        XCTAssertEqual(decoded.inferredMode(), .textOnly)

        let reencoded = try JSONEncoder().encode(decoded)
        let obj = try JSONSerialization.jsonObject(with: reencoded) as! [String: Any]
        XCTAssertNil(obj["knowledge"])
        XCTAssertNil(obj["knowledgePackId"])
        XCTAssertNil(obj["knowledgePacks"])
    }

    func testTextOnlyAndVoicePreviewModes() {
        XCTAssertEqual(DomainFixtures.textOnlyPersona.inferredMode(), .textOnly)
        XCTAssertEqual(DomainFixtures.voicePreviewPersona.inferredMode(), .voicePreview)
        let empty = PersonaDocument(id: "x", name: "x", version: "0.0.1")
        XCTAssertNil(empty.inferredMode())
    }

    func testPersonaModeRawValues() {
        XCTAssertEqual(PersonaMode.full.rawValue, "full")
        XCTAssertEqual(PersonaMode.textOnly.rawValue, "textOnly")
        XCTAssertEqual(PersonaMode.voicePreview.rawValue, "voicePreview")
    }
}
