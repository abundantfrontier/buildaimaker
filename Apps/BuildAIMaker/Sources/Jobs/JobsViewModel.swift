import AppKit
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

    private var controller: JobQueueController
    private var jobsTask: Task<Void, Never>?
    private var progressTask: Task<Void, Never>?

    init(controller: JobQueueController) {
        self.controller = controller
    }

    /// Rebind to the app-wide queue (Train / MCP share this instance).
    func attachSharedQueue(_ shared: JobQueueController) {
        if shared !== controller {
            stop()
            controller = shared
        }
        start()
    }

    var nowRunning: [JobRecord] {
        jobs.filter {
            switch $0.status {
            case .queued, .preparing, .running: return true
            default: return false
            }
        }
    }

    var recentFinished: [JobRecord] {
        jobs.filter { job in
            switch job.status {
            case .queued, .preparing, .running: return false
            default: return true
            }
        }
    }

    func openJobFolder(_ job: JobRecord) {
        let dir = LibraryPaths.jobDirectory(id: job.id)
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: dir.path)
    }

    func jobTitle(_ job: JobRecord) -> String {
        switch job.modality {
        case .llm: return "Teaching"
        case .foundationAdapter: return "Apple adapter"
        case .voiceClone: return "Voice"
        case .voiceFinetune: return "Voice teach"
        }
    }

    func statusTitle(_ job: JobRecord) -> String {
        switch job.status {
        case .queued: return "Waiting"
        case .preparing: return "Starting"
        case .running: return "Running"
        case .succeeded: return "Worked"
        case .failed: return "Failed"
        case .cancelled: return "Stopped"
        case .interrupted: return "Cut off"
        case .draft: return "Draft"
        }
    }

    func whenLabel(_ job: JobRecord) -> String {
        guard let date = JobTimestamps.parse(job.updatedAt) else { return job.updatedAt }
        let secs = Date().timeIntervalSince(date)
        if secs < 45 { return "Just now" }
        if secs < 3600 { return "\(Int(secs / 60)) min ago" }
        if secs < 86_400 { return "\(Int(secs / 3600))h ago" }
        return "Earlier"
    }

    func durationLabel(_ job: JobRecord) -> String? {
        guard let start = JobTimestamps.parse(job.createdAt),
              let end = JobTimestamps.parse(job.updatedAt)
        else { return nil }
        let s = max(0, end.timeIntervalSince(start))
        if s < 90 { return "\(Int(s))s" }
        return "\(Int(s / 60)) min"
    }

    /// Shared product queue (same instance as Train / MCP).
    static func makeDefault() throws -> JobsViewModel {
        JobsViewModel(controller: try AppJobQueueFactory.makeDefault())
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
                    self.jobs = snapshot.sorted { $0.updatedAt > $1.updatedAt }
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
                self.jobs = listed.sorted { $0.updatedAt > $1.updatedAt }
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
                statusMessage = "Queued synthetic job \(id.prefix(8))… (shared queue)"
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
