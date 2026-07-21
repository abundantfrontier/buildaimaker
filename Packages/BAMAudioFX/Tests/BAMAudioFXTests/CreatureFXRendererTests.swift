import XCTest
@testable import BAMAudioFX

final class CreatureFXRendererTests: XCTestCase {
    func testRenderWritesWavAndProfile() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bam-fx-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        var params = CreatureFXParams.fromPreset(.robot)
        params.textures = [.buzzSaw, .servo]
        let result = try CreatureFXRenderer.renderPreview(
            params: params,
            characterName: "Unit-7",
            outputDirectory: dir
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.audioURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.profileURL.path))
        let attrs = try FileManager.default.attributesOfItem(atPath: result.audioURL.path)
        let size = attrs[.size] as? NSNumber
        XCTAssertNotNil(size)
        XCTAssertGreaterThan(size!.intValue, 1000)
        XCTAssertGreaterThan(result.durationSeconds, 1)
        XCTAssertFalse(result.usedSystemTTS)
    }

    func testResampleChangesLength() {
        let input = [Float](repeating: 0.5, count: 1000)
        let up = CreatureFXRenderer.resample(input, from: 1.0, to: 2.0)
        XCTAssertEqual(up.count, 2000)
        let down = CreatureFXRenderer.resample(input, from: 2.0, to: 1.0)
        XCTAssertEqual(down.count, 500)
    }

    func testSpokenPreviewUsesTTSWhenAvailable() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bam-fx-tts-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let params = CreatureFXParams.fromPreset(.alien)
        let result = try await CreatureFXRenderer.renderSpokenPreview(
            speechText: "Hello. I am Mr. Z, a polite outsider.",
            params: params,
            characterName: "Mr. Z",
            outputDirectory: dir
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.audioURL.path))
        XCTAssertGreaterThan(result.durationSeconds, 0.4)
        // On macOS with voices installed this should be true; if TTS fails, buzz fallback still writes audio.
        if result.usedSystemTTS {
            XCTAssertEqual(result.spokenText?.contains("Mr. Z"), true)
        }
    }

    func testPresetDefaultsInRange() {
        for p in CreatureVoicePreset.allCases {
            let params = CreatureFXParams.fromPreset(p)
            XCTAssertGreaterThanOrEqual(params.size, 0)
            XCTAssertLessThanOrEqual(params.size, 1)
            XCTAssertGreaterThan(params.pitchRate, 0.5)
            XCTAssertLessThan(params.pitchRate, 2.0)
        }
    }
}
