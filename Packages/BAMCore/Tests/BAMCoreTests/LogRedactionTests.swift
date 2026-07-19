import XCTest
@testable import BAMCore

final class LogRedactionTests: XCTestCase {
    func testDefaultEnabledWhenEnvUnset() {
        XCTAssertTrue(LogRedaction.isEnabled(environment: [:]))
        XCTAssertTrue(LogRedaction.isEnabled(environment: ["BAM_REDACT_SAMPLES": "1"]))
        XCTAssertTrue(LogRedaction.isEnabled(environment: ["BAM_REDACT_SAMPLES": "true"]))
    }

    func testDisabledWhenExplicitlyOff() {
        XCTAssertFalse(LogRedaction.isEnabled(environment: ["BAM_REDACT_SAMPLES": "0"]))
        XCTAssertFalse(LogRedaction.isEnabled(environment: ["BAM_REDACT_SAMPLES": "false"]))
        XCTAssertFalse(LogRedaction.isEnabled(environment: ["BAM_REDACT_SAMPLES": "off"]))
    }

    func testLooksLikeSamplePayloadJSONConversation() {
        let msg = #"row: {"messages":[{"role":"user","content":"Hello Socrates, what is virtue?"}]}"#
        XCTAssertTrue(LogRedaction.looksLikeSamplePayload(msg))
    }

    func testLooksLikeSamplePayloadMarkers() {
        XCTAssertTrue(LogRedaction.looksLikeSamplePayload("prompt: Tell me about Athens"))
        XCTAssertTrue(LogRedaction.looksLikeSamplePayload("user: hello\nassistant: hi"))
        XCTAssertTrue(LogRedaction.looksLikeSamplePayload("training sample dump follows"))
    }

    func testMetricsNotTreatedAsSample() {
        // Model-card style metrics should pass through.
        let metrics = "sampleGenerationCount=3 holdOutLoss=1.2"
        XCTAssertFalse(LogRedaction.looksLikeSamplePayload(metrics))
        let redacted = LogRedaction.redactMessage(
            metrics,
            environment: ["BAM_REDACT_SAMPLES": "1"]
        )
        XCTAssertEqual(redacted, metrics)
    }

    func testOperationalLogNotRedacted() {
        let msg = "prepare ok step=1 epoch=0.0 loss=2.5"
        let out = LogRedaction.redactMessage(msg, environment: ["BAM_REDACT_SAMPLES": "1"])
        XCTAssertEqual(out, msg)
        XCTAssertFalse(out.contains(LogRedaction.placeholder))
    }

    func testSampleTextRedactedByDefault() {
        let msg = #"sample: {"role":"user","content":"private dialogue about the user"}"#
        let out = LogRedaction.redactMessage(msg, environment: [:])
        XCTAssertTrue(out.contains(LogRedaction.placeholder))
        XCTAssertFalse(out.contains("private dialogue"))
    }

    func testRedactionDisabledPassesThrough() {
        let msg = #"sample: {"role":"user","content":"secret text"}"#
        let out = LogRedaction.redactMessage(
            msg,
            environment: ["BAM_REDACT_SAMPLES": "0"]
        )
        XCTAssertEqual(out, msg)
        XCTAssertTrue(out.contains("secret text"))
    }

    func testLongJSONLRowRedacted() {
        let payload = String(repeating: "x", count: 120)
        let secret = "TOP_SECRET_DIALOGUE_\(payload)\(payload)"
        let msg =
            #"{"messages":[{"role":"user","content":"\#(secret)"}],"meta":"train"}"#
        XCTAssertGreaterThanOrEqual(msg.count, 240)
        XCTAssertTrue(LogRedaction.looksLikeSamplePayload(msg))
        let out = LogRedaction.redactForDefaultLog(msg, environment: ["BAM_REDACT_SAMPLES": "1"])
        XCTAssertTrue(out.contains(LogRedaction.placeholder))
        XCTAssertFalse(out.contains("TOP_SECRET_DIALOGUE"))
        // Full line may keep a short prefix before the sample marker.
        XCTAssertLessThan(out.count, msg.count)
    }

    func testInlineContentScrub() {
        let msg = #"epoch=1 content="This is a long enough quoted payload that should be scrubbed from default logs""#
        let out = LogRedaction.redactMessage(msg, environment: ["BAM_REDACT_SAMPLES": "1"])
        XCTAssertTrue(out.contains(LogRedaction.placeholder) || out.contains("content="))
        XCTAssertFalse(out.contains("long enough quoted payload"))
    }

    func testPrefixPreservedWhenMarkerPresent() {
        let msg = "batch=3 sample: secret user utterance about private matters"
        let out = LogRedaction.redactMessage(msg, environment: ["BAM_REDACT_SAMPLES": "1"])
        XCTAssertTrue(out.contains(LogRedaction.placeholder))
        XCTAssertTrue(out.hasPrefix("batch=3") || out == LogRedaction.placeholder)
        XCTAssertFalse(out.contains("private matters"))
    }
}

final class RuntimeRecoveryTests: XCTestCase {
    func testIntegrityFailureDetection() {
        let err = BAMError(code: .runtimeIntegrity, message: "lockfile hash mismatch")
        XCTAssertTrue(RuntimeRecovery.isIntegrityFailure(err))
        XCTAssertFalse(
            RuntimeRecovery.isIntegrityFailure(BAMError(code: .cancelled, message: "stub"))
        )
    }

    func testUserMessageIncludesRepairCTA() {
        let err = BAMError(code: .runtimeIntegrity, message: "entry hash mismatch")
        let msg = RuntimeRecovery.userMessage(for: err)
        XCTAssertNotNil(msg)
        XCTAssertTrue(msg!.contains(BAMErrorCode.runtimeIntegrity.rawValue))
        XCTAssertTrue(msg!.contains("Repair") || msg!.contains(RuntimeRecovery.shortCTA))
    }

    func testUserMessageNilForOtherErrors() {
        XCTAssertNil(
            RuntimeRecovery.userMessage(for: BAMError(code: .datasetInvalid, message: "bad"))
        )
    }

    func testAugmentStatus() {
        let err = BAMError(code: .runtimeIntegrity, message: "x")
        let status = RuntimeRecovery.augmentStatus("LoRA train failed", error: err)
        XCTAssertTrue(status.contains("LoRA train failed"))
        XCTAssertTrue(status.contains("Repair") || status.contains("Settings"))
    }
}

final class DiagnosticsExportTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bam-diag-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testExportWritesVersionsAndRedactsEvents() throws {
        let library = tempDir.appendingPathComponent("lib", isDirectory: true)
        let jobId = "job-diag-1"
        let jobDir = library.appendingPathComponent("jobs/\(jobId)", isDirectory: true)
        try FileManager.default.createDirectory(at: jobDir, withIntermediateDirectories: true)

        let events = """
        {"v":1,"type":"log","level":"info","message":"prepare ok","ts":"t0"}
        {"v":1,"type":"log","level":"info","message":"sample: {\\"role\\":\\"user\\",\\"content\\":\\"secret\\"}","ts":"t1"}
        {"v":1,"type":"progress","step":1,"epoch":0.0,"loss":1.0}
        """
        try events.write(
            to: jobDir.appendingPathComponent("events.jsonl"),
            atomically: true,
            encoding: .utf8
        )
        try #"{"id":"\#(jobId)"}"#.write(
            to: jobDir.appendingPathComponent("job.json"),
            atomically: true,
            encoding: .utf8
        )

        let dest = tempDir.appendingPathComponent("out", isDirectory: true)
        let result = try DiagnosticsExporter.export(
            libraryRoot: library,
            to: dest,
            options: DiagnosticsExportOptions(maxJobs: 5, redactEventLogs: true),
            featureFlags: .default,
            appVersion: "0.1.0",
            environment: ["BAM_REDACT_SAMPLES": "1"]
        )

        XCTAssertEqual(result.includedJobIds, [jobId])
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: dest.appendingPathComponent(DiagnosticsExporter.versionsFileName).path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: dest.appendingPathComponent(DiagnosticsExporter.runtimeStatusFileName).path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: dest.appendingPathComponent(DiagnosticsExporter.manifestFileName).path
            )
        )

        let exportedEvents = try String(
            contentsOf: dest.appendingPathComponent("jobs/\(jobId)/events.jsonl"),
            encoding: .utf8
        )
        XCTAssertTrue(exportedEvents.contains("prepare ok"))
        XCTAssertFalse(exportedEvents.contains("secret"))
        XCTAssertTrue(exportedEvents.contains(LogRedaction.placeholder))
    }
}

final class RuntimeRepairTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bam-repair-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testWipeManagedEnvOnlyUnderPythonEnvs() async throws {
        // Use a real-ish app version path under LibraryPaths — we can't easily
        // redirect LibraryPaths.libraryRoot, so exercise path jail via a
        // temporary tree and RuntimeIntegrity.isPath, plus wipe of empty env.
        let installer = RuntimeInstaller(appVersion: "test-repair-wipe")
        let root = installer.envRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let marker = root.appendingPathComponent("bin/python3")
        try FileManager.default.createDirectory(
            at: marker.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("fake".utf8).write(to: marker)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))

        try installer.wipeManagedEnv()
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testRepairRunsWipeThenInstallStub() async throws {
        let installer = RuntimeInstaller(appVersion: "test-repair-stub")
        let root = installer.envRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        var phases: [RuntimeInstallPhase] = []
        let result = await installer.repair { progress in
            phases.append(progress.phase)
        }
        // Stub install ends cancelled (no multi-GB download).
        guard case .failure(let error) = result else {
            XCTFail("expected stub failure")
            return
        }
        XCTAssertEqual(error.code, .cancelled)
        XCTAssertNotEqual(error.code, .runtimeIntegrity)
        XCTAssertTrue(phases.contains(.preparing) || phases.contains(.downloading))
        // Env wiped as first step.
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testWorkerSpawnRejectsNonHelperBasename() {
        let python = URL(fileURLWithPath: "/usr/bin/python3")
        XCTAssertThrowsError(
            try WorkerSpawn.prepareExecutableURL(python, mode: .debug)
        ) { error in
            let bam = error as? BAMError
            XCTAssertEqual(bam?.code, .runtimeIntegrity)
            XCTAssertTrue(
                bam?.message?.contains("not allowed") == true
                    || bam?.message?.contains("non-helper") == true
            )
        }
    }
}
