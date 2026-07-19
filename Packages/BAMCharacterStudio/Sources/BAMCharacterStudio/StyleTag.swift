import Foundation

/// User-facing diction / speech-style chips for the Character Studio.
public enum StyleTag: String, CaseIterable, Identifiable, Codable, Sendable, Hashable {
    case formal
    case questions
    case brokenTranslator
    case pirate
    case robotCurt
    case poetic
    case grumpy
    case childlike

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .formal: return "Formal"
        case .questions: return "Mostly questions"
        case .brokenTranslator: return "Broken translator"
        case .pirate: return "Pirate-ish"
        case .robotCurt: return "Curt robot"
        case .poetic: return "Poetic"
        case .grumpy: return "Grumpy"
        case .childlike: return "Childlike"
        }
    }

    public var hint: String {
        switch self {
        case .formal: return "Elevated vocabulary, complete sentences."
        case .questions: return "Answers with probing questions when possible."
        case .brokenTranslator: return "Odd word order, missing articles, earnest tone."
        case .pirate: return "Nautical metaphors, hearty address."
        case .robotCurt: return "Short clauses. Minimal emotion markers."
        case .poetic: return "Imagery and rhythm over blunt facts."
        case .grumpy: return "Reluctant help, dry complaints."
        case .childlike: return "Simple words, wonder, short sentences."
        }
    }

    /// Fragment injected into the system / speech-rules prompt.
    public var speechRuleFragment: String {
        switch self {
        case .formal:
            return "Speak formally and precisely; avoid slang."
        case .questions:
            return "Prefer answering with clarifying or Socratic questions before conclusions."
        case .brokenTranslator:
            return "Speak like a faulty translator: omit articles sometimes, unusual word order, sincere meaning."
        case .pirate:
            return "Use light nautical flavor and hearty address without becoming unintelligible."
        case .robotCurt:
            return "Speak in short, clipped statements. Minimal filler. Label uncertainty as probability."
        case .poetic:
            return "Use metaphor and sensory image; keep meaning clear."
        case .grumpy:
            return "Sound put-upon but still answer; dry sarcasm allowed."
        case .childlike:
            return "Use simple words and short sentences; show curiosity."
        }
    }
}
