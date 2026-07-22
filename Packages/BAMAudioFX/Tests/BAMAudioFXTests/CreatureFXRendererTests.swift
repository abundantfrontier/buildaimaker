import AVFoundation
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
        // Buzz fallback is fixed ~1.6s; real TTS is usually longer and marks usedSystemTTS.
        XCTAssertTrue(
            result.usedSystemTTS,
            "Expected system TTS path; got buzz fallback (check speech voices / buffer format)"
        )
        XCTAssertEqual(result.spokenText?.contains("Mr. Z"), true)
        // Profile must record TTS usage for debugging user reports.
        let profile = try String(contentsOf: result.profileURL, encoding: .utf8)
        XCTAssertTrue(profile.contains("creature-fx-tts-v1"))
        XCTAssertTrue(profile.contains("usedSystemTTS"))
    }

    func testExtractMonoFromInt16Buffer() throws {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        )!
        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4)!
        pcm.frameLength = 4
        let ptr = pcm.int16ChannelData![0]
        ptr[0] = 0
        ptr[1] = Int16.max / 2
        ptr[2] = Int16.min / 2
        ptr[3] = 0
        let samples = SystemSpeechSynthesizer.extractMonoFloat(from: pcm)
        XCTAssertEqual(samples.count, 4)
        XCTAssertGreaterThan(samples[1], 0.4)
        XCTAssertLessThan(samples[2], -0.4)
    }

    func testPresetDefaultsInRange() {
        for p in CreatureVoicePreset.allCases {
            let params = CreatureFXParams.fromPreset(p)
            XCTAssertGreaterThanOrEqual(params.size, 0)
            XCTAssertLessThanOrEqual(params.size, 1)
            XCTAssertGreaterThan(params.pitchRate, 0.4)
            XCTAssertLessThan(params.pitchRate, 2.2)
            XCTAssertGreaterThanOrEqual(params.formant, 0)
            XCTAssertLessThanOrEqual(params.formant, 1)
            XCTAssertGreaterThanOrEqual(params.robotize, 0)
            XCTAssertLessThanOrEqual(params.robotize, 1)
        }
    }

    func testRobotAndFairyPresetsDifferStrongly() {
        let robot = CreatureFXParams.fromPreset(.robot)
        let fairy = CreatureFXParams.fromPreset(.fairy)
        // Pitch should be far apart (deep robot-ish vs high fairy).
        XCTAssertLessThan(robot.size, 0.55)
        XCTAssertGreaterThan(fairy.size, 0.7)
        XCTAssertGreaterThan(abs(robot.pitchRate - fairy.pitchRate), 0.4)
        // Machine vs organic
        XCTAssertGreaterThan(robot.robotize, 0.5)
        XCTAssertEqual(fairy.robotize, 0, accuracy: 0.01)
        XCTAssertGreaterThan(robot.metallic, fairy.metallic)
        XCTAssertGreaterThan(fairy.formant, robot.formant)
    }

    func testCharacterVoiceChangesEnergyVsIdentity() {
        // Apply robot vs ghost chains to the same carrier; peaks should still be finite.
        var robot = [Float](repeating: 0, count: 4_000)
        for i in robot.indices {
            let t = Double(i) / 24_000
            robot[i] = Float(sin(2 * .pi * 220 * t) * 0.5)
        }
        var ghost = robot
        CreatureFXRenderer.applyCharacterVoice(
            &robot,
            params: .fromPreset(.robot),
            sampleRate: 24_000
        )
        CreatureFXRenderer.applyCharacterVoice(
            &ghost,
            params: .fromPreset(.ghost),
            sampleRate: 24_000
        )
        XCTAssertFalse(robot.allSatisfy { $0 == 0 })
        XCTAssertFalse(ghost.allSatisfy { $0 == 0 })
        // Outputs should not be identical after different character chains.
        let same = zip(robot, ghost).allSatisfy { abs($0 - $1) < 1e-5 }
        XCTAssertFalse(same, "Robot and ghost processing should diverge")
    }
}
