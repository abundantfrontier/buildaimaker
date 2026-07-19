import Foundation

/// Offline template builder: paste + style tags → bible + JSONL (CS-2).
/// No network; deterministic enough for tests. Optional “riff” expands from seeds.
public struct CorpusBuilder: Sendable {
    public init() {}

    public func build(
        name: String,
        species: String,
        vibe: String,
        paste: String,
        styleTags: Set<StyleTag>,
        riffExtra: Int = 0
    ) -> CorpusBuildResult {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeName = trimmedName.isEmpty ? "Unnamed" : trimmedName
        let safeSpecies = species.trimmingCharacters(in: .whitespacesAndNewlines)
        let notes = paste.trimmingCharacters(in: .whitespacesAndNewlines)

        let rules = styleTags.map(\.speechRuleFragment)
        var traits = extractBulletishTraits(from: notes)
        if traits.isEmpty, !safeSpecies.isEmpty {
            traits = ["Is a \(safeSpecies)", "Fictional character for play"]
        }

        let bible = CharacterBible(
            name: safeName,
            species: safeSpecies.isEmpty ? "creature" : safeSpecies,
            vibe: vibe.trimmingCharacters(in: .whitespacesAndNewlines),
            traits: traits,
            speechRules: rules.isEmpty
                ? ["Stay consistent with the notes the creator provided."]
                : rules,
            taboos: ["Do not impersonate real living people.", "Do not claim legal or medical authority."],
            sourceNotes: notes,
            styleTags: styleTags.map(\.rawValue).sorted(),
            generator: "template-v1"
        )

        var examples = seedExamples(bible: bible, notes: notes, tags: styleTags)
        if riffExtra > 0 {
            examples.append(contentsOf: riffExamples(bible: bible, count: riffExtra, from: examples))
        }

        let jsonl = encodeJSONL(system: bible.systemPrompt, examples: examples)
        return CorpusBuildResult(bible: bible, examples: examples, jsonl: jsonl)
    }

    /// Expand corpus with additional synthetic turns in the same diction.
    public func riff(result: CorpusBuildResult, extra: Int) -> CorpusBuildResult {
        guard extra > 0 else { return result }
        var examples = result.examples
        examples.append(contentsOf: riffExamples(bible: result.bible, count: extra, from: examples))
        let jsonl = encodeJSONL(system: result.bible.systemPrompt, examples: examples)
        return CorpusBuildResult(bible: result.bible, examples: examples, jsonl: jsonl)
    }

    // MARK: - Private

    private func extractBulletishTraits(from notes: String) -> [String] {
        let lines = notes
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        var traits: [String] = []
        for line in lines.prefix(8) {
            if line.hasPrefix("-") || line.hasPrefix("•") || line.hasPrefix("*") {
                let t = line.drop(while: { $0 == "-" || $0 == "•" || $0 == "*" || $0 == " " })
                if !t.isEmpty { traits.append(String(t)) }
            }
        }
        if traits.isEmpty {
            // First sentence-ish chunk as a trait-ish blurb.
            let chunks = notes
                .replacingOccurrences(of: "\n", with: " ")
                .components(separatedBy: CharacterSet(charactersIn: ".!?"))
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { $0.count > 12 }
            traits = Array(chunks.prefix(3))
        }
        return traits
    }

    private func seedExamples(
        bible: CharacterBible,
        notes: String,
        tags: Set<StyleTag>
    ) -> [DialogueExample] {
        var out: [DialogueExample] = []

        // From notes: turn sentences into user prompts with in-character answers.
        let sentences = notes
            .replacingOccurrences(of: "\n", with: " ")
            .components(separatedBy: CharacterSet(charactersIn: ".!?"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count > 8 }

        for (idx, sentence) in sentences.prefix(4).enumerated() {
            let user: String
            if idx == 0 {
                user = "Who are you?"
            } else if idx == 1 {
                user = "Tell me about yourself."
            } else {
                user = "What should I know about: \(sentence.prefix(48))…?"
            }
            let assistant = stylizeAnswer(
                base: answerFromNote(sentence, name: bible.name, species: bible.species),
                tags: tags,
                name: bible.name
            )
            out.append(DialogueExample(user: user, assistant: assistant))
        }

        // Always include a few fixed scaffolds so small pastes still train.
        let scaffolds: [(String, String)] = [
            (
                "Hello!",
                stylizeAnswer(
                    base: "I am \(bible.name), a \(bible.species). Speak, and I will answer in my own way.",
                    tags: tags,
                    name: bible.name
                )
            ),
            (
                "What do you want?",
                stylizeAnswer(
                    base: defaultDesire(species: bible.species, vibe: bible.vibe),
                    tags: tags,
                    name: bible.name
                )
            ),
            (
                "How do you speak?",
                stylizeAnswer(
                    base: bible.speechRules.joined(separator: " "),
                    tags: tags,
                    name: bible.name
                )
            ),
        ]
        for (u, a) in scaffolds {
            out.append(DialogueExample(user: u, assistant: a))
        }

        // Dedupe similar user lines.
        var seen = Set<String>()
        return out.filter { ex in
            let key = ex.user.lowercased()
            if seen.contains(key) { return false }
            seen.insert(key)
            return true
        }
    }

    private func riffExamples(
        bible: CharacterBible,
        count: Int,
        from existing: [DialogueExample]
    ) -> [DialogueExample] {
        let prompts = [
            "What frightens you?",
            "Where is home?",
            "What is funny to you?",
            "Give me advice.",
            "What do you think of humans?",
            "Sing—or describe—a song of your people.",
            "What is forbidden?",
            "How do you hunt—or gather—what you need?",
        ]
        var out: [DialogueExample] = []
        let seedBits = existing.prefix(3).map(\.assistant).joined(separator: " ")
        for i in 0..<count {
            let q = prompts[i % prompts.count]
            let base = "As \(bible.name): drawing on \"\(seedBits.prefix(80))…\" — \(shortReply(for: q, species: bible.species))"
            out.append(
                DialogueExample(
                    user: q,
                    assistant: stylizeAnswer(base: base, tags: Set(bible.styleTags.compactMap(StyleTag.init(rawValue:))), name: bible.name)
                )
            )
        }
        return out
    }

    private func answerFromNote(_ sentence: String, name: String, species: String) -> String {
        "I am \(name). Among my kind (\(species)), this is true: \(sentence)."
    }

    private func defaultDesire(species: String, vibe: String) -> String {
        if !vibe.isEmpty {
            return "I seek a path that fits my nature: \(vibe)."
        }
        return "I want to be understood—on my terms—as a \(species)."
    }

    private func shortReply(for prompt: String, species: String) -> String {
        switch prompt {
        case "What frightens you?":
            return "Silence without meaning. Also vacuum cleaners, if I am small."
        case "Where is home?":
            return "Wherever my story is remembered—and the air suits a \(species)."
        case "What is funny to you?":
            return "When certainty trips over a question."
        case "Give me advice.":
            return "Listen twice. Speak once. Leave room for wonder."
        case "What do you think of humans?":
            return "Loud, clever, fragile—worth talking to carefully."
        default:
            return "That depends on the weather inside the tale."
        }
    }

    private func stylizeAnswer(base: String, tags: Set<StyleTag>, name: String) -> String {
        var text = base
        if tags.contains(.robotCurt) {
            text = text
                .replacingOccurrences(of: "!", with: ".")
                .replacingOccurrences(of: "I am", with: "Unit designation:")
            if !text.hasSuffix(".") { text += "." }
            text = String(text.prefix(220))
        }
        if tags.contains(.brokenTranslator) {
            text = text
                .replacingOccurrences(of: " the ", with: " ")
                .replacingOccurrences(of: " a ", with: " ")
            text = "Yes. \(text) Is clear?"
        }
        if tags.contains(.pirate) {
            text = "Arr, \(text) Aye."
        }
        if tags.contains(.questions) {
            text = "\(text) But tell me—what do *you* believe?"
        }
        if tags.contains(.grumpy) {
            text = "Fine. \(text) Don't make me repeat it."
        }
        if tags.contains(.childlike) {
            text = "Oh! \(text) Want to hear more?"
        }
        if tags.contains(.poetic), !tags.contains(.robotCurt) {
            text = "In the hush between stars: \(text)"
        }
        if tags.contains(.formal), !tags.contains(.brokenTranslator) {
            text = text.replacingOccurrences(of: "Don't", with: "Do not")
        }
        // Ensure name sometimes appears for character lock-in.
        if !text.localizedCaseInsensitiveContains(name), name.count < 32 {
            text = "\(text) —\(name)"
        }
        return text
    }

    private func encodeJSONL(system: String, examples: [DialogueExample]) -> String {
        var lines: [String] = []
        let encoder = JSONEncoder()
        encoder.outputFormatting = []

        for ex in examples {
            let row: [String: Any] = [
                "messages": [
                    ["role": "system", "content": system],
                    ["role": "user", "content": ex.user],
                    ["role": "assistant", "content": ex.assistant],
                ],
            ]
            if let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]),
               let line = String(data: data, encoding: .utf8)
            {
                lines.append(line)
            }
        }
        return lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
    }
}
