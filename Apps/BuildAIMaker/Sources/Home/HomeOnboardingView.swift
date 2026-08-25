import AppKit
import SwiftUI
import BAMCore
import BAMDatasets
import BAMInference
import BAMModelCatalog
import BAMModels
import BAMPersistence
import BAMResourcesUI

/// Home first-run checklist + environment setup gate + MVP metrics.
struct HomeOnboardingView: View {
    @Binding var selection: SidebarDestination?
    @StateObject private var model = HomeOnboardingViewModel()
    @State private var showModelBrowser = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header

                // Always-visible when runtime or model missing (not permanently dismissible).
                if model.setup.needsAttention {
                    environmentSetupSection
                } else {
                    environmentReadyBanner
                }

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
        .sheet(isPresented: $showModelBrowser) {
            ModelBrowserView {
                model.refresh()
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.refresh()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Re-probe library, runtime, and metrics")
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(AppIdentity.displayName)
                .font(.largeTitle.weight(.semibold))
            Text(
                "Make a fictional character: name, story, and voice. Then chat in Playground, or Teach them from their stories."
            )
            .font(.body)
            .foregroundStyle(BAMColors.secondaryLabel)

            if model.setup.isReady {
                Button {
                    selection = .characters
                } label: {
                    Label("Start: Create a character", systemImage: "theatermasks")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            } else {
                Text("Finish setup below first — then Create a character unlocks the full path.")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        }
    }

    // MARK: - Environment setup gate

    private var environmentSetupSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title2)
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Setup required")
                        .font(.title2.weight(.semibold))
                    Text(
                        "Apple on-device chat can work with no extra download. Teaching from stories needs teaching tools "
                            + "(Settings → Repair) and a real starting model. A tiny practice model is only for testing screens."
                    )
                    .font(.callout)
                    .foregroundStyle(BAMColors.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(spacing: 10) {
                setupRow(
                    title: "Apple on-device model (default chat)",
                    detail: model.setup.appleDetail,
                    done: model.setup.appleFoundation.isUsable,
                    systemImage: "apple.logo"
                ) {
                    Button("Open Apple Intelligence settings") {
                        // Opens System Settings deep link when possible.
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Siri-Settings.extension") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Playground") {
                        selection = .playground
                    }
                    .buttonStyle(.bordered)
                }

                setupRow(
                    title: "Teaching tools (optional)",
                    detail: model.setup.runtimeDetail,
                    done: model.setup.runtimeInstalled,
                    systemImage: "terminal"
                ) {
                    if model.isInstallingRuntime {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Button(model.setup.runtimeInstalled ? "Repair…" : "Install runtime") {
                            Task { await model.installRuntime() }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isInstallingRuntime)
                    }
                    Button("Settings") {
                        selection = .settings
                    }
                    .buttonStyle(.bordered)
                }

                setupRow(
                    title: "Starting model (optional teach)",
                    detail: model.setup.modelDetail,
                    done: model.setup.hasBaseModel,
                    systemImage: "cpu"
                ) {
                    Button("Tiny practice model") {
                        model.installFixture()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isInstallingFixture)

                    Button("Browse sources") {
                        showModelBrowser = true
                    }
                    .buttonStyle(.bordered)

                    Button("Models") {
                        selection = .models
                    }
                    .buttonStyle(.bordered)
                }
            }

            if let msg = model.setupActionMessage {
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(BAMColors.secondaryLabel)
                    .textSelection(.enabled)
            }
            if let err = model.setupActionError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            HStack {
                Text("\(model.setup.completedCount)/3 ready · Apple preferred for chat")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(BAMColors.secondaryLabel)
                ProgressView(value: model.setup.progress)
                    .progressViewStyle(.linear)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.orange.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.orange.opacity(0.35), lineWidth: 1)
        )
    }

    private var environmentReadyBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.seal.fill")
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 2) {
                Text("Environment ready")
                    .font(.callout.weight(.semibold))
                Text(model.setup.readySummary)
                    .font(.caption)
                    .foregroundStyle(BAMColors.secondaryLabel)
            }
            Spacer()
            Button {
                selection = .characters
            } label: {
                Label("Create character", systemImage: "theatermasks")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.green.opacity(0.12))
        )
    }

    private func setupRow(
        title: String,
        detail: String,
        done: Bool,
        systemImage: String,
        @ViewBuilder actions: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: done ? "checkmark.circle.fill" : systemImage)
                    .foregroundStyle(done ? .green : .orange)
                    .font(.title3)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body.weight(.semibold))
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(BAMColors.secondaryLabel)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 0)
            }
            if !done {
                HStack(spacing: 8) {
                    actions()
                }
                .padding(.leading, 38)
            } else {
                HStack(spacing: 8) {
                    actions()
                }
                .padding(.leading, 38)
                .opacity(0.85)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    // MARK: - Checklist

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
                        .foregroundStyle(done ? BAMColors.secondaryLabel : .primary)
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
            Text("First-run checklist complete — teach, chat, and optionally train without leaving the app.")
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
                linkButton("Characters", .characters, "theatermasks")
                linkButton("Models", .models, "cpu")
                linkButton("Playground", .playground, "bubble.left.and.bubble.right")
                linkButton("Train", .train, "hammer")
                linkButton("Actions", .actions, "bolt.horizontal")
                linkButton("Settings", .settings, "gearshape")
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
        case .importDataset: return .characters
        case .installFixture: return .models
        case .dryRunOrTrain: return .train
        case .playgroundChat: return .playground
        }
    }
}

// MARK: - Setup status

struct EnvironmentSetupStatus: Equatable, Sendable {
    var runtimeInstalled: Bool
    var runtimePath: String
    var hasBaseModel: Bool
    var localModelCount: Int
    var fixtureInstalled: Bool
    /// Apple on-device Foundation Model (preferred Playground default when ready).
    var appleFoundation: AppleFoundationModelStatus
    var appleUnavailableReason: String?

    /// Open-stack train path still wants runtime + local model; chat can use Apple alone.
    var needsAttention: Bool {
        // Prefer Apple: if Apple FM is ready, only surface open-stack gaps as soft optional.
        if appleFoundation.isUsable {
            return false
        }
        return !runtimeInstalled || !hasBaseModel
    }

    var isReady: Bool {
        appleFoundation.isUsable || (runtimeInstalled && hasBaseModel)
    }

    var completedCount: Int {
        var n = 0
        if appleFoundation.isUsable { n += 1 }
        if runtimeInstalled { n += 1 }
        if hasBaseModel { n += 1 }
        return n
    }

    var progress: Double {
        Double(completedCount) / 3.0
    }

    var runtimeDetail: String {
        if runtimeInstalled {
            return "Teaching tools are installed."
        }
        return "Needed only if you want to Teach from stories. Settings → Repair downloads them (large)."
    }

    var modelDetail: String {
        if hasBaseModel {
            var parts = ["\(localModelCount) starting model(s) on this Mac"]
            if fixtureInstalled { parts.append("includes the tiny practice model") }
            return parts.joined(separator: " · ")
        }
        return "Optional if Apple on-device chat works. You need a real starting model to Teach; the tiny practice one is only for screens."
    }

    var appleDetail: String {
        var d = appleFoundation.detail
        if let r = appleUnavailableReason, !r.isEmpty {
            d += " (\(r))"
        }
        return d
    }

    var readySummary: String {
        if appleFoundation.isUsable {
            return "Apple on-device chat is ready. Playground can use it. Teaching from a local model is optional."
        }
        return "Runtime \(runtimeInstalled ? "OK" : "missing") · \(localModelCount) open model(s)"
            + (fixtureInstalled ? " (fixture)" : "")
    }
}

// MARK: - View model

@MainActor
final class HomeOnboardingViewModel: ObservableObject {
    @Published private(set) var checklist = OnboardingChecklistState()
    @Published private(set) var metrics = MVPMetricsSnapshot()
    @Published private(set) var probe = OnboardingLibraryProbe()
    @Published private(set) var setup = EnvironmentSetupStatus(
        runtimeInstalled: false,
        runtimePath: "",
        hasBaseModel: false,
        localModelCount: 0,
        fixtureInstalled: false,
        appleFoundation: .unknown,
        appleUnavailableReason: nil
    )
    @Published private(set) var isInstallingRuntime = false
    @Published private(set) var isInstallingFixture = false
    @Published var setupActionMessage: String?
    @Published var setupActionError: String?

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
        setup = Self.buildSetupStatus(libraryRoot: libraryRoot)
    }

    func dismissChecklist() {
        onboardingStore.dismiss()
        refresh()
    }

    func resetChecklist() {
        onboardingStore.reset()
        refresh()
    }

    func installFixture() {
        isInstallingFixture = true
        setupActionError = nil
        setupActionMessage = nil
        defer { isInstallingFixture = false }
        do {
            let modelsBase = libraryRoot.appendingPathComponent("models/base", isDirectory: true)
            let result = try ModelInstallService(modelsBaseURL: modelsBase).installFixture(overwrite: true)
            OnboardingStore().markCompleted(.installFixture)
            setupActionMessage = "Fixture installed at \(result.modelRecord.localPath)"
            refresh()
        } catch {
            setupActionError = (error as? BAMError)?.errorDescription ?? error.localizedDescription
        }
    }

    func installRuntime() async {
        isInstallingRuntime = true
        setupActionError = nil
        setupActionMessage = "Installing managed Python…"
        defer { isInstallingRuntime = false }

        let installer = RuntimeInstaller(appVersion: RuntimePaths.spikeAppVersion)
        let result = await installer.installManagedRuntime { progress in
            Task { @MainActor in
                self.setupActionMessage = progress.message
            }
        }
        switch result {
        case .success:
            setupActionMessage = "Training runtime installed."
            refresh()
        case .failure(let error):
            setupActionError = error.errorDescription ?? error.message ?? error.code.rawValue
            setupActionMessage = nil
            refresh()
        }
    }

    static func buildSetupStatus(
        libraryRoot: URL,
        fileManager: FileManager = .default
    ) -> EnvironmentSetupStatus {
        let runtime = RuntimeInstaller(appVersion: RuntimePaths.spikeAppVersion).status(fileManager: fileManager)
        let modelsBase = libraryRoot.appendingPathComponent("models/base", isDirectory: true)
        let installer = ModelInstallService(modelsBaseURL: modelsBase)
        let fixture = installer.isFixtureInstalled()
        let scanned = (try? LocalModelScanner(modelsBaseURL: modelsBase).scan()) ?? []
        let count = scanned.count
        let hasBase = count > 0 || fixture
        let apple = AppleFoundationModelSupport.probeStatus()
        return EnvironmentSetupStatus(
            runtimeInstalled: runtime.isInstalled,
            runtimePath: runtime.envRoot.path,
            hasBaseModel: hasBase,
            localModelCount: max(count, fixture ? 1 : 0),
            fixtureInstalled: fixture,
            appleFoundation: apple,
            appleUnavailableReason: AppleFoundationModelSupport.unavailableReasonDescription()
        )
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
        let appleUsable = AppleFoundationModelSupport.probeStatus().isUsable

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
            hasAppleChatModel: appleUsable,
            hasDryRunOrTrain: hasDryRunOrTrain,
            hasPlaygroundChat: hasPlayground
        )
    }
}
