import XCTest
@testable import BAMInference

final class PlaygroundTraceTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bam-trace-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testDisabledRecorderIsNoOp() throws {
        let recorder = PlaygroundTraceRecorder(enabled: false, outputDirectory: tempDir)
        let url = try recorder.recordTurn(
            stages: [
                PlaygroundTraceStage(name: "complete", durationMs: 12),
            ],
            backendId: "echo",
            latencyMs: 12
        )
        XCTAssertNil(url)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: recorder.traceFileURL.path)
        )
    }

    func testEnabledRecorderWritesAndReads() throws {
        let recorder = PlaygroundTraceRecorder(enabled: true, outputDirectory: tempDir)
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let t1 = Date(timeIntervalSince1970: 1_700_000_000.05)
        let t2 = Date(timeIntervalSince1970: 1_700_000_000.12)
        let stages = PlaygroundTraceRecorder.stagesForCompletion(
            formatStarted: t0,
            completeStarted: t1,
            completeEnded: t2,
            totalEnded: t2
        )
        let written = try recorder.recordTurn(
            stages: stages,
            backendId: "echo",
            latencyMs: 70,
            isStub: true,
            baseModelPath: "/models/base/x",
            adapterPath: nil,
            adapterEnabled: false,
            sessionId: "sess-1"
        )
        XCTAssertEqual(written, recorder.traceFileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: recorder.traceFileURL.path))

        let doc = try recorder.read()
        XCTAssertNotNil(doc)
        XCTAssertEqual(doc?.v, 1)
        XCTAssertEqual(doc?.sessionId, "sess-1")
        XCTAssertEqual(doc?.backendId, "echo")
        XCTAssertEqual(doc?.latencyMs, 70)
        XCTAssertEqual(doc?.isStub, true)
        XCTAssertEqual(doc?.stages.count, 3)
        XCTAssertEqual(doc?.stages.map(\.name), ["format", "complete", "turn"])
        XCTAssertNotNil(doc?.stages.first?.durationMs)
    }

    func testUnderLibraryRootPath() {
        let root = URL(fileURLWithPath: "/tmp/bam-lib", isDirectory: true)
        let recorder = PlaygroundTraceRecorder.underLibraryRoot(root, enabled: true)
        XCTAssertTrue(recorder.outputDirectory.path.hasSuffix("diagnostics"))
        XCTAssertTrue(recorder.traceFileURL.lastPathComponent == "playground_trace.json")
    }

    func testIsEnabledEnvOverrides() {
        XCTAssertFalse(
            PlaygroundTraceRecorder.isEnabled(
                environment: ["BAM_PLAYGROUND_TRACE": "0"],
                defaults: UserDefaults(suiteName: UUID().uuidString)!
            )
        )
        XCTAssertTrue(
            PlaygroundTraceRecorder.isEnabled(
                environment: ["BAM_PLAYGROUND_TRACE": "1"],
                defaults: UserDefaults(suiteName: UUID().uuidString)!
            )
        )
        // Default when key absent: on
        let suite = "bam.trace.enable.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertTrue(PlaygroundTraceRecorder.isEnabled(environment: [:], defaults: defaults))
        defaults.set(false, forKey: PlaygroundTraceRecorder.defaultsEnabledKey)
        XCTAssertFalse(PlaygroundTraceRecorder.isEnabled(environment: [:], defaults: defaults))
    }
}
