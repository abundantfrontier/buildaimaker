import Foundation
import BAMCore

/// Thin L1 helper for `Contents/Helpers/bam-llm-worker`.
///
/// Flow:
/// 1. Resolve `Workers/python` pins root
/// 2. Verify L2 runtime-pins (lockfile + entry hashes)
/// 3. Optionally check interpreter under managed env
/// 4. Prefer real Python `llm_worker` when mlx-lm is available and not forced fake
/// 5. Else speak Runner Protocol v1 with **CI-safe fake LoRA train** that writes
///    stub adapter + model card (hold-out loss + sample gens — K25)
///
/// Fake train is selected when:
/// - `BAM_LORA_FAKE=1`, or
/// - managed Python / mlx-lm is unavailable (typical CI), or
/// - `CI=true` without an explicit real-runtime override
///
/// Real path: exec managed `python` on `llm_worker/main.py` (see Workers/python/README.md).
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

        let forceFake = shouldForceFake(env: env)
        if !forceFake, let python = resolveManagedPython(envRoot: envRoot, env: env) {
            // Hand off protocol + train to Python entry (real mlx-lm path when installed).
            try execPythonWorker(python: python, pinsRoot: pinsRoot, env: env)
            // exec never returns on success
        }

        // CI-safe / dogfood-without-wheels path: native protocol speaker + stub adapter.
        runNativeProtocolLoop(forceFake: true, pins: pins)
    }

    // MARK: - Fake / real selection

    static func shouldForceFake(env: [String: String]) -> Bool {
        if env["BAM_LORA_FAKE"] == "1" { return true }
        if env["BAM_LORA_REAL"] == "1" { return false }
        // Default: fake when CI or skip-interpreter (no multi-GB wheels).
        if env["CI"] == "true" || env["CI"] == "1" { return true }
        if env[RuntimePaths.EnvironmentKey.skipInterpreterCheck] == "1" { return true }
        return false
    }

    static func resolveManagedPython(envRoot: URL, env: [String: String]) -> URL? {
        if let override = env["BAM_PYTHON_BIN"], !override.isEmpty {
            let url = URL(fileURLWithPath: override)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        let candidates = [
            envRoot.appendingPathComponent("bin/python3"),
            envRoot.appendingPathComponent("bin/python"),
        ]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c.path) {
            return c
        }
        return nil
    }

    /// Replace process with Python protocol worker. Does not return on success.
    static func execPythonWorker(python: URL, pinsRoot: URL, env: [String: String]) throws {
        let entry = pinsRoot.appendingPathComponent("llm_worker/main.py")
        guard FileManager.default.fileExists(atPath: entry.path) else {
            throw BAMError(
                code: .runtimeIntegrity,
                message: "llm_worker entry missing: \(entry.path)"
            )
        }

        // Prefer exec so stdin/stdout stay the protocol pipes.
        let process = Process()
        process.executableURL = python
        process.arguments = [entry.path]
        process.standardInput = FileHandle.standardInput
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        var childEnv = env
        childEnv["PYTHONPATH"] = pinsRoot.path
        childEnv["BAM_PYTHON_PINS_ROOT"] = pinsRoot.path
        process.environment = childEnv
        try process.run()
        process.waitUntilExit()
        exit(process.terminationStatus)
    }

    // MARK: - Native protocol (fake train)

    static func runNativeProtocolLoop(forceFake: Bool, pins: RuntimePins) {
        emitHello(pins: pins, resume: false)

        guard let helloOk = readLine(), lineContainsType(helloOk, "hello_ok") else {
            fputs("expected hello_ok\n", stderr)
            exit(2)
        }

        var job: [String: Any]?
        var paths: [String: Any]?
        var cancelRequested = false

        // Background cancel/ping reader shares state with the run loop.
        let state = WorkerState()
        let stdinThread = Thread {
            while let line = readLine() {
                if lineContainsType(line, "ping") {
                    emitHeartbeat()
                    continue
                }
                if lineContainsType(line, "cancel") {
                    state.cancelRequested = true
                    cancelRequested = true
                    continue
                }
                if lineContainsType(line, "prepare") {
                    if let j = extractObject(line, key: "job") {
                        state.job = j
                        job = j
                    }
                    if let p = extractObject(line, key: "paths") {
                        state.paths = p
                        paths = p
                    }
                    state.prepared = true
                    emit([
                        "v": ProtocolVersions.runnerProtocolVersion,
                        "type": "log",
                        "level": "info",
                        "message": "prepare ok (native; forceFake=\(forceFake))",
                        "ts": isoNow(),
                    ])
                    continue
                }
                if lineContainsType(line, "run") || lineContainsType(line, "resume") {
                    if let p = extractObject(line, key: "paths") {
                        state.paths = p
                        paths = p
                    }
                    if let j = extractObject(line, key: "job") {
                        state.job = j
                        job = j
                    }
                    state.runRequested = true
                    continue
                }
            }
        }
        stdinThread.qualityOfService = .userInitiated
        stdinThread.start()

        // Wait for run (or cancel) with timeout.
        let runDeadline = Date().addingTimeInterval(120)
        while !state.runRequested && Date() < runDeadline {
            if state.cancelRequested || cancelRequested {
                emitResult(status: "cancelled", message: "cancelled before train")
                exit(0)
            }
            Thread.sleep(forTimeInterval: 0.01)
        }

        if !state.runRequested {
            // Prepare-only session (dry-run): stdin closed or timeout without run.
            exit(0)
        }

        runFakeTrain(job: state.job ?? job, paths: state.paths ?? paths, state: state)
    }

    final class WorkerState: @unchecked Sendable {
        var cancelRequested = false
        var prepared = false
        var runRequested = false
        var job: [String: Any]?
        var paths: [String: Any]?
    }

    static func runFakeTrain(job: [String: Any]?, paths: [String: Any]?, state: WorkerState) {
        emit([
            "v": ProtocolVersions.runnerProtocolVersion,
            "type": "log",
            "level": "info",
            "message": "fake LoRA train start (BAM_LORA_FAKE / mlx-lm unavailable)",
            "ts": isoNow(),
        ])
        emitHeartbeat()

        let steps = 3
        var lastLoss = 1.5
        for step in 1 ... steps {
            if isCancelled(state: state, paths: paths) {
                emitResult(status: "cancelled", message: "cancelled")
                exit(0)
            }
            let epoch = Double(step) / Double(steps)
            lastLoss = max(0.2, 1.5 - Double(step) * 0.25)
            emit([
                "v": ProtocolVersions.runnerProtocolVersion,
                "type": "progress",
                "step": step,
                "epoch": epoch,
                "loss": lastLoss,
                "lr": 0.0001,
                "tokensPerSec": 50.0 + Double(step),
                "etaSec": Double(steps - step) * 0.05,
                "metrics": [
                    "totalSteps": Double(steps),
                    "holdOutLoss": 1.25,
                    "fake": 1.0,
                ] as [String: Any],
            ])
            emitHeartbeat()
            Thread.sleep(forTimeInterval: 0.02)
        }

        // Write stub adapter + model card under job artifacts/adapter.
        let holdOut = 1.25
        do {
            try writeStubAdapter(job: job, paths: paths, trainLoss: lastLoss, holdOutLoss: holdOut)
        } catch {
            emit([
                "v": ProtocolVersions.runnerProtocolVersion,
                "type": "error",
                "code": "BAM_SCHEMA_INVALID",
                "message": "failed to write stub adapter: \(error)",
                "retriable": false,
            ])
            emitResult(status: "failed", message: "stub adapter write failed")
            exit(1)
        }

        emit([
            "v": ProtocolVersions.runnerProtocolVersion,
            "type": "artifact",
            "kind": "lora_adapter",
            "path": "artifacts/adapter",
            "meta": [
                "fake": "1",
                "holdOutLoss": String(holdOut),
            ] as [String: String],
        ])
        emitResult(
            status: "succeeded",
            message: "fake LoRA train complete",
            artifacts: [["kind": "lora_adapter", "path": "artifacts/adapter"]]
        )
        exit(0)
    }

    static func isCancelled(state: WorkerState, paths: [String: Any]?) -> Bool {
        if state.cancelRequested { return true }
        if let flag = paths?["cancelFlagPath"] as? String,
           FileManager.default.fileExists(atPath: flag)
        {
            return true
        }
        return false
    }

    static func writeStubAdapter(
        job: [String: Any]?,
        paths: [String: Any]?,
        trainLoss: Double,
        holdOutLoss: Double
    ) throws {
        let fm = FileManager.default
        let outputPath = paths?["outputPath"] as? String
        let jobDir = paths?["jobDir"] as? String
        let adapterDir: URL
        if let outputPath {
            adapterDir = URL(fileURLWithPath: outputPath, isDirectory: true)
                .appendingPathComponent("adapter", isDirectory: true)
        } else if let jobDir {
            adapterDir = URL(fileURLWithPath: jobDir, isDirectory: true)
                .appendingPathComponent("artifacts/adapter", isDirectory: true)
        } else {
            adapterDir = URL(fileURLWithPath: "artifacts/adapter", isDirectory: true)
        }

        try fm.createDirectory(at: adapterDir, withIntermediateDirectories: true)

        let rank = ((job?["hyperparameters"] as? [String: Any])?["loraRank"] as? Int) ?? 16
        let alpha = ((job?["hyperparameters"] as? [String: Any])?["loraAlpha"] as? Int) ?? 32
        let baseKey = job?["baseModelSourceKey"] as? String ?? ""
        let jobId = job?["id"] as? String ?? "unknown"

        let config: [String: Any] = [
            "peft_type": "LORA",
            "r": rank,
            "lora_alpha": alpha,
            "target_modules": ["q_proj", "v_proj"],
            "base_model_name_or_path": baseKey,
            "bam_fake": true,
        ]
        let configData = try JSONSerialization.data(
            withJSONObject: config,
            options: [.sortedKeys, .prettyPrinted]
        )
        try configData.write(
            to: adapterDir.appendingPathComponent("adapter_config.json"),
            options: .atomic
        )
        try Data("BAM_LORA_STUB\n".utf8).write(
            to: adapterDir.appendingPathComponent("adapters.safetensors"),
            options: .atomic
        )

        let metrics: [String: Any] = [
            "method": "lora",
            "fakeTrain": true,
            "trainLoss": trainLoss,
            "holdOutLoss": holdOutLoss,
            "jobId": jobId,
            "sampleGenerationCount": 2,
            "sampleGenerations": [
                [
                    "prompt": "Hello!",
                    "completion": "Hi — this is a stub generation from a CI-safe LoRA adapter.",
                ],
                [
                    "prompt": "Summarize BuildAIMaker in one sentence.",
                    "completion":
                        "BuildAIMaker is a local-first Mac app for LoRA fine-tunes and voice personas.",
                ],
            ],
        ]
        let metricsData = try JSONSerialization.data(
            withJSONObject: metrics,
            options: [.sortedKeys, .prettyPrinted]
        )
        try metricsData.write(
            to: adapterDir.appendingPathComponent("metrics.json"),
            options: .atomic
        )

        let card = """
            # Model Card — LoRA Adapter

            ## Identity

            - Method: `lora`
            - Job id: `\(jobId)`
            - Base model source: `\(baseKey)`
            - Train mode: **fake** (`BAM_LORA_FAKE` or mlx-lm unavailable)

            ## Hyperparameters

            rank=\(rank), alpha=\(alpha)

            ## Evaluation (MVP / K25)

            Job “done” for MVP = **hold-out validation loss** (when available) + **sample generations**.

            - Final train loss: `\(String(format: "%.6f", trainLoss))`
            - Hold-out validation loss: `\(String(format: "%.6f", holdOutLoss))`

            ### Sample generations

            1. **Prompt:** Hello!
               **Completion:** Hi — this is a stub generation from a CI-safe LoRA adapter.

            2. **Prompt:** Summarize BuildAIMaker in one sentence.
               **Completion:** BuildAIMaker is a local-first Mac app for LoRA fine-tunes and voice personas.

            ## Notes

            - Produced by CI-safe fake train (`BAM_LORA_FAKE=1` or mlx-lm missing).
            - Replace with real mlx-lm adapter when the managed training runtime is installed.

            ## Artifacts

            - `adapter_config.json`
            - `adapters.safetensors` (weights; stub in fake mode)
            - `metrics.json`
            - `model_card.md` (this file)
            """
        try Data(card.utf8).write(
            to: adapterDir.appendingPathComponent("model_card.md"),
            options: .atomic
        )
    }

    // MARK: - Protocol helpers

    private static func emitHello(pins: RuntimePins, resume: Bool) {
        let hello: [String: Any] = [
            "v": ProtocolVersions.runnerProtocolVersion,
            "type": "hello",
            "workerId": "bam-llm-worker",
            "workerVersion": "0.2.0",
            "caps": [
                "modalities": ["llm"],
                "resume": resume,
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

    private static func emitResult(
        status: String,
        message: String?,
        artifacts: [[String: String]] = []
    ) {
        var payload: [String: Any] = [
            "v": ProtocolVersions.runnerProtocolVersion,
            "type": "result",
            "status": status,
            "artifacts": artifacts,
        ]
        if let message {
            payload["message"] = message
        } else {
            payload["message"] = NSNull()
        }
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
