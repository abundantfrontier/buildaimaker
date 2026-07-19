import BAMCore
import BAMJobs
import BAMModels
import Foundation

/// Wire protocol version currently spoken by this package.
public let runnerProtocolV: Int = ProtocolVersions.runnerProtocolVersion

// MARK: - Supervisor → Worker commands

/// Commands the supervisor writes to the worker's stdin (NDJSON).
public enum SupervisorCommand: Sendable, Equatable {
    case helloOk(minV: Int, maxV: Int)
    case prepare(job: JobSpec, paths: JobPaths)
    case run(job: JobSpec, paths: JobPaths)
    case resume(job: JobSpec, paths: JobPaths, checkpoint: CheckpointRef)
    case cancel(jobId: String)
    case ping

    public var typeName: String {
        switch self {
        case .helloOk: return "hello_ok"
        case .prepare: return "prepare"
        case .run: return "run"
        case .resume: return "resume"
        case .cancel: return "cancel"
        case .ping: return "ping"
        }
    }
}

// MARK: - Worker → Supervisor messages

/// Messages the worker emits on stdout (NDJSON).
public enum WorkerMessage: Sendable, Equatable {
    case hello(
        workerId: String,
        workerVersion: String,
        caps: RunnerCapabilities,
        v: Int
    )
    case log(level: String, message: String, ts: String)
    case progress(
        step: Int,
        epoch: Double,
        loss: Double?,
        lr: Double?,
        tokensPerSec: Double?,
        etaSec: Double?,
        metrics: [String: Double]
    )
    case checkpoint(path: String, step: Int)
    case artifact(kind: String, path: String)
    case heartbeat(rssBytes: Int64, gpuUtil: Double?, cpuUtil: Double?, ts: String)
    case error(code: String, message: String, retriable: Bool)
    case result(status: String, artifacts: [RunnerArtifactRef], message: String?)

    public var typeName: String {
        switch self {
        case .hello: return "hello"
        case .log: return "log"
        case .progress: return "progress"
        case .checkpoint: return "checkpoint"
        case .artifact: return "artifact"
        case .heartbeat: return "heartbeat"
        case .error: return "error"
        case .result: return "result"
        }
    }

    /// Maps wire events used by the queue controller onto `RunnerEvent`.
    /// Returns `nil` for `hello` (handshake-only).
    public func asRunnerEvent() -> RunnerEvent? {
        switch self {
        case .hello:
            return nil
        case let .log(level, message, ts):
            return .log(level: level, message: message, ts: ts)
        case let .progress(step, epoch, loss, lr, tokensPerSec, etaSec, metrics):
            return .progress(
                step: step,
                epoch: epoch,
                loss: loss,
                lr: lr,
                tokensPerSec: tokensPerSec,
                etaSec: etaSec,
                metrics: metrics
            )
        case let .checkpoint(path, step):
            return .checkpoint(path: path, step: step)
        case let .artifact(kind, path):
            return .artifact(kind: kind, path: path)
        case let .heartbeat(rssBytes, gpuUtil, cpuUtil, ts):
            return .heartbeat(rssBytes: rssBytes, gpuUtil: gpuUtil, cpuUtil: cpuUtil, ts: ts)
        case let .error(code, message, retriable):
            return .error(code: code, message: message, retriable: retriable)
        case let .result(status, artifacts, message):
            return .result(status: status, artifacts: artifacts, message: message)
        }
    }
}
