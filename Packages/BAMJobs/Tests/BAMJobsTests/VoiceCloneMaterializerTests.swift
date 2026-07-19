import BAMCore
import BAMModels
import XCTest

@testable import BAMJobs

final class VoiceCloneMaterializerTests: XCTestCase {
    private var root: URL!
    private var fm: FileManager!

    override func setUpWithError() throws {
        fm = .default
        root = fm.temporaryDirectory
            .appendingPathComponent("bam-voice-mat-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
        root = nil
    }

    // MARK: - JobPaths materialization

    func testMakePathsForVoiceCloneFixture() throws {
        let ref = try writeRefWav(named: "ref.wav", under: root.appendingPathComponent("voices/staging"))
        let paths = try VoiceCloneMaterializer.makePaths(
            job: DomainFixtures.voiceCloneJobSpec,
            libraryRoot: root,
            referenceAudioPath: ref.path
        )

        XCTAssertEqual(paths.libraryRoot, root.path)
        XCTAssertTrue(paths.jobDir.hasPrefix(root.path))
        XCTAssertEqual(paths.referenceAudioPath, ref.path)
        XCTAssertNil(paths.datasetPath)
        XCTAssertNil(paths.baseModelPath)
        XCTAssertTrue(paths.outputPath.hasSuffix("/artifacts") || paths.outputPath.hasSuffix("artifacts"))
        try VoiceCloneMaterializer.validateVoicePaths(paths)
    }

    func testMaterializeCreatesJobLayoutAndJobJSON() throws {
        let ref = try writeRefWav(named: "clip.wav", under: root.appendingPathComponent("voices/staging"))
        let job = DomainFixtures.voiceCloneJobSpec
        let result = try VoiceCloneMaterializer.materialize(
            job: job,
            libraryRoot: root,
            referenceAudioPath: ref.path
        )

        XCTAssertTrue(fm.fileExists(atPath: result.paths.jobDir))
        XCTAssertTrue(fm.fileExists(atPath: result.paths.outputPath))
        XCTAssertTrue(fm.fileExists(atPath: result.paths.checkpointPath))
        XCTAssertTrue(fm.fileExists(atPath: result.paths.logPath))

        let jobJSON = JobPathsFactory.jobJSONURL(paths: result.paths)
        XCTAssertTrue(fm.fileExists(atPath: jobJSON.path))

        let data = try Data(contentsOf: jobJSON)
        let decoded = try JSONDecoder().decode(JobSpec.self, from: data)
        XCTAssertEqual(decoded, job)
        XCTAssertEqual(decoded.modality, .voiceClone)
        XCTAssertEqual(decoded.engineId, "f5-tts")

        // JobSpec must not embed free-form paths.
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertNil(obj["referenceAudioPath"])
    }

    func testRejectsNonVoiceModality() {
        XCTAssertThrowsError(
            try VoiceCloneMaterializer.makePaths(
                job: DomainFixtures.llmJobSpec,
                libraryRoot: root,
                referenceAudioPath: root.appendingPathComponent("x.wav").path
            )
        ) { error in
            XCTAssertEqual((error as? BAMError)?.code, .schemaInvalid)
        }
    }

    func testRejectsMissingReferenceAudioPath() {
        let job = DomainFixtures.voiceCloneJobSpec
        // Build paths manually without reference and validate.
        let paths = JobPathsFactory.make(jobId: job.id, libraryRoot: root, referenceAudioPath: nil)
        XCTAssertThrowsError(try VoiceCloneMaterializer.validateVoicePaths(paths)) { error in
            let bam = error as? BAMError
            XCTAssertEqual(bam?.code, .pathEscape)
            XCTAssertTrue(bam?.message?.contains("referenceAudioPath") == true)
        }
    }

    func testRejectsEscapedReferenceAudioPath() throws {
        let outside = fm.temporaryDirectory
            .appendingPathComponent("bam-voice-outside-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: outside) }
        let evil = try writeRefWav(named: "evil.wav", under: outside)

        XCTAssertThrowsError(
            try VoiceCloneMaterializer.makePaths(
                job: DomainFixtures.voiceCloneJobSpec,
                libraryRoot: root,
                referenceAudioPath: evil.path
            )
        ) { error in
            XCTAssertEqual((error as? BAMError)?.code, .pathEscape)
        }
    }

    // MARK: - Stub voice_profile

    func testWriteStubVoiceProfileFromRefWav() throws {
        let ref = try writeRefWav(named: "fifteen-sec.wav", under: root.appendingPathComponent("inbox"))
        let out = root.appendingPathComponent("voices/\(DomainFixtures.voiceProfileId)", isDirectory: true)

        let profile = try VoiceCloneMaterializer.writeStubVoiceProfile(
            referenceWavURL: ref,
            outDir: out,
            engineId: "f5-tts",
            consentRecordId: DomainFixtures.consentRecordId,
            consentContentHash: DomainFixtures.voiceCloneJobSpec.consentContentHash,
            language: "en"
        )

        XCTAssertTrue(profile.stub)
        XCTAssertEqual(profile.engineId, "f5-tts")
        XCTAssertTrue(profile.referenceAudioHash.hasPrefix("sha256:"))
        XCTAssertTrue(fm.fileExists(atPath: profile.profilePath))
        XCTAssertTrue(fm.fileExists(atPath: profile.referenceWavPath))
        XCTAssertTrue(
            fm.fileExists(
                atPath: out.appendingPathComponent(VoiceCloneMaterializer.engineCacheDirectoryName).path
            )
        )

        let data = try Data(contentsOf: URL(fileURLWithPath: profile.profilePath))
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(obj["kind"] as? String, "voice_profile")
        XCTAssertEqual(obj["engineId"] as? String, "f5-tts")
        XCTAssertEqual(obj["stub"] as? Bool, true)
        XCTAssertEqual(obj["consentRecordId"] as? String, DomainFixtures.consentRecordId)
        XCTAssertNotNil(obj["referenceAudioHash"] as? String)
    }

    func testStubProfileRejectsXTTSEngine() throws {
        let ref = try writeRefWav(named: "x.wav", under: root.appendingPathComponent("inbox"))
        XCTAssertThrowsError(
            try VoiceCloneMaterializer.writeStubVoiceProfile(
                referenceWavURL: ref,
                outDir: root.appendingPathComponent("voices/xtts-blocked"),
                engineId: "xtts-v2"
            )
        ) { error in
            XCTAssertEqual((error as? BAMError)?.code, .licenseBlock)
        }
    }

    func testMaterializeRejectsXTTSBeforeJobDirs() throws {
        let staging = root.appendingPathComponent("voices/staging", isDirectory: true)
        let ref = try writeRefWav(named: "ref.wav", under: staging)
        let job = JobSpec.voiceClone(
            id: DomainFixtures.voiceCloneJobId,
            engineId: "xtts-v2",
            consentRecordId: DomainFixtures.consentRecordId,
            consentContentHash: DomainFixtures.voiceCloneJobSpec.consentContentHash ?? "sha256:x"
        )
        XCTAssertThrowsError(
            try VoiceCloneMaterializer.materialize(
                job: job,
                libraryRoot: root,
                referenceAudioPath: ref.path
            )
        ) { error in
            XCTAssertEqual((error as? BAMError)?.code, .licenseBlock)
        }
        // No partial job tree.
        let jobDir = root
            .appendingPathComponent("jobs")
            .appendingPathComponent(DomainFixtures.voiceCloneJobId)
        XCTAssertFalse(fm.fileExists(atPath: jobDir.path))
    }

    func testMaterializeWithStubProfileRejectsXTTSBeforeJobDirs() throws {
        let staging = root.appendingPathComponent("voices/staging", isDirectory: true)
        let ref = try writeRefWav(named: "ref.wav", under: staging)
        let job = JobSpec.voiceClone(
            id: DomainFixtures.voiceCloneJobId,
            engineId: "coqui-xtts",
            consentRecordId: DomainFixtures.consentRecordId,
            consentContentHash: "sha256:abc"
        )
        XCTAssertThrowsError(
            try VoiceCloneMaterializer.materializeWithStubProfile(
                job: job,
                libraryRoot: root,
                referenceAudioPath: ref.path
            )
        ) { error in
            XCTAssertEqual((error as? BAMError)?.code, .licenseBlock)
        }
        let jobDir = root
            .appendingPathComponent("jobs")
            .appendingPathComponent(DomainFixtures.voiceCloneJobId)
        XCTAssertFalse(fm.fileExists(atPath: jobDir.path))
    }

    func testMaterializeWithStubProfileEndToEnd() throws {
        let staging = root.appendingPathComponent("voices/staging", isDirectory: true)
        let ref = try writeRefWav(named: "ref.wav", under: staging)
        let job = DomainFixtures.voiceCloneJobSpec

        let (jobMat, profile) = try VoiceCloneMaterializer.materializeWithStubProfile(
            job: job,
            libraryRoot: root,
            referenceAudioPath: ref.path,
            voiceProfileId: DomainFixtures.voiceProfileId
        )

        XCTAssertEqual(jobMat.spec.id, job.id)
        XCTAssertEqual(jobMat.paths.referenceAudioPath, ref.path)
        XCTAssertTrue(profile.stub)
        XCTAssertTrue(fm.fileExists(atPath: profile.profilePath))

        // Library-facing voice dir also created.
        let libraryVoice = root
            .appendingPathComponent("voices")
            .appendingPathComponent(DomainFixtures.voiceProfileId)
            .appendingPathComponent("profile.json")
        XCTAssertTrue(fm.fileExists(atPath: libraryVoice.path))

        // Artifact under job output.
        let artifactProfile = URL(fileURLWithPath: jobMat.paths.outputPath)
            .appendingPathComponent("voice_profile/profile.json")
        XCTAssertTrue(fm.fileExists(atPath: artifactProfile.path))
    }

    func testJobSpecHasNoReferenceAudioPathKey() throws {
        let data = try JSONEncoder().encode(DomainFixtures.voiceCloneJobSpec)
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertNil(obj["referenceAudioPath"])
        XCTAssertEqual(obj["engineId"] as? String, "f5-tts")
        XCTAssertEqual(obj["modality"] as? String, "voiceClone")
    }

    // MARK: - Helpers

    /// Minimal RIFF/WAV header + silence payload (enough to be a real file; not 15 s audio).
    @discardableResult
    private func writeRefWav(named name: String, under dir: URL) throws -> URL {
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        // 44-byte header + 16 bytes of PCM zeros (8 samples mono 16-bit).
        var data = Data()
        data.append(contentsOf: Array("RIFF".utf8))
        data.append(contentsOf: UInt32(36).littleEndianBytes) // chunk size placeholder-ish
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        data.append(contentsOf: UInt32(16).littleEndianBytes)
        data.append(contentsOf: UInt16(1).littleEndianBytes) // PCM
        data.append(contentsOf: UInt16(1).littleEndianBytes) // mono
        data.append(contentsOf: UInt32(16_000).littleEndianBytes) // sample rate
        data.append(contentsOf: UInt32(32_000).littleEndianBytes) // byte rate
        data.append(contentsOf: UInt16(2).littleEndianBytes) // block align
        data.append(contentsOf: UInt16(16).littleEndianBytes) // bits
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
