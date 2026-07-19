import Foundation

/// Product feature flags. Most flags default to **off**; ship-enabled features flip on
/// in the PR that lands the corresponding product surface.
public struct FeatureFlags: Sendable, Equatable {
    public var llmTraining: Bool
    public var voiceClone: Bool
    public var voiceFinetune: Bool
    public var personaPacks: Bool
    public var talkMode: Bool
    public var cloudRunner: Bool
    public var knowledgePacks: Bool
    public var telemetryOptIn: Bool

    public init(
        llmTraining: Bool = false,
        voiceClone: Bool = false,
        voiceFinetune: Bool = false,
        personaPacks: Bool = false,
        talkMode: Bool = false,
        cloudRunner: Bool = false,
        knowledgePacks: Bool = false,
        telemetryOptIn: Bool = false
    ) {
        self.llmTraining = llmTraining
        self.voiceClone = voiceClone
        self.voiceFinetune = voiceFinetune
        self.personaPacks = personaPacks
        self.talkMode = talkMode
        self.cloudRunner = cloudRunner
        self.knowledgePacks = knowledgePacks
        self.telemetryOptIn = telemetryOptIn
    }

    /// Default product flags. `ff.voiceClone` is **on** (PR-Voice-UI); all others remain off.
    public static let `default` = FeatureFlags(voiceClone: true)

    /// Stable string keys used in config / docs (e.g. `ff.llmTraining`).
    public enum Key: String, CaseIterable, Sendable {
        case llmTraining = "ff.llmTraining"
        case voiceClone = "ff.voiceClone"
        case voiceFinetune = "ff.voiceFinetune"
        case personaPacks = "ff.personaPacks"
        case talkMode = "ff.talkMode"
        case cloudRunner = "ff.cloudRunner"
        case knowledgePacks = "ff.knowledgePacks"
        case telemetryOptIn = "ff.telemetryOptIn"
    }

    public func isEnabled(_ key: Key) -> Bool {
        switch key {
        case .llmTraining: return llmTraining
        case .voiceClone: return voiceClone
        case .voiceFinetune: return voiceFinetune
        case .personaPacks: return personaPacks
        case .talkMode: return talkMode
        case .cloudRunner: return cloudRunner
        case .knowledgePacks: return knowledgePacks
        case .telemetryOptIn: return telemetryOptIn
        }
    }
}
