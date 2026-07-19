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
        case .importDataset: return "Import a dataset"
        case .installFixture: return "Install a base model"
        case .dryRunOrTrain: return "Dry-run or train LoRA"
        case .playgroundChat: return "Try the playground"
        }
    }

    public var detail: String {
        switch self {
        case .importDataset:
            return "Import ShareGPT or OpenAI-messages JSONL under Datasets."
        case .installFixture:
            return "Install the offline fixture (or any local base) under Models."
        case .dryRunOrTrain:
            return "Validate & dry-run, or run a LoRA train from Train."
        case .playgroundChat:
            return "Chat against base + optional adapter in Playground."
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
        case .importDataset: return "datasets"
        case .installFixture: return "models"
        case .dryRunOrTrain: return "train"
        case .playgroundChat: return "playground"
        }
    }
}

/// Observable library/product signals used to complete checklist steps automatically.
public struct OnboardingLibraryProbe: Sendable, Equatable {
    /// At least one ready text dataset in the library.
    public var hasReadyDataset: Bool
    /// Fixture installed and/or any local base model present.
    public var hasLocalBaseModel: Bool
    /// A dry-run finished, a train succeeded, or an adapter artifact exists.
    public var hasDryRunOrTrain: Bool
    /// At least one playground completion (reply) was recorded.
    public var hasPlaygroundChat: Bool

    public init(
        hasReadyDataset: Bool = false,
        hasLocalBaseModel: Bool = false,
        hasDryRunOrTrain: Bool = false,
        hasPlaygroundChat: Bool = false
    ) {
        self.hasReadyDataset = hasReadyDataset
        self.hasLocalBaseModel = hasLocalBaseModel
        self.hasDryRunOrTrain = hasDryRunOrTrain
        self.hasPlaygroundChat = hasPlaygroundChat
    }

    /// Whether the probe alone marks `step` complete.
    public func isComplete(_ step: OnboardingStep) -> Bool {
        switch step {
        case .importDataset: return hasReadyDataset
        case .installFixture: return hasLocalBaseModel
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
