import SwiftUI
import BAMCore
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
            PlaceholderDetailView(
                destination: .datasets,
                subtitle: "Import and manage training datasets."
            )
        case .models:
            PlaceholderDetailView(
                destination: .models,
                subtitle: "Browse base models and adapters."
            )
        case .train:
            PlaceholderDetailView(
                destination: .train,
                subtitle: featureFlags.llmTraining
                    ? "Configure a fine-tuning job."
                    : "LLM training is not enabled yet (ff.llmTraining is off)."
            )
        case .jobs:
            PlaceholderDetailView(
                destination: .jobs,
                subtitle: "Queue, progress, and job history."
            )
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

/// Settings shell: feature flags + managed training runtime install stub.
struct SettingsPlaceholderView: View {
    let featureFlags: FeatureFlags

    @State private var installProgress = RuntimeInstallProgress()
    @State private var installMessage: String?
    @State private var isInstalling = false

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
                Text("Two-layer trust: UI launches only TeamID-signed Helpers/bam-*-worker (L1); helper verifies runtime-pins.json before exec (L2). Fail closed: BAM_RUNTIME_INTEGRITY.")
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
            installMessage = error.errorDescription
                ?? "Install failed (\(error.code.rawValue)). Multi-GB download is not performed in this spike."
        }
    }
}
