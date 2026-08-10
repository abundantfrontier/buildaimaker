import SwiftUI
import BAMCore
import BAMJobs
import BAMModels
import BAMPersistence
import BAMResourcesUI

/// Jobs pane: list, start fake job, cancel, live progress.
struct JobsView: View {
    @StateObject private var model: JobsViewModel
    private let loadError: String?

    init() {
        do {
            let vm = try JobsViewModel.makeDefault()
            _model = StateObject(wrappedValue: vm)
            loadError = nil
        } catch {
            // Fallback in-memory store so the pane still renders if library open fails.
            if let vm = try? Self.fallbackViewModel() {
                _model = StateObject(wrappedValue: vm)
                loadError = "Library open failed; using in-memory store. \(error.localizedDescription)"
            } else {
                let db = try! LibraryDatabase.openInMemory()
                let store = JobStore(database: db)
                let controller = JobQueueController(
                    store: store,
                    runner: FakeTrainingRunner(config: .testing)
                )
                _model = StateObject(wrappedValue: JobsViewModel(controller: controller))
                loadError = error.localizedDescription
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if let loadError {
                Text(loadError)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            if let status = model.statusMessage {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(BAMColors.secondaryLabel)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }
            if model.jobs.isEmpty {
                emptyState
            } else {
                jobList
            }
        }
        .background(BAMColors.detailBackground)
        .navigationTitle(SidebarDestination.jobs.title)
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Label("Jobs", systemImage: SidebarDestination.jobs.systemImage)
                .font(.headline)
            Spacer()
            Button {
                model.startFakeJob()
            } label: {
                Label("Start Fake Job", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.isBusy)
            .help("Enqueue a synthetic training job (fake runner, no GPU).")
        }
        .padding(12)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: SidebarDestination.jobs.systemImage)
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(BAMColors.secondaryLabel)
            Text("No jobs yet")
                .font(.title3.weight(.semibold))
            Text("Start a fake job to exercise the queue, progress events, and cancel.")
                .font(.body)
                .foregroundStyle(BAMColors.tertiaryLabel)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var jobList: some View {
        List {
            ForEach(model.jobs, id: \.id) { job in
                JobRowView(
                    job: job,
                    progress: model.progress(for: job),
                    canCancel: model.canCancel(job),
                    onCancel: { model.cancel(jobId: job.id) }
                )
            }
        }
        .listStyle(.inset)
    }

    private static func fallbackViewModel() throws -> JobsViewModel {
        let pair = try JobQueueController.makeInMemoryForTesting(
            runnerConfig: FakeRunnerConfig(
                stepCount: 20,
                stepInterval: .milliseconds(200)
            )
        )
        return JobsViewModel(controller: pair.controller)
    }
}

private struct JobRowView: View {
    let job: JobRecord
    let progress: JobProgressSnapshot?
    let canCancel: Bool
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                statusBadge
                Text(job.modality.rawValue)
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(BAMColors.sidebarBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                Text(job.id)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(BAMColors.secondaryLabel)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if canCancel {
                    Button("Cancel", role: .destructive, action: onCancel)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }

            if job.status == .running || job.status == .preparing, let progress {
                progressBlock(progress)
            }

            if let code = job.errorCode {
                Text("\(code)\(job.errorMessage.map { ": \($0)" } ?? "")")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Text("updated \(job.updatedAt)")
                    .font(.caption2)
                    .foregroundStyle(BAMColors.tertiaryLabel)
                Spacer()
                Text("created \(job.createdAt)")
                    .font(.caption2)
                    .foregroundStyle(BAMColors.tertiaryLabel)
            }
        }
        .padding(.vertical, 4)
    }

    private var statusBadge: some View {
        Text(job.status.rawValue)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(statusForeground)
            .background(statusBackground)
            .clipShape(Capsule())
    }

    private var statusForeground: Color {
        switch job.status {
        case .succeeded: return .green
        case .failed, .cancelled: return .red
        case .interrupted: return .orange
        case .running, .preparing: return .blue
        case .queued, .draft: return BAMColors.secondaryLabel
        }
    }

    private var statusBackground: Color {
        statusForeground.opacity(0.15)
    }

    @ViewBuilder
    private func progressBlock(_ progress: JobProgressSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if job.status == .preparing {
                ProgressView(value: 0.05)
            } else if let fraction = progress.fractionComplete {
                ProgressView(value: fraction)
            } else {
                ProgressView()
            }
            HStack(spacing: 12) {
                Text("step \(progress.step)")
                if let loss = progress.loss {
                    Text(String(format: "loss %.3f", loss))
                }
                if let tps = progress.tokensPerSec {
                    Text(String(format: "%.0f tok/s", tps))
                }
                if let eta = progress.etaSec {
                    Text(String(format: "ETA %.1fs", eta))
                }
                if let gpu = progress.gpuUtil {
                    Text(String(format: "GPU %.0f%%", gpu * 100))
                }
            }
            .font(.caption2)
            .foregroundStyle(BAMColors.secondaryLabel)
            if let message = progress.message {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(BAMColors.tertiaryLabel)
                    .lineLimit(1)
            }
        }
    }
}
