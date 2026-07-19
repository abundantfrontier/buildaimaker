import BAMCore
import BAMJobs
import BAMModels
import BAMRunners
import Foundation

/// Result of a prepare-only dry-run against an mlx-lm worker (or echo worker).
public struct MLXDryRunResult: Sendable, Equatable {
    public var materialize: LLMMaterializeResult
    public var workerId: String?
    public var capabilities: RunnerCapabilities?
    public var prepareLogMessages: [String]
    /// Always false for this PR — dry-run never starts weight updates.
    public var didTrain: Bool
    public var workerExecutablePath: String

    public init(
        materialize: LLMMaterializeResult,
        workerId: String?,
        capabilities: RunnerCapabilities?,
        prepareLogMessages: [String],
        didTrain: Bool = false,
        workerExecutablePath: String
    ) {
        self.materialize = materialize
        self.workerId = workerId
        self.capabilities = capabilities
        self.prepareLogMessages = prepareLogMessages
        self.didTrain = didTrain
        self.workerExecutablePath = workerExecutablePath
    }
}

/// mlx-lm worker client: job materialization + **prepare only** (no `run` / weight updates).
///
/// Wraps `ProcessSupervisor` with a hard guarantee that `run` / `resume` are never sent.
public actor MLXWorkerClient {
    public let executableURL: URL
    public let arguments: [String]
    public let config: ProcessSupervisorConfig
    public let materializer: JobMaterializer

    public init(
        executableURL: URL,
        arguments: [String] = [],
        config: ProcessSupervisorConfig = ProcessSupervisorConfig(),
        materializer: JobMaterializer = JobMaterializer()
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.config = config
        self.materializer = materializer
    }

    /// Materialize job dir then invoke worker `prepare` only. Never sends `run`.
    public func dryRun(request: LLMMaterializeRequest) async throws -> MLXDryRunResult {
        let materialized = try materializer.materialize(request)

        let supervisor = ProcessSupervisor(
            executableURL: executableURL,
            arguments: arguments,
            config: config
        )

        let caps = try await supervisor.start(paths: materialized.paths)
        // Prepare only — no weight updates (run/resume intentionally omitted).
        try await supervisor.prepare(job: materialized.spec, paths: materialized.paths)

        // Brief pause so workers can emit prepare log lines before we tear down.
        try? await Task.sleep(for: .milliseconds(50))

        // Tear down without writing cancel.flag — dry-run must leave job layout
        // re-runnable (not in a cancelled filesystem state). Prefer SIGTERM/SIGKILL.
        await Self.shutdownDryRun(
            supervisor: supervisor,
            cancelFlagPath: materialized.paths.cancelFlagPath,
            timeout: max(config.cancelGraceT1 + config.cancelGraceT2 + 0.5, 1)
        )

        return MLXDryRunResult(
            materialize: materialized,
            workerId: await supervisor.lastWorkerId,
            capabilities: caps,
            prepareLogMessages: ["prepare sent (run not invoked; dry-run)"],
            didTrain: false,
            workerExecutablePath: executableURL.path
        )
    }

    /// Stops the worker without `CancelFlag.write`. Clears any flag that might exist.
    private static func shutdownDryRun(
        supervisor: ProcessSupervisor,
        cancelFlagPath: String,
        timeout: TimeInterval
    ) async {
        // Never leave a cancelled layout after prepare-only dry-run.
        CancelFlag.clear(at: cancelFlagPath)
        await supervisor.signalTerminate()
        _ = await supervisor.waitUntilExit(timeout: timeout)
        if await supervisor.isRunning {
            await supervisor.forceKill()
            _ = await supervisor.waitUntilExit(timeout: 0.5)
        }
        CancelFlag.clear(at: cancelFlagPath)
    }

    /// Materialize only (no worker process). Useful for Validate without a built helper.
    public nonisolated func materializeOnly(
        request: LLMMaterializeRequest
    ) throws -> LLMMaterializeResult {
        try materializer.materialize(request)
    }

    // MARK: - Worker resolution

    /// Resolves a worker binary for dry-run: env override → bam-llm-worker → bam-echo-worker.
    public static func resolveWorkerExecutable(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) throws -> URL {
        if let override = environment["BAM_LLM_WORKER_PATH"] ?? environment["BAM_ECHO_WORKER_PATH"],
           !override.isEmpty
        {
            let url = URL(fileURLWithPath: override)
            guard fileManager.isExecutableFile(atPath: url.path)
                || fileManager.fileExists(atPath: url.path)
            else {
                throw BAMError(
                    code: .runtimeIntegrity,
                    message: "Worker override not found: \(override)"
                )
            }
            return url
        }

        if let llm = WorkerSpawn.resolveDevelopmentHelper(
            named: WorkerSpawn.llmWorkerName,
            environment: environment,
            fileManager: fileManager
        ) {
            return llm
        }

        // Fall back to echo worker (CI-friendly prepare protocol speaker).
        if let echo = resolveBuildProduct(
            named: "bam-echo-worker",
            environment: environment,
            fileManager: fileManager
        ) {
            return echo
        }

        throw BAMError(
            code: .runtimeIntegrity,
            message:
                "No worker binary found (bam-llm-worker / bam-echo-worker). Run `swift build` or set BAM_LLM_WORKER_PATH."
        )
    }

    private static func resolveBuildProduct(
        named name: String,
        environment: [String: String],
        fileManager: FileManager
    ) -> URL? {
        let cwd = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
        var dir = cwd
        for _ in 0 ..< 10 {
            for config in ["debug", "release"] {
                let candidates = [
                    dir.appendingPathComponent(".build/\(config)/\(name)"),
                    dir.appendingPathComponent(".build/arm64-apple-macosx/\(config)/\(name)"),
                    dir.appendingPathComponent(".build/x86_64-apple-macosx/\(config)/\(name)"),
                ]
                for c in candidates
                where fileManager.isExecutableFile(atPath: c.path)
                    || fileManager.fileExists(atPath: c.path)
                {
                    return c
                }
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        _ = environment
        return nil
    }
}
