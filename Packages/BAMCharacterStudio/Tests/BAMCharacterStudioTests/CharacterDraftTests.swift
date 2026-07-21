import XCTest
@testable import BAMCharacterStudio

final class CharacterDraftTests: XCTestCase {
    func testBaseModelFieldsRoundTrip() throws {
        let draft = CharacterDraft(
            name: "Zorp",
            baseModelId: "mlx-community--Qwen2.5-0.5B-Instruct-4bit",
            baseModelPath: "/tmp/models/base/mlx-community--Qwen2.5-0.5B-Instruct-4bit",
            baseModelName: "Qwen2.5 Instruct 0.5B",
            baseModelSourceKey: "mlx-community/Qwen2.5-0.5B-Instruct-4bit",
            wizardStepRaw: 1
        )
        XCTAssertTrue(draft.hasSelectedBaseModel)

        let data = try JSONEncoder().encode(draft)
        let decoded = try JSONDecoder().decode(CharacterDraft.self, from: data)
        XCTAssertEqual(decoded.baseModelId, draft.baseModelId)
        XCTAssertEqual(decoded.baseModelPath, draft.baseModelPath)
        XCTAssertEqual(decoded.baseModelName, draft.baseModelName)
        XCTAssertEqual(decoded.baseModelSourceKey, draft.baseModelSourceKey)
        XCTAssertTrue(decoded.hasSelectedBaseModel)
    }

    func testLegacyDraftWithoutBaseModelDecodes() throws {
        let json = """
        {
          "id": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
          "name": "Oldie",
          "speciesPreset": "alien",
          "customSpecies": "",
          "vibe": "curious",
          "storyPaste": "",
          "styleTags": [],
          "riffCount": 2,
          "voicePreset": "alien",
          "size": 0.5,
          "grit": 0.35,
          "atmosphere": 0.4,
          "textureBuzzSaw": false,
          "textureSongbird": false,
          "textureDrip": false,
          "textureServo": false,
          "examples": [],
          "wizardStepRaw": 1,
          "createdAt": "2026-01-01T00:00:00Z",
          "updatedAt": "2026-01-01T00:00:00Z"
        }
        """.data(using: .utf8)!

        let draft = try JSONDecoder().decode(CharacterDraft.self, from: json)
        XCTAssertNil(draft.baseModelPath)
        XCTAssertFalse(draft.hasSelectedBaseModel)
        XCTAssertEqual(draft.name, "Oldie")
        // Named but no model → resume on model step (1).
        XCTAssertEqual(draft.resumeStepRaw, 1)
    }

    func testResumeStepUsesContentHeuristics() {
        var draft = CharacterDraft(name: "Zorp")
        XCTAssertEqual(draft.resumeStepRaw, 1) // model

        draft.baseModelPath = "/tmp/m"
        draft.baseModelName = "Fixture"
        XCTAssertEqual(draft.resumeStepRaw, 2) // mind

        draft.examples = [DialogueExample(user: "hi", assistant: "hello")]
        XCTAssertEqual(draft.resumeStepRaw, 2) // still mind (or stay)

        draft.previewAudioPath = "/tmp/v.wav"
        XCTAssertEqual(draft.resumeStepRaw, 3) // voice

        draft.isComplete = true
        XCTAssertEqual(draft.resumeStepRaw, 4) // done
    }

    func testProgressLabelReflectsModelSelection() {
        var draft = CharacterDraft(name: "Zorp")
        XCTAssertTrue(draft.progressLabel.contains("Model"))

        draft.baseModelPath = "/tmp/m"
        draft.baseModelName = "Fixture"
        XCTAssertTrue(draft.progressLabel.contains("Model picked"))
    }
}
