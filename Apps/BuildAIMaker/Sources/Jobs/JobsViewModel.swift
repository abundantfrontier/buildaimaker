import Foundation
import SwiftUI
import BAMCore
import BAMJobs
import BAMModels
import BAMPersistence
import BAMRunnersMLX
import BAMRunnersVoice

/// Observable façade over `JobQueueController` for the Jobs sidebar pane.
@MainActor
final class JobsViewModel: ObservableObject {
    @Published private(set) var jobs: [JobRecord] = []
    @Published private(set) var progressByJob: [String: JobProgressSnapshot] = [:]
    @Published private(set) var statusMessage: String?
    @Published private(set) var isBusy = false

    private let controller: JobQueueController
    private var jobsTask: Task<Void, Never>?
    private var progressTask: Task<Void, Never>?

    init(controller: JobQueueController) {
        self.controller = controller
    }

    /// Opens the default library database + composite runner (LLM fake + voice stub + foundation adapter).
    static func makeDefault() throws -> JobsViewModel {
        let db = try LibraryDatabase.openDefault()
        let store = JobStore(database: db)
        let foundationInstalled = FoundationToolkitProbe.probe().installed
        let runner = CompositeTrainingRunner(
            llm: FakeTrainingRunner(
                config: FakeRunnerConfig(
                    stepCount: 20,
                    stepInterval: .milliseconds(200),
                    heartbeatEverySteps: 2,
                    prepareDelay: .milliseconds(100)
                )
            ),
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
                    // Use real toolkit when installed; otherwise stub (dogfood-safe).
                    forceFakeTrain: !foundationInstalled
                )
            )
        )
        let controller = JobQueueController(
            store: store,
            runner: runner,
            libraryRoot: LibraryPaths.libraryRoot,
            heartbeatTimeout: HeartbeatMonitor.defaultTimeoutSeconds
        )
        return JobsViewModel(controller: controller)
    }

    func start() {
        jobsTask?.cancel()
        progressTask?.cancel()

        jobsTask = Task { [weak self] in
            guard let self else { return }
            let stream = await self.controller.jobsUpdates()
            for await snapshot in stream {
                guard !Task.isCancelled else { break }
                await MainActor.run {
                    self.jobs = snapshot
                }
            }
        }

        progressTask = Task { [weak self] in
            guard let self else { return }
            let stream = await self.controller.progressUpdates()
            for await (jobId, snap) in stream {
                guard !Task.isCancelled else { break }
                await MainActor.run {
                    self.progressByJob[jobId] = snap
                }
            }
        }

        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.controller.recoverStaleJobs()
                let listed = try await self.controller.listJobs()
                self.jobs = listed
            } catch {
                self.statusMessage = error.localizedDescription
            }
        }
    }

    func stop() {
        jobsTask?.cancel()
        progressTask?.cancel()
        jobsTask = nil
        progressTask = nil
    }

    func startFakeJob() {
        guard !isBusy else { return }
        isBusy = true
        statusMessage = nil
        Task {
            defer { isBusy = false }
            do {
                let id = BAMID.generate()
                let spec = JobSpec.llm(
                    id: id,
                    baseModelId: DomainFixtures.baseModelId,
                    baseModelSourceKey: "fake/qwen2.5-demo",
                    datasetVersionId: DomainFixtures.datasetVersionId,
                    hyperparameters: LLMHyperparameters(epochs: 1, batchSize: 1)
                )
                _ = try await controller.enqueue(spec: spec)
                statusMessage = "Queued fake job \(id.prefix(8))…"
            } catch {
                statusMessage = error.localizedDescription
            }
        }
    }

    func cancel(jobId: String) {
        Task {
            do {
                try await controller.cancel(jobId: jobId)
                statusMessage = "Cancel requested"
                // M2: cancel within product path (latency measured separately in dogfood).
                MVPMetricsStore.shared.increment(.jobCancelled)
            } catch {
                statusMessage = error.localizedDescription
            }
        }
    }

    func canCancel(_ job: JobRecord) -> Bool {
        switch job.status {
        case .draft, .queued, .preparing, .running:
            return true
        default:
            return false
        }
    }

    func progress(for job: JobRecord) -> JobProgressSnapshot? {
        progressByJob[job.id]
    }
}
