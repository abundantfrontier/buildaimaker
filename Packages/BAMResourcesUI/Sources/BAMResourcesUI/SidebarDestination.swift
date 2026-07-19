import Foundation

/// Top-level navigation destinations shown in the app sidebar.
public enum SidebarDestination: String, CaseIterable, Identifiable, Hashable, Sendable {
    case home
    case datasets
    case models
    case train
    case jobs
    case playground
    case voices
    case personas
    case settings

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .home: return "Home"
        case .datasets: return "Datasets"
        case .models: return "Models"
        case .train: return "Train"
        case .jobs: return "Jobs"
        case .playground: return "Playground"
        case .voices: return "Voices"
        case .personas: return "Personas"
        case .settings: return "Settings"
        }
    }

    public var systemImage: String {
        switch self {
        case .home: return "house"
        case .datasets: return "doc.text"
        case .models: return "cpu"
        case .train: return "hammer"
        case .jobs: return "list.bullet.rectangle"
        case .playground: return "bubble.left.and.bubble.right"
        case .voices: return "waveform"
        case .personas: return "person.2"
        case .settings: return "gearshape"
        }
    }
}
