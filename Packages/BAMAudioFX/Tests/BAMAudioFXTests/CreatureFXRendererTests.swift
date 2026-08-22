import AVFoundation
import XCTest
@testable import BAMAudioFX

final class CreatureFXRendererTests: XCTestCase {
    func testRenderWritesWavAndProfile() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bam-fx-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        var params = CreatureFXParams.fromPreset(.robot)
        XCTAssertTrue(params.textures.isEmpty, "Presets must not dump SFX beds")
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
        XCTAssertTrue(
            profile.contains("creature-fx-tts-v1") || profile.contains("kokoro-catalog-v1"),
            "Expected system or catalog engine id in profile"
        )
        XCTAssertTrue(profile.contains("usedSystemTTS"))
    }

    func testCatalogVoiceIdsAreUniquePerPreset() {
        let defaults = CreatureVoicePreset.allCases.map(\.defaultCatalogVoiceId)
        XCTAssertEqual(Set(defaults).count, defaults.count, "Each preset needs its own default speaker")
        XCTAssertEqual(CreatureVoicePreset.sultry.defaultCatalogVoiceId, "af_nicole")
        XCTAssertEqual(CreatureVoicePreset.fairy.defaultCatalogVoiceId, "af_heart")
        XCTAssertNotEqual(
            CreatureVoicePreset.sultry.catalogVoiceId(register: .higher),
            CreatureVoicePreset.pirate.catalogVoiceId(register: .lower)
        )
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
        // Cards start slider-neutral; identity is speaker + signature, not pitch stretch.
        XCTAssertEqual(robot.size, 0.5, accuracy: 0.01)
        XCTAssertEqual(fairy.size, 0.5, accuracy: 0.01)
        XCTAssertEqual(robot.robotize, 0, accuracy: 0.01)
        XCTAssertEqual(fairy.robotize, 0, accuracy: 0.01)
        XCTAssertTrue(robot.textures.isEmpty)
        XCTAssertTrue(fairy.textures.isEmpty)
        XCTAssertNotEqual(robot.catalogVoiceId, fairy.catalogVoiceId)
        let alien = CreatureFXParams.fromPreset(.alien)
        XCTAssertEqual(alien.register, .lower)
        XCTAssertEqual(alien.catalogVoiceId, "am_puck")
        XCTAssertEqual(alien.speed, 0.22, accuracy: 0.01)
        XCTAssertEqual(alien.tremble, 0.08, accuracy: 0.01)
        XCTAssertEqual(alien.grit, 0, accuracy: 0.01)
        XCTAssertEqual(alien.metallic, 0, accuracy: 0.01)
        XCTAssertTrue(alien.textures.contains(.chime))
        XCTAssertTrue(alien.textures.contains(.crystal))
        XCTAssertGreaterThan(alien.textureMix["chime"] ?? 0, 0.2)
        XCTAssertEqual(CreatureVoicePreset.alien.catalogActingSpeed, 0.80, accuracy: 0.01)
        XCTAssertEqual(alien.catalogActingDeliverySpeed, 0.80, accuracy: 0.02)
        var faster = alien
        faster.speed = 1.0
        XCTAssertGreaterThan(faster.catalogActingDeliverySpeed, alien.catalogActingDeliverySpeed + 0.25)
        var slower = alien
        slower.speed = 0
        XCTAssertLessThan(slower.catalogActingDeliverySpeed, alien.catalogActingDeliverySpeed - 0.12)
        XCTAssertTrue(
            CreatureVoicePreset.alien.spokenPreviewLine(characterName: "Rocky").contains("question?")
        )
        XCTAssertNotEqual(robot.preset.speechVoiceHint, fairy.preset.speechVoiceHint)
        XCTAssertEqual(CreatureVoicePreset.sultry.defaultRegister, .higher)
        XCTAssertEqual(CreatureVoicePreset.sultry.title, "Warm")
        XCTAssertEqual(CreatureVoicePreset.deep.title, "Deep")
        XCTAssertEqual(CreatureVoicePreset.deep.defaultRegister, .lower)
        XCTAssertTrue(CreatureVoicePreset.deep.isHumanLeaning)
        XCTAssertEqual(CreatureVoicePreset.deep.defaultCatalogVoiceId, "am_michael")
        XCTAssertEqual(CreatureVoicePreset.alien.defaultCatalogVoiceId, "am_puck")
        XCTAssertEqual(CreatureVoicePreset.alien.defaultRegister, .lower)
        XCTAssertEqual(CreatureVoicePreset.alien.catalogVoiceId(register: .higher), "af_bella")
        XCTAssertNotEqual(CreatureVoicePreset.sultry.defaultCatalogVoiceId, CreatureVoicePreset.deep.defaultCatalogVoiceId)
        XCTAssertNotEqual(
            CreatureVoicePreset.alien.defaultCatalogVoiceId,
            CreatureVoicePreset.goblin.defaultCatalogVoiceId
        )
        XCTAssertGreaterThanOrEqual(CreatureFXParams.fromPreset(.sultry).breath, 0)
        XCTAssertFalse(CreatureVoicePreset.sultry.usesMouthSizeFormant)
        XCTAssertTrue(CreatureVoicePreset.sultry.isHumanLeaning)
        XCTAssertTrue(CreatureVoicePreset.dragon.usesMouthSizeFormant)
        let sultry = CreatureFXParams.fromPreset(.sultry)
        XCTAssertEqual(sultry.pitchRate, 1.0, accuracy: 0.08)
        XCTAssertLessThan(sultry.atmosphere, 0.12)
        XCTAssertEqual(sultry.tremble, 0, accuracy: 0.01)
        XCTAssertEqual(sultry.grit, 0, accuracy: 0.01)
    }

    func testWarmPresenceKeepsFiniteSignal() {
        var samples = [Float](repeating: 0, count: 6_000)
        for i in samples.indices {
            samples[i] = Float(sin(2 * .pi * 220 * Double(i) / 24_000) * 0.4)
        }
        CreatureFXRenderer.applyWarmPresence(&samples, sampleRate: 24_000)
        CreatureFXRenderer.applyIntimateBreath(&samples, amount: 0.28, sampleRate: 24_000)
        XCTAssertFalse(samples.contains { $0.isNaN || $0.isInfinite })
        XCTAssertFalse(samples.allSatisfy { $0 == 0 })
    }

    func testSultryChainIsNotADelayIdentity() {
        var sultry = [Float](repeating: 0, count: 4_000)
        for i in sultry.indices {
            let t = Double(i) / 24_000
            sultry[i] = Float(sin(2 * .pi * 220 * t) * 0.5)
        }
        var ghost = sultry
        var robot = sultry
        CreatureFXRenderer.applyCharacterVoice(
            &sultry,
            params: .fromPreset(.sultry),
            sampleRate: 24_000
        )
        CreatureFXRenderer.applyCharacterVoice(
            &ghost,
            params: .fromPreset(.ghost),
            sampleRate: 24_000
        )
        CreatureFXRenderer.applyCharacterVoice(
            &robot,
            params: .fromPreset(.robot),
            sampleRate: 24_000
        )
        XCTAssertFalse(zip(sultry, ghost).allSatisfy { abs($0 - $1) < 1e-5 })
        XCTAssertFalse(zip(sultry, robot).allSatisfy { abs($0 - $1) < 1e-5 })
        XCTAssertFalse(sultry.contains { $0.isNaN || $0.isInfinite })
    }

    func testLoudnessMatchBringsQuietSignalUp() {
        var quiet = [Float](repeating: 0.02, count: 4_000)
        for i in quiet.indices {
            quiet[i] = Float(sin(2 * .pi * 400 * Double(i) / 24_000) * 0.02)
        }
        CreatureFXRenderer.applyLoudnessMatch(&quiet, size: 0.9, formant: 0.85)
        let peak = quiet.map { abs($0) }.max() ?? 0
        XCTAssertGreaterThan(peak, 0.08)
        XCTAssertLessThan(peak, 0.95)
    }

    func testFormantShiftChangesWaveWithoutNaN() {
        var samples = [Float](repeating: 0, count: 8_000)
        for i in samples.indices {
            samples[i] = Float(sin(2 * .pi * 180 * Double(i) / 24_000) * 0.4)
        }
        CreatureFXRenderer.applyFormantShift(&samples, ratio: 1.28)
        XCTAssertFalse(samples.contains { $0.isNaN || $0.isInfinite })
        XCTAssertFalse(samples.allSatisfy { $0 == 0 })
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
