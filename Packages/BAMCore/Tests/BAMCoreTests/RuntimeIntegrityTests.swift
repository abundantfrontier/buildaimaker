import XCTest
import BAMCore

final class RuntimeIntegrityTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bam-pins-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
    }

    // MARK: - Hash helpers

    func testSha256HexKnownVector() {
        // echo -n "abc" | shasum -a 256
        let data = Data("abc".utf8)
        let hex = RuntimeIntegrity.sha256Hex(of: data)
        XCTAssertEqual(
            hex,
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    func testNormalizeHashStripsPrefix() {
        XCTAssertEqual(
            RuntimeIntegrity.normalizeHash("SHA256:ABCD"),
            "abcd"
        )
        XCTAssertEqual(
            RuntimeIntegrity.normalizeHash("  deadbeef  "),
            "deadbeef"
        )
    }

    // MARK: - Golden: match passes

    func testVerifyMatchPasses() throws {
        let lockBody = "mlx==0.22.1\n"
        let entryBody = "print('ok')\n"
        try writeFixture(lock: lockBody, entry: entryBody)

        let lockHash = RuntimeIntegrity.sha256Hex(of: Data(lockBody.utf8))
        let entryHash = RuntimeIntegrity.sha256Hex(of: Data(entryBody.utf8))

        let pins = RuntimePins(
            appVersion: "0.1.0",
            sizeBudgetBytes: 1024,
            sizeBudgetLabel: "test",
            lockfile: RuntimePinFile(relativePath: "requirements.lock", sha256: lockHash),
            interpreterRelativePath: "bin/python3",
            entries: [
                RuntimePinEntry(
                    id: "llm_worker.main",
                    relativePath: "llm_worker/main.py",
                    sha256: entryHash
                ),
            ]
        )
        try writePins(pins)

        let loaded = try RuntimeIntegrity.verifyPinsRoot(tempDir)
        XCTAssertEqual(loaded.appVersion, "0.1.0")
        XCTAssertEqual(loaded.lockfile.sha256, lockHash)
    }

    func testVerifyMatchWithSha256Prefix() throws {
        let lockBody = "x\n"
        let entryBody = "y\n"
        try writeFixture(lock: lockBody, entry: entryBody)

        let lockHash = RuntimeIntegrity.sha256Hex(of: Data(lockBody.utf8))
        let entryHash = RuntimeIntegrity.sha256Hex(of: Data(entryBody.utf8))

        let pins = RuntimePins(
            appVersion: "0.1.0",
            lockfile: RuntimePinFile(
                relativePath: "requirements.lock",
                sha256: "sha256:" + lockHash
            ),
            interpreterRelativePath: "bin/python3",
            entries: [
                RuntimePinEntry(
                    id: "llm_worker.main",
                    relativePath: "llm_worker/main.py",
                    sha256: "sha256:" + entryHash
                ),
            ]
        )
        try writePins(pins)
        XCTAssertNoThrow(try RuntimeIntegrity.verifyPinsRoot(tempDir))
    }

    // MARK: - Golden: mismatch fails closed

    func testLockfileMismatchFailsWithBAMRuntimeIntegrity() throws {
        try writeFixture(lock: "good\n", entry: "entry\n")
        let entryHash = RuntimeIntegrity.sha256Hex(of: Data("entry\n".utf8))

        let pins = RuntimePins(
            appVersion: "0.1.0",
            lockfile: RuntimePinFile(
                relativePath: "requirements.lock",
                sha256: String(repeating: "0", count: 64)
            ),
            interpreterRelativePath: "bin/python3",
            entries: [
                RuntimePinEntry(
                    id: "llm_worker.main",
                    relativePath: "llm_worker/main.py",
                    sha256: entryHash
                ),
            ]
        )
        try writePins(pins)

        XCTAssertThrowsError(try RuntimeIntegrity.verifyPinsRoot(tempDir)) { error in
            let bam = error as? BAMError
            XCTAssertEqual(bam?.code, .runtimeIntegrity)
            XCTAssertEqual(bam?.code.rawValue, "BAM_RUNTIME_INTEGRITY")
            XCTAssertTrue(bam?.message?.contains("lockfile hash mismatch") == true)
        }
    }

    func testEntryMismatchFailsWithBAMRuntimeIntegrity() throws {
        try writeFixture(lock: "lock\n", entry: "entry\n")
        let lockHash = RuntimeIntegrity.sha256Hex(of: Data("lock\n".utf8))

        let pins = RuntimePins(
            appVersion: "0.1.0",
            lockfile: RuntimePinFile(relativePath: "requirements.lock", sha256: lockHash),
            interpreterRelativePath: "bin/python3",
            entries: [
                RuntimePinEntry(
                    id: "llm_worker.main",
                    relativePath: "llm_worker/main.py",
                    sha256: String(repeating: "a", count: 64)
                ),
            ]
        )
        try writePins(pins)

        XCTAssertThrowsError(try RuntimeIntegrity.verifyPinsRoot(tempDir)) { error in
            let bam = error as? BAMError
            XCTAssertEqual(bam?.code, .runtimeIntegrity)
            XCTAssertTrue(bam?.message?.contains("entry hash mismatch") == true)
        }
    }

    func testPathEscapeRejected() {
        XCTAssertThrowsError(
            try RuntimeIntegrity.resolvedFile(relativePath: "../etc/passwd", under: tempDir)
        ) { error in
            XCTAssertEqual((error as? BAMError)?.code, .runtimeIntegrity)
        }
        XCTAssertThrowsError(
            try RuntimeIntegrity.resolvedFile(relativePath: "/etc/passwd", under: tempDir)
        ) { error in
            XCTAssertEqual((error as? BAMError)?.code, .runtimeIntegrity)
        }
    }

    func testMissingInterpreterWhenRequired() throws {
        try writeFixture(lock: "l\n", entry: "e\n")
        let lockHash = RuntimeIntegrity.sha256Hex(of: Data("l\n".utf8))
        let entryHash = RuntimeIntegrity.sha256Hex(of: Data("e\n".utf8))
        let pins = RuntimePins(
            appVersion: "0.1.0",
            lockfile: RuntimePinFile(relativePath: "requirements.lock", sha256: lockHash),
            interpreterRelativePath: "bin/python3",
            entries: [
                RuntimePinEntry(
                    id: "llm_worker.main",
                    relativePath: "llm_worker/main.py",
                    sha256: entryHash
                ),
            ]
        )
        let envRoot = tempDir.appendingPathComponent("env", isDirectory: true)
        try FileManager.default.createDirectory(at: envRoot, withIntermediateDirectories: true)

        XCTAssertThrowsError(
            try RuntimeIntegrity.verify(
                pins: pins,
                pinsRoot: tempDir,
                options: .init(requireInterpreterPresent: true, managedEnvRoot: envRoot)
            )
        ) { error in
            XCTAssertEqual((error as? BAMError)?.code, .runtimeIntegrity)
            XCTAssertTrue((error as? BAMError)?.message?.contains("interpreter missing") == true)
        }
    }

    func testInterpreterPathAllowlistedWithoutPresence() throws {
        try writeFixture(lock: "l\n", entry: "e\n")
        let lockHash = RuntimeIntegrity.sha256Hex(of: Data("l\n".utf8))
        let entryHash = RuntimeIntegrity.sha256Hex(of: Data("e\n".utf8))
        let pins = RuntimePins(
            appVersion: "0.1.0",
            lockfile: RuntimePinFile(relativePath: "requirements.lock", sha256: lockHash),
            interpreterRelativePath: "bin/python3",
            entries: [
                RuntimePinEntry(
                    id: "llm_worker.main",
                    relativePath: "llm_worker/main.py",
                    sha256: entryHash
                ),
            ]
        )
        let envRoot = tempDir.appendingPathComponent("env", isDirectory: true)
        try FileManager.default.createDirectory(at: envRoot, withIntermediateDirectories: true)

        XCTAssertNoThrow(
            try RuntimeIntegrity.verify(
                pins: pins,
                pinsRoot: tempDir,
                options: .init(requireInterpreterPresent: false, managedEnvRoot: envRoot)
            )
        )
    }

    func testBAMErrorCodeRuntimeIntegrityExists() {
        XCTAssertEqual(BAMErrorCode.runtimeIntegrity.rawValue, "BAM_RUNTIME_INTEGRITY")
        XCTAssertTrue(BAMErrorCode.allCases.contains(.runtimeIntegrity))
    }

    func testRuntimeInstallerStatusReportsBudget() {
        let installer = RuntimeInstaller(appVersion: "0.1.0", pinsRoot: nil)
        let status = installer.status()
        XCTAssertEqual(status.appVersion, "0.1.0")
        XCTAssertFalse(status.sizeBudgetLabel.isEmpty)
        XCTAssertGreaterThan(status.sizeBudgetBytes, 0)
        XCTAssertFalse(status.isInstalled)
    }

    func testWorkerTrustDebugAllowsMissingTeamIDForLocalBinary() throws {
        // Create an empty file — unsigned → treated as ad-hoc.
        let helper = tempDir.appendingPathComponent("bam-llm-worker")
        try Data().write(to: helper)
        try WorkerTrust.verifyHelperLaunch(helperURL: helper, mode: .debug)
    }

    func testWorkerTrustReleaseRejectsUnsignedHelper() throws {
        let helper = tempDir.appendingPathComponent("bam-llm-worker")
        try Data().write(to: helper)
        XCTAssertThrowsError(
            try WorkerTrust.verifyHelperLaunch(helperURL: helper, mode: .release)
        ) { error in
            XCTAssertEqual((error as? BAMError)?.code, .runtimeIntegrity)
        }
    }

    // MARK: - Fixtures

    private func writeFixture(lock: String, entry: String) throws {
        try lock.write(
            to: tempDir.appendingPathComponent("requirements.lock"),
            atomically: true,
            encoding: .utf8
        )
        let workerDir = tempDir.appendingPathComponent("llm_worker", isDirectory: true)
        try FileManager.default.createDirectory(at: workerDir, withIntermediateDirectories: true)
        try entry.write(
            to: workerDir.appendingPathComponent("main.py"),
            atomically: true,
            encoding: .utf8
        )
    }

    private func writePins(_ pins: RuntimePins) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(pins)
        try data.write(to: tempDir.appendingPathComponent("runtime-pins.json"))
    }
}
