import BAMCore
import Foundation

/// Optional real generate path via `python -m mlx_lm.generate` when available.
///
/// Availability is probed once; on failure (missing env / module / weights) the
/// factory falls back to `EchoLLMBackend`. CI never requires this backend.
public struct MLXGenerateBackend: LLMBackend, Sendable {
    public static let id = "mlx-generate"

    public var backendId: String { Self.id }

    /// Python interpreter to use (managed env preferred).
    public var pythonURL: URL
    /// Soft timeout for a single generate call (seconds).
    public var timeoutSeconds: TimeInterval

    public init(
        pythonURL: URL,
        timeoutSeconds: TimeInterval = 180
    ) {
        self.pythonURL = pythonURL
        self.timeoutSeconds = timeoutSeconds
    }

    public func complete(_ request: LLMCompletionRequest) async throws -> LLMCompletionResult {
        guard let basePath = request.baseModelPath, !basePath.isEmpty else {
            throw BAMError(code: .modelNotFound, message: "Base model path required for mlx-generate.")
        }

        // Full transcript for Gemma's native chat template (not last-user-only).
        let packed = ChatPromptFormatter.messagesForMLXChat(request.messages)
        let fallbackUser = ChatPromptFormatter.lastUserMessage(from: request.messages)
            ?? ChatPromptFormatter.format(
                templateId: request.templateId,
                messages: request.messages
            )
        var messagesJSON: String?
        if packed.count >= 1 {
            let data = try JSONSerialization.data(withJSONObject: packed)
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("bam-mlx-messages-\(UUID().uuidString).json")
            try data.write(to: url, options: .atomic)
            messagesJSON = url.path
        }

        let start = Date()
        defer {
            if let messagesJSON {
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: messagesJSON))
            }
        }
        let output = try await Self.runGenerate(
            python: pythonURL,
            modelPath: basePath,
            adapterPath: request.effectiveAdapterPath,
            prompt: fallbackUser,
            systemPrompt: messagesJSON == nil
                ? ChatPromptFormatter.systemPrompt(from: request.messages)
                : nil,
            messagesJSONPath: messagesJSON,
            maxTokens: request.maxTokens,
            timeoutSeconds: timeoutSeconds
        )
        let elapsed = Date().timeIntervalSince(start) * 1000

        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw BAMError(
                code: .capabilityUnsupported,
                message: "mlx-lm generate returned empty output."
            )
        }

        return LLMCompletionResult(
            assistantMessage: .assistant(text),
            backendId: backendId,
            latencyMs: elapsed,
            isStub: false,
            detail: nil
        )
    }

    // MARK: - Availability

    /// True when a usable Python with `mlx_lm` is found (managed env or override).
    ///
    /// Never calls `Process.waitUntilExit` on the main thread: that pumps the
    /// run loop and can abort SwiftUI (`AG::precondition_failure` in layout).
    public static func isAvailable(
        pythonURL: URL? = nil,
        fileManager: FileManager = .default
    ) -> Bool {
        offMainIfNeeded {
            isAvailableUncachedOnWorker(pythonURL: pythonURL, fileManager: fileManager)
        }
    }

    private static let cacheLock = NSLock()
    private static var cachedPythonPath: String?
    private static var cachedAvailable: Bool?

    /// Call after Settings Repair so Train re-probes the venv.
    public static func invalidateAvailabilityCache() {
        cacheLock.lock()
        cachedPythonPath = nil
        cachedAvailable = nil
        cacheLock.unlock()
    }

    private static func isAvailableUncachedOnWorker(
        pythonURL: URL?,
        fileManager: FileManager
    ) -> Bool {
        guard let python = pythonURL ?? resolvePython(fileManager: fileManager) else {
            return false
        }
        cacheLock.lock()
        if cachedPythonPath == python.path, let cachedAvailable {
            cacheLock.unlock()
            return cachedAvailable
        }
        cacheLock.unlock()

        let ok = probeMLXLM(python: python)
        cacheLock.lock()
        cachedPythonPath = python.path
        cachedAvailable = ok
        cacheLock.unlock()
        return ok
    }

    /// Preferred managed interpreter when present and executable.
    public static func resolvePython(
        appVersion: String = RuntimePaths.spikeAppVersion,
        fileManager: FileManager = .default
    ) -> URL? {
        let managed = RuntimePaths.managedInterpreter(appVersion: appVersion)
        if fileManager.isExecutableFile(atPath: managed.path) {
            return managed
        }
        // Dev fallback: `python3` on PATH (still must pass probe).
        if let pathPython = which("python3", fileManager: fileManager) {
            return pathPython
        }
        return nil
    }

    public static func makeIfAvailable(
        timeoutSeconds: TimeInterval = 180,
        fileManager: FileManager = .default
    ) -> MLXGenerateBackend? {
        offMainIfNeeded {
            guard let python = resolvePython(fileManager: fileManager),
                  isAvailableUncachedOnWorker(pythonURL: python, fileManager: fileManager)
            else {
                return nil
            }
            return MLXGenerateBackend(pythonURL: python, timeoutSeconds: timeoutSeconds)
        }
    }

    /// `Process.waitUntilExit` pumps the main run loop; never call it on main.
    private static func offMainIfNeeded<T>(_ body: () -> T) -> T {
        if Thread.isMainThread {
            var value: T!
            DispatchQueue.global(qos: .userInitiated).sync {
                value = body()
            }
            return value
        }
        return body()
    }

    // MARK: - Process helpers

    private static func probeMLXLM(python: URL) -> Bool {
        let process = Process()
        process.executableURL = python
        process.arguments = ["-c", "import mlx_lm"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private static func which(
        _ name: String,
        fileManager: FileManager
    ) -> URL? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [name]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let path = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !path.isEmpty, fileManager.isExecutableFile(atPath: path) else { return nil }
            return URL(fileURLWithPath: path)
        } catch {
            return nil
        }
    }

    private static func runGenerate(
        python: URL,
        modelPath: String,
        adapterPath: String?,
        prompt: String,
        systemPrompt: String?,
        messagesJSONPath: String?,
        maxTokens: Int,
        timeoutSeconds: TimeInterval
    ) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let text = try runGenerateSync(
                        python: python,
                        modelPath: modelPath,
                        adapterPath: adapterPath,
                        prompt: prompt,
                        systemPrompt: systemPrompt,
                        messagesJSONPath: messagesJSONPath,
                        maxTokens: maxTokens,
                        timeoutSeconds: timeoutSeconds
                    )
                    continuation.resume(returning: text)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func runGenerateSync(
        python: URL,
        modelPath: String,
        adapterPath: String?,
        prompt: String,
        systemPrompt: String?,
        messagesJSONPath: String?,
        maxTokens: Int,
        timeoutSeconds: TimeInterval
    ) throws -> String {
        let launcher = try resolveGenerateLauncher()
        var args = [
            launcher.path,
            "--model", modelPath,
            "--prompt", prompt,
            "--max-tokens", String(maxTokens),
        ]
        if let messagesJSONPath, !messagesJSONPath.isEmpty {
            args.append(contentsOf: ["--messages-json", messagesJSONPath])
        } else if let systemPrompt, !systemPrompt.isEmpty {
            args.append(contentsOf: ["--system-prompt", systemPrompt])
        }
        if let adapterPath, !adapterPath.isEmpty {
            // mlx-lm accepts --adapter-path when LoRA adapters are present.
            args.append(contentsOf: ["--adapter-path", adapterPath])
        }

        let process = Process()
        process.executableURL = python
        process.arguments = args
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        try process.run()

        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            throw BAMError(
                code: .workerHung,
                message: "mlx-lm generate timed out after \(Int(timeoutSeconds))s."
            )
        }

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        let stdout = String(data: outData, encoding: .utf8) ?? ""
        let stderr = String(data: errData, encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            let snippet = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw BAMError(
                code: .workerCrash,
                message: humanizeGenerateFailure(
                    status: process.terminationStatus,
                    stderr: snippet
                )
            )
        }

        // mlx_lm.generate prints ========== generation ========== then stats.
        return extractGeneration(stdout: stdout, prompt: prompt)
    }

    /// Prefer the repo/bundle helper; otherwise write the same Gemma 4 patch to temp.
    private static func resolveGenerateLauncher() throws -> URL {
        if let pins = RuntimePaths.resolvePinsRoot() {
            let script = pins
                .appendingPathComponent("llm_worker", isDirectory: true)
                .appendingPathComponent("generate_cli.py", isDirectory: false)
            if FileManager.default.fileExists(atPath: script.path) {
                return script
            }
        }
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("bam-run-mlx-generate.py", isDirectory: false)
        try embeddedGenerateLauncher.write(to: dest, atomically: true, encoding: .utf8)
        return dest
    }

    private static func humanizeGenerateFailure(status: Int32, stderr: String) -> String {
        let low = stderr.lowercased()
        if low.contains("gemma4_unified")
            || (low.contains("model type") && low.contains("not supported"))
        {
            return "This Gemma 4 file isn’t recognized by stock mlx-lm generate. BAM should use its compatibility helper — restart the app after updating."
        }
        if low.contains("vision") && low.contains("not in model") {
            return "This Gemma 4 file includes picture weights. Chat now skips those and uses the text part — retry."
        }
        return "mlx-lm generate failed (status \(status)): \(stderr.prefix(400))"
    }

    /// Fallback when Workers/python is not next to the binary. Prefer generate_cli.py.
    private static let embeddedGenerateLauncher = """
        import json, sys
        from pathlib import Path
        from mlx_lm import utils as _u
        getattr(_u, "MODEL_REMAPPING", {}).setdefault("gemma4_unified", "gemma4")
        from mlx_lm.models import gemma4 as _g4
        _orig = _g4.Model.sanitize
        def _sanitize(self, weights):
            cleaned = {}
            for key, value in weights.items():
                tail = key[6:] if key.startswith("model.") else key
                head = tail.split(".", 1)[0]
                if head.startswith(("vision", "audio", "multi_modal", "multimodal")):
                    continue
                cleaned[key] = value
            return _orig(self, cleaned)
        _g4.Model.sanitize = _sanitize
        argv = sys.argv
        if "--messages-json" in argv:
            i = argv.index("--messages-json")
            path = argv[i + 1]
            argv = argv[:i] + argv[i + 2:]
            model = argv[argv.index("--model") + 1]
            messages = json.loads(Path(path).read_text())
            from transformers import AutoTokenizer
            tok = AutoTokenizer.from_pretrained(model, trust_remote_code=True, local_files_only=True)
            try:
                prompt = tok.apply_chat_template(messages, tokenize=False, add_generation_prompt=True, enable_thinking=False)
            except TypeError:
                prompt = tok.apply_chat_template(messages, tokenize=False, add_generation_prompt=True)
            if "--prompt" in argv:
                argv[argv.index("--prompt") + 1] = prompt
            else:
                argv[1:1] = ["--prompt", prompt]
            if "--system-prompt" in argv:
                j = argv.index("--system-prompt")
                argv = argv[:j] + argv[j + 2:]
            argv[1:1] = ["--ignore-chat-template"]
            sys.argv = argv
        elif "--chat-template-config" not in argv:
            argv[1:1] = ["--chat-template-config", '{"enable_thinking": false}']
            sys.argv = argv
        from mlx_lm.generate import main as _main
        _main()
        """

    /// Pull the generated block out of mlx_lm.generate's banner + stats.
    private static func extractGeneration(stdout: String, prompt: String) -> String {
        let lines = stdout.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var banners: [Int] = []
        for (index, line) in lines.enumerated() where line.trimmingCharacters(in: .whitespaces) == "==========" {
            banners.append(index)
        }
        if banners.count >= 2, banners[0] + 1 < banners[1] {
            let body = lines[(banners[0] + 1)..<banners[1]]
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty { return stripThoughtChannel(body) }
        }
        return stripThoughtChannel(stripPromptEcho(stdout: stdout, prompt: prompt))
    }

    private static func stripThoughtChannel(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("<|channel>thought") else { return trimmed }
        if let end = trimmed.range(of: "<channel|>") {
            return String(trimmed[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }

    /// Best-effort: if stdout contains the prompt, return the suffix after it.
    private static func stripPromptEcho(stdout: String, prompt: String) -> String {
        if let range = stdout.range(of: prompt) {
            let after = stdout[range.upperBound...]
            return String(after).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
