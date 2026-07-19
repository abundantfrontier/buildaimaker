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

/// Lightweight settings shell listing feature-flag state (all off in scaffold).
struct SettingsPlaceholderView: View {
    let featureFlags: FeatureFlags

    var body: some View {
        Form {
            Section("About") {
                LabeledContent("App", value: AppIdentity.displayName)
                LabeledContent("Runner protocol", value: "v\(ProtocolVersions.runnerProtocolVersion)")
                LabeledContent("Library schema", value: "v\(ProtocolVersions.librarySchemaVersion)")
                LabeledContent("Library root", value: LibraryPaths.libraryRoot.path)
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
}
