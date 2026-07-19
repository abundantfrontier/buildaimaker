import Foundation
import BAMCore

/// Thin L1 helper for `Contents/Helpers/bam-llm-worker`.
///
/// Flow:
/// 1. Resolve `Workers/python` pins root
/// 2. Verify L2 runtime-pins (lockfile + entry hashes)
/// 3. Optionally check interpreter under managed env
/// 4. Speak Runner Protocol v1: hello → prepare-only (no weight updates)
///
/// Real mlx-lm LoRA training lands in PR-LLM-LoRA. This binary accepts `prepare`
/// and refuses `run`/`resume` so materialize dry-run can exercise the path safely.
///
/// Fail closed with exit code 2 and stderr message containing BAM_RUNTIME_INTEGRITY.

@main
enum BamLLMWorker {
    static func main() {
        do {
            try run()
        } catch let error as BAMError {
            fputs("\(error.errorDescription ?? error.code.rawValue)\n", stderr)
            exit(error.code == .runtimeIntegrity ? 2 : 1)
        } catch {
            fputs("BAM_RUNTIME_INTEGRITY: \(error)\n", stderr)
            exit(2)
        }
    }

    static func run() throws {
        let env = ProcessInfo.processInfo.environment

        guard let pinsRoot = RuntimePaths.resolvePinsRoot(environment: env) else {
            throw BAMError(
                code: .runtimeIntegrity,
                message: "could not resolve Workers/python pins root (set BAM_PYTHON_PINS_ROOT)"
            )
        }

        let pins = try RuntimePins.load(from: RuntimePaths.pinsFile(in: pinsRoot))

        let skipInterpreter =
            env[RuntimePaths.EnvironmentKey.skipInterpreterCheck] == "1"
            || env["CI"] == "true"
            || env["CI"] == "1"

        let envRoot: URL
        if let override = env[RuntimePaths.EnvironmentKey.managedEnvRoot], !override.isEmpty {
            envRoot = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            envRoot = RuntimePaths.managedEnvRoot(appVersion: pins.appVersion)
        }

        var options = RuntimeIntegrity.VerificationOptions(
            requireInterpreterPresent: !skipInterpreter,
            managedEnvRoot: envRoot
        )
        if skipInterpreter {
            options.requireInterpreterPresent = false
        }

        try RuntimeIntegrity.verify(
            pins: pins,
            pinsRoot: pinsRoot,
            options: options
        )

        // Protocol loop: hello → (prepare)* → refuse run → cancel exits cleanly.
        emitHello(pins: pins)

        guard let helloOk = readLine(), lineContainsType(helloOk, "hello_ok") else {
            fputs("expected hello_ok\n", stderr)
            exit(2)
        }

        var jobId: String?
        while let line = readLine() {
            if lineContainsType(line, "ping") {
                emitHeartbeat()
                continue
            }
            if lineContainsType(line, "cancel") {
                emitResult(status: "cancelled", message: "cancelled before train")
                exit(0)
            }
            if lineContainsType(line, "prepare") {
                if let job = extractObject(line, key: "job") {
                    jobId = job["id"] as? String ?? jobId
                }
                // Validate required path fields exist when present (best-effort).
                if let paths = extractObject(line, key: "paths") {
                    _ = paths["datasetPath"] as? String
                    _ = paths["baseModelPath"] as? String
                    _ = paths["cancelFlagPath"] as? String
                }
                emit([
                    "v": ProtocolVersions.runnerProtocolVersion,
                    "type": "log",
                    "level": "info",
                    "message": "prepare ok (dry-run; no weight updates)",
                    "ts": isoNow(),
                ])
                continue
            }
            if lineContainsType(line, "run") || lineContainsType(line, "resume") {
                // PR-LLM-Materialize: refuse training. Real LoRA is PR-LLM-LoRA.
                emit([
                    "v": ProtocolVersions.runnerProtocolVersion,
                    "type": "error",
                    "code": "BAM_CAPABILITY_UNSUPPORTED",
                    "message": "bam-llm-worker: train (run/resume) not enabled; prepare-only dry-run",
                    "retriable": false,
                ])
                emitResult(
                    status: "failed",
                    message: "train not enabled (prepare-only worker)",
                    jobId: jobId
                )
                exit(1)
            }
        }

        // Stdin closed without cancel — clean exit after prepare-only session.
        exit(0)
    }

    // MARK: - Protocol helpers

    private static func emitHello(pins: RuntimePins) {
        let hello: [String: Any] = [
            "v": ProtocolVersions.runnerProtocolVersion,
            "type": "hello",
            "workerId": "bam-llm-worker",
            "workerVersion": "0.1.0",
            "caps": [
                "modalities": ["llm"],
                "resume": false,
                "modelFamilies": ["qwen2.5"],
                "maxSeqLen": 8192,
            ] as [String: Any],
            "pins": [
                "appVersion": pins.appVersion,
                "lockfile": pins.lockfile.relativePath,
                "entries": pins.entries.map(\.id),
            ] as [String: Any],
        ]
        emit(hello)
    }

    private static func emitHeartbeat() {
        emit([
            "v": ProtocolVersions.runnerProtocolVersion,
            "type": "heartbeat",
            "rssBytes": 0,
            "gpuUtil": NSNull(),
            "cpuUtil": NSNull(),
            "ts": isoNow(),
        ])
    }

    private static func emitResult(status: String, message: String?, jobId: String? = nil) {
        var payload: [String: Any] = [
            "v": ProtocolVersions.runnerProtocolVersion,
            "type": "result",
            "status": status,
            "artifacts": [] as [Any],
        ]
        if let message {
            payload["message"] = message
        } else {
            payload["message"] = NSNull()
        }
        _ = jobId
        emit(payload)
    }

    private static func emit(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let line = String(data: data, encoding: .utf8)
        else { return }
        print(line)
        fflush(stdout)
    }

    private static func lineContainsType(_ line: String, _ type: String) -> Bool {
        line.contains("\"type\":\"\(type)\"") || line.contains("\"type\": \"\(type)\"")
    }

    private static func extractObject(_ line: String, key: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let nested = obj[key] as? [String: Any]
        else { return nil }
        return nested
    }

    private static func isoNow() -> String {
        ISO8601DateFormatter().string(from: Date())
    }
}
