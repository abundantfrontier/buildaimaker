import BAMCore
import BAMInference
import BAMJobs
import BAMModels
import BAMPersistence
import BAMRunners
import BAMRunnersMLX
import BAMRunnersVoice
import Foundation

/// Shared product job queue (Train UI, Jobs pane, MCP `finetune.start`).
enum AppJobQueueFactory {
    /// Open LoRA can run real worker weights when mlx-lm is importable.
    static func mlxLoRAAvailable() -> Bool {
        MLXGenerateBackend.isAvailable()
    }

    static func appleToolkitInstalled() -> Bool {
        FoundationToolkitProbe.probe().installed
    }

    /// True when queued open-LoRA jobs will not update real weights.
    static func willFakeOpenLoRA() -> Bool {
        openLoRABlocker() != nil
    }

    /// Human reason Train is still fake, or nil when a real worker can run.
    static func openLoRABlocker() -> String? {
        if !mlxLoRAAvailable() {
            return "mlx-lm is not importable in the training venv. Settings → Repair."
        }
        if (try? MLXWorkerClient.resolveWorkerExecutable()) == nil {
            return "Training worker not found next to the app. Rebuild BuildAIMaker."
        }
        return nil
    }

    static func willFakeAppleAdapter() -> Bool {
        !appleToolkitInstalled()
    }

    static func makeDefault() throws -> JobQueueController {
        let db = try LibraryDatabase.openDefault()
        return JobQueueController(
            store: JobStore(database: db),
            runner: makeCompositeRunner(),
            libraryRoot: LibraryPaths.libraryRoot,
            // Gemma 4 load can stay silent for minutes; worker pulses every 5s.
            heartbeatTimeout: 300
        )
    }

    static func makeCompositeRunner() -> CompositeTrainingRunner {
        CompositeTrainingRunner(
            llm: makeLLMRunner(),
            voice: StubVoiceCloneRunner(
                config: StubVoiceCloneRunnerConfig(
                    stepCount: 8,
                    stepInterval: .milliseconds(120),
                    prepareDelay: .milliseconds(50)
                )
            ),
            foundation: FoundationModelsAdapterRunner(
                config: FoundationModelsAdapterRunnerConfig(
                    stepCount: 8,
                    stepInterval: .milliseconds(120),
                    prepareDelay: .milliseconds(50),
                    forceFakeTrain: willFakeAppleAdapter()
                )
            )
        )
    }

    static func makeLLMRunner() -> any TrainingRunner {
        ResolvingOpenLoRARunner()
    }

    /// Picked at prepare/run time so Settings Repair is visible without restart.
    static func makeConcreteLLMRunner() -> any TrainingRunner {
        if !willFakeOpenLoRA(),
           let worker = try? MLXWorkerClient.resolveWorkerExecutable()
        {
            var config = ProcessSupervisorConfig()
            config.helloDeadline = 30
            config.heartbeatTimeout = 120
            if let pins = RuntimePaths.resolvePinsRoot() {
                config.extraEnvironment[RuntimePaths.EnvironmentKey.pythonPinsRoot] = pins.path
            }
            config.extraEnvironment[RuntimePaths.EnvironmentKey.managedEnvRoot] =
                RuntimePaths.managedEnvRoot().path
            return SupervisedTrainingRunner(executableURL: worker, config: config)
        }
        return FakeTrainingRunner(
            config: FakeRunnerConfig(
                stepCount: 20,
                stepInterval: .milliseconds(200),
                heartbeatEverySteps: 2,
                prepareDelay: .milliseconds(100)
            )
        )
    }
}

/// One concrete runner per job so prepare() and run() share the same supervisor.
private final class ResolvingOpenLoRARunner: TrainingRunner, @unchecked Sendable {
    let id = "resolving-open-lora"
    let protocolVersion = ProtocolVersions.runnerProtocolVersion
    private let lock = NSLock()
    private var runners: [String: any TrainingRunner] = [:]

    private func runner(for jobId: String) -> any TrainingRunner {
        lock.lock()
        defer { lock.unlock() }
        if let existing = runners[jobId] { return existing }
        let created = AppJobQueueFactory.makeConcreteLLMRunner()
        runners[jobId] = created
        return created
    }

    func capabilities() async throws -> RunnerCapabilities {
        try await AppJobQueueFactory.makeConcreteLLMRunner().capabilities()
    }

    func prepare(job: JobSpec, paths: JobPaths) async throws {
        try await runner(for: job.id).prepare(job: job, paths: paths)
    }

    func run(job: JobSpec, paths: JobPaths) -> AsyncThrowingStream<RunnerEvent, Error> {
        runner(for: job.id).run(job: job, paths: paths)
    }

    func resume(
        job: JobSpec,
        paths: JobPaths,
        checkpoint: CheckpointRef
    ) -> AsyncThrowingStream<RunnerEvent, Error> {
        runner(for: job.id).resume(job: job, paths: paths, checkpoint: checkpoint)
    }

    func cancel(jobId: String) async {
        let existing: (any TrainingRunner)?
        lock.lock()
        existing = runners[jobId]
        lock.unlock()
        await existing?.cancel(jobId: jobId)
    }
}
