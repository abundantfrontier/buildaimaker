import Foundation
import BAMCore

/// Thin L1 helper stub for `Contents/Helpers/bam-llm-worker`.
///
/// Flow (spike):
/// 1. Resolve `Workers/python` pins root
/// 2. Verify L2 runtime-pins (lockfile + entry hashes)
/// 3. Optionally check interpreter under managed env
/// 4. Print JSON `hello` and exit 0 (no real Python exec in CI)
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
        // Spike / CI: still allowlist the path when skip is set, without requiring file.
        if skipInterpreter {
            options.requireInterpreterPresent = false
        }

        try RuntimeIntegrity.verify(
            pins: pins,
            pinsRoot: pinsRoot,
            options: options
        )

        // Real path: exec managed python -m llm_worker …
        // Spike: emit hello JSON compatible with runner protocol v1 and exit.
        let hello: [String: Any] = [
            "v": ProtocolVersions.runnerProtocolVersion,
            "type": "hello",
            "workerId": "bam-llm-worker",
            "workerVersion": "0.1.0",
            "caps": [
                "modalities": ["llm"],
                "resume": true,
                "modelFamilies": ["qwen2.5"],
                "maxSeqLen": 8192,
            ] as [String: Any],
            "pins": [
                "appVersion": pins.appVersion,
                "lockfile": pins.lockfile.relativePath,
                "entries": pins.entries.map(\.id),
            ] as [String: Any],
        ]

        let data = try JSONSerialization.data(withJSONObject: hello, options: [.sortedKeys])
        if let line = String(data: data, encoding: .utf8) {
            print(line)
        }
        exit(0)
    }
}
