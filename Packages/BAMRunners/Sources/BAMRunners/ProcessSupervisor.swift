import BAMCore
import BAMJobs
import BAMModels
import Foundation

/// Configuration for process supervision (defaults match design; tests shorten timeouts).
public struct ProcessSupervisorConfig: Sendable, Equatable {
    public var helloDeadline: TimeInterval
    public var heartbeatTimeout: TimeInterval
    public var cancelGraceT1: TimeInterval
    public var cancelGraceT2: TimeInterval
    public var maxLineBytes: Int
    /// Extra environment variables for the worker process.
    public var extraEnvironment: [String: String]
    /// When true, supervisor polls cancel.flag and escalates signals after grace.
    public var escalateSignalsOnCancel: Bool

    public init(
        helloDeadline: TimeInterval = RunnerProtocolLimits.helloDeadlineSeconds,
        heartbeatTimeout: TimeInterval = RunnerProtocolLimits.heartbeatTimeoutSeconds,
        cancelGraceT1: TimeInterval = RunnerProtocolLimits.cancelGraceT1Seconds,
        cancelGraceT2: TimeInterval = RunnerProtocolLimits.cancelGraceT2Seconds,
        maxLineBytes: Int = RunnerProtocolLimits.maxLineBytes,
        extraEnvironment: [String: String] = [:],
        escalateSignalsOnCancel: Bool = true
    ) {
        self.helloDeadline = helloDeadline
        self.heartbeatTimeout = heartbeatTimeout
        self.cancelGraceT1 = cancelGraceT1
        self.cancelGraceT2 = cancelGraceT2
        self.maxLineBytes = maxLineBytes
        self.extraEnvironment = extraEnvironment
        self.escalateSignalsOnCancel = escalateSignalsOnCancel
    }

    /// Fast timeouts for unit tests.
    public static let testing = ProcessSupervisorConfig(
        helloDeadline: 5,
        heartbeatTimeout: 2,
        cancelGraceT1: 0.3,
        cancelGraceT2: 0.2,
        escalateSignalsOnCancel: true
    )
}

/// Launches a worker helper, speaks Runner Protocol v1 over NDJSON stdin/stdout,
/// enforces path jail, cancel.flag, hung-heartbeat detection, and signal escalation.
public actor ProcessSupervisor {
    public let executableURL: URL
    public let arguments: [String]
    public let config: ProcessSupervisorConfig

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var readTask: Task<Void, Never>?
    private var cancelEscalationTask: Task<Void, Never>?
    private var stderrTask: Task<Void, Never>?

    private var lineBuffer = Data()
    private var pendingLines: [String] = []
    private var lineContinuations: [UUID: CheckedContinuation<String?, Never>] = [:]
    private var processExited = false
    private var exitStatus: Int32?
    private var lastHeartbeatAt: Date?
    private var negotiatedCaps: RunnerCapabilities?
    private var workerId: String?
    private var stderrLogURL: URL?
    private var lineTooLarge = false
    /// Last job id seen on prepare/run/resume (for flag-only cancel cmd).
    private var lastJobId: String?
    /// Whether cancel stdin command was already sent for the current generation.
    private var cancelCommandSent = false

    public init(
        executableURL: URL,
        arguments: [String] = [],
        config: ProcessSupervisorConfig = ProcessSupervisorConfig()
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.config = config
    }

    deinit {
        readTask?.cancel()
        cancelEscalationTask?.cancel()
        stderrTask?.cancel()
        if let process, process.isRunning {
            process.terminate()
        }
    }

    /// Negotiated capabilities after a successful hello handshake (if any).
    public var capabilities: RunnerCapabilities? { negotiatedCaps }

    public var lastWorkerId: String? { workerId }

    public var isRunning: Bool {
        process?.isRunning == true
    }

    public var terminationStatus: Int32? { exitStatus }

    // MARK: - Lifecycle

    /// Spawns the worker with `cwd = jobDir`, waits for `hello`, replies `hello_ok`.
    ///
    /// **L1 gate:** only `bam-*-worker` helpers are launched; TeamID / validity
    /// checked via `WorkerTrust` (never applied to venv/CPython). Prefer
    /// resolving executables through `WorkerSpawn.prepareHelperLaunch` first.
    @discardableResult
    public func start(paths: JobPaths) async throws -> RunnerCapabilities {
        try PathJail.validate(paths: paths)

        // L1: refuse non-helper executables (e.g. system/managed python).
        let prepared = try WorkerSpawn.prepareExecutableURL(
            executableURL,
            mode: WorkerTrust.defaultMode
        )
        let launchURL = prepared.url

        // Reset cancel escalation from any prior generation (reuse hazard).
        clearCancelEscalation()
        cancelCommandSent = false
        lastJobId = nil

        let jobDirURL = URL(fileURLWithPath: paths.jobDir, isDirectory: true)
        try FileManager.default.createDirectory(at: jobDirURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            atPath: paths.logPath,
            withIntermediateDirectories: true
        )
        stderrLogURL = URL(fileURLWithPath: paths.logPath)
            .appendingPathComponent("worker.stderr.log", isDirectory: false)

        let proc = Process()
        proc.executableURL = launchURL
        proc.arguments = arguments
        proc.currentDirectoryURL = jobDirURL
        proc.qualityOfService = .utility

        // BAM_REDACT_SAMPLES defaults to 1; extraEnvironment may override for debug.
        var env = WorkerSpawn.workerEnvironment(
            base: ProcessInfo.processInfo.environment,
            extra: config.extraEnvironment
        )
        env[LibraryPaths.EnvironmentKey.libraryRoot] = paths.libraryRoot
        if env[LibraryPaths.EnvironmentKey.redactSamples] == nil {
            env[LibraryPaths.EnvironmentKey.redactSamples] = "1"
        }
        proc.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        let inPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        proc.standardInput = inPipe

        stdinHandle = inPipe.fileHandleForWriting
        process = proc
        processExited = false
        exitStatus = nil
        lineBuffer = Data()
        pendingLines = []
        lastHeartbeatAt = nil
        negotiatedCaps = nil
        workerId = nil
        lineTooLarge = false

        let supervisor = self
        proc.terminationHandler = { p in
            Task { await supervisor.handleTermination(status: p.terminationStatus) }
        }

        try proc.run()
        startReading(stdout: outPipe.fileHandleForReading, stderr: errPipe.fileHandleForReading)

        let helloLine = try await readLine(timeout: config.helloDeadline)
        guard let helloLine else {
            await forceKill()
            if lineTooLarge {
                throw BAMError(
                    code: .workerCrash,
                    message: "Protocol line exceeded \(config.maxLineBytes) bytes"
                )
            }
            throw BAMError(
                code: .workerCrash,
                message: "Worker exited before hello (status=\(exitStatus.map(String.init) ?? "?"))"
            )
        }

        let message: WorkerMessage
        do {
            message = try ProtocolCodec.decodeWorkerLine(helloLine)
        } catch let error as BAMError where error.code == .protocolMismatch {
            await forceKill()
            throw error
        } catch {
            await forceKill()
            throw BAMError(
                code: .protocolMismatch,
                message: "Invalid hello: \(error.localizedDescription)"
            )
        }

        guard case let .hello(id, _, caps, _) = message else {
            await forceKill()
            throw BAMError(
                code: .protocolMismatch,
                message: "Expected hello, got \(message.typeName)"
            )
        }

        workerId = id
        negotiatedCaps = caps
        lastHeartbeatAt = Date()

        try send(
            .helloOk(
                minV: ProtocolCodec.minSupportedVersion,
                maxV: ProtocolCodec.maxSupportedVersion
            )
        )
        return caps
    }

    /// Sends `prepare` after path-jail validation (including optional **original** raw JobSpec path keys).
    ///
    /// - Parameter rawSpecJSON: Original on-disk / store payload. Must **not** be re-encoded
    ///   Codable output (that drops free path keys and makes the side-channel a no-op).
    public func prepare(job: JobSpec, paths: JobPaths, rawSpecJSON: Data? = nil) async throws {
        try PathJail.validate(paths: paths)
        try PathJail.validateModalityRequirements(job: job, paths: paths)
        if let rawSpecJSON {
            try PathJail.validateRawJobSpecPaths(rawSpecJSON: rawSpecJSON, paths: paths)
        }
        lastJobId = job.id
        try send(.prepare(job: job, paths: paths))
    }

    /// Sends `run` and yields protocol events until `result` or process death / hang.
    public func run(job: JobSpec, paths: JobPaths) -> AsyncThrowingStream<RunnerEvent, Error> {
        eventStream(
            sendFirst: .run(job: job, paths: paths),
            job: job,
            paths: paths,
            checkpoint: nil
        )
    }

    /// Sends `resume` and yields events. Requires negotiated `caps.resume == true`
    /// and a jailed checkpoint path under `paths.checkpointPath`.
    public func resume(
        job: JobSpec,
        paths: JobPaths,
        checkpoint: CheckpointRef
    ) -> AsyncThrowingStream<RunnerEvent, Error> {
        eventStream(
            sendFirst: .resume(job: job, paths: paths, checkpoint: checkpoint),
            job: job,
            paths: paths,
            checkpoint: checkpoint
        )
    }

    /// Cooperative cancel: write cancel.flag, send cancel command, escalate SIGTERM/SIGKILL.
    public func cancel(jobId: String, paths: JobPaths) async {
        lastJobId = jobId
        try? CancelFlag.write(at: paths.cancelFlagPath)
        sendCancelCommandIfNeeded(jobId: jobId)
        guard config.escalateSignalsOnCancel else { return }
        startCancelEscalation()
    }

    /// Best-effort clean shutdown wait.
    public func waitUntilExit(timeout: TimeInterval) async -> Int32? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if processExited {
                clearCancelEscalation()
                return exitStatus
            }
            if process?.isRunning != true {
                exitStatus = process?.terminationStatus
                processExited = true
                clearCancelEscalation()
                return exitStatus
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return exitStatus
    }

    public func signalTerminate() {
        process?.terminate() // SIGTERM
    }

    public func forceKill() {
        process?.interrupt() // SIGINT first (harmless if dead)
        if let proc = process, proc.isRunning {
            let pid = proc.processIdentifier
            if pid > 0 {
                kill(pid, SIGKILL)
            }
        }
    }

    // MARK: - Event stream

    private func eventStream(
        sendFirst: SupervisorCommand,
        job: JobSpec,
        paths: JobPaths,
        checkpoint: CheckpointRef?
    ) -> AsyncThrowingStream<RunnerEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    // Path jail before run/resume (design: before prepare/run/resume).
                    try PathJail.validate(paths: paths)
                    try PathJail.validateModalityRequirements(job: job, paths: paths)
                    if let checkpoint {
                        try PathJail.validateCheckpoint(checkpoint, paths: paths)
                        let caps = await self.negotiatedCaps
                        if caps?.resume != true {
                            throw BAMError(
                                code: .capabilityUnsupported,
                                message: "Worker did not advertise caps.resume; cannot resume"
                            )
                        }
                    }

                    await self.setLastJobId(job.id)
                    try await self.send(sendFirst)
                    await self.markHeartbeat()

                    while !Task.isCancelled {
                        if await self.lineTooLargeFlag() {
                            await self.forceKill()
                            throw BAMError(
                                code: .workerCrash,
                                message: "Protocol line exceeded max size"
                            )
                        }

                        if let last = await self.lastHeartbeatDate(),
                           Date().timeIntervalSince(last) > self.config.heartbeatTimeout
                        {
                            await self.forceKill()
                            throw BAMError(
                                code: .workerHung,
                                message: "No heartbeat within \(self.config.heartbeatTimeout)s"
                            )
                        }

                        // Flag-only cancel: send cancel cmd + escalate signals.
                        if CancelFlag.exists(at: paths.cancelFlagPath) {
                            await self.handleExternalCancelFlag(paths: paths)
                        }

                        let line = try await self.readLine(timeout: 0.25)
                        if let line {
                            let message = try ProtocolCodec.decodeWorkerLine(line)
                            if case .heartbeat = message {
                                await self.markHeartbeat()
                            }
                            if case .hello = message {
                                continue
                            }
                            if let event = message.asRunnerEvent() {
                                // Defense-in-depth: never surface raw sample text in queue logs.
                                let redacted = Self.redactEvent(event)
                                continuation.yield(redacted)
                                if case .result = redacted {
                                    _ = await self.waitUntilExit(timeout: 2)
                                    await self.clearCancelEscalation()
                                    continuation.finish()
                                    return
                                }
                                // Bare error event: keep streaming until process exit / result.
                            }
                        } else if await self.hasExited() {
                            await self.clearCancelEscalation()
                            let status = await self.terminationStatus ?? -1
                            throw BAMError(
                                code: .workerCrash,
                                message: self.mapExit(status)
                            )
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    // MARK: - Cancel helpers

    private func setLastJobId(_ id: String) {
        lastJobId = id
    }

    private func handleExternalCancelFlag(paths: JobPaths) {
        let jobId = lastJobId ?? URL(fileURLWithPath: paths.jobDir).lastPathComponent
        sendCancelCommandIfNeeded(jobId: jobId)
        if config.escalateSignalsOnCancel {
            startCancelEscalation()
        }
    }

    private func sendCancelCommandIfNeeded(jobId: String) {
        guard !cancelCommandSent else { return }
        cancelCommandSent = true
        try? send(.cancel(jobId: jobId))
    }

    private func clearCancelEscalation() {
        cancelEscalationTask?.cancel()
        cancelEscalationTask = nil
        // Allow re-arm on a later cancel of the same process generation after clear.
        // cancelCommandSent stays true until next start().
    }

    private func startCancelEscalation() {
        guard cancelEscalationTask == nil else { return }
        let t1 = config.cancelGraceT1
        let t2 = config.cancelGraceT2
        cancelEscalationTask = Task {
            try? await Task.sleep(for: .seconds(t1))
            if Task.isCancelled { return }
            if await self.isRunning {
                await self.signalTerminate()
            }
            try? await Task.sleep(for: .seconds(t2))
            if Task.isCancelled { return }
            if await self.isRunning {
                await self.forceKill()
            }
        }
    }

    // MARK: - Line I/O

    private func send(_ command: SupervisorCommand) throws {
        guard let stdinHandle else {
            throw BAMError(code: .workerCrash, message: "stdin not available")
        }
        let line = try ProtocolCodec.encodeLine(command)
        var data = Data(line.utf8)
        data.append(0x0A)
        try stdinHandle.write(contentsOf: data)
    }

    private func readLine(timeout: TimeInterval) async throws -> String? {
        if lineTooLarge {
            return nil
        }
        if !pendingLines.isEmpty {
            return pendingLines.removeFirst()
        }
        if processExited {
            return nil
        }

        let id = UUID()
        return await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            lineContinuations[id] = cont
            Task {
                let deadline = Date().addingTimeInterval(timeout)
                while Date() < deadline {
                    if await self.continuationMissing(id) {
                        return
                    }
                    if await self.hasExited() {
                        await self.resumeContinuation(id, with: nil)
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(10))
                }
                await self.resumeContinuation(id, with: nil)
            }
        }
    }

    private func continuationMissing(_ id: UUID) -> Bool {
        lineContinuations[id] == nil
    }

    private func resumeContinuation(_ id: UUID, with value: String?) {
        guard let cont = lineContinuations.removeValue(forKey: id) else { return }
        cont.resume(returning: value)
    }

    private func deliverLine(_ line: String) {
        if let (id, cont) = lineContinuations.first {
            lineContinuations.removeValue(forKey: id)
            cont.resume(returning: line)
        } else {
            pendingLines.append(line)
        }
    }

    private func failAllWaiters() {
        let all = lineContinuations
        lineContinuations.removeAll()
        for (_, cont) in all {
            cont.resume(returning: nil)
        }
    }

    private func startReading(stdout: FileHandle, stderr: FileHandle) {
        readTask?.cancel()
        stderrTask?.cancel()

        // IMPORTANT: `FileHandle.availableData` can block. Run these loops off the
        // actor executor so they never hold the ProcessSupervisor isolation domain
        // (would deadlock hello/readLine/cancel). Hop back with `await` for mutations.
        readTask = Task { [weak self] in
            while !Task.isCancelled {
                let chunk = stdout.availableData
                if chunk.isEmpty {
                    try? await Task.sleep(for: .milliseconds(8))
                    guard let self else { break }
                    if await self.process?.isRunning != true {
                        let rest = stdout.availableData
                        if !rest.isEmpty {
                            await self.appendStdout(rest)
                        }
                        await self.finishStdout()
                        break
                    }
                    continue
                }
                await self?.appendStdout(chunk)
            }
        }

        stderrTask = Task { [weak self] in
            while !Task.isCancelled {
                let data = stderr.availableData
                if data.isEmpty {
                    try? await Task.sleep(for: .milliseconds(50))
                    guard let self else { break }
                    if await self.process?.isRunning != true {
                        let rest = stderr.availableData
                        if !rest.isEmpty {
                            await self.appendStderr(rest)
                        }
                        break
                    }
                    continue
                }
                await self?.appendStderr(data)
            }
        }
    }

    private func appendStdout(_ data: Data) {
        if lineBuffer.count + data.count > config.maxLineBytes + 64 * 1024 {
            lineTooLarge = true
            failAllWaiters()
            forceKill()
            return
        }
        lineBuffer.append(data)
        while let range = lineBuffer.range(of: Data([0x0A])) {
            let lineData = lineBuffer.subdata(in: lineBuffer.startIndex..<range.lowerBound)
            lineBuffer.removeSubrange(lineBuffer.startIndex..<range.upperBound)
            if lineData.count > config.maxLineBytes {
                lineTooLarge = true
                failAllWaiters()
                forceKill()
                return
            }
            if let line = String(data: lineData, encoding: .utf8) {
                deliverLine(line)
            }
        }
    }

    private func appendStderr(_ data: Data) {
        guard let stderrLogURL else { return }
        if !FileManager.default.fileExists(atPath: stderrLogURL.path) {
            try? data.write(to: stderrLogURL, options: .atomic)
            return
        }
        guard let handle = try? FileHandle(forWritingTo: stderrLogURL) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }

    private func finishStdout() {
        lineBuffer.removeAll(keepingCapacity: false)
        processExited = true
        if let proc = process {
            exitStatus = proc.terminationStatus
        }
        failAllWaiters()
        clearCancelEscalation()
    }

    private func handleTermination(status: Int32) {
        exitStatus = status
        processExited = true
        failAllWaiters()
        clearCancelEscalation()
    }

    private func markHeartbeat() {
        lastHeartbeatAt = Date()
    }

    /// Apply `LogRedaction` to worker log/error/result messages (default on).
    private static func redactEvent(_ event: RunnerEvent) -> RunnerEvent {
        switch event {
        case let .log(level, message, ts):
            return .log(
                level: level,
                message: LogRedaction.redactMessage(message, level: level),
                ts: ts
            )
        case let .error(code, message, retriable):
            return .error(
                code: code,
                message: LogRedaction.redactForDefaultLog(message),
                retriable: retriable
            )
        case let .result(status, artifacts, message):
            let redacted = message.map { LogRedaction.redactForDefaultLog($0) }
            return .result(status: status, artifacts: artifacts, message: redacted)
        default:
            return event
        }
    }

    private func lastHeartbeatDate() -> Date? { lastHeartbeatAt }

    private func lineTooLargeFlag() -> Bool { lineTooLarge }

    private func hasExited() -> Bool {
        processExited || process?.isRunning != true
    }

    private func mapExit(_ status: Int32) -> String {
        if let code = WorkerExitCode.classify(status) {
            return "Worker exited \(status) (\(code.meaning))"
        }
        return "Worker exited with unexpected status \(status)"
    }
}
