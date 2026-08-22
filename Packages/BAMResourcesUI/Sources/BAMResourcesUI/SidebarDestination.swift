import Foundation

/// Top-level navigation destinations shown in the app sidebar.
public enum SidebarDestination: String, CaseIterable, Identifiable, Hashable, Sendable {
    case home
    case characters
    case datasets
    case models
    case train
    case jobs
    case playground
    /// Future: F5-TTS few-shot clone (stub runner today). Hidden from the sidebar.
    case voices
    /// Future: persona pack zip (LLM + voice). Playground binds a Character, not a pack.
    case personas
    case actions
    case settings

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .home: return "Home"
        case .characters: return "Characters"
        case .datasets: return "Datasets"
        case .models: return "Models"
        case .train: return "Train"
        case .jobs: return "Jobs"
        case .playground: return "Playground"
        case .voices: return "Voices"
        case .personas: return "Personas"
        case .actions: return "Actions"
        case .settings: return "Settings"
        }
    }

    public var systemImage: String {
        switch self {
        case .home: return "house"
        case .characters: return "theatermasks"
        case .datasets: return "doc.text"
        case .models: return "cpu"
        case .train: return "hammer"
        case .jobs: return "list.bullet.rectangle"
        case .playground: return "bubble.left.and.bubble.right"
        case .voices: return "waveform"
        case .personas: return "person.2"
        case .actions: return "bolt.horizontal"
        case .settings: return "gearshape"
        }
    }

    /// Primary “toy” destinations vs power-user / research.
    public var isAdvanced: Bool {
        switch self {
        case .datasets, .models, .train, .jobs, .voices, .personas, .actions:
            return true
        case .home, .characters, .playground, .settings:
            return false
        }
    }

    /// Shown in the sidebar. Voices clone + Personas packs stay compiled for a
    /// later ship (see VoicesView / PersonasView) but are not a working studio path.
    public var isUserVisible: Bool {
        switch self {
        case .voices, .personas:
            return false
        default:
            return true
        }
    }
}
