import BAMConsent
import BAMCore
import BAMJobs
import BAMModels
import XCTest

@testable import BAMRunnersVoice

final class VoiceCloneServiceTests: XCTestCase {
    private var root: URL!
    private var service: VoiceCloneService!
    private var fm: FileManager!

    override func setUpWithError() throws {
        fm = .default
        let pair = try VoiceCloneService.makeInMemoryForTesting(
            runnerConfig: .testing,
            heartbeatTimeout: 5
        )
        service = pair.service
        root = pair.libraryRoot
    }

    override func tearDownWithError() throws {
        if let root {
            try? fm.removeItem(at: root)
        }
        service = nil
        root = nil
    }

    func testImportReferenceAudioLandsUnderLibraryStaging() throws {
        let src = try writeRefWav(named: "user-clip.wav", under: root.appendingPathComponent("inbox"))
        let imported = try service.importReferenceAudio(from: src)

        XCTAssertTrue(imported.referenceAudioPath.hasPrefix(root.path))
        XCTAssertTrue(imported.referenceAudioPath.contains("/voices/staging/"))
        XCTAssertTrue(imported.referenceAudioPath.hasSuffix("/ref.wav"))
        XCTAssertTrue(fm.fileExists(atPath: imported.referenceAudioPath))
    }

    func testStartCloneRequiresConsent() async throws {
        let src = try writeRefWav(named: "ref.wav", under: root.appendingPathComponent("inbox"))
        let imported = try service.importReferenceAudio(from: src)

        do {
            _ = try await service.startCloneJob(
                referenceAudioPath: imported.referenceAudioPath,
                consentRecordId: DomainFixtures.consentRecordId
            )
            XCTFail("expected consentRequired")
        } catch let error as BAMError {
            // Missing consent row surfaces as consent required / schema from fetchAndVerify
            XCTAssertTrue(
                error.code == .consentRequired
                    || error.code == .consentTamper
                    || error.code == .schemaInvalid
                    || error.message?.contains("not found") == true
                    || error.message?.lowercased().contains("consent") == true,
                "unexpected \(error)"
            )
        }
    }

    func testStartCloneJobMaterializesReferenceAudioPathOnlyAndRegistersProfile() async throws {
        let consent = try seedConsent()
        let src = try writeRefWav(named: "fifteen.wav", under: root.appendingPathComponent("inbox"))
        let imported = try service.importReferenceAudio(from: src)

        let started = try await service.startCloneJob(
            referenceAudioPath: imported.referenceAudioPath,
            consentRecordId: consent.id,
            language: "en"
        )

        XCTAssertEqual(started.spec.modality, .voiceClone)
        XCTAssertEqual(started.spec.consentRecordId, consent.id)
        XCTAssertNotNil(started.paths.referenceAudioPath)
        XCTAssertEqual(started.paths.referenceAudioPath, imported.referenceAudioPath)
        XCTAssertNil(started.paths.datasetPath)
        XCTAssertNil(started.paths.baseModelPath)

        // JobSpec must not embed free-form paths.
        let data = try JSONEncoder().encode(started.spec)
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertNil(obj["referenceAudioPath"])

        let finished = try await service.waitForJob(jobId: started.job.id, timeout: .seconds(5))
        XCTAssertEqual(finished.status, .succeeded, finished.errorMessage ?? "")

        let profile = try await service.finalizeSucceededJob(jobId: started.job.id)
        XCTAssertEqual(profile.id, started.voiceProfileId)
        XCTAssertEqual(profile.consentRecordId, consent.id)
        XCTAssertEqual(profile.engineId, "f5-tts")
        XCTAssertTrue(profile.localPath.contains("/voices/"))
        XCTAssertTrue(
            fm.fileExists(
                atPath: URL(fileURLWithPath: profile.localPath)
                    .appendingPathComponent("profile.json").path
            )
        )

        let listed = try service.listProfiles()
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed.first?.id, profile.id)
    }

    func testRejectsXTTSEngine() async throws {
        let consent = try seedConsent()
        let src = try writeRefWav(named: "x.wav", under: root.appendingPathComponent("inbox"))
        let imported = try service.importReferenceAudio(from: src)

        do {
            _ = try await service.startCloneJob(
                referenceAudioPath: imported.referenceAudioPath,
                consentRecordId: consent.id,
                engineId: "xtts-v2"
            )
            XCTFail("expected license block")
        } catch let error as BAMError {
            XCTAssertEqual(error.code, .licenseBlock)
        }
    }

    func testRejectsEscapedReferenceAudioPath() async throws {
        let consent = try seedConsent()
        let outside = fm.temporaryDirectory
            .appendingPathComponent("bam-voice-outside-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: outside) }
        let evil = try writeRefWav(named: "evil.wav", under: outside)

        do {
            _ = try await service.startCloneJob(
                referenceAudioPath: evil.path,
                consentRecordId: consent.id
            )
            XCTFail("expected path escape")
        } catch let error as BAMError {
            XCTAssertEqual(error.code, .pathEscape)
        }
    }

    func testStubRunnerValidateRequiresConsentFields() throws {
        let paths = DomainFixtures.voiceCloneJobPaths
        var job = DomainFixtures.voiceCloneJobSpec
        job.consentRecordId = nil
        XCTAssertThrowsError(try StubVoiceCloneRunner.validateJob(job, paths: paths)) { error in
            XCTAssertEqual((error as? BAMError)?.code, .consentRequired)
        }
    }

    func testCompositeRoutesVoiceModality() async throws {
        let fake = FakeTrainingRunner(config: .testing)
        let stub = StubVoiceCloneRunner(config: .testing)
        let composite = CompositeTrainingRunner(llm: fake, voice: stub)
        let caps = try await composite.capabilities()
        XCTAssertTrue(caps.modalities.contains(.llm))
        XCTAssertTrue(caps.modalities.contains(.voiceClone))
        XCTAssertTrue(caps.engineIds?.contains("f5-tts") == true)
    }

    // MARK: - Helpers

    private func seedConsent() throws -> ConsentRecord {
        try service.consentService.persist(DomainFixtures.goldenConsentRecord)
    }

    @discardableResult
    private func writeRefWav(named name: String, under dir: URL) throws -> URL {
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        var data = Data()
        data.append(contentsOf: Array("RIFF".utf8))
        data.append(contentsOf: UInt32(36).littleEndianBytes)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        data.append(contentsOf: UInt32(16).littleEndianBytes)
        data.append(contentsOf: UInt16(1).littleEndianBytes)
        data.append(contentsOf: UInt16(1).littleEndianBytes)
        data.append(contentsOf: UInt32(16_000).littleEndianBytes)
        data.append(contentsOf: UInt32(32_000).littleEndianBytes)
        data.append(contentsOf: UInt16(2).littleEndianBytes)
        data.append(contentsOf: UInt16(16).littleEndianBytes)
        data.append(contentsOf: Array("data".utf8))
        data.append(contentsOf: UInt32(16).littleEndianBytes)
        data.append(Data(repeating: 0, count: 16))
        try data.write(to: url)
        return url
    }
}

private extension UInt16 {
    var littleEndianBytes: [UInt8] {
        let v = littleEndian
        return [UInt8(v & 0xff), UInt8((v >> 8) & 0xff)]
    }
}

private extension UInt32 {
    var littleEndianBytes: [UInt8] {
        let v = littleEndian
        return [
            UInt8(v & 0xff),
            UInt8((v >> 8) & 0xff),
            UInt8((v >> 16) & 0xff),
            UInt8((v >> 24) & 0xff),
        ]
    }
}
