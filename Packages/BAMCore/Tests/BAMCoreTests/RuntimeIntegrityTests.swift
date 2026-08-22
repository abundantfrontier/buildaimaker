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

    /// Committed `Workers/python/runtime-pins.json` must match lock + entry on disk.
    func testCommittedRuntimePinsMatchRepoArtifacts() throws {
        guard let pinsRoot = findRepoPinsRoot() else {
            XCTFail("could not locate Workers/python from \(#filePath)")
            return
        }
        XCTAssertNoThrow(
            try RuntimeIntegrity.verifyPinsRoot(pinsRoot, options: .pinsOnly)
        )
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
            XCTAssertEqual((error as? BAMError)?.code, .pathEscape)
        }
        XCTAssertThrowsError(
            try RuntimeIntegrity.resolvedFile(relativePath: "/etc/passwd", under: tempDir)
        ) { error in
            XCTAssertEqual((error as? BAMError)?.code, .pathEscape)
        }
        XCTAssertThrowsError(
            try RuntimeIntegrity.resolvedFile(relativePath: "a\0b", under: tempDir)
        ) { error in
            let code = (error as? BAMError)?.code
            XCTAssertTrue(code == .pathEscape || code == .runtimeIntegrity)
        }
    }

    /// Symlink pointing outside the managed root must fail the allowlist.
    func testSymlinkEscapeRejectedForInterpreter() throws {
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
        let binDir = envRoot.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)

        // Outside target (not under envRoot).
        let outside = tempDir.appendingPathComponent("outside-python")
        try Data("# fake\n".utf8).write(to: outside)

        let link = binDir.appendingPathComponent("python3")
        try FileManager.default.createSymbolicLink(
            atPath: link.path,
            withDestinationPath: outside.path
        )

        // Random file outside the venv is not a real CPython — still reject.
        XCTAssertThrowsError(
            try RuntimeIntegrity.verify(
                pins: pins,
                pinsRoot: tempDir,
                options: .init(requireInterpreterPresent: true, managedEnvRoot: envRoot)
            )
        ) { error in
            let bam = error as? BAMError
            XCTAssertEqual(bam?.code, .runtimeIntegrity)
            XCTAssertTrue(
                bam?.message?.contains("not allowed") == true,
                bam?.message ?? ""
            )
        }

        // Same when presence is optional but the bad link exists.
        XCTAssertThrowsError(
            try RuntimeIntegrity.verify(
                pins: pins,
                pinsRoot: tempDir,
                options: .init(requireInterpreterPresent: false, managedEnvRoot: envRoot)
            )
        ) { error in
            XCTAssertEqual((error as? BAMError)?.code, .runtimeIntegrity)
        }
    }

    func testVenvPythonSymlinkToSystemInterpreterIsAllowed() throws {
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
        let binDir = envRoot.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        let systemPython = "/usr/bin/python3"
        try XCTSkipUnless(FileManager.default.fileExists(atPath: systemPython))
        try FileManager.default.createSymbolicLink(
            atPath: binDir.appendingPathComponent("python3").path,
            withDestinationPath: systemPython
        )
        XCTAssertNoThrow(
            try RuntimeIntegrity.verify(
                pins: pins,
                pinsRoot: tempDir,
                options: .init(requireInterpreterPresent: true, managedEnvRoot: envRoot)
            )
        )
    }

    func testSymlinkEscapeRejectedForPinEntry() throws {
        let lockBody = "lock\n"
        try lockBody.write(
            to: tempDir.appendingPathComponent("requirements.lock"),
            atomically: true,
            encoding: .utf8
        )
        let lockHash = RuntimeIntegrity.sha256Hex(of: Data(lockBody.utf8))

        let outside = tempDir.appendingPathComponent("evil-entry.py")
        try Data("print('evil')\n".utf8).write(to: outside)
        let workerDir = tempDir.appendingPathComponent("llm_worker", isDirectory: true)
        try FileManager.default.createDirectory(at: workerDir, withIntermediateDirectories: true)
        let link = workerDir.appendingPathComponent("main.py")
        try FileManager.default.createSymbolicLink(
            atPath: link.path,
            withDestinationPath: outside.path
        )

        // outside is still under tempDir (pins root) — use a sibling outside pins root.
        let pinsRoot = tempDir.appendingPathComponent("pins", isDirectory: true)
        try FileManager.default.createDirectory(at: pinsRoot, withIntermediateDirectories: true)
        try lockBody.write(
            to: pinsRoot.appendingPathComponent("requirements.lock"),
            atomically: true,
            encoding: .utf8
        )
        let realOutside = tempDir.appendingPathComponent("totally-outside.py")
        try Data("x\n".utf8).write(to: realOutside)
        let pinsWorker = pinsRoot.appendingPathComponent("llm_worker", isDirectory: true)
        try FileManager.default.createDirectory(at: pinsWorker, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: pinsWorker.appendingPathComponent("main.py").path,
            withDestinationPath: realOutside.path
        )

        // Wait — realOutside is under tempDir parent of pinsRoot; pinsRoot is tempDir/pins,
        // realOutside is tempDir/totally-outside.py — outside pinsRoot. Good.
        // But hashing would still work if we didn't jail. Jail should fail.

        let pins = RuntimePins(
            appVersion: "0.1.0",
            lockfile: RuntimePinFile(relativePath: "requirements.lock", sha256: lockHash),
            interpreterRelativePath: "bin/python3",
            entries: [
                RuntimePinEntry(
                    id: "llm_worker.main",
                    relativePath: "llm_worker/main.py",
                    sha256: RuntimeIntegrity.sha256Hex(of: Data("x\n".utf8))
                ),
            ]
        )
        let encoder = JSONEncoder()
        try encoder.encode(pins).write(to: pinsRoot.appendingPathComponent("runtime-pins.json"))

        XCTAssertThrowsError(try RuntimeIntegrity.verifyPinsRoot(pinsRoot)) { error in
            XCTAssertEqual((error as? BAMError)?.code, .pathEscape)
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

    func testDecodeRejectsEmptyEntriesAndUnsupportedVersion() throws {
        let emptyEntries = """
        {"version":1,"appVersion":"0.1.0","lockfile":{"relativePath":"requirements.lock","sha256":"\(String(repeating: "a", count: 64))"},"interpreterRelativePath":"bin/python3","entries":[]}
        """
        XCTAssertThrowsError(
            try RuntimePins.decode(Data(emptyEntries.utf8))
        ) { error in
            XCTAssertEqual((error as? BAMError)?.code, .runtimeIntegrity)
        }

        let badVersion = """
        {"version":2,"appVersion":"0.1.0","lockfile":{"relativePath":"requirements.lock","sha256":"\(String(repeating: "a", count: 64))"},"interpreterRelativePath":"bin/python3","entries":[{"id":"x","relativePath":"x.py","sha256":"\(String(repeating: "b", count: 64))"}]}
        """
        XCTAssertThrowsError(
            try RuntimePins.decode(Data(badVersion.utf8))
        ) { error in
            XCTAssertEqual((error as? BAMError)?.code, .runtimeIntegrity)
        }
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

    func testRefreshPinHashesRewritesStaleEntryHash() throws {
        let pinsRoot = tempDir.appendingPathComponent("refresh-pins", isDirectory: true)
        try FileManager.default.createDirectory(at: pinsRoot, withIntermediateDirectories: true)
        let lock = "lock-body\n"
        try lock.write(
            to: pinsRoot.appendingPathComponent("requirements.lock"),
            atomically: true,
            encoding: .utf8
        )
        let workerDir = pinsRoot.appendingPathComponent("llm_worker", isDirectory: true)
        try FileManager.default.createDirectory(at: workerDir, withIntermediateDirectories: true)
        try Data("print('worker')\n".utf8).write(to: workerDir.appendingPathComponent("main.py"))

        let stale = """
        {
          "version": 1,
          "appVersion": "0.1.0",
          "lockfile": {"relativePath":"requirements.lock","sha256":"\(String(repeating: "0", count: 64))"},
          "interpreterRelativePath": "bin/python3",
          "entries": [{"id":"llm_worker.main","relativePath":"llm_worker/main.py","sha256":"\(String(repeating: "1", count: 64))"}]
        }
        """
        try Data(stale.utf8).write(to: pinsRoot.appendingPathComponent("runtime-pins.json"))

        let installer = RuntimeInstaller(appVersion: "0.1.0", pinsRoot: pinsRoot)
        let pins = try installer.refreshPinHashes()
        XCTAssertNotEqual(pins.lockfile.sha256, String(repeating: "0", count: 64))
        XCTAssertEqual(pins.entries.first?.sha256.count, 64)
        try RuntimeIntegrity.verify(pins: pins, pinsRoot: pinsRoot, options: .pinsOnly)
    }

    func testInstallManagedRuntimeCreatesOrReportsError() async {
        let installer = RuntimeInstaller(appVersion: "test-install-\(UUID().uuidString.prefix(8))", pinsRoot: nil)
        let result = await installer.installManagedRuntime()
        switch result {
        case .success:
            XCTAssertTrue(installer.status().isInstalled)
            try? installer.wipeManagedEnv()
        case .failure(let error):
            // No system python3 in some CI images.
            XCTAssertNotEqual(error.code, .cancelled)
            XCTAssertTrue(
                error.code == .runtimeIntegrity
                    || (error.message?.contains("python3") == true)
            )
        }
    }

    // MARK: - WorkerTrust / WorkerSpawn

    func testWorkerTrustDebugAllowsMissingTeamIDForLocalBinary() throws {
        let helper = tempDir.appendingPathComponent("bam-llm-worker")
        try Data().write(to: helper)
        try WorkerTrust.verifyHelperLaunch(
            helperURL: helper,
            mode: .debug,
            expectedBundleURL: nil,
            requireHelpersDirectory: false
        )
    }

    func testWorkerTrustReleaseRejectsUnsignedHelper() throws {
        let helper = tempDir.appendingPathComponent("bam-llm-worker")
        try Data().write(to: helper)
        XCTAssertThrowsError(
            try WorkerTrust.verifyHelperLaunch(
                helperURL: helper,
                mode: .release,
                requireHelpersDirectory: false
            )
        ) { error in
            let bam = error as? BAMError
            XCTAssertEqual(bam?.code, .runtimeIntegrity)
            XCTAssertTrue(
                bam?.message?.contains("signature") == true
                    || bam?.message?.contains("TeamID") == true
            )
        }
    }

    func testWorkerTrustRejectsBadHelperName() throws {
        let helper = tempDir.appendingPathComponent("evil-binary")
        try Data().write(to: helper)
        XCTAssertThrowsError(
            try WorkerTrust.verifyHelperLaunch(
                helperURL: helper,
                mode: .debug,
                requireHelpersDirectory: false
            )
        ) { error in
            XCTAssertEqual((error as? BAMError)?.code, .runtimeIntegrity)
            XCTAssertTrue((error as? BAMError)?.message?.contains("not allowed") == true)
        }
    }

    func testWorkerTrustEnforcesHelpersDirectory() throws {
        let bundle = tempDir.appendingPathComponent("Fake.app", isDirectory: true)
        let helpers = WorkerTrust.helpersDirectory(inBundle: bundle)
        try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)

        let outside = tempDir.appendingPathComponent("bam-llm-worker")
        try Data().write(to: outside)

        XCTAssertThrowsError(
            try WorkerTrust.verifyHelperLaunch(
                helperURL: outside,
                mode: .debug,
                expectedBundleURL: bundle,
                requireHelpersDirectory: true
            )
        ) { error in
            XCTAssertEqual((error as? BAMError)?.code, .runtimeIntegrity)
            XCTAssertTrue((error as? BAMError)?.message?.contains("Helpers") == true)
        }
    }

    func testWorkerTrustAllowedBasenames() {
        XCTAssertTrue(WorkerTrust.isAllowedHelperBasename("bam-llm-worker"))
        XCTAssertTrue(WorkerTrust.isAllowedHelperBasename("bam-voice-worker"))
        XCTAssertFalse(WorkerTrust.isAllowedHelperBasename("llm-worker"))
        XCTAssertFalse(WorkerTrust.isAllowedHelperBasename("bam-worker"))
        XCTAssertFalse(WorkerTrust.isAllowedHelperBasename("bam-llm"))
        XCTAssertFalse(WorkerTrust.isAllowedHelperBasename("../bam-llm-worker"))
    }

    func testResolvePinsRootHonorsSearchRoots() throws {
        let python = tempDir.appendingPathComponent("Workers/python", isDirectory: true)
        try FileManager.default.createDirectory(at: python, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: python.appendingPathComponent("runtime-pins.json"))
        let found = RuntimePaths.resolvePinsRoot(
            environment: [:],
            searchRoots: [tempDir]
        )
        XCTAssertEqual(found?.path, python.path)
    }

    func testResolveDevelopmentHelperFindsSiblingOfSearchRoot() {
        // processSearchRoots includes the test executable dir; also cover the
        // walk used when CWD is $HOME and the helper sits next to the app.
        let helper = tempDir.appendingPathComponent("bam-llm-worker")
        FileManager.default.createFile(atPath: helper.path, contents: Data(), attributes: nil)
        // Sibling lookup is via processSearchRoots; pin a CWD-style walk by
        // placing the helper under a fake .build tree as well.
        let build = tempDir
            .appendingPathComponent(".build/arm64-apple-macosx/debug", isDirectory: true)
        try? FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
        let nested = build.appendingPathComponent("bam-echo-worker")
        FileManager.default.createFile(atPath: nested.path, contents: Data(), attributes: nil)

        let cwd = FileManager.default.currentDirectoryPath
        FileManager.default.changeCurrentDirectoryPath(tempDir.path)
        defer { FileManager.default.changeCurrentDirectoryPath(cwd) }

        let foundLLM = WorkerSpawn.resolveDevelopmentHelper(named: "bam-llm-worker")
        XCTAssertEqual(foundLLM?.lastPathComponent, "bam-llm-worker")
        let foundEcho = WorkerSpawn.resolveDevelopmentHelper(named: "bam-echo-worker")
        XCTAssertEqual(foundEcho?.path, nested.path)
    }

    func testWorkerSpawnPrepareFindsExplicitHelper() throws {
        let helper = tempDir.appendingPathComponent("bam-llm-worker")
        try Data().write(to: helper)
        let prepared = try WorkerSpawn.prepareHelperLaunch(
            helperName: "bam-llm-worker",
            bundleURL: nil,
            explicitHelperURL: helper,
            mode: .debug
        )
        XCTAssertEqual(prepared.url.path, helper.path)
        XCTAssertEqual(prepared.name, "bam-llm-worker")
    }

    func testCodeIdentityHasTeamIDSemantics() {
        let withTeam = WorkerTrust.CodeIdentity(
            teamID: "ABCD123456",
            signingID: "com.example",
            signatureValid: true
        )
        XCTAssertTrue(withTeam.hasTeamID)
        let without = WorkerTrust.CodeIdentity(
            teamID: nil,
            signingID: nil,
            signatureValid: false
        )
        XCTAssertFalse(without.hasTeamID)
        let empty = WorkerTrust.CodeIdentity(teamID: "", signingID: nil, signatureValid: false)
        XCTAssertFalse(empty.hasTeamID)
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

    private func findRepoPinsRoot() -> URL? {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<10 {
            let candidate = dir.appendingPathComponent("Workers/python", isDirectory: true)
            let pins = candidate.appendingPathComponent("runtime-pins.json")
            if FileManager.default.fileExists(atPath: pins.path) {
                return candidate
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        return RuntimePaths.resolvePinsRoot()
    }
}
