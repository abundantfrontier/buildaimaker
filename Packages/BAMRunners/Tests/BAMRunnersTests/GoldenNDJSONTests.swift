import BAMCore
import BAMJobs
import BAMModels
import XCTest

@testable import BAMRunners

/// Golden NDJSON transcript fixtures for Runner Protocol v1 (no GPU).
///
/// Fixtures live under `Packages/BAMRunners/Tests/BAMRunnersTests/Fixtures/`.
final class GoldenNDJSONTests: XCTestCase {
    func testHappyPathTranscript() throws {
        let lines = try loadFixture("happy_path.ndjson")
        XCTAssertGreaterThanOrEqual(lines.count, 5)

        var types: [String] = []
        for line in lines {
            let msg = try ProtocolCodec.decodeWorkerLine(line)
            types.append(msg.typeName)
            // Every line negotiates v1.
            _ = msg
        }
        XCTAssertEqual(types.first, "hello")
        XCTAssertTrue(types.contains("progress"))
        XCTAssertTrue(types.contains("heartbeat"))
        XCTAssertEqual(types.last, "result")

        let last = try ProtocolCodec.decodeWorkerLine(lines.last!)
        guard case let .result(status, artifacts, _) = last else {
            return XCTFail("last must be result")
        }
        XCTAssertEqual(status, "succeeded")
        XCTAssertFalse(artifacts.isEmpty)
    }

    func testCancelMidRunTranscript() throws {
        let lines = try loadFixture("cancel_mid_run.ndjson")
        var sawProgress = false
        var resultStatus: String?
        for line in lines {
            let msg = try ProtocolCodec.decodeWorkerLine(line)
            if case .progress = msg { sawProgress = true }
            if case let .result(status, _, _) = msg { resultStatus = status }
        }
        XCTAssertTrue(sawProgress)
        XCTAssertEqual(resultStatus, "cancelled")
    }

    func testHungHeartbeatTranscriptShape() throws {
        // Hung scenario: hello + one heartbeat, then silence (no result).
        let lines = try loadFixture("hung_heartbeat.ndjson")
        XCTAssertEqual(lines.count, 2)
        let hello = try ProtocolCodec.decodeWorkerLine(lines[0])
        guard case .hello = hello else { return XCTFail("hello") }
        let hb = try ProtocolCodec.decodeWorkerLine(lines[1])
        guard case .heartbeat = hb else { return XCTFail("heartbeat") }
    }

    func testBadLineRejected() throws {
        let lines = try loadFixture("bad_line.ndjson")
        // First line is valid hello; second is garbage.
        _ = try ProtocolCodec.decodeWorkerLine(lines[0])
        XCTAssertThrowsError(try ProtocolCodec.decodeWorkerLine(lines[1])) { error in
            XCTAssertEqual((error as? BAMError)?.code, .schemaInvalid)
        }
    }

    func testProtocolMismatchFixture() throws {
        let lines = try loadFixture("protocol_mismatch.ndjson")
        XCTAssertThrowsError(try ProtocolCodec.decodeWorkerLine(lines[0])) { error in
            XCTAssertEqual((error as? BAMError)?.code, .protocolMismatch)
        }
    }

    func testSupervisorCommandsFixtureRoundTrip() throws {
        // Supervisor-side golden: encode commands match expected type field.
        let job = DomainFixtures.llmJobSpec
        let paths = DomainFixtures.llmJobPaths
        let commands: [SupervisorCommand] = [
            .helloOk(minV: 1, maxV: 1),
            .prepare(job: job, paths: paths),
            .run(job: job, paths: paths),
            .resume(job: job, paths: paths, checkpoint: CheckpointRef(path: "checkpoints/step-1", step: 1)),
            .cancel(jobId: job.id),
            .ping,
        ]
        let expected = ["hello_ok", "prepare", "run", "resume", "cancel", "ping"]
        for (cmd, type) in zip(commands, expected) {
            let line = try ProtocolCodec.encodeLine(cmd)
            let data = try XCTUnwrap(line.data(using: .utf8))
            let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(obj["type"] as? String, type)
            XCTAssertEqual(obj["v"] as? Int, 1)
        }
    }

    // MARK: - Fixture loading

    private func loadFixture(_ name: String) throws -> [String] {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: name.replacingOccurrences(of: ".ndjson", with: ""), withExtension: "ndjson")
                ?? fixtureURLOnDisk(name)
        )
        let text = try String(contentsOf: url, encoding: .utf8)
        return text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
    }

    /// Fallback when Bundle.module resources are not yet wired.
    private func fixtureURLOnDisk(_ name: String) -> URL? {
        let thisFile = URL(fileURLWithPath: #filePath)
        let dir = thisFile.deletingLastPathComponent().appendingPathComponent("Fixtures")
        let url = dir.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}
