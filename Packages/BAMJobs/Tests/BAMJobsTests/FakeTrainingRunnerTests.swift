import XCTest
import BAMModels
import BAMCore
@testable import BAMJobs

final class FakeTrainingRunnerTests: XCTestCase {
    func testEmitsProgressAndSucceeds() async throws {
        let runner = FakeTrainingRunner(config: .testing)
        let spec = DomainFixtures.llmJobSpec
        let paths = DomainFixtures.llmJobPaths

        try await runner.prepare(job: spec, paths: paths)

        var events: [RunnerEvent] = []
        for try await event in runner.run(job: spec, paths: paths) {
            events.append(event)
        }

        XCTAssertTrue(events.contains { if case .progress = $0 { return true }; return false })
        XCTAssertTrue(events.contains { if case .heartbeat = $0 { return true }; return false })
        XCTAssertTrue(events.contains { if case .result(let s, _, _) = $0 { return s == "succeeded" }; return false })

        // NDJSON encoding produces type field.
        let progress = events.first { $0.typeName == "progress" }!
        let line = try progress.ndjsonLine()
        XCTAssertTrue(line.contains("\"type\":\"progress\""))
        XCTAssertTrue(line.contains("\"v\":1"))
    }

    func testCancelMidRun() async throws {
        let config = FakeRunnerConfig(
            stepCount: 50,
            stepInterval: .milliseconds(30),
            heartbeatEverySteps: 1,
            prepareDelay: .milliseconds(1)
        )
        let runner = FakeTrainingRunner(config: config)
        let spec = DomainFixtures.llmJobSpec
        let paths = DomainFixtures.llmJobPaths
        try await runner.prepare(job: spec, paths: paths)

        var sawCancelled = false
        let stream = runner.run(job: spec, paths: paths)
        var progressCount = 0

        for try await event in stream {
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

        XCTAssertTrue(sawCancelled, "expected cancelled result after cancel()")
        XCTAssertLessThan(progressCount, 50)
    }

    func testCapabilities() async throws {
        let runner = FakeTrainingRunner()
        let caps = try await runner.capabilities()
        XCTAssertTrue(caps.modalities.contains(.llm))
        XCTAssertEqual(runner.protocolVersion, ProtocolVersions.runnerProtocolVersion)
    }
}
