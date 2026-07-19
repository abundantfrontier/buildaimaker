import XCTest
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
