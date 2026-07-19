import Foundation

/// Product feature flags.
///
/// Defaults after PR-Persona / PR-Play-Text / PR-LLM-LoRA / PR-Voice-UI:
/// - `ff.llmTraining` **on** (dogfood)
/// - `ff.playground` **on** (text playground always available)
/// - `ff.voiceClone` **on**
/// - `ff.personaPacks` **on** (resolution + Pack Format v1)
/// Remaining flags stay off until their shipping PRs enable them. Overrides can
/// still be applied via `UserDefaults` / dev tooling by constructing a custom
/// `FeatureFlags`.
public struct FeatureFlags: Sendable, Equatable {
    public var llmTraining: Bool
    /// Text playground (base + optional adapter chat). Always on after PR-Play-Text.
    public var playground: Bool
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
        /// PR-LLM-LoRA: default **true** for dogfood (design table: `ff.llmTraining` on).
        llmTraining: Bool = true,
        /// PR-Play-Text: default **true** — text playground always available.
        playground: Bool = true,
        voiceClone: Bool = true,
        voiceFinetune: Bool = false,
        /// PR-Persona: default **true** — persona resolution + Pack v1 zip.
        personaPacks: Bool = true,
        talkMode: Bool = false,
        cloudRunner: Bool = false,
        knowledgePacks: Bool = false,
        telemetryOptIn: Bool = false,
        hfHubDownload: Bool = false
    ) {
        self.llmTraining = llmTraining
        self.playground = playground
        self.voiceClone = voiceClone
        self.voiceFinetune = voiceFinetune
        self.personaPacks = personaPacks
        self.talkMode = talkMode
        self.cloudRunner = cloudRunner
        self.knowledgePacks = knowledgePacks
        self.telemetryOptIn = telemetryOptIn
        self.hfHubDownload = hfHubDownload
    }

    /// Default product flags (`llmTraining` + `playground` + `voiceClone` + `personaPacks` on).
    public static let `default` = FeatureFlags()

    /// Stable string keys used in config / docs (e.g. `ff.llmTraining`).
    public enum Key: String, CaseIterable, Sendable {
        case llmTraining = "ff.llmTraining"
        case playground = "ff.playground"
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
        case .playground: return playground
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
