import SwiftUI
import BAMCore
import BAMJobs
import BAMModels
import BAMPersistence
import BAMResourcesUI

/// Live teaching status: what’s running, what finished, Stop / Show files.
struct JobsView: View {
    @EnvironmentObject private var controlPlane: ControlPlaneEnvironment
    @StateObject private var model: JobsViewModel
    @State private var showOlder = false

    init() {
        // Placeholder only — `onAppear` rebinds to `controlPlane.jobQueue`.
        let db = try! LibraryDatabase.openInMemory()
        let controller = JobQueueController(
            store: JobStore(database: db),
            runner: FakeTrainingRunner(config: .testing)
        )
        _model = StateObject(wrappedValue: JobsViewModel(controller: controller))
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if let status = model.statusMessage {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(BAMColors.secondaryLabel)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
            }
            if model.jobs.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        nowSection
                        recentSection
                    }
                    .padding(16)
                    .frame(maxWidth: 720, alignment: .leading)
                }
            }
        }
        .background(BAMColors.detailBackground)
        .navigationTitle("What’s running")
        .onAppear {
            model.attachSharedQueue(controlPlane.jobQueue)
        }
        .guideHighlight("jobs.list")
        .onDisappear { model.stop() }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("What’s running")
                    .font(.headline)
                Text("Live teaching jobs. Stop one here if you need to.")
                    .font(.caption)
                    .foregroundStyle(BAMColors.secondaryLabel)
            }
            Spacer()
            Button {
                model.attachSharedQueue(controlPlane.jobQueue)
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
        }
        .padding(12)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(BAMColors.secondaryLabel)
            Text("Nothing is running")
                .font(.title3.weight(.semibold))
            Text("Start teaching from Train. This page shows the live job and what finished.")
                .font(.body)
                .foregroundStyle(BAMColors.tertiaryLabel)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var nowSection: some View {
        let running = model.nowRunning
        VStack(alignment: .leading, spacing: 10) {
            Text("Now")
                .font(.title3.weight(.semibold))
            if running.isEmpty {
                Text("Nothing is teaching right now.")
                    .font(.callout)
                    .foregroundStyle(BAMColors.secondaryLabel)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(BAMColors.sidebarBackground, in: RoundedRectangle(cornerRadius: 10))
            } else {
                ForEach(running, id: \.id) { job in
                    jobCard(job, live: true)
                }
            }
        }
    }

    @ViewBuilder
    private var recentSection: some View {
        let done = model.recentFinished
        let shown = showOlder ? done : Array(done.prefix(5))
        VStack(alignment: .leading, spacing: 10) {
            Text("Recently finished")
                .font(.title3.weight(.semibold))
            if done.isEmpty {
                Text("No finished jobs yet.")
                    .font(.callout)
                    .foregroundStyle(BAMColors.secondaryLabel)
            } else {
                ForEach(shown, id: \.id) { job in
                    jobCard(job, live: false)
                }
                if done.count > 5 {
                    Button(showOlder ? "Show fewer" : "Show older (\(done.count - 5))") {
                        showOlder.toggle()
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.blue)
                }
            }
        }
    }

    private func jobCard(_ job: JobRecord, live: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(model.statusTitle(job))
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .foregroundStyle(statusColor(job))
                    .background(statusColor(job).opacity(0.18), in: Capsule())
                Text(model.jobTitle(job))
                    .font(.callout.weight(.semibold))
                Spacer()
                Text(model.whenLabel(job))
                    .font(.caption)
                    .foregroundStyle(BAMColors.secondaryLabel)
            }

            if live, let progress = model.progress(for: job) {
                if let frac = progress.fractionComplete {
                    ProgressView(value: frac)
                } else {
                    ProgressView()
                }
                if let message = progress.message, !message.isEmpty {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(BAMColors.secondaryLabel)
                } else {
                    Text("Working… leave this window open.")
                        .font(.caption)
                        .foregroundStyle(BAMColors.secondaryLabel)
                }
            }

            if let err = job.errorMessage, !err.isEmpty, job.status != .succeeded {
                Text(plainError(err))
                    .font(.caption)
                    .foregroundStyle(job.status == .interrupted ? .orange : .red)
                    .lineLimit(3)
            }

            HStack(spacing: 12) {
                if let dur = model.durationLabel(job) {
                    Text(dur)
                        .font(.caption2)
                        .foregroundStyle(BAMColors.tertiaryLabel)
                }
                Spacer()
                if model.canCancel(job) {
                    Button("Stop", role: .destructive) {
                        model.cancel(jobId: job.id)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                Button("Show files") {
                    model.openJobFolder(job)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BAMColors.sidebarBackground, in: RoundedRectangle(cornerRadius: 10))
    }

    private func statusColor(_ job: JobRecord) -> Color {
        switch job.status {
        case .succeeded: return .green
        case .failed, .cancelled: return .red
        case .interrupted: return .orange
        case .running, .preparing: return .blue
        case .queued, .draft: return BAMColors.secondaryLabel
        }
    }

    private func plainError(_ raw: String) -> String {
        if raw.localizedCaseInsensitiveContains("heartbeat") {
            return "Cut off while the model was still loading (timeout)."
        }
        if raw.count > 180 { return String(raw.prefix(180)) + "…" }
        return raw
    }
}
