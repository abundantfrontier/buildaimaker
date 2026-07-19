import SwiftUI
import BAMCore
import BAMModelCatalog
import BAMResourcesUI

struct RootView: View {
    @State private var selection: SidebarDestination? = .home
    private let featureFlags = FeatureFlags.default

    var body: some View {
        NavigationSplitView {
            SidebarChrome(selection: $selection)
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 280)
        } detail: {
            detail(for: selection ?? .home)
        }
        .frame(minWidth: 800, minHeight: 500)
    }

    @ViewBuilder
    private func detail(for destination: SidebarDestination) -> some View {
        switch destination {
        case .home:
            HomeOnboardingView(selection: $selection)
        case .datasets:
            DatasetsView()

        case .models:
            ModelsView()
        case .train:
            // Train wizard: dry-run + full LoRA when ff.llmTraining (default on after PR-LLM-LoRA).
            TrainView()
        case .jobs:
            JobsView()
        case .playground:
            // Text playground: base + optional adapter, A/B toggle, JSONL export (ff.playground always on).
            if featureFlags.playground {
                PlaygroundView()
            } else {
                PlaceholderDetailView(
                    destination: .playground,
                    subtitle: "Playground is not enabled (ff.playground is off)."
                )
            }
        case .voices:
            PlaceholderDetailView(
                destination: .voices,
                subtitle: featureFlags.voiceClone
                    ? "Manage voice profiles."
                    : "Voice cloning is not enabled yet (ff.voiceClone is off)."
            )
        case .personas:
            PlaceholderDetailView(
                destination: .personas,
                subtitle: featureFlags.personaPacks
                    ? "Compose persona packs."
                    : "Persona packs are not enabled yet (ff.personaPacks is off)."
            )
        case .settings:
            SettingsPlaceholderView(featureFlags: featureFlags)
        }
    }

}

/// Settings shell: feature flags + managed training runtime install stub.
struct SettingsPlaceholderView: View {
    let featureFlags: FeatureFlags

    @State private var installProgress = RuntimeInstallProgress()
    @State private var installMessage: String?
    @State private var isInstalling = false
    @State private var helperValidationMessage: String?

    private var installer: RuntimeInstaller {
        RuntimeInstaller(appVersion: RuntimePaths.spikeAppVersion)
    }

    private var runtimeStatus: RuntimeInstallStatus {
        installer.status()
    }

    var body: some View {
        Form {
            Section("About") {
                LabeledContent("App", value: AppIdentity.displayName)
                LabeledContent("Runner protocol", value: "v\(ProtocolVersions.runnerProtocolVersion)")
                LabeledContent("Library schema", value: "v\(ProtocolVersions.librarySchemaVersion)")
                LabeledContent("Library root", value: LibraryPaths.libraryRoot.path)
            }

            Section {
                LabeledContent("Status") {
                    Text(runtimeStatus.isInstalled ? "Installed" : "Not installed")
                        .foregroundStyle(runtimeStatus.isInstalled ? .primary : .secondary)
                }
                LabeledContent("App version pin", value: runtimeStatus.appVersion)
                LabeledContent("Env root", value: runtimeStatus.envRoot.path)
                LabeledContent("Size budget", value: runtimeStatus.sizeBudgetLabel)
                Text(
                    "Training uses a managed Python environment (mlx-lm). Download is multi-gigabyte (\(runtimeStatus.sizeBudgetLabel)); wheels install under Application Support after the notarized app is installed—not inside the .app bundle."
                )
                .font(.callout)
                .foregroundStyle(.secondary)

                if isInstalling || installProgress.phase == .downloading || installProgress.phase == .preparing {
                    ProgressView(value: installProgress.fractionCompleted) {
                        Text(installProgress.message.isEmpty ? "Installing…" : installProgress.message)
                    } currentValueLabel: {
                        Text(byteProgressLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let installMessage {
                    Text(installMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                if let err = runtimeStatus.lastError {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Button {
                    Task { await runInstallStub() }
                } label: {
                    Label(
                        runtimeStatus.isInstalled ? "Repair training runtime" : "Install training runtime",
                        systemImage: "arrow.down.circle"
                    )
                }
                .disabled(isInstalling || !featureFlags.llmTraining)
                .help(
                    featureFlags.llmTraining
                        ? "Download managed Python wheels (\(runtimeStatus.sizeBudgetLabel) budget)."
                        : "Enable ff.llmTraining to install the training runtime."
                )

                if !featureFlags.llmTraining {
                    Text("ff.llmTraining is off — install control is disabled in this shell.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Training runtime")
            } footer: {
                Text("Two-layer trust: UI launches only TeamID-signed Helpers/bam-*-worker via WorkerSpawn.prepareHelperLaunch (L1); helper verifies runtime-pins.json before exec (L2). Fail closed: BAM_RUNTIME_INTEGRITY.")
            }

            Section {
                Text("Before any Process launch, the supervisor must call WorkerSpawn.prepareHelperLaunch (L1 TeamID / validity). This control exercises that gate without starting a worker.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                if let helperValidationMessage {
                    Text(helperValidationMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                Button {
                    validateHelperL1()
                } label: {
                    Label("Validate helper (L1)", systemImage: "checkmark.shield")
                }
                .help("Resolve bam-llm-worker and run WorkerTrust via WorkerSpawn.prepareHelperLaunch.")
            } header: {
                Text("Worker trust")
            }

            Section("Feature flags") {
                ForEach(FeatureFlags.Key.allCases, id: \.rawValue) { key in
                    LabeledContent(key.rawValue) {
                        Text(featureFlags.isEnabled(key) ? "On" : "Off")
                            .foregroundStyle(featureFlags.isEnabled(key) ? .primary : .secondary)
                    }
                }
            }

            Section {
                metricsSettingsRows
                Text("Local UserDefaults counters only (PR-Onboarding). Not remote telemetry.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Reset local metrics") {
                    MVPMetricsStore.shared.resetAll()
                }
                Button("Reset first-run checklist") {
                    OnboardingStore().reset()
                }
            } header: {
                Text("MVP metrics (M1–M5)")
            }

            Section {
                Toggle(
                    "Write playground_trace.json",
                    isOn: Binding(
                        get: {
                            UserDefaults.standard.object(
                                forKey: "bam.playgroundTrace.enabled"
                            ) as? Bool ?? true
                        },
                        set: { UserDefaults.standard.set($0, forKey: "bam.playgroundTrace.enabled") }
                    )
                )
                Text(
                    "Optional BAMInference diagnostics under \(LibraryPaths.libraryRoot.path)/diagnostics/playground_trace.json. Env BAM_PLAYGROUND_TRACE=0 forces off."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            } header: {
                Text("Playground diagnostics")
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle(SidebarDestination.settings.title)
    }

    @ViewBuilder
    private var metricsSettingsRows: some View {
        let metrics = MVPMetricsStore.shared.snapshot()
        ForEach(MVPMetricEvent.allCases) { event in
            LabeledContent("\(event.metricId) \(event.displayName)") {
                Text("\(metrics.count(for: event))")
                    .monospacedDigit()
            }
        }
        LabeledContent("M5 network-free") {
            Text(metrics.m5Passes ? "Pass" : "Fail")
                .foregroundStyle(metrics.m5Passes ? Color.primary : Color.red)
        }
    }

    private var byteProgressLabel: String {
        let received = installProgress.bytesReceived
        let expected = installProgress.bytesExpected
        guard expected > 0 else { return "" }
        return "\(formatBytes(received)) / \(formatBytes(expected))"
    }

    private func formatBytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    /// L1 call site: only path the UI uses to approve a helper before spawn.
    private func validateHelperL1() {
        do {
            // Prefer bundled Helpers when running as a real .app; else dev build product.
            let bundleURL: URL? = {
                let b = Bundle.main.bundleURL
                let helpers = WorkerTrust.helpersDirectory(inBundle: b)
                if FileManager.default.fileExists(atPath: helpers.path) {
                    return b
                }
                return nil
            }()
            let prepared = try WorkerSpawn.prepareHelperLaunch(
                helperName: WorkerSpawn.llmWorkerName,
                bundleURL: bundleURL,
                mode: WorkerTrust.defaultMode
            )
            helperValidationMessage =
                "L1 OK (\(prepared.mode)): \(prepared.url.path)"
        } catch let error as BAMError {
            helperValidationMessage = error.errorDescription ?? error.code.rawValue
        } catch {
            helperValidationMessage = String(describing: error)
        }
    }

    @MainActor
    private func runInstallStub() async {
        isInstalling = true
        installMessage = nil
        installProgress = RuntimeInstallProgress(
            phase: .preparing,
            bytesReceived: 0,
            bytesExpected: runtimeStatus.sizeBudgetBytes,
            message: "Starting…"
        )
        let result = await installer.installStub { progress in
            Task { @MainActor in
                installProgress = progress
            }
        }
        isInstalling = false
        switch result {
        case .success:
            installProgress.phase = .complete
            installMessage = "Training runtime installed."
        case .failure(let error):
            installProgress.phase = .failed
            // Stub uses BAM_CANCELLED — not BAM_RUNTIME_INTEGRITY.
            installMessage = error.errorDescription
                ?? "Install not performed (\(error.code.rawValue)). Multi-GB download is deferred in this spike."
        }
    }
}
