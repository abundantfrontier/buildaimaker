import SwiftUI
import AppKit
import BAMCore
import BAMPersistence
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

/// Settings shell: about, feature flags, and library archive backup.
struct SettingsPlaceholderView: View {
    let featureFlags: FeatureFlags

    @State private var includeModelWeights = false
    @State private var isExporting = false
    @State private var exportStatus: String?
    @State private var exportError: String?

    var body: some View {
        Form {
            Section("About") {
                LabeledContent("App", value: AppIdentity.displayName)
                LabeledContent("Runner protocol", value: "v\(ProtocolVersions.runnerProtocolVersion)")
                LabeledContent("Library schema", value: "v\(ProtocolVersions.librarySchemaVersion)")
                LabeledContent("Library root", value: LibraryPaths.libraryRoot.path)
            }

            Section {
                Text(LibraryArchiveExporter.defaultWeightsSkipNote)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle("Include model weights", isOn: $includeModelWeights)
                    .help("When off, models/base and models/adapters are omitted from the archive.")

                Button("Export library archive…") {
                    exportLibraryArchive()
                }
                .disabled(isExporting)

                if isExporting {
                    ProgressView("Exporting…")
                        .controlSize(.small)
                }
                if let exportStatus {
                    Text(exportStatus)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                if let exportError {
                    Text(exportError)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            } header: {
                Text("Library durability")
            } footer: {
                Text(
                    "Creates a zip of library.sqlite (SQLite online backup), config, consent, personas, datasets, voices, and jobs. Python envs and download cache are always skipped from this panel. Prefer exporting when the app is idle for the calmest snapshot."
                )
            }

            Section("Feature flags") {
                ForEach(FeatureFlags.Key.allCases, id: \.rawValue) { key in
                    LabeledContent(key.rawValue) {
                        Text(featureFlags.isEnabled(key) ? "On" : "Off")
                            .foregroundStyle(featureFlags.isEnabled(key) ? .primary : .secondary)
                    }
                }
            }

            // K22 / PR-Remote-Fake: remote backend is interface-only; no real cloud/SSH in v1.
            Section("Remote training") {
                LabeledContent("Status") {
                    Text(CloudPolicy.deferredMessage)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent(FeatureFlags.Key.cloudRunner.rawValue) {
                    Text(featureFlags.cloudRunner ? "On" : "Off")
                        .foregroundStyle(featureFlags.cloudRunner ? .primary : .secondary)
                }
                Text("Local Apple Silicon only for v1. Real cloud/SSH deferred until after product-market fit. Fake remote runner exists for API stability only.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle(SidebarDestination.settings.title)
    }

    /// Presents a save panel, then runs export off the main actor.
    private func exportLibraryArchive() {
        exportStatus = nil
        exportError = nil

        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = LibraryArchiveExporter.suggestedArchiveFileName()
        panel.title = "Export library archive"
        panel.message = includeModelWeights
            ? "Full archive including model weights. library.sqlite is snapshotted via online backup."
            : "Archive excludes large model weights (recommended). library.sqlite is snapshotted via online backup."
        panel.prompt = "Export"

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        isExporting = true
        let includeWeights = includeModelWeights
        DispatchQueue.global(qos: .userInitiated).async {
            let options = LibraryArchiveExportOptions(
                includeModelWeights: includeWeights,
                includePythonEnvs: false,
                includeDownloadCache: false,
                compressToZip: true
            )
            do {
                // Exporter fails closed with BAM_EXPORT_FAILED if library root / sqlite is missing.
                let result = try LibraryArchiveExporter.exportDefaultLibrary(
                    to: url,
                    options: options
                )
                DispatchQueue.main.async {
                    isExporting = false
                    exportStatus =
                        "Exported \(result.includedRelativePaths.count) entries (~\(Self.formatBytes(result.bytesCopied))) → \(result.archiveURL.path)"
                    exportError = nil
                }
            } catch let error as BAMError {
                DispatchQueue.main.async {
                    isExporting = false
                    exportError = error.errorDescription ?? error.code.rawValue
                }
            } catch {
                DispatchQueue.main.async {
                    isExporting = false
                    exportError = error.localizedDescription
                }
            }
        }
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
