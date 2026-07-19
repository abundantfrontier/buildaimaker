import SwiftUI
import BAMCore
import BAMModelCatalog
import BAMResourcesUI
import BAMConsent

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
        case .characters:
            CharactersView(selection: $selection)
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
            // Text + Talk playground: chat, PTT STT→LLM→TTS (ff.playground / ff.talkMode).
            if featureFlags.playground {
                PlaygroundView()
            } else {
                PlaceholderDetailView(
                    destination: .playground,
                    subtitle: "Playground is not enabled (ff.playground is off)."
                )
            }
        case .voices:
            VoicesView(featureFlags: featureFlags)
        case .personas:
            // Persona composition + Pack Format v1 import/export (ff.personaPacks on after PR-Persona).
            PersonasView(featureFlags: featureFlags)
        case .settings:
            SettingsView(featureFlags: featureFlags)
        }
    }

}
