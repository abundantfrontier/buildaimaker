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
            PlaceholderDetailView(
                destination: .home,
                subtitle: homeSubtitle
            )
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
            PlaceholderDetailView(
                destination: .playground,
                subtitle: "Chat against base models and adapters."
            )
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

    private var homeSubtitle: String {
        "\(AppIdentity.displayName) — local-first AI fine-tuning on Apple Silicon. Requires \(AppIdentity.minimumUnifiedMemoryGB) GB unified memory."
    }
}

/// Settings shell: feature flags, managed training runtime install/repair,
/// L1 helper gate, and diagnostics export.
struct SettingsPlaceholderView: View {
    let featureFlags: FeatureFlags

    @State private var installProgress = RuntimeInstallProgress()
    @State private var installMessage: String?
    @State private var isInstalling = false
    @State private var helperValidationMessage: String?
    @State private var integrityMessage: String?
    @State private var integrityOK = true
    @State private var diagnosticsMessage: String?
    @State private var isExportingDiagnostics = false
    /// Bumps to refresh `runtimeStatus` after repair / re-check.
    @State private var statusTick = 0

    private var installer: RuntimeInstaller {
        RuntimeInstaller(appVersion: RuntimePaths.spikeAppVersion)
    }

    private var runtimeStatus: RuntimeInstallStatus {
        _ = statusTick
        return installer.status()
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
                if !integrityOK || runtimeStatus.lastError != nil {
                    Label(
                        RuntimeRecovery.shortCTA,
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.red)
                    .font(.callout)
                }

                LabeledContent("Status") {
                    Text(runtimeStatus.isInstalled ? "Installed" : "Not installed")
                        .foregroundStyle(runtimeStatus.isInstalled ? .primary : .secondary)
                }
                LabeledContent("App version pin", value: runtimeStatus.appVersion)
                LabeledContent("Env root", value: runtimeStatus.envRoot.path)
                LabeledContent("Size budget", value: runtimeStatus.sizeBudgetLabel)
                LabeledContent("Integrity") {
                    Text(integrityOK ? "OK" : "Failed")
                        .foregroundStyle(integrityOK ? Color.primary : Color.red)
                }
                Text(
                    "Training uses a managed Python environment (mlx-lm). Download is multi-gigabyte (\(runtimeStatus.sizeBudgetLabel)); wheels install under Application Support after the notarized app is installed—not inside the .app bundle. TeamID is never applied to the venv."
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
                        .textSelection(.enabled)
                }

                if let err = runtimeStatus.lastError {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }

                if let integrityMessage {
                    Text(integrityMessage)
                        .font(.caption)
                        .foregroundStyle(integrityOK ? Color.secondary : Color.red)
                        .textSelection(.enabled)
                }

                HStack {
                    Button {
                        Task { await runInstallOrRepair(repair: runtimeStatus.isInstalled || !integrityOK) }
                    } label: {
                        Label(
                            runtimeStatus.isInstalled || !integrityOK
                                ? RuntimeRecovery.repairActionTitle
                                : "Install training runtime",
                            systemImage: "arrow.down.circle"
                        )
                    }
                    .disabled(isInstalling || !featureFlags.llmTraining)
                    .help(
                        featureFlags.llmTraining
                            ? "Wipe managed env (if present) and reinstall from pins (\(runtimeStatus.sizeBudgetLabel) budget)."
                            : "Enable ff.llmTraining to install the training runtime."
                    )

                    Button {
                        recheckIntegrity()
                    } label: {
                        Label("Re-check pins", systemImage: "checkmark.seal")
                    }
                    .help("Re-run L2 runtime-pins.json lock/entry hash verification.")
                }

                if !featureFlags.llmTraining {
                    Text("ff.llmTraining is off — install control is disabled in this shell.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Training runtime")
            } footer: {
                Text("Two-layer trust: UI launches only TeamID-signed Helpers/bam-*-worker via WorkerSpawn.prepareHelperLaunch (L1); helper verifies runtime-pins.json before exec (L2). Fail closed: BAM_RUNTIME_INTEGRITY → \(RuntimeRecovery.shortCTA) System Python is never a fallback.")
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

            Section {
                Text("Exports versions, feature flags, runtime status, and recent job events.jsonl (sample text redacted). Does not include datasets or model weights.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                if let diagnosticsMessage {
                    Text(diagnosticsMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                Button {
                    Task { await exportDiagnostics() }
                } label: {
                    if isExportingDiagnostics {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Export diagnostics…", systemImage: "shippingbox")
                    }
                }
                .disabled(isExportingDiagnostics)
                .help("Write a redacted diagnostics folder under Application Support.")
            } header: {
                Text("Diagnostics")
            }

            Section("Feature flags") {
                ForEach(FeatureFlags.Key.allCases, id: \.rawValue) { key in
                    LabeledContent(key.rawValue) {
                        Text(featureFlags.isEnabled(key) ? "On" : "Off")
                            .foregroundStyle(featureFlags.isEnabled(key) ? .primary : .secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle(SidebarDestination.settings.title)
        .onAppear { recheckIntegrity() }
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
            helperValidationMessage = RuntimeRecovery.userMessage(for: error)
                ?? (error.errorDescription ?? error.code.rawValue)
        } catch {
            helperValidationMessage = String(describing: error)
        }
    }

    private func recheckIntegrity() {
        let result = installer.recheckIntegrity()
        integrityOK = result.isOK
        if result.isOK {
            integrityMessage = result.detail ?? "L2 pins OK"
        } else {
            integrityMessage = (result.detail ?? BAMErrorCode.runtimeIntegrity.rawValue)
                + "\n" + RuntimeRecovery.shortCTA
        }
        statusTick += 1
    }

    @MainActor
    private func runInstallOrRepair(repair: Bool) async {
        isInstalling = true
        installMessage = nil
        installProgress = RuntimeInstallProgress(
            phase: .preparing,
            bytesReceived: 0,
            bytesExpected: runtimeStatus.sizeBudgetBytes,
            message: repair ? "Starting repair…" : "Starting…"
        )
        let result: Result<Void, BAMError>
        if repair {
            result = await installer.repair { progress in
                Task { @MainActor in
                    installProgress = progress
                }
            }
        } else {
            result = await installer.installStub { progress in
                Task { @MainActor in
                    installProgress = progress
                }
            }
        }
        isInstalling = false
        statusTick += 1
        recheckIntegrity()
        switch result {
        case .success:
            installProgress.phase = .complete
            installMessage = repair
                ? "Training runtime repaired."
                : "Training runtime installed."
        case .failure(let error):
            installProgress.phase = .failed
            // Stub uses BAM_CANCELLED — not BAM_RUNTIME_INTEGRITY.
            if error.code == .runtimeIntegrity {
                installMessage = RuntimeRecovery.userMessage(for: error)
            } else {
                installMessage = error.errorDescription
                    ?? "Install not performed (\(error.code.rawValue)). Multi-GB download is deferred in this spike."
            }
        }
    }

    @MainActor
    private func exportDiagnostics() async {
        isExportingDiagnostics = true
        diagnosticsMessage = nil
        defer { isExportingDiagnostics = false }
        do {
            let stamp = ISO8601DateFormatter().string(from: Date())
                .replacingOccurrences(of: ":", with: "-")
            let dest = LibraryPaths.libraryRoot
                .appendingPathComponent("diagnostics", isDirectory: true)
                .appendingPathComponent("export-\(stamp)", isDirectory: true)
            let result = try DiagnosticsExporter.export(
                libraryRoot: LibraryPaths.libraryRoot,
                to: dest,
                featureFlags: featureFlags
            )
            diagnosticsMessage =
                "Exported \(result.includedJobIds.count) job(s) → \(result.destinationURL.path)"
        } catch {
            diagnosticsMessage = error.localizedDescription
        }
    }
}
