import SwiftUI
import BAMCore
import BAMConsent
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
            VoicesPlaceholderView(featureFlags: featureFlags)
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

/// Voices shell: consent attestation available before full voice-clone UI (PR-Voice-UI).
struct VoicesPlaceholderView: View {
    let featureFlags: FeatureFlags
    @State private var showConsent = false
    @State private var consentService: ConsentService?

    var body: some View {
        Group {
            if showConsent, let consentService {
                ConsentRecordsView(service: consentService)
            } else {
                VStack(spacing: 16) {
                    Image(systemName: SidebarDestination.voices.systemImage)
                        .font(.system(size: 48, weight: .light))
                        .foregroundStyle(.secondary)
                    Text(SidebarDestination.voices.title)
                        .font(.title2.weight(.semibold))
                    Text(subtitle)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 400)
                    Button("Voice consent attestations…") {
                        openConsent()
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle(SidebarDestination.voices.title)
            }
        }
    }

    private var subtitle: String {
        if featureFlags.voiceClone {
            return "Manage voice profiles. Consent records are required before cloning."
        }
        return "Voice cloning is not enabled yet (ff.voiceClone is off). You can still create consent records."
    }

    private func openConsent() {
        do {
            if consentService == nil {
                let db = try BAMPersistence.LibraryDatabase.openDefault()
                let store = ConsentStore(
                    database: db,
                    consentDirectory: LibraryPaths.consent,
                    writeJSONFiles: true
                )
                consentService = ConsentService(store: store)
            }
            showConsent = true
        } catch {
            // Fall back to in-memory so the form is still reachable if library open fails.
            if let mem = try? ConsentService.makeInMemory(writeJSONFiles: false) {
                consentService = mem
                showConsent = true
            }
        }
    }
}

/// Settings shell: feature flags + consent attestation entry point.
struct SettingsPlaceholderView: View {
    let featureFlags: FeatureFlags
    @State private var showConsent = false
    @State private var consentService: ConsentService?

    var body: some View {
        Group {
            if showConsent, let consentService {
                ConsentRecordsView(service: consentService)
            } else {
                Form {
                    Section("About") {
                        LabeledContent("App", value: AppIdentity.displayName)
                        LabeledContent("Runner protocol", value: "v\(ProtocolVersions.runnerProtocolVersion)")
                        LabeledContent("Library schema", value: "v\(ProtocolVersions.librarySchemaVersion)")
                        LabeledContent("Library root", value: LibraryPaths.libraryRoot.path)
                    }

                    Section("Voice consent") {
                        Text(
                            "Create and review consent records bound by canonical content hash before voice cloning."
                        )
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        Button("Manage consent records…") {
                            openConsent()
                        }
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
        }
    }

    private func openConsent() {
        do {
            if consentService == nil {
                let db = try BAMPersistence.LibraryDatabase.openDefault()
                let store = ConsentStore(
                    database: db,
                    consentDirectory: LibraryPaths.consent,
                    writeJSONFiles: true
                )
                consentService = ConsentService(store: store)
            }
            showConsent = true
        } catch {
            if let mem = try? ConsentService.makeInMemory(writeJSONFiles: false) {
                consentService = mem
                showConsent = true
            }
        }
    }
}
