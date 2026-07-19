import XCTest
import BAMCore
import BAMJobs
import BAMModels
@testable import BAMRunners

final class FakeRemoteRunnerTests: XCTestCase {
    private var tempRoot: URL!

    override func setUp() async throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("bam-fake-remote-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
    }

    // MARK: - Cloud policy / flag remains off

    func testCloudRunnerFlagDefaultsOff() {
        XCTAssertFalse(FeatureFlags.default.cloudRunner)
        XCTAssertFalse(CloudPolicy.isCloudRunnerEnabled(.default))
        XCTAssertEqual(CloudPolicy.deferredMessage, "Remote training deferred post-PMF")
        XCTAssertEqual(CloudPolicy.featureFlagKey, .cloudRunner)
    }

    func testRequireCloudRunnerEnabledThrowsWhenOff() {
        XCTAssertThrowsError(try CloudPolicy.requireCloudRunnerEnabled(.default)) { error in
            let bam = error as? BAMError
            XCTAssertEqual(bam?.code, .capabilityUnsupported)
            XCTAssertEqual(bam?.message, CloudPolicy.deferredMessage)
        }
    }

    func testRequireCloudRunnerEnabledPassesWhenOn() throws {
        var flags = FeatureFlags.default
        flags.cloudRunner = true
        try CloudPolicy.requireCloudRunnerEnabled(flags)
        XCTAssertTrue(CloudPolicy.isCloudRunnerEnabled(flags))
    }

    // MARK: - Connection

    func testConnectAndDisconnect() async throws {
        let runner = FakeRemoteRunner(config: .testing)
        var connected = await runner.isConnected()
        XCTAssertFalse(connected)

        try await runner.connect()
        connected = await runner.isConnected()
        XCTAssertTrue(connected)
        XCTAssertEqual(runner.kind, .fake)
        XCTAssertEqual(runner.endpoint.kind, .fake)

        await runner.disconnect()
        connected = await runner.isConnected()
        XCTAssertFalse(connected)
    }

    func testOperationsRequireConnection() async throws {
        let runner = FakeRemoteRunner(config: .testing)
        let spec = DomainFixtures.llmJobSpec
        let paths = makePaths(jobId: spec.id)

        do {
            _ = try await runner.submit(job: spec, paths: paths)
            XCTFail("expected not-connected error")
        } catch let error as BAMError {
            XCTAssertEqual(error.code, .capabilityUnsupported)
        }

        do {
            try await runner.prepare(job: spec, paths: paths)
            XCTFail("expected not-connected error")
        } catch let error as BAMError {
            XCTAssertEqual(error.code, .capabilityUnsupported)
        }
    }

    // MARK: - Full remote job lifecycle

    func testHappyPathLifecyclePhasesAndEvents() async throws {
        let runner = FakeRemoteRunner(config: .testing)
        let spec = DomainFixtures.llmJobSpec
        let paths = makePaths(jobId: spec.id)

        try await runner.connect()
        let handle = try await runner.submit(job: spec, paths: paths)
        XCTAssertEqual(handle.localJobId, spec.id)
        XCTAssertTrue(handle.remoteJobId.contains(spec.id))
        var phase = try await runner.remoteStatus(handle: handle)
        XCTAssertEqual(phase, .pending)

        try await runner.prepare(job: spec, paths: paths)
        // After prepare: upload + queue complete.
        phase = try await runner.remoteStatus(handle: handle)
        XCTAssertEqual(phase, .queued)

        var events: [RunnerEvent] = []
        var sawProgress = false
        var sawHeartbeat = false
        var sawDownloadLog = false
        var resultStatus: String?

        for try await event in runner.run(job: spec, paths: paths) {
            events.append(event)
            switch event {
            case .progress:
                sawProgress = true
                phase = try await runner.remoteStatus(handle: handle)
                XCTAssertEqual(phase, .running)
            case .heartbeat:
                sawHeartbeat = true
            case let .log(_, message, _):
                if message.contains("downloading") {
                    sawDownloadLog = true
                }
            case let .result(status, artifacts, _):
                resultStatus = status
                XCTAssertFalse(artifacts.isEmpty)
            default:
                break
            }
        }

        XCTAssertTrue(sawProgress)
        XCTAssertTrue(sawHeartbeat)
        XCTAssertTrue(sawDownloadLog)
        XCTAssertEqual(resultStatus, "succeeded")
        phase = try await runner.remoteStatus(handle: handle)
        XCTAssertEqual(phase, .succeeded)

        let history = runner.phaseHistory(localJobId: spec.id)
        // Must include the remote lifecycle milestones (order preserved).
        XCTAssertTrue(history.contains(.pending))
        XCTAssertTrue(history.contains(.uploading))
        XCTAssertTrue(history.contains(.queued))
        XCTAssertTrue(history.contains(.running))
        XCTAssertTrue(history.contains(.downloading))
        XCTAssertTrue(history.contains(.succeeded))
        assertPhaseOrder(history, expected: [
            .pending, .uploading, .queued, .running, .downloading, .succeeded,
        ])

        // Artifact stub written under job output.
        let marker = URL(fileURLWithPath: paths.outputPath)
            .appendingPathComponent("adapter")
            .appendingPathComponent("fake-remote.marker")
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
    }

    func testCancelMidRun() async throws {
        let config = FakeRemoteRunnerConfig(
            stepCount: 40,
            stepInterval: .milliseconds(20),
            connectDelay: .milliseconds(1),
            uploadDelay: .milliseconds(1),
            queueDelay: .milliseconds(1),
            downloadDelay: .milliseconds(1),
            heartbeatEverySteps: 1
        )
        let runner = FakeRemoteRunner(config: config)
        let spec = DomainFixtures.llmJobSpec
        let paths = makePaths(jobId: spec.id)

        try await runner.connect()
        try await runner.prepare(job: spec, paths: paths)

        var progressCount = 0
        var sawCancelled = false

        for try await event in runner.run(job: spec, paths: paths) {
            if case .progress = event {
                progressCount += 1
                if progressCount == 2 {
                    await runner.cancel(jobId: spec.id)
                }
            }
            if case .result(let status, _, _) = event, status == "cancelled" {
                sawCancelled = true
            }
        }

        XCTAssertTrue(sawCancelled)
        XCTAssertLessThan(progressCount, 40)

        let history = runner.phaseHistory(localJobId: spec.id)
        XCTAssertTrue(history.contains(.cancelled))
        XCTAssertTrue(history.last == .cancelled || history.contains(.cancelled))
    }

    func testCancelDuringPrepare() async throws {
        let config = FakeRemoteRunnerConfig(
            stepCount: 5,
            stepInterval: .milliseconds(5),
            connectDelay: .milliseconds(1),
            uploadDelay: .milliseconds(80),
            queueDelay: .milliseconds(1),
            downloadDelay: .milliseconds(1)
        )
        let runner = FakeRemoteRunner(config: config)
        let spec = DomainFixtures.llmJobSpec
        let paths = makePaths(jobId: spec.id)

        try await runner.connect()
        _ = try await runner.submit(job: spec, paths: paths)

        let prepareTask = Task {
            try await runner.prepare(job: spec, paths: paths)
        }
        // Cancel while upload delay is in flight.
        try await Task.sleep(for: .milliseconds(10))
        await runner.cancel(jobId: spec.id)

        do {
            try await prepareTask.value
            // May succeed if prepare finished before cancel observed — either way phase is terminal.
        } catch let error as BAMError {
            XCTAssertEqual(error.code, .cancelled)
        }

        let phase = try await runner.remoteStatus(
            handle: RemoteJobHandle(remoteJobId: "remote-\(spec.id)", localJobId: spec.id)
        )
        // If cancel won, cancelled; if prepare finished first, queued.
        XCTAssertTrue(phase == .cancelled || phase == .queued || phase == .uploading)
    }

    func testCapabilitiesAndProtocolVersion() async throws {
        let runner = FakeRemoteRunner()
        let caps = try await runner.capabilities()
        XCTAssertTrue(caps.modalities.contains(.llm))
        XCTAssertTrue(caps.modelFamilies.contains("fake-remote"))
        XCTAssertEqual(runner.protocolVersion, ProtocolVersions.runnerProtocolVersion)
        XCTAssertFalse(caps.resume)
    }

    func testFetchArtifactsRequiresSucceededOrDownloading() async throws {
        let runner = FakeRemoteRunner(config: .testing)
        let spec = DomainFixtures.llmJobSpec
        let paths = makePaths(jobId: spec.id)

        try await runner.connect()
        let handle = try await runner.submit(job: spec, paths: paths)

        do {
            _ = try await runner.fetchArtifacts(handle: handle, paths: paths)
            XCTFail("expected artifacts unavailable in pending")
        } catch let error as BAMError {
            XCTAssertEqual(error.code, .schemaInvalid)
        }
    }

    func testNoRealCloudKindExists() {
        // v1 only exposes `.fake` — real SSH/cloud kinds must not ship yet.
        XCTAssertEqual(RemoteRunnerKind.allCases, [.fake])
    }

    // MARK: - Helpers

    private func makePaths(jobId: String) -> JobPaths {
        JobPathsFactory.make(jobId: jobId, libraryRoot: tempRoot)
    }

    private func assertPhaseOrder(_ history: [RemoteJobPhase], expected: [RemoteJobPhase]) {
        var searchFrom = history.startIndex
        for phase in expected {
            guard let idx = history[searchFrom...].firstIndex(of: phase) else {
                XCTFail("missing phase \(phase.rawValue) in order; history=\(history.map(\.rawValue))")
                return
            }
            searchFrom = history.index(after: idx)
        }
    }
}
