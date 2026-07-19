import BAMCore
import BAMJobs
import BAMModels
import XCTest

@testable import BAMRunners

final class ProtocolCodecTests: XCTestCase {
    func testEncodeHelloOk() throws {
        let line = try ProtocolCodec.encodeLine(.helloOk(minV: 1, maxV: 1))
        XCTAssertTrue(line.contains("\"type\":\"hello_ok\"") || line.contains("\"type\" : \"hello_ok\""))
        XCTAssertTrue(line.contains("\"v\":1") || line.contains("\"v\" : 1"))
    }

    func testEncodePrepareRoundTripShape() throws {
        let job = DomainFixtures.llmJobSpec
        let paths = DomainFixtures.llmJobPaths
        let line = try ProtocolCodec.encodeLine(.prepare(job: job, paths: paths))
        let data = try XCTUnwrap(line.data(using: .utf8))
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["type"] as? String, "prepare")
        XCTAssertNotNil(obj["job"] as? [String: Any])
        XCTAssertNotNil(obj["paths"] as? [String: Any])
        let pathsObj = try XCTUnwrap(obj["paths"] as? [String: Any])
        // referenceAudioPath encoded as JSON null for LLM jobs.
        XCTAssertTrue(pathsObj["referenceAudioPath"] is NSNull || pathsObj["referenceAudioPath"] == nil)
    }

    func testDecodeHello() throws {
        let line = """
        {"v":1,"type":"hello","workerId":"bam-llm-worker","workerVersion":"0.1.0","caps":{"modalities":["llm"],"resume":true,"modelFamilies":["qwen2.5"],"maxSeqLen":8192}}
        """
        let msg = try ProtocolCodec.decodeWorkerLine(line)
        guard case let .hello(id, ver, caps, v) = msg else {
            return XCTFail("expected hello")
        }
        XCTAssertEqual(id, "bam-llm-worker")
        XCTAssertEqual(ver, "0.1.0")
        XCTAssertEqual(v, 1)
        XCTAssertEqual(caps.modalities, [.llm])
        XCTAssertTrue(caps.resume)
        XCTAssertEqual(caps.maxSeqLen, 8192)
    }

    func testDecodeProgressAndResult() throws {
        let progress =
            #"{"v":1,"type":"progress","step":12,"epoch":0.4,"loss":1.02,"lr":0.0001,"tokensPerSec":120.5,"etaSec":600,"metrics":{}}"#
        let p = try ProtocolCodec.decodeWorkerLine(progress)
        guard case let .progress(step, epoch, loss, _, _, _, _) = p else {
            return XCTFail("progress")
        }
        XCTAssertEqual(step, 12)
        XCTAssertEqual(epoch, 0.4, accuracy: 0.0001)
        XCTAssertEqual(loss, 1.02)

        let result =
            #"{"v":1,"type":"result","status":"succeeded","artifacts":[{"kind":"lora_adapter","path":"artifacts/adapter"}],"message":null}"#
        let r = try ProtocolCodec.decodeWorkerLine(result)
        guard case let .result(status, artifacts, message) = r else {
            return XCTFail("result")
        }
        XCTAssertEqual(status, "succeeded")
        XCTAssertEqual(artifacts.count, 1)
        XCTAssertNil(message)
    }

    func testProtocolMismatchOnBadVersion() {
        let line = #"{"v":99,"type":"hello","workerId":"x","workerVersion":"0","caps":{"modalities":["llm"],"resume":false}}"#
        XCTAssertThrowsError(try ProtocolCodec.decodeWorkerLine(line)) { error in
            XCTAssertEqual((error as? BAMError)?.code, .protocolMismatch)
        }
    }

    func testBadJSONLine() {
        XCTAssertThrowsError(try ProtocolCodec.decodeWorkerLine("not-json")) { error in
            XCTAssertEqual((error as? BAMError)?.code, .schemaInvalid)
        }
    }

    func testNegotiateBounds() {
        XCTAssertNoThrow(try ProtocolCodec.negotiate(workerVersion: 1))
        XCTAssertThrowsError(try ProtocolCodec.negotiate(workerVersion: 0)) { error in
            XCTAssertEqual((error as? BAMError)?.code, .protocolMismatch)
        }
        XCTAssertThrowsError(try ProtocolCodec.negotiate(workerVersion: 2)) { error in
            XCTAssertEqual((error as? BAMError)?.code, .protocolMismatch)
        }
    }

    func testEncodeCancelAndPing() throws {
        let cancel = try ProtocolCodec.encodeLine(.cancel(jobId: "abc"))
        XCTAssertTrue(cancel.contains("cancel"))
        XCTAssertTrue(cancel.contains("abc"))
        let ping = try ProtocolCodec.encodeLine(.ping)
        XCTAssertTrue(ping.contains("ping"))
    }

    func testAsRunnerEventMapping() throws {
        let line =
            #"{"v":1,"type":"heartbeat","rssBytes":123,"gpuUtil":0.5,"cpuUtil":0.1,"ts":"t"}"#
        let msg = try ProtocolCodec.decodeWorkerLine(line)
        let event = try XCTUnwrap(msg.asRunnerEvent())
        guard case let .heartbeat(rss, gpu, cpu, ts) = event else {
            return XCTFail("heartbeat event")
        }
        XCTAssertEqual(rss, 123)
        XCTAssertEqual(gpu, 0.5)
        XCTAssertEqual(cpu, 0.1)
        XCTAssertEqual(ts, "t")
    }

    func testWorkerExitCodesDocumented() {
        XCTAssertEqual(WorkerExitCode.success.rawValue, 0)
        XCTAssertEqual(WorkerExitCode.handledFailure.rawValue, 1)
        XCTAssertEqual(WorkerExitCode.protocolError.rawValue, 2)
        XCTAssertEqual(WorkerExitCode.sigterm.rawValue, 130)
        XCTAssertEqual(WorkerExitCode.sigkill.rawValue, 137)
        // Design lists 130; Process.terminate() on macOS is typically 143.
        XCTAssertEqual(WorkerExitCode.classify(130), .sigterm)
        XCTAssertEqual(WorkerExitCode.classify(143), .sigterm)
        XCTAssertEqual(WorkerExitCode.posixSigtermStatus, 143)
        // Spike CLI license block is not a supervised worker exit.
        XCTAssertEqual(WorkerExitCode.spikeCLILicenseBlockStatus, 3)
        XCTAssertNil(WorkerExitCode.classify(3))
        for code in WorkerExitCode.allCases {
            XCTAssertFalse(code.meaning.isEmpty)
        }
    }

    func testMissingRequiredFieldsRejected() {
        let cases = [
            #"{"v":1,"type":"hello","workerVersion":"0","caps":{}}"#, // missing workerId
            #"{"v":1,"type":"progress","epoch":1.0}"#, // missing step
            #"{"v":1,"type":"heartbeat","rssBytes":1}"#, // missing ts
            #"{"v":1,"type":"result","status":"succeeded"}"#, // missing artifacts
            #"{"v":1,"type":"result","status":"weird","artifacts":[]}"#, // bad status
            #"{"v":1,"type":"error","message":"x"}"#, // missing code
        ]
        for line in cases {
            XCTAssertThrowsError(try ProtocolCodec.decodeWorkerLine(line), line) { error in
                let code = (error as? BAMError)?.code
                XCTAssertTrue(
                    code == .schemaInvalid || code == .protocolMismatch,
                    "expected schema/protocol error for \(line), got \(String(describing: error))"
                )
            }
        }
    }

    func testArtifactMetaRetainedOnWorkerMessage() throws {
        let line =
            #"{"v":1,"type":"artifact","kind":"lora_adapter","path":"artifacts/adapter","meta":{"rank":"16"}}"#
        let msg = try ProtocolCodec.decodeWorkerLine(line)
        guard case let .artifact(kind, path, meta) = msg else {
            return XCTFail("artifact")
        }
        XCTAssertEqual(kind, "lora_adapter")
        XCTAssertEqual(path, "artifacts/adapter")
        XCTAssertEqual(meta?["rank"], "16")
        // RunnerEvent mapping drops meta in v1.
        let event = try XCTUnwrap(msg.asRunnerEvent())
        guard case let .artifact(ek, ep) = event else {
            return XCTFail("runner artifact")
        }
        XCTAssertEqual(ek, kind)
        XCTAssertEqual(ep, path)
    }
}
