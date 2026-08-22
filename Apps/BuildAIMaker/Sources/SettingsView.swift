import AppKit
import BAMAudioFX
import BAMConsent
import BAMCore
import BAMInference
import BAMResourcesUI
import BAMRunnersMLX
import SwiftUI

/// Settings: runtime install, flags, consent, metrics — layout fixed for macOS.
struct SettingsView: View {
    let featureFlags: FeatureFlags
    @EnvironmentObject private var controlPlane: ControlPlaneEnvironment
    @State private var showConsent = false
    @State private var installProgress = RuntimeInstallProgress()
    @State private var installMessage: String?
    @State private var isInstalling = false
    @State private var helperValidationMessage: String?
    @State private var statusRefresh = 0
    @State private var mcpCopyMessage: String?

    private var installer: RuntimeInstaller {
        RuntimeInstaller(appVersion: RuntimePaths.spikeAppVersion)
    }

    private var runtimeStatus: RuntimeInstallStatus {
        _ = statusRefresh
        return installer.status()
    }

    private var mlxImportLabel: String {
        _ = statusRefresh
        return MLXGenerateBackend.isAvailable() ? "Importable" : "Not in venv"
    }

    private var trainWorkerFound: Bool {
        _ = statusRefresh
        return (try? MLXWorkerClient.resolveWorkerExecutable()) != nil
    }

    private var trainWorkerLabel: String {
        _ = statusRefresh
        if let url = try? MLXWorkerClient.resolveWorkerExecutable() {
            return url.lastPathComponent
        }
        return "Not found"
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
                LabeledContent("Socket") {
                    Text(MCPClientConfig.socketExists ? "Listening" : "Not found")
                        .foregroundStyle(MCPClientConfig.socketExists ? .green : .orange)
                        .fontWeight(.semibold)
                }
                Text(MCPClientConfig.socketPath)
                    .font(.caption)
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
                LabeledContent("Token file") {
                    Text(MCPClientConfig.tokenExists ? "Present" : "Missing")
                        .foregroundStyle(MCPClientConfig.tokenExists ? .green : .orange)
                }
                Text(MCPClientConfig.tokenPath)
                    .font(.caption)
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
                if let rpc = controlPlane.rpcStatus {
                    Text(rpc)
                        .font(.caption)
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                }
                Text(
                    """
                    Leave BuildAIMaker running, then point Grok (or another MCP host) at \
                    buildaimaker-mcp. Expensive and destructive tools pause for the orange banner.
                    """
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                Button {
                    copyToPasteboard(MCPClientConfig.grokSnippet())
                    mcpCopyMessage = "Copied Grok snippet"
                } label: {
                    Label("Copy Grok snippet", systemImage: "doc.on.clipboard")
                }
                .buttonStyle(.borderedProminent)
                Button {
                    copyToPasteboard(MCPClientConfig.socketPath)
                    mcpCopyMessage = "Copied socket path"
                } label: {
                    Label("Copy socket path", systemImage: "link")
                }
                if let mcpCopyMessage {
                    Text(mcpCopyMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("MCP / agents")
            } footer: {
                Text("See Docs/mcp-bridge.md. Bridge binary: \(MCPClientConfig.resolveBridgeBinary())")
            }

            Section {
                LabeledContent("Catalog") {
                    Text(catalogStatusLabel)
                        .foregroundStyle(catalogStatusColor)
                        .fontWeight(.semibold)
                }
                Text("Kokoro speakers live under Application Support. Each character card uses a different throat. Mac voices are the fallback.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(CatalogTTSRuntime.modelDirectory.path)
                    .font(.caption)
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
                Button {
                    Task { await CatalogTTSRuntime.ensureReady(); statusRefresh += 1 }
                } label: {
                    Label("Install / repair character voices", systemImage: "waveform")
                }
            } header: {
                Text("Character voices")
            }

            Section {
                LabeledContent("Status") {
                    Text(runtimeStatus.isInstalled ? "Installed" : "Not installed")
                        .foregroundStyle(runtimeStatus.isInstalled ? .green : .orange)
                        .fontWeight(.semibold)
                }
                LabeledContent("mlx-lm") {
                    Text(mlxImportLabel)
                        .foregroundStyle(MLXGenerateBackend.isAvailable() ? .green : .orange)
                        .fontWeight(.semibold)
                }
                LabeledContent("Train worker") {
                    Text(trainWorkerLabel)
                        .foregroundStyle(trainWorkerFound ? .green : .orange)
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
                    Repair refreshes worker pin hashes, recreates a 3.10+ venv if needed, \
                    and installs mlx-lm (several GB) so Train can run a real LoRA — not a fake job.
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

                if runtimeStatus.isInstalled, runtimeStatus.lastError == nil {
                    Text("If Train still fakes the run, click Repair to install mlx-lm into this venv.")
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

    private func copyToPasteboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    private var catalogStatusLabel: String {
        _ = statusRefresh
        switch CatalogTTSRuntime.currentStatus() {
        case .ready: return "Ready"
        case .installing(let note): return note
        case .failed(let err): return "Failed — \(err)"
        case .missing: return "Not installed"
        }
    }

    private var catalogStatusColor: Color {
        switch CatalogTTSRuntime.currentStatus() {
        case .ready: return .green
        case .installing: return .orange
        case .failed: return .red
        case .missing: return .orange
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
        let result = await installer.repair { progress in
            Task { @MainActor in
                installProgress = progress
            }
        }
        isInstalling = false
        statusRefresh += 1
        switch result {
        case .success:
            MLXGenerateBackend.invalidateAvailabilityCache()
            installProgress.phase = .complete
            if MLXGenerateBackend.isAvailable(), trainWorkerFound {
                installMessage = "Training runtime ready. mlx-lm imports and the worker was found."
            } else if MLXGenerateBackend.isAvailable() {
                installMessage = "mlx-lm imports, but the train worker is still missing. Rebuild BuildAIMaker."
            } else {
                installMessage = "Venv repaired, but mlx-lm still does not import. Check the error above."
            }
        case .failure(let error):
            installProgress.phase = .failed
            installMessage = error.errorDescription
                ?? "Install failed (\(error.code.rawValue))."
        }
    }
}
