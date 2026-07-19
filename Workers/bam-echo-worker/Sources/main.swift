import Foundation

/// Protocol-speaking echo worker for CI / golden / supervisor tests (no GPU).
///
/// Modes via `BAM_ECHO_MODE`:
/// - `happy` (default): hello → prepare/run → progress + heartbeat → result succeeded
/// - `cancel`: cooperative cancel via cancel cmd or cancel.flag
/// - `hung`: hello then silence (no heartbeats) for hung detection
/// - `bad_line`: emit a non-JSON line after hello_ok
/// - `mismatch`: emit hello with unsupported protocol version
///
/// Exit codes follow Runner Protocol v1 documentation.

enum EchoMode: String {
    case happy
    case cancel
    case hung
    case badLine = "bad_line"
    case mismatch
}

@main
enum BamEchoWorker {
    static func main() {
        let env = ProcessInfo.processInfo.environment
        let mode = EchoMode(rawValue: env["BAM_ECHO_MODE"] ?? "happy") ?? .happy
        let steps = Int(env["BAM_ECHO_STEPS"] ?? "3") ?? 3
        let stepMs = Int(env["BAM_ECHO_STEP_MS"] ?? "30") ?? 30

        switch mode {
        case .mismatch:
            emit([
                "v": 99,
                "type": "hello",
                "workerId": "bam-echo-worker",
                "workerVersion": "0.1.0",
                "caps": ["modalities": ["llm"], "resume": false] as [String: Any],
            ])
            // Wait briefly for kill, then exit protocol error.
            Thread.sleep(forTimeInterval: 2)
            exit(2)

        case .hung:
            emitHello()
            // Read hello_ok then hang (no heartbeats).
            _ = readLine()
            while true {
                Thread.sleep(forTimeInterval: 1)
            }

        case .badLine:
            emitHello()
            _ = readLine() // hello_ok
            print("this is not json")
            fflush(stdout)
            // Continue reading until killed or cancel.
            while let line = readLine() {
                if lineContainsType(line, "cancel") {
                    emitResult(status: "cancelled")
                    exit(0)
                }
            }
            exit(1)

        case .happy, .cancel:
            emitHello()
            guard let helloOk = readLine(), lineContainsType(helloOk, "hello_ok") else {
                fputs("expected hello_ok\n", stderr)
                exit(2)
            }

            // Background stdin reader sets cancelRequested on cancel commands
            // so the run loop can observe cooperative cancel without select(2).
            let cancelState = CancelState()
            let stdinThread = Thread {
                while let line = readLine() {
                    if lineContainsType(line, "ping") {
                        // Respond from background — supervisor may ping.
                        emitHeartbeat()
                        continue
                    }
                    if lineContainsType(line, "cancel") {
                        cancelState.requested = true
                        continue
                    }
                    if lineContainsType(line, "prepare") {
                        if let paths = extractPaths(line) {
                            cancelState.cancelFlagPath = paths["cancelFlagPath"] as? String
                        }
                        if let job = extractJob(line) {
                            cancelState.jobId = job["id"] as? String ?? cancelState.jobId
                        }
                        cancelState.prepared = true
                        emit([
                            "v": 1,
                            "type": "log",
                            "level": "info",
                            "message": "prepare ok",
                            "ts": isoNow(),
                        ])
                        continue
                    }
                    if lineContainsType(line, "run") || lineContainsType(line, "resume") {
                        if let paths = extractPaths(line) {
                            cancelState.cancelFlagPath = paths["cancelFlagPath"] as? String
                        }
                        cancelState.runRequested = true
                        continue
                    }
                }
            }
            stdinThread.qualityOfService = .userInitiated
            stdinThread.start()

            // Wait for run command.
            let runDeadline = Date().addingTimeInterval(30)
            while !cancelState.runRequested && Date() < runDeadline {
                if cancelState.requested {
                    emitResult(status: "cancelled")
                    exit(0)
                }
                Thread.sleep(forTimeInterval: 0.01)
            }
            guard cancelState.runRequested else {
                fputs("timeout waiting for run\n", stderr)
                exit(2)
            }

            emit([
                "v": 1,
                "type": "log",
                "level": "info",
                "message": "run start",
                "ts": isoNow(),
            ])
            emitHeartbeat()

            for step in 1 ... max(1, steps) {
                if isCancelled(state: cancelState) {
                    emitResult(status: "cancelled")
                    exit(0)
                }

                let epoch = Double(step) / Double(max(1, steps))
                emit([
                    "v": 1,
                    "type": "progress",
                    "step": step,
                    "epoch": epoch,
                    "loss": max(0.1, 2.0 - Double(step) * 0.3),
                    "lr": 0.0001,
                    "tokensPerSec": 100.0 + Double(step),
                    "etaSec": Double(max(0, steps - step)) * Double(stepMs) / 1000.0,
                    "metrics": ["totalSteps": Double(steps)] as [String: Any],
                ])
                emitHeartbeat()

                if step == steps / 2, steps >= 2 {
                    emit([
                        "v": 1,
                        "type": "checkpoint",
                        "path": "checkpoints/step-\(step)",
                        "step": step,
                    ])
                }

                Thread.sleep(forTimeInterval: Double(stepMs) / 1000.0)
            }

            emit([
                "v": 1,
                "type": "artifact",
                "kind": "lora_adapter",
                "path": "artifacts/adapter",
            ])
            emitResult(status: "succeeded", artifacts: [
                ["kind": "lora_adapter", "path": "artifacts/adapter"],
            ])
            exit(0)
        }
    }

    final class CancelState: @unchecked Sendable {
        var requested = false
        var prepared = false
        var runRequested = false
        var cancelFlagPath: String?
        var jobId = "unknown"
    }

    static func isCancelled(state: CancelState) -> Bool {
        if state.requested { return true }
        if let path = state.cancelFlagPath,
           FileManager.default.fileExists(atPath: path)
        {
            return true
        }
        return false
    }

    // MARK: - Helpers

    static func emitHello() {
        emit([
            "v": 1,
            "type": "hello",
            "workerId": "bam-echo-worker",
            "workerVersion": "0.1.0",
            "caps": [
                "modalities": ["llm", "voiceClone"],
                "resume": true,
                "modelFamilies": ["echo", "qwen2.5"],
                "maxSeqLen": 2048,
            ] as [String: Any],
        ])
    }

    static func emitHeartbeat() {
        emit([
            "v": 1,
            "type": "heartbeat",
            "rssBytes": 256 * 1024 * 1024,
            "gpuUtil": 0.1,
            "cpuUtil": 0.2,
            "ts": isoNow(),
        ])
    }

    static func emitResult(status: String, artifacts: [[String: String]] = []) {
        var payload: [String: Any] = [
            "v": 1,
            "type": "result",
            "status": status,
            "artifacts": artifacts,
            "message": NSNull(),
        ]
        if status == "cancelled" {
            payload["message"] = "cancelled"
        }
        emit(payload)
    }

    static func emit(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
              let line = String(data: data, encoding: .utf8)
        else { return }
        print(line)
        fflush(stdout)
    }

    static func isoNow() -> String {
        ISO8601DateFormatter().string(from: Date())
    }

    static func lineContainsType(_ line: String, _ type: String) -> Bool {
        line.contains("\"type\":\"\(type)\"") || line.contains("\"type\": \"\(type)\"")
    }

    static func extractPaths(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let paths = obj["paths"] as? [String: Any]
        else { return nil }
        return paths
    }

    static func extractJob(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let job = obj["job"] as? [String: Any]
        else { return nil }
        return job
    }

    }
