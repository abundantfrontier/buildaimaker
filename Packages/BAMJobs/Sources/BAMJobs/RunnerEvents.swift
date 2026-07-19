import BAMCore
import BAMModels
import Foundation

/// Capability advertisement (mirrors worker `hello.caps`; full wire protocol in PR-Protocol).
public struct RunnerCapabilities: Codable, Sendable, Equatable {
    public var modalities: [JobModality]
    public var resume: Bool
    public var modelFamilies: [String]
    public var maxSeqLen: Int?
    public var engineIds: [String]?

    public init(
        modalities: [JobModality],
        resume: Bool = false,
        modelFamilies: [String] = [],
        maxSeqLen: Int? = nil,
        engineIds: [String]? = nil
    ) {
        self.modalities = modalities
        self.resume = resume
        self.modelFamilies = modelFamilies
        self.maxSeqLen = maxSeqLen
        self.engineIds = engineIds
    }
}

/// Checkpoint reference for resume (not used by fake runner success path).
public struct CheckpointRef: Codable, Sendable, Equatable {
    public var path: String
    public var step: Int

    public init(path: String, step: Int) {
        self.path = path
        self.step = step
    }
}

/// Result artifact announced by a runner.
public struct RunnerArtifactRef: Codable, Sendable, Equatable {
    public var kind: String
    public var path: String

    public init(kind: String, path: String) {
        self.kind = kind
        self.path = path
    }
}

/// NDJSON-shaped runner events (subset used by queue + fake runner).
///
/// Full catalog and process supervisor land in PR-Protocol / BAMRunners.
public enum RunnerEvent: Sendable, Equatable {
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

    /// Wire-style type string (`progress`, `heartbeat`, …).
    public var typeName: String {
        switch self {
        case .log: return "log"
        case .progress: return "progress"
        case .checkpoint: return "checkpoint"
        case .artifact: return "artifact"
        case .heartbeat: return "heartbeat"
        case .error: return "error"
        case .result: return "result"
        }
    }

    /// Encodes one NDJSON protocol line (`v:1` + type + fields).
    public func ndjsonLine(encoder: JSONEncoder = RunnerEvent.defaultEncoder) throws -> String {
        let payload = asDictionary()
        let data = try encoder.encode(AnyCodableDictionary(payload))
        guard let line = String(data: data, encoding: .utf8) else {
            throw BAMError(code: .schemaInvalid, message: "Failed to UTF-8 encode runner event")
        }
        return line
    }

    public static let defaultEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    private func asDictionary() -> [String: AnyCodable] {
        var d: [String: AnyCodable] = [
            "v": AnyCodable(1),
            "type": AnyCodable(typeName),
        ]
        switch self {
        case let .log(level, message, ts):
            d["level"] = AnyCodable(level)
            d["message"] = AnyCodable(message)
            d["ts"] = AnyCodable(ts)
        case let .progress(step, epoch, loss, lr, tokensPerSec, etaSec, metrics):
            d["step"] = AnyCodable(step)
            d["epoch"] = AnyCodable(epoch)
            if let loss { d["loss"] = AnyCodable(loss) }
            if let lr { d["lr"] = AnyCodable(lr) }
            if let tokensPerSec { d["tokensPerSec"] = AnyCodable(tokensPerSec) }
            if let etaSec { d["etaSec"] = AnyCodable(etaSec) }
            if !metrics.isEmpty {
                d["metrics"] = AnyCodable(metrics.mapValues { AnyCodable($0) })
            }
        case let .checkpoint(path, step):
            d["path"] = AnyCodable(path)
            d["step"] = AnyCodable(step)
        case let .artifact(kind, path):
            d["kind"] = AnyCodable(kind)
            d["path"] = AnyCodable(path)
        case let .heartbeat(rssBytes, gpuUtil, cpuUtil, ts):
            d["rssBytes"] = AnyCodable(rssBytes)
            if let gpuUtil { d["gpuUtil"] = AnyCodable(gpuUtil) }
            if let cpuUtil { d["cpuUtil"] = AnyCodable(cpuUtil) }
            d["ts"] = AnyCodable(ts)
        case let .error(code, message, retriable):
            d["code"] = AnyCodable(code)
            d["message"] = AnyCodable(message)
            d["retriable"] = AnyCodable(retriable)
        case let .result(status, artifacts, message):
            d["status"] = AnyCodable(status)
            d["artifacts"] = AnyCodable(
                artifacts.map { ["kind": AnyCodable($0.kind), "path": AnyCodable($0.path)] }
            )
            if let message { d["message"] = AnyCodable(message) }
        }
        return d
    }
}

// MARK: - Minimal AnyCodable for NDJSON encoding

struct AnyCodable: Encodable, @unchecked Sendable {
    let value: Any

    init(_ value: Any) {
        self.value = value
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case let v as String: try container.encode(v)
        case let v as Int: try container.encode(v)
        case let v as Int64: try container.encode(v)
        case let v as Double: try container.encode(v)
        case let v as Bool: try container.encode(v)
        case let v as [String: AnyCodable]: try container.encode(v)
        case let v as [AnyCodable]: try container.encode(v)
        case let v as [[String: AnyCodable]]: try container.encode(v)
        default:
            throw EncodingError.invalidValue(
                value,
                .init(codingPath: encoder.codingPath, debugDescription: "Unsupported AnyCodable")
            )
        }
    }
}

struct AnyCodableDictionary: Encodable {
    let value: [String: AnyCodable]
    init(_ value: [String: AnyCodable]) { self.value = value }
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: DynamicKey.self)
        for (k, v) in value {
            try container.encode(v, forKey: DynamicKey(stringValue: k)!)
        }
    }
}

struct DynamicKey: CodingKey {
    var stringValue: String
    init?(stringValue: String) { self.stringValue = stringValue }
    var intValue: Int? { nil }
    init?(intValue: Int) { nil }
}

// MARK: - Live progress snapshot (UI / controller)

/// Aggregated live progress for a running job (last progress + heartbeat).
public struct JobProgressSnapshot: Sendable, Equatable {
    public var step: Int
    public var epoch: Double
    public var loss: Double?
    public var lr: Double?
    public var tokensPerSec: Double?
    public var etaSec: Double?
    public var rssBytes: Int64?
    public var gpuUtil: Double?
    public var cpuUtil: Double?
    public var message: String?
    /// Total planned steps when known (from progress metrics `totalSteps`).
    public var totalSteps: Int?

    public init(
        step: Int = 0,
        epoch: Double = 0,
        loss: Double? = nil,
        lr: Double? = nil,
        tokensPerSec: Double? = nil,
        etaSec: Double? = nil,
        rssBytes: Int64? = nil,
        gpuUtil: Double? = nil,
        cpuUtil: Double? = nil,
        message: String? = nil,
        totalSteps: Int? = nil
    ) {
        self.step = step
        self.epoch = epoch
        self.loss = loss
        self.lr = lr
        self.tokensPerSec = tokensPerSec
        self.etaSec = etaSec
        self.rssBytes = rssBytes
        self.gpuUtil = gpuUtil
        self.cpuUtil = cpuUtil
        self.message = message
        self.totalSteps = totalSteps
    }

    /// Fraction complete in `0...1` when `totalSteps` is known.
    public var fractionComplete: Double? {
        guard let totalSteps, totalSteps > 0 else { return nil }
        return min(1, max(0, Double(step) / Double(totalSteps)))
    }

    public mutating func apply(_ event: RunnerEvent) {
        switch event {
        case let .progress(step, epoch, loss, lr, tokensPerSec, etaSec, metrics):
            self.step = step
            self.epoch = epoch
            self.loss = loss
            self.lr = lr
            self.tokensPerSec = tokensPerSec
            self.etaSec = etaSec
            if let total = metrics["totalSteps"] {
                self.totalSteps = Int(total)
            }
        case let .heartbeat(rssBytes, gpuUtil, cpuUtil, _):
            self.rssBytes = rssBytes
            self.gpuUtil = gpuUtil
            self.cpuUtil = cpuUtil
        case let .log(_, message, _):
            self.message = message
        default:
            break
        }
    }
}
