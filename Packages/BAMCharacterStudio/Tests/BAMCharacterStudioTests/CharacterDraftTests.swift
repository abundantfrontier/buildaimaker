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

    func testNewDraftStartsOnAlienChordMix() {
        let draft = CharacterDraft(name: "Visitor")
        XCTAssertEqual(draft.voicePreset, "alien")
        XCTAssertEqual(draft.voiceRegister, "lower")
        XCTAssertEqual(draft.speed, 0.22, accuracy: 0.01)
        XCTAssertTrue(draft.textureIdSet.contains("chime"))
        XCTAssertTrue(draft.textureIdSet.contains("crystal"))
        XCTAssertGreaterThan(draft.textureLevel("chime"), 0.2)
    }

    func testVoiceSynthesisKnobsRoundTrip() throws {
        var draft = CharacterDraft(name: "Unit-7", voicePreset: "robot")
        draft.size = 0.12
        draft.formant = 0.55
        draft.metallic = 0.8
        draft.tremble = 0.1
        draft.breath = 0.05
        draft.speed = 0.5
        draft.robotize = 0.75
        let data = try JSONEncoder().encode(draft)
        let decoded = try JSONDecoder().decode(CharacterDraft.self, from: data)
        XCTAssertEqual(decoded.formant, 0.55, accuracy: 0.001)
        XCTAssertEqual(decoded.metallic, 0.8, accuracy: 0.001)
        XCTAssertEqual(decoded.robotize, 0.75, accuracy: 0.001)
        XCTAssertEqual(decoded.speed, 0.5, accuracy: 0.001)
    }

    func testLegacyDraftFillsVoiceKnobsFromPreset() throws {
        let json = """
        {
          "id": "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
          "name": "Old Robot",
          "speciesPreset": "robot",
          "customSpecies": "",
          "vibe": "precise",
          "storyPaste": "",
          "styleTags": [],
          "riffCount": 2,
          "voicePreset": "robot",
          "size": 0.45,
          "grit": 0.55,
          "atmosphere": 0.25,
          "textureBuzzSaw": true,
          "textureSongbird": false,
          "textureDrip": false,
          "textureServo": true,
          "examples": [],
          "wizardStepRaw": 3,
          "createdAt": "2026-01-01T00:00:00Z",
          "updatedAt": "2026-01-01T00:00:00Z"
        }
        """.data(using: .utf8)!

        let draft = try JSONDecoder().decode(CharacterDraft.self, from: json)
        // Missing knobs should migrate from robot defaults.
        XCTAssertGreaterThan(draft.robotize, 0.5)
        XCTAssertGreaterThan(draft.metallic, 0.5)
        XCTAssertEqual(draft.formant, 0.55, accuracy: 0.01)
    }
}
