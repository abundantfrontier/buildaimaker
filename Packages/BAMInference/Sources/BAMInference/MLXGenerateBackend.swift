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
        timeoutSeconds: TimeInterval = 60
    ) {
        self.pythonURL = pythonURL
        self.timeoutSeconds = timeoutSeconds
    }

    public func complete(_ request: LLMCompletionRequest) async throws -> LLMCompletionResult {
        guard let basePath = request.baseModelPath, !basePath.isEmpty else {
            throw BAMError(code: .modelNotFound, message: "Base model path required for mlx-generate.")
        }

        let prompt = ChatPromptFormatter.format(
            templateId: request.templateId,
            messages: request.messages
        )

        let start = Date()
        let output = try await Self.runGenerate(
            python: pythonURL,
            modelPath: basePath,
            adapterPath: request.effectiveAdapterPath,
            prompt: prompt,
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
    public static func isAvailable(
        pythonURL: URL? = nil,
        fileManager: FileManager = .default
    ) -> Bool {
        guard let python = pythonURL ?? resolvePython(fileManager: fileManager) else {
            return false
        }
        return probeMLXLM(python: python)
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
        timeoutSeconds: TimeInterval = 60,
        fileManager: FileManager = .default
    ) -> MLXGenerateBackend? {
        guard let python = resolvePython(fileManager: fileManager),
              probeMLXLM(python: python)
        else {
            return nil
        }
        return MLXGenerateBackend(pythonURL: python, timeoutSeconds: timeoutSeconds)
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
        maxTokens: Int,
        timeoutSeconds: TimeInterval
    ) throws -> String {
        var args = [
            "-m", "mlx_lm.generate",
            "--model", modelPath,
            "--prompt", prompt,
            "--max-tokens", String(maxTokens),
        ]
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
                message: "mlx-lm generate failed (status \(process.terminationStatus)): \(snippet.prefix(400))"
            )
        }

        // mlx_lm.generate prints the prompt + generation; take the last non-empty block.
        return stripPromptEcho(stdout: stdout, prompt: prompt)
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
