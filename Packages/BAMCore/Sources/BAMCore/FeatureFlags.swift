import Foundation

/// Product feature flags. All flags default to **off** in the Phase 0 shell.
/// Enable only via future PRs that ship the corresponding feature.
public struct FeatureFlags: Sendable, Equatable {
    public var llmTraining: Bool
    public var voiceClone: Bool
    public var voiceFinetune: Bool
    public var personaPacks: Bool
    public var talkMode: Bool
    public var cloudRunner: Bool
    public var knowledgePacks: Bool
    public var telemetryOptIn: Bool
    /// Optional Hugging Face Hub download path (dogfood). Default off — CI stays offline.
    public var hfHubDownload: Bool

    public init(
        llmTraining: Bool = false,
        voiceClone: Bool = false,
        voiceFinetune: Bool = false,
        personaPacks: Bool = false,
        talkMode: Bool = false,
        cloudRunner: Bool = false,
        knowledgePacks: Bool = false,
        telemetryOptIn: Bool = false,
        hfHubDownload: Bool = false
    ) {
        self.llmTraining = llmTraining
        self.voiceClone = voiceClone
        self.voiceFinetune = voiceFinetune
        self.personaPacks = personaPacks
        self.talkMode = talkMode
        self.cloudRunner = cloudRunner
        self.knowledgePacks = knowledgePacks
        self.telemetryOptIn = telemetryOptIn
        self.hfHubDownload = hfHubDownload
    }

    /// Default product flags: every flag off (Phase 0 scaffold).
    public static let `default` = FeatureFlags()

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
        case hfHubDownload = "ff.hfHubDownload"
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
        case .hfHubDownload: return hfHubDownload
        }
    }
}
