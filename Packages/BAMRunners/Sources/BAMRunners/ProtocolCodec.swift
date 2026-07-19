import BAMCore
import BAMJobs
import BAMModels
import Foundation

/// NDJSON encoder/decoder for Runner Protocol v1 with version negotiation.
public enum ProtocolCodec: Sendable {
    public static let minSupportedVersion = 1
    public static let maxSupportedVersion = 1

    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    public static let decoder: JSONDecoder = {
        JSONDecoder()
    }()

    // MARK: - Encode supervisor → worker

    public static func encodeLine(_ command: SupervisorCommand) throws -> String {
        let dict = try commandDictionary(command)
        let data = try JSONSerialization.data(
            withJSONObject: dict,
            options: [.sortedKeys]
        )
        guard data.count <= RunnerProtocolLimits.maxLineBytes else {
            throw BAMError(
                code: .schemaInvalid,
                message: "Encoded command exceeds max line size (\(data.count) bytes)"
            )
        }
        guard let line = String(data: data, encoding: .utf8) else {
            throw BAMError(code: .schemaInvalid, message: "Failed to UTF-8 encode command")
        }
        return line
    }

    // MARK: - Decode worker → supervisor

    /// Decodes one NDJSON line. Rejects lines over the max size and unknown/mismatched `v`.
    public static func decodeWorkerLine(_ line: String) throws -> WorkerMessage {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw BAMError(code: .schemaInvalid, message: "Empty protocol line")
        }
        let utf8Count = trimmed.utf8.count
        guard utf8Count <= RunnerProtocolLimits.maxLineBytes else {
            throw BAMError(
                code: .workerCrash,
                message: "Protocol line exceeds \(RunnerProtocolLimits.maxLineBytes) bytes"
            )
        }
        guard let data = trimmed.data(using: .utf8) else {
            throw BAMError(code: .schemaInvalid, message: "Protocol line is not UTF-8")
        }

        let obj: [String: Any]
        do {
            guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw BAMError(code: .schemaInvalid, message: "Protocol line is not a JSON object")
            }
            obj = parsed
        } catch let error as BAMError {
            throw error
        } catch {
            throw BAMError(
                code: .schemaInvalid,
                message: "Invalid JSON: \(error.localizedDescription)"
            )
        }

        let v = (obj["v"] as? Int) ?? (obj["v"] as? NSNumber)?.intValue
        guard let v else {
            throw BAMError(code: .protocolMismatch, message: "Missing protocol version `v`")
        }
        try negotiate(workerVersion: v)

        guard let type = obj["type"] as? String else {
            throw BAMError(code: .schemaInvalid, message: "Missing message `type`")
        }

        return try parseWorkerMessage(type: type, obj: obj, v: v, data: data)
    }

    /// Version negotiation: worker `v` must fall within supervisor min/max.
    public static func negotiate(workerVersion: Int) throws {
        guard workerVersion >= minSupportedVersion, workerVersion <= maxSupportedVersion else {
            throw BAMError(
                code: .protocolMismatch,
                message:
                    "Unsupported protocol version \(workerVersion) (supported \(minSupportedVersion)...\(maxSupportedVersion))"
            )
        }
    }

    // MARK: - Internals

    private static func commandDictionary(_ command: SupervisorCommand) throws -> [String: Any] {
        switch command {
        case let .helloOk(minV, maxV):
            return [
                "v": runnerProtocolV,
                "type": "hello_ok",
                "minV": minV,
                "maxV": maxV,
            ]
        case let .prepare(job, paths):
            return try jobPathsEnvelope(type: "prepare", job: job, paths: paths)
        case let .run(job, paths):
            return try jobPathsEnvelope(type: "run", job: job, paths: paths)
        case let .resume(job, paths, checkpoint):
            var env = try jobPathsEnvelope(type: "resume", job: job, paths: paths)
            env["checkpoint"] = [
                "path": checkpoint.path,
                "step": checkpoint.step,
            ]
            return env
        case let .cancel(jobId):
            return [
                "v": runnerProtocolV,
                "type": "cancel",
                "jobId": jobId,
            ]
        case .ping:
            return [
                "v": runnerProtocolV,
                "type": "ping",
            ]
        }
    }

    private static func jobPathsEnvelope(
        type: String,
        job: JobSpec,
        paths: JobPaths
    ) throws -> [String: Any] {
        let jobData = try encoder.encode(job)
        let pathsData = try encoder.encode(paths)
        guard
            let jobObj = try JSONSerialization.jsonObject(with: jobData) as? [String: Any],
            let pathsObj = try JSONSerialization.jsonObject(with: pathsData) as? [String: Any]
        else {
            throw BAMError(code: .schemaInvalid, message: "Failed to reify job/paths JSON")
        }
        return [
            "v": runnerProtocolV,
            "type": type,
            "job": jobObj,
            "paths": pathsObj,
        ]
    }

    private static func parseWorkerMessage(
        type: String,
        obj: [String: Any],
        v: Int,
        data: Data
    ) throws -> WorkerMessage {
        switch type {
        case "hello":
            let workerId = obj["workerId"] as? String ?? "unknown"
            let workerVersion = obj["workerVersion"] as? String ?? "0"
            let caps = parseCapabilities(obj["caps"] as? [String: Any] ?? [:])
            return .hello(
                workerId: workerId,
                workerVersion: workerVersion,
                caps: caps,
                v: v
            )

        case "log":
            return .log(
                level: obj["level"] as? String ?? "info",
                message: obj["message"] as? String ?? "",
                ts: obj["ts"] as? String ?? ""
            )

        case "progress":
            let step = intValue(obj["step"]) ?? 0
            let epoch = doubleValue(obj["epoch"]) ?? 0
            var metrics: [String: Double] = [:]
            if let m = obj["metrics"] as? [String: Any] {
                for (k, val) in m {
                    if let d = doubleValue(val) { metrics[k] = d }
                }
            }
            return .progress(
                step: step,
                epoch: epoch,
                loss: doubleValue(obj["loss"]),
                lr: doubleValue(obj["lr"]),
                tokensPerSec: doubleValue(obj["tokensPerSec"]),
                etaSec: doubleValue(obj["etaSec"]),
                metrics: metrics
            )

        case "checkpoint":
            return .checkpoint(
                path: obj["path"] as? String ?? "",
                step: intValue(obj["step"]) ?? 0
            )

        case "artifact":
            return .artifact(
                kind: obj["kind"] as? String ?? "",
                path: obj["path"] as? String ?? ""
            )

        case "heartbeat":
            return .heartbeat(
                rssBytes: int64Value(obj["rssBytes"]) ?? 0,
                gpuUtil: doubleValue(obj["gpuUtil"]),
                cpuUtil: doubleValue(obj["cpuUtil"]),
                ts: obj["ts"] as? String ?? ""
            )

        case "error":
            return .error(
                code: obj["code"] as? String ?? BAMErrorCode.workerCrash.rawValue,
                message: obj["message"] as? String ?? "",
                retriable: (obj["retriable"] as? Bool) ?? false
            )

        case "result":
            var artifacts: [RunnerArtifactRef] = []
            if let arr = obj["artifacts"] as? [[String: Any]] {
                for item in arr {
                    artifacts.append(
                        RunnerArtifactRef(
                            kind: item["kind"] as? String ?? "",
                            path: item["path"] as? String ?? ""
                        )
                    )
                }
            }
            let message: String?
            if obj["message"] is NSNull {
                message = nil
            } else {
                message = obj["message"] as? String
            }
            return .result(
                status: obj["status"] as? String ?? "failed",
                artifacts: artifacts,
                message: message
            )

        default:
            throw BAMError(
                code: .schemaInvalid,
                message: "Unknown worker message type: \(type)"
            )
        }
    }

    /// Lenient caps parse — missing optional fields use defaults (wire may omit).
    private static func parseCapabilities(_ capsObj: [String: Any]) -> RunnerCapabilities {
        let modalityStrings = capsObj["modalities"] as? [String] ?? []
        let modalities = modalityStrings.compactMap { JobModality(rawValue: $0) }
        let resume = (capsObj["resume"] as? Bool) ?? false
        let modelFamilies = capsObj["modelFamilies"] as? [String] ?? []
        let maxSeqLen = intValue(capsObj["maxSeqLen"])
        let engineIds = capsObj["engineIds"] as? [String]
        return RunnerCapabilities(
            modalities: modalities,
            resume: resume,
            modelFamilies: modelFamilies,
            maxSeqLen: maxSeqLen,
            engineIds: engineIds
        )
    }

    private static func intValue(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let n = any as? NSNumber { return n.intValue }
        if let d = any as? Double { return Int(d) }
        return nil
    }

    private static func int64Value(_ any: Any?) -> Int64? {
        if let i = any as? Int64 { return i }
        if let i = any as? Int { return Int64(i) }
        if let n = any as? NSNumber { return n.int64Value }
        return nil
    }

    private static func doubleValue(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        if let n = any as? NSNumber { return n.doubleValue }
        return nil
    }
}
