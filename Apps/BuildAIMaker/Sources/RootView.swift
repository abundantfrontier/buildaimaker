import SwiftUI
import BAMControlPlane
import BAMCore
import BAMModelCatalog
import BAMResourcesUI
import BAMConsent

struct RootView: View {
    @State private var selection: SidebarDestination? = .home
    @State private var applyingRemoteRoute = false
    @StateObject private var characterLaunch = CharacterStudioLaunchContext()
    @EnvironmentObject private var controlPlane: ControlPlaneEnvironment
    private let featureFlags = FeatureFlags.default

    var body: some View {
        NavigationSplitView {
            SidebarChrome(selection: $selection)
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 280)
        } detail: {
            // Detail view must stay the destination root (wrappers blank the lists).
            // Coach/confirm sit in the detail column only and do not eat sidebar clicks.
            detail(for: selection ?? .home)
                .overlay(alignment: .top) {
                    AgentChrome()
                }
        }
        .frame(minWidth: 800, minHeight: 500)
        .environmentObject(characterLaunch)
        .environment(\.guideHighlightId, controlPlane.highlight)
        .onChange(of: selection) { _, newValue in
            guard !applyingRemoteRoute, let dest = newValue else { return }
            Task {
                _ = await controlPlane.invoke(
                    NavGoHandler.id,
                    params: .object([
                        "route": .string(dest.rawValue),
                        "reveal": .bool(false),
                    ])
                )
            }
        }
        // Only follow the published route — not every stateRevision, or a
        // sidebar click is snapped back to the previous screen.
        .onChange(of: controlPlane.route) { _, newRoute in
            applyRemoteRoute(newRoute)
        }
        .onAppear {
            applyRemoteRoute(controlPlane.route)
        }
    }

    private func applyRemoteRoute(_ newRoute: String) {
        guard let dest = SidebarDestination(rawValue: newRoute), dest != selection else { return }
        applyingRemoteRoute = true
        selection = dest
        applyingRemoteRoute = false
    }

    @ViewBuilder
    private func detail(for destination: SidebarDestination) -> some View {
        switch destination {
        case .home:
            HomeOnboardingView(selection: $selection)
        case .characters:
            CharactersView(selection: $selection)
        case .datasets:
            DatasetsView()

        case .models:
            ModelsView()
        case .train:
            // Dry-run + full LoRA when ff.llmTraining (default on). Character handoff preselects model/dataset.
            TrainView()
        case .jobs:
            JobsView()
        case .playground:
            // Text + Talk playground. Character handoff binds model path + system prompt.
            if featureFlags.playground {
                PlaygroundView()
            } else {
                PlaceholderDetailView(
                    destination: .playground,
                    subtitle: "Playground is not enabled (ff.playground is off)."
                )
            }
        case .voices:
            // Future use: F5-TTS few-shot clone UI (`VoicesView`). Hidden from the
            // sidebar — the live path is Character → Voice (Kokoro catalog + FX).
            // VoicesView(featureFlags: featureFlags)
            PlaceholderDetailView(
                destination: .voices,
                subtitle: "Voice clone is reserved for a later build. Use a character’s Voice step (Kokoro speakers) instead."
            )
        case .personas:
            // Future use: persona pack zip (`PersonasView`). Playground binds a
            // Character (model + LoRA + Kokoro), not a pack.
            // PersonasView(featureFlags: featureFlags)
            PlaceholderDetailView(
                destination: .personas,
                subtitle: "Persona packs are reserved for a later build. Chat as a character from Playground."
            )
        case .actions:
            AgentActionsView()
        case .settings:
            SettingsView(featureFlags: featureFlags)
        }
    }

}
