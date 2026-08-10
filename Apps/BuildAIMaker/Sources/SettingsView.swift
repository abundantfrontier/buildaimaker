import BAMConsent
import BAMCore
import BAMResourcesUI
import SwiftUI

/// Settings: runtime install, flags, consent, metrics — layout fixed for macOS.
struct SettingsView: View {
    let featureFlags: FeatureFlags
    @State private var showConsent = false
    @State private var installProgress = RuntimeInstallProgress()
    @State private var installMessage: String?
    @State private var isInstalling = false
    @State private var helperValidationMessage: String?
    @State private var statusRefresh = 0

    private var installer: RuntimeInstaller {
        RuntimeInstaller(appVersion: RuntimePaths.spikeAppVersion)
    }

    private var runtimeStatus: RuntimeInstallStatus {
        _ = statusRefresh
        return installer.status()
    }

    var body: some View {
        Group {
            if showConsent {
                ConsentLibraryShell(onDismiss: { showConsent = false })
            } else {
                settingsForm
            }
        }
        .navigationTitle(SidebarDestination.settings.title)
    }

    private var settingsForm: some View {
        Form {
            Section("About") {
                LabeledContent("App", value: AppIdentity.displayName)
                LabeledContent("Runner protocol", value: "v\(ProtocolVersions.runnerProtocolVersion)")
                LabeledContent("Library schema", value: "v\(ProtocolVersions.librarySchemaVersion)")
                Text(LibraryPaths.libraryRoot.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Section {
                LabeledContent("Status") {
                    Text(runtimeStatus.isInstalled ? "Installed" : "Not installed")
                        .foregroundStyle(runtimeStatus.isInstalled ? .green : .orange)
                        .fontWeight(.semibold)
                }
                LabeledContent("App version pin", value: runtimeStatus.appVersion)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Env root")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(runtimeStatus.envRoot.path)
                        .font(.caption)
                        .textSelection(.enabled)
                }
                LabeledContent("Heavy wheel budget", value: runtimeStatus.sizeBudgetLabel)

                Text(
                    """
                    Install creates a local Python venv under Application Support (uses system python3). \
                    Full multi‑GB mlx-lm / F5 wheels are not auto-downloaded yet — venv is enough for path wiring and light tests.
                    """
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                if isInstalling {
                    ProgressView(value: installProgress.fractionCompleted) {
                        Text(installProgress.message.isEmpty ? "Installing…" : installProgress.message)
                    }
                }

                if let installMessage {
                    Text(installMessage)
                        .font(.callout)
                        .foregroundStyle(installProgress.phase == .failed ? .red : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let err = runtimeStatus.lastError {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button {
                    Task { await runInstall() }
                } label: {
                    Label(
                        runtimeStatus.isInstalled ? "Repair / reinstall runtime" : "Install training runtime",
                        systemImage: "arrow.down.circle"
                    )
                }
                .disabled(isInstalling)
                .buttonStyle(.borderedProminent)

                if runtimeStatus.isInstalled {
                    Text("Python venv is present. Train may still need ML packages installed separately.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Training runtime")
            } footer: {
                Text("Two-layer trust: signed Helpers (L1) + runtime-pins.json (L2). Fail closed: BAM_RUNTIME_INTEGRITY.")
            }

            Section {
                Text("Checks that a helper binary can be resolved for L1 trust (does not start training).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let helperValidationMessage {
                    Text(helperValidationMessage)
                        .font(.caption)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button {
                    validateHelperL1()
                } label: {
                    Label("Validate helper (L1)", systemImage: "checkmark.shield")
                }
            } header: {
                Text("Worker trust")
            }

            Section("Voice consent") {
                Text("Consent records bound by content hash before voice cloning.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Manage consent records…") {
                    showConsent = true
                }
            }

            Section("Feature flags (read-only)") {
                ForEach(FeatureFlags.Key.allCases, id: \.rawValue) { key in
                    LabeledContent(key.rawValue) {
                        Text(featureFlags.isEnabled(key) ? "On" : "Off")
                            .foregroundStyle(featureFlags.isEnabled(key) ? .primary : .secondary)
                    }
                }
                Text("ff.llmTraining does not block Install — runtime is always available for dogfood.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Section {
                metricsSettingsRows
                Text("Local UserDefaults only — not remote telemetry.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Reset local metrics") {
                    MVPMetricsStore.shared.resetAll()
                    statusRefresh += 1
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
                            UserDefaults.standard.object(forKey: "bam.playgroundTrace.enabled") as? Bool ?? true
                        },
                        set: { UserDefaults.standard.set($0, forKey: "bam.playgroundTrace.enabled") }
                    )
                )
                Text("Diagnostics under Application Support …/diagnostics/")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Playground diagnostics")
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: 720)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private var metricsSettingsRows: some View {
        let metrics = MVPMetricsStore.shared.snapshot()
        ForEach(MVPMetricEvent.allCases) { event in
            LabeledContent("\(event.metricId)") {
                Text("\(metrics.count(for: event))")
                    .monospacedDigit()
            }
        }
        LabeledContent("M5 network-free") {
            Text(metrics.m5Passes ? "Pass" : "Fail")
                .foregroundStyle(metrics.m5Passes ? Color.primary : Color.red)
        }
    }

    private func validateHelperL1() {
        do {
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
            helperValidationMessage = "L1 OK (\(prepared.mode)): \(prepared.url.path)"
        } catch let error as BAMError {
            helperValidationMessage = error.errorDescription ?? error.code.rawValue
        } catch {
            helperValidationMessage = String(describing: error)
        }
    }

    @MainActor
    private func runInstall() async {
        isInstalling = true
        installMessage = nil
        installProgress = RuntimeInstallProgress(
            phase: .preparing,
            bytesReceived: 0,
            bytesExpected: runtimeStatus.sizeBudgetBytes,
            message: "Starting…"
        )
        let result = await installer.installManagedRuntime { progress in
            Task { @MainActor in
                installProgress = progress
            }
        }
        isInstalling = false
        statusRefresh += 1
        switch result {
        case .success:
            installProgress.phase = .complete
            installMessage = "Managed Python venv installed. Status should show Installed."
        case .failure(let error):
            installProgress.phase = .failed
            installMessage = error.errorDescription
                ?? "Install failed (\(error.code.rawValue))."
        }
    }
}
