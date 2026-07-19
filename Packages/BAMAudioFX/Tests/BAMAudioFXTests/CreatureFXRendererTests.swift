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
