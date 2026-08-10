import BAMCore
import BAMJobs
import BAMModels
import XCTest

@testable import BAMRunners

final class PathJailTests: XCTestCase {
    private var root: URL!
    private var outside: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bam-jail-\(UUID().uuidString)", isDirectory: true)
        outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("bam-outside-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: outside)
    }

    func testAcceptsNestedPath() throws {
        let nested = root.appendingPathComponent("jobs/abc/artifacts").path
        try PathJail.assertUnderRoot(nested, root: root.path, label: "outputPath")
    }

    func testRejectsEscapeWithDotDot() throws {
        // Resolving .. should still escape if final path is outside.
        let escaped = root.appendingPathComponent("../\(outside.lastPathComponent)/secret").path
        // Create the outside secret so resolvingSymlinks still lands outside root.
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        XCTAssertThrowsError(
            try PathJail.assertUnderRoot(escaped, root: root.path, label: "datasetPath")
        ) { error in
            let bam = error as? BAMError
            XCTAssertEqual(bam?.code, .pathEscape)
        }
    }

    func testRejectsAbsoluteOutsideRoot() throws {
        XCTAssertThrowsError(
            try PathJail.assertUnderRoot(outside.path, root: root.path, label: "ref")
        ) { error in
            XCTAssertEqual((error as? BAMError)?.code, .pathEscape)
        }
    }

    func testRejectsRelativePath() {
        XCTAssertThrowsError(
            try PathJail.assertUnderRoot("relative/path", root: root.path, label: "x")
        ) { error in
            XCTAssertEqual((error as? BAMError)?.code, .pathEscape)
        }
    }

    func testSymlinkEscapeRejected() throws {
        let insideLink = root.appendingPathComponent("escape-link", isDirectory: false)
        // Symlink from inside root → outside directory.
        try FileManager.default.createSymbolicLink(
            at: insideLink,
            withDestinationURL: outside
        )
        XCTAssertThrowsError(
            try PathJail.assertUnderRoot(insideLink.path, root: root.path, label: "symlink")
        ) { error in
            XCTAssertEqual((error as? BAMError)?.code, .pathEscape)
        }
    }

    func testValidateJobPathsHappy() throws {
        let jobDir = root.appendingPathComponent("jobs/j1", isDirectory: true)
        try FileManager.default.createDirectory(at: jobDir, withIntermediateDirectories: true)
        let paths = JobPaths(
            jobDir: jobDir.path,
            libraryRoot: root.path,
            datasetPath: root.appendingPathComponent("datasets/d1").path,
            baseModelPath: root.appendingPathComponent("models/base/m1").path,
            referenceAudioPath: nil,
            outputPath: jobDir.appendingPathComponent("artifacts").path,
            checkpointPath: jobDir.appendingPathComponent("checkpoints").path,
            cancelFlagPath: jobDir.appendingPathComponent("cancel.flag").path,
            logPath: jobDir.appendingPathComponent("logs").path
        )
        try PathJail.validate(paths: paths)
    }

    func testEscapedReferenceAudioPathRejected() throws {
        let jobDir = root.appendingPathComponent("jobs/j2", isDirectory: true)
        try FileManager.default.createDirectory(at: jobDir, withIntermediateDirectories: true)
        let paths = JobPaths(
            jobDir: jobDir.path,
            libraryRoot: root.path,
            referenceAudioPath: outside.appendingPathComponent("evil.wav").path,
            outputPath: jobDir.appendingPathComponent("artifacts").path,
            checkpointPath: jobDir.appendingPathComponent("checkpoints").path,
            cancelFlagPath: jobDir.appendingPathComponent("cancel.flag").path,
            logPath: jobDir.appendingPathComponent("logs").path
        )
        XCTAssertThrowsError(try PathJail.validate(paths: paths)) { error in
            XCTAssertEqual((error as? BAMError)?.code, .pathEscape)
        }
    }

    func testRawJobSpecPathMismatchRejected() throws {
        let jobDir = root.appendingPathComponent("jobs/j3", isDirectory: true)
        try FileManager.default.createDirectory(at: jobDir, withIntermediateDirectories: true)
        let ref = root.appendingPathComponent("voices/staging/v1/ref.wav").path
        let paths = JobPaths(
            jobDir: jobDir.path,
            libraryRoot: root.path,
            referenceAudioPath: ref,
            outputPath: jobDir.appendingPathComponent("artifacts").path,
            checkpointPath: jobDir.appendingPathComponent("checkpoints").path,
            cancelFlagPath: jobDir.appendingPathComponent("cancel.flag").path,
            logPath: jobDir.appendingPathComponent("logs").path
        )
        // Legacy free path on JobSpec that does not match JobPaths.
        let raw: [String: Any] = [
            "v": 1,
            "id": "job",
            "modality": "voiceClone",
            "referenceAudioPath": outside.appendingPathComponent("other.wav").path,
        ]
        let data = try JSONSerialization.data(withJSONObject: raw)
        XCTAssertThrowsError(
            try PathJail.validateRawJobSpecPaths(rawSpecJSON: data, paths: paths)
        ) { error in
            XCTAssertEqual((error as? BAMError)?.code, .pathEscape)
        }
    }

    func testRawJobSpecMatchingReferenceAudioAccepted() throws {
        let jobDir = root.appendingPathComponent("jobs/j4", isDirectory: true)
        try FileManager.default.createDirectory(at: jobDir, withIntermediateDirectories: true)
        let ref = root.appendingPathComponent("voices/staging/v1/ref.wav").path
        let paths = JobPaths(
            jobDir: jobDir.path,
            libraryRoot: root.path,
            referenceAudioPath: ref,
            outputPath: jobDir.appendingPathComponent("artifacts").path,
            checkpointPath: jobDir.appendingPathComponent("checkpoints").path,
            cancelFlagPath: jobDir.appendingPathComponent("cancel.flag").path,
            logPath: jobDir.appendingPathComponent("logs").path
        )
        let raw: [String: Any] = [
            "v": 1,
            "id": "job",
            "modality": "voiceClone",
            "referenceAudioPath": ref,
        ]
        let data = try JSONSerialization.data(withJSONObject: raw)
        try PathJail.validateRawJobSpecPaths(rawSpecJSON: data, paths: paths)
    }

    func testVoiceCloneRequiresReferenceAudio() {
        let jobDir = root.appendingPathComponent("jobs/j5", isDirectory: true)
        let paths = JobPaths(
            jobDir: jobDir.path,
            libraryRoot: root.path,
            referenceAudioPath: nil,
            outputPath: jobDir.appendingPathComponent("artifacts").path,
            checkpointPath: jobDir.appendingPathComponent("checkpoints").path,
            cancelFlagPath: jobDir.appendingPathComponent("cancel.flag").path,
            logPath: jobDir.appendingPathComponent("logs").path
        )
        let job = JobSpec.voiceClone(
            id: "v",
            consentRecordId: UUID().uuidString,
            consentContentHash: "sha256:abc"
        )
        XCTAssertThrowsError(
            try PathJail.validateModalityRequirements(job: job, paths: paths)
        ) { error in
            XCTAssertEqual((error as? BAMError)?.code, .pathEscape)
        }
    }

    func testJobLocalFieldsMustNestUnderJobDir() throws {
        let jobDir = root.appendingPathComponent("jobs/j6", isDirectory: true)
        try FileManager.default.createDirectory(at: jobDir, withIntermediateDirectories: true)
        // outputPath under libraryRoot but NOT under jobDir.
        let paths = JobPaths(
            jobDir: jobDir.path,
            libraryRoot: root.path,
            outputPath: root.appendingPathComponent("other/artifacts").path,
            checkpointPath: jobDir.appendingPathComponent("checkpoints").path,
            cancelFlagPath: jobDir.appendingPathComponent("cancel.flag").path,
            logPath: jobDir.appendingPathComponent("logs").path
        )
        XCTAssertThrowsError(try PathJail.validate(paths: paths)) { error in
            XCTAssertEqual((error as? BAMError)?.code, .pathEscape)
        }
    }

    func testCheckpointPathJailedUnderCheckpointDir() throws {
        let jobDir = root.appendingPathComponent("jobs/j7", isDirectory: true)
        try FileManager.default.createDirectory(at: jobDir, withIntermediateDirectories: true)
        let paths = JobPaths(
            jobDir: jobDir.path,
            libraryRoot: root.path,
            outputPath: jobDir.appendingPathComponent("artifacts").path,
            checkpointPath: jobDir.appendingPathComponent("checkpoints").path,
            cancelFlagPath: jobDir.appendingPathComponent("cancel.flag").path,
            logPath: jobDir.appendingPathComponent("logs").path
        )
        try PathJail.validateCheckpoint(
            CheckpointRef(path: "checkpoints/step-1", step: 1),
            paths: paths
        )
        XCTAssertThrowsError(
            try PathJail.validateCheckpoint(
                CheckpointRef(path: "/etc/passwd", step: 1),
                paths: paths
            )
        ) { error in
            XCTAssertEqual((error as? BAMError)?.code, .pathEscape)
        }
    }
}
