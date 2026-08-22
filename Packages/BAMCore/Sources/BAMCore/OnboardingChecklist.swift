import Foundation

/// First-run Home checklist steps (PR-Onboarding).
///
/// Order matches the intended creator path: dataset → base model → train/dry-run → playground.
public enum OnboardingStep: String, CaseIterable, Codable, Sendable, Identifiable {
    case importDataset
    case installFixture
    case dryRunOrTrain
    case playgroundChat

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .importDataset: return "Teach a character"
        case .installFixture: return "Have a chat model"
        case .dryRunOrTrain: return "Try Train (optional)"
        case .playgroundChat: return "Try the playground"
        }
    }

    public var detail: String {
        switch self {
        case .importDataset:
            return "Build a story in Create, or import JSONL under Datasets."
        case .installFixture:
            return "Apple on-device counts for chat. Open MLX models are optional for Train."
        case .dryRunOrTrain:
            return "Queue LoRA or an Apple adapter from Train. Skip if you only want to chat."
        case .playgroundChat:
            return "Chat with your character in Playground (Apple or an open model)."
        }
    }

    public var systemImage: String {
        switch self {
        case .importDataset: return "doc.text"
        case .installFixture: return "cpu"
        case .dryRunOrTrain: return "hammer"
        case .playgroundChat: return "bubble.left.and.bubble.right"
        }
    }

    /// Sidebar destination the step deep-links to (app maps raw values).
    public var destinationHint: String {
        switch self {
        case .importDataset: return "characters"
        case .installFixture: return "models"
        case .dryRunOrTrain: return "train"
        case .playgroundChat: return "playground"
        }
    }
}

/// Observable library/product signals used to complete checklist steps automatically.
public struct OnboardingLibraryProbe: Sendable, Equatable {
    /// At least one ready text dataset in the library (wizard mind or imported JSONL).
    public var hasReadyDataset: Bool
    /// Fixture installed and/or any local **open** base model present.
    public var hasLocalBaseModel: Bool
    /// Apple on-device Foundation Model is usable for chat (no download).
    public var hasAppleChatModel: Bool
    /// A dry-run finished, a train succeeded, or an adapter artifact exists.
    public var hasDryRunOrTrain: Bool
    /// At least one playground completion (reply) was recorded.
    public var hasPlaygroundChat: Bool

    /// Apple chat **or** a local open model — enough to talk in Playground.
    public var hasChatModel: Bool { hasAppleChatModel || hasLocalBaseModel }

    public init(
        hasReadyDataset: Bool = false,
        hasLocalBaseModel: Bool = false,
        hasAppleChatModel: Bool = false,
        hasDryRunOrTrain: Bool = false,
        hasPlaygroundChat: Bool = false
    ) {
        self.hasReadyDataset = hasReadyDataset
        self.hasLocalBaseModel = hasLocalBaseModel
        self.hasAppleChatModel = hasAppleChatModel
        self.hasDryRunOrTrain = hasDryRunOrTrain
        self.hasPlaygroundChat = hasPlaygroundChat
    }

    /// Whether the probe alone marks `step` complete.
    public func isComplete(_ step: OnboardingStep) -> Bool {
        switch step {
        case .importDataset: return hasReadyDataset
        case .installFixture: return hasChatModel
        case .dryRunOrTrain: return hasDryRunOrTrain
        case .playgroundChat: return hasPlaygroundChat
        }
    }
}

/// Persisted first-run flags (UserDefaults / test double).
public struct OnboardingPersistedState: Sendable, Equatable, Codable {
    /// User dismissed the checklist banner even if incomplete.
    public var dismissed: Bool
    /// Manual step completions (unioned with library probe).
    public var manuallyCompleted: Set<OnboardingStep>

    public init(dismissed: Bool = false, manuallyCompleted: Set<OnboardingStep> = []) {
        self.dismissed = dismissed
        self.manuallyCompleted = manuallyCompleted
    }
}

/// Computed checklist snapshot for Home UI and unit tests.
public struct OnboardingChecklistState: Sendable, Equatable {
    public var completed: Set<OnboardingStep>
    public var dismissed: Bool

    public init(completed: Set<OnboardingStep> = [], dismissed: Bool = false) {
        self.completed = completed
        self.dismissed = dismissed
    }

    public var isFullyComplete: Bool {
        OnboardingStep.allCases.allSatisfy { completed.contains($0) }
    }

    public var remaining: [OnboardingStep] {
        OnboardingStep.allCases.filter { !completed.contains($0) }
    }

    public var completedCount: Int { completed.count }

    public var totalCount: Int { OnboardingStep.allCases.count }

    public var progress: Double {
        guard totalCount > 0 else { return 0 }
        return Double(completedCount) / Double(totalCount)
    }

    /// Whether the Home checklist panel should still be shown.
    public var shouldShow: Bool {
        !dismissed && !isFullyComplete
    }

    public func isComplete(_ step: OnboardingStep) -> Bool {
        completed.contains(step)
    }
}

/// Pure evaluator: library probe ∪ manual completions → checklist state.
public enum OnboardingChecklistEvaluator: Sendable {
    public static func evaluate(
        probe: OnboardingLibraryProbe,
        persisted: OnboardingPersistedState = OnboardingPersistedState()
    ) -> OnboardingChecklistState {
        var completed = persisted.manuallyCompleted
        for step in OnboardingStep.allCases where probe.isComplete(step) {
            completed.insert(step)
        }
        return OnboardingChecklistState(completed: completed, dismissed: persisted.dismissed)
    }
}

/// UserDefaults-backed store for dismiss / manual complete flags.
///
/// `@unchecked Sendable`: `UserDefaults` is thread-safe for simple key I/O
/// but not formally Sendable in the SDK.
public struct OnboardingStore: @unchecked Sendable {
    public static let suiteKeyPrefix = "bam.onboarding."
    public static let dismissedKey = "bam.onboarding.dismissed"
    public static let manualCompletedKey = "bam.onboarding.manualCompleted"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func loadPersisted() -> OnboardingPersistedState {
        let dismissed = defaults.bool(forKey: Self.dismissedKey)
        let raw = defaults.stringArray(forKey: Self.manualCompletedKey) ?? []
        let steps = Set(raw.compactMap { OnboardingStep(rawValue: $0) })
        return OnboardingPersistedState(dismissed: dismissed, manuallyCompleted: steps)
    }

    public func save(_ state: OnboardingPersistedState) {
        defaults.set(state.dismissed, forKey: Self.dismissedKey)
        defaults.set(
            state.manuallyCompleted.map(\.rawValue).sorted(),
            forKey: Self.manualCompletedKey
        )
    }

    public func dismiss() {
        var s = loadPersisted()
        s.dismissed = true
        save(s)
    }

    public func markCompleted(_ step: OnboardingStep) {
        var s = loadPersisted()
        s.manuallyCompleted.insert(step)
        save(s)
    }

    public func reset() {
        defaults.removeObject(forKey: Self.dismissedKey)
        defaults.removeObject(forKey: Self.manualCompletedKey)
    }
}
