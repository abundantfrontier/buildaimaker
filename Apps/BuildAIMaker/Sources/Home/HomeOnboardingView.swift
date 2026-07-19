import SwiftUI
import BAMCore
import BAMDatasets
import BAMModelCatalog
import BAMModels
import BAMPersistence
import BAMResourcesUI

/// Home first-run checklist + lightweight MVP metrics (M1–M5) harness.
struct HomeOnboardingView: View {
    @Binding var selection: SidebarDestination?
    @StateObject private var model = HomeOnboardingViewModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                if model.checklist.shouldShow {
                    checklistSection
                } else if model.checklist.isFullyComplete {
                    completeBanner
                }
                metricsSection
                quickLinks
            }
            .padding(24)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(BAMColors.detailBackground)
        .navigationTitle(SidebarDestination.home.title)
        .onAppear { model.refresh() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.refresh()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Re-probe library and metrics")
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(AppIdentity.displayName)
                .font(.largeTitle.weight(.semibold))
            Text(
                "Local-first AI fine-tuning on Apple Silicon. Requires \(AppIdentity.minimumUnifiedMemoryGB) GB unified memory."
            )
            .font(.body)
            .foregroundStyle(BAMColors.secondaryLabel)
        }
    }

    private var checklistSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Get started")
                    .font(.title2.weight(.semibold))
                Spacer()
                Text("\(model.checklist.completedCount)/\(model.checklist.totalCount)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(BAMColors.secondaryLabel)
                Button("Dismiss") {
                    model.dismissChecklist()
                }
                .font(.caption)
                .help("Hide the checklist until you reset it in Settings (or complete all steps).")
            }

            ProgressView(value: model.checklist.progress)
                .progressViewStyle(.linear)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(OnboardingStep.allCases) { step in
                    checklistRow(step)
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    private func checklistRow(_ step: OnboardingStep) -> some View {
        let done = model.checklist.isComplete(step)
        return Button {
            selection = destination(for: step)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: done ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(done ? .green : BAMColors.secondaryLabel)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(step.title)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                        .strikethrough(done, color: BAMColors.secondaryLabel)
                    Text(step.detail)
                        .font(.caption)
                        .foregroundStyle(BAMColors.secondaryLabel)
                        .multilineTextAlignment(.leading)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(BAMColors.tertiaryLabel)
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var completeBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.seal.fill")
                .foregroundStyle(.green)
            Text("First-run checklist complete — import, train, and play without leaving the app.")
                .font(.callout)
            Spacer()
            Button("Reset") {
                model.resetChecklist()
            }
            .font(.caption)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.green.opacity(0.12))
        )
    }

    private var metricsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("MVP metrics (local)")
                .font(.title3.weight(.semibold))
            Text("M1–M5 event counters stored in UserDefaults — no network. M5 should stay at zero during train/play.")
                .font(.caption)
                .foregroundStyle(BAMColors.secondaryLabel)

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 140), spacing: 10)],
                spacing: 10
            ) {
                ForEach(MVPMetricEvent.allCases) { event in
                    metricTile(event)
                }
            }

            if model.metrics.m5Passes {
                Label("M5: no network calls recorded during train/play", systemImage: "network.slash")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else {
                Label(
                    "M5: \(model.metrics.m5NetworkCallsDuringTrainPlay) network call(s) during train/play",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    private func metricTile(_ event: MVPMetricEvent) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(event.metricId)
                .font(.caption2.weight(.bold))
                .foregroundStyle(BAMColors.tertiaryLabel)
            Text("\(model.metrics.count(for: event))")
                .font(.title2.monospacedDigit().weight(.semibold))
            Text(event.displayName)
                .font(.caption2)
                .foregroundStyle(BAMColors.secondaryLabel)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .stroke(BAMColors.separator.opacity(0.5), lineWidth: 1)
        )
    }

    private var quickLinks: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Go to")
                .font(.headline)
            HStack(spacing: 12) {
                linkButton("Datasets", .datasets, "doc.text")
                linkButton("Models", .models, "cpu")
                linkButton("Train", .train, "hammer")
                linkButton("Playground", .playground, "bubble.left.and.bubble.right")
            }
        }
    }

    private func linkButton(_ title: String, _ dest: SidebarDestination, _ image: String) -> some View {
        Button {
            selection = dest
        } label: {
            Label(title, systemImage: image)
        }
        .buttonStyle(.bordered)
    }

    private func destination(for step: OnboardingStep) -> SidebarDestination {
        switch step {
        case .importDataset: return .datasets
        case .installFixture: return .models
        case .dryRunOrTrain: return .train
        case .playgroundChat: return .playground
        }
    }
}

// MARK: - View model

@MainActor
final class HomeOnboardingViewModel: ObservableObject {
    @Published private(set) var checklist = OnboardingChecklistState()
    @Published private(set) var metrics = MVPMetricsSnapshot()
    @Published private(set) var probe = OnboardingLibraryProbe()

    private let onboardingStore: OnboardingStore
    private let metricsStore: MVPMetricsStore
    private let libraryRoot: URL

    init(
        libraryRoot: URL = LibraryPaths.libraryRoot,
        onboardingStore: OnboardingStore = OnboardingStore(),
        metricsStore: MVPMetricsStore = .shared
    ) {
        self.libraryRoot = libraryRoot
        self.onboardingStore = onboardingStore
        self.metricsStore = metricsStore
    }

    func refresh() {
        metrics = metricsStore.snapshot()
        let persisted = onboardingStore.loadPersisted()
        probe = Self.buildProbe(
            libraryRoot: libraryRoot,
            metrics: metrics,
            persisted: persisted
        )
        checklist = OnboardingChecklistEvaluator.evaluate(probe: probe, persisted: persisted)
    }

    func dismissChecklist() {
        onboardingStore.dismiss()
        refresh()
    }

    func resetChecklist() {
        onboardingStore.reset()
        refresh()
    }

    static func buildProbe(
        libraryRoot: URL,
        metrics: MVPMetricsSnapshot,
        persisted: OnboardingPersistedState = OnboardingStore().loadPersisted(),
        fileManager: FileManager = .default
    ) -> OnboardingLibraryProbe {
        var hasDataset = false
        if let service = try? DatasetLibraryService.openDefault() {
            if let listed = try? service.listDatasets() {
                hasDataset = listed.contains { $0.status == .ready && $0.modality == .text }
            }
        }
        // M4 import success also counts even if the dataset was later deleted.
        if metrics.count(for: .datasetImportOK) > 0 {
            hasDataset = true
        }

        let modelsBase = libraryRoot.appendingPathComponent("models/base", isDirectory: true)
        let hasBase: Bool
        do {
            let scanned = try LocalModelScanner(modelsBaseURL: modelsBase).scan()
            hasBase = !scanned.isEmpty
                || ModelInstallService(modelsBaseURL: modelsBase).isFixtureInstalled()
        } catch {
            hasBase = ModelInstallService(modelsBaseURL: modelsBase).isFixtureInstalled()
        }

        let adaptersRoot = libraryRoot.appendingPathComponent("models/adapters", isDirectory: true)
        var hasAdapter = false
        var isDir: ObjCBool = false
        if fileManager.fileExists(atPath: adaptersRoot.path, isDirectory: &isDir), isDir.boolValue,
           let contents = try? fileManager.contentsOfDirectory(
               at: adaptersRoot,
               includingPropertiesForKeys: [.isDirectoryKey],
               options: [.skipsHiddenFiles]
           )
        {
            hasAdapter = contents.contains { url in
                (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            }
        }

        let hasDryRunOrTrain =
            hasAdapter
            || metrics.count(for: .trainCompleted) > 0
            || persisted.manuallyCompleted.contains(.dryRunOrTrain)

        let hasPlayground =
            metrics.count(for: .playgroundReply) > 0
            || persisted.manuallyCompleted.contains(.playgroundChat)

        return OnboardingLibraryProbe(
            hasReadyDataset: hasDataset,
            hasLocalBaseModel: hasBase,
            hasDryRunOrTrain: hasDryRunOrTrain,
            hasPlaygroundChat: hasPlayground
        )
    }
}
