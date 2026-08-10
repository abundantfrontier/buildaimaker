import BAMCore
import BAMModels
import Foundation

/// Persona composition resolution (design: `resolvePersona`).
///
/// Modes: `.full` | `.textOnly` | `.voicePreview`. Empty composition → `EMPTY_PERSONA`.
/// Knowledge/RAG keys are not part of `PersonaDocument` (K26); pass
/// `rawJSONContainedKnowledgeKeys: true` when the importer detected ignored keys.
public enum PersonaResolver: Sendable {
    /// Resolves a persona document against a library lookup.
    ///
    /// - Parameters:
    ///   - document: Nested persona composition (ids only; no knowledge keys).
    ///   - library: Model / adapter / voice / consent lookup.
    ///   - rawJSONContainedKnowledgeKeys: When true, attaches `IGNORED_KNOWLEDGE`.
    public static func resolve(
        _ document: PersonaDocument,
        library: any PersonaLibraryLookup,
        rawJSONContainedKnowledgeKeys: Bool = false
    ) throws -> ResolvedPersona {
        var errors: [PersonaResolutionCode] = []
        var messages: [String] = []
        var warnings: [PersonaResolutionWarning] = []

        var base: ModelRecord?
        var adapter: ArtifactRecord?
        var voice: VoiceProfileRecord?

        let hasLLM = document.llm?.hasLLM == true
        let hasVoice = document.voice?.hasVoice == true

        if !hasLLM && !hasVoice {
            throw PersonaUnresolvedError(
                codes: [.emptyPersona],
                messages: ["Persona has no LLM or voice components (EMPTY_PERSONA)"]
            )
        }

        // --- LLM branch ---
        if hasLLM, let llm = document.llm {
            // Prefer open LoRA adapter id; Foundation adapter is parallel (Apple path).
            if let adapterId = llm.adapterArtifactId {
                if let art = try library.artifact(id: adapterId) {
                    adapter = art
                    if let artBase = art.baseModelId, let personaBase = llm.baseModelId,
                       artBase != personaBase
                    {
                        errors.append(.adapterBaseMismatch)
                        messages.append(
                            "Adapter base \(artBase) does not match persona base \(personaBase)"
                        )
                    } else if art.baseModelId == nil, llm.baseModelId != nil {
                        // Adapter without baseModelId — still resolve base from persona.
                    } else if let artBase = art.baseModelId, llm.baseModelId == nil {
                        errors.append(.adapterBaseMismatch)
                        messages.append(
                            "Adapter requires base \(artBase) but persona base is nil"
                        )
                    }
                } else {
                    errors.append(.missingAdapter)
                    messages.append("Adapter artifact not found: \(adapterId)")
                }
                if let baseId = llm.baseModelId {
                    if let model = try library.model(id: baseId) {
                        base = model
                    } else {
                        errors.append(.missingBase)
                        messages.append("Base model not found: \(baseId)")
                    }
                } else {
                    // Adapter without base on persona is invalid until base resolved.
                    errors.append(.missingBase)
                    messages.append("Missing base model while adapter is present")
                }
            } else if let foundationId = llm.foundationAdapterArtifactId {
                // Apple Foundation adapter — base is the system model (may not be in models table).
                if let art = try library.artifact(id: foundationId) {
                    adapter = art
                } else {
                    // Directory-only install (Train publish without GRDB) — allow resolve;
                    // Playground/Train scan disk by id. Soft: no fatal MISSING_ADAPTER.
                    messages.append(
                        "Foundation adapter id \(foundationId) not in library DB — use models/foundation-adapters scan"
                    )
                }
                if let baseId = llm.baseModelId {
                    if baseId == "apple-foundation" || baseId.hasPrefix("apple") {
                        // System model — no disk base required.
                    } else if let model = try library.model(id: baseId) {
                        base = model
                    } else {
                        errors.append(.missingBase)
                        messages.append("Base model not found: \(baseId)")
                    }
                }
                // Signature mismatch is warned at chat time, not a hard resolve fail.
            } else if let baseId = llm.baseModelId {
                if let model = try library.model(id: baseId) {
                    base = model
                } else if baseId == "apple-foundation" {
                    // Apple system model only — OK without library model row.
                } else {
                    errors.append(.missingBase)
                    messages.append("Base model not found: \(baseId)")
                }
            }
        }
        // else: voice-only — do NOT add NO_LLM

        // --- Voice branch ---
        if hasVoice, let voiceId = document.voice?.voiceProfileId {
            if let profile = try library.voiceProfile(id: voiceId) {
                voice = profile
                // verifyConsentHash(voice)
                if !verifyConsentHash(profile: profile, library: library) {
                    errors.append(.consentTamper)
                    messages.append(
                        "Consent hash verification failed for voice \(voiceId)"
                    )
                }
            } else {
                errors.append(.missingVoice)
                messages.append("Voice profile not found: \(voiceId)")
            }
        }

        if !errors.isEmpty {
            throw PersonaUnresolvedError(codes: errors, messages: messages)
        }

        let mode: PersonaMode
        if hasLLM && hasVoice {
            mode = .full
        } else if hasLLM {
            mode = .textOnly
        } else {
            mode = .voicePreview
            warnings.append(.voicePreviewNoLLM)
        }

        if rawJSONContainedKnowledgeKeys {
            warnings.append(.ignoredKnowledge)
        }

        return ResolvedPersona(
            mode: mode,
            document: document,
            base: base,
            adapter: adapter,
            voice: voice,
            systemPrompt: document.systemPrompt,
            sampling: document.sampling,
            warnings: warnings
        )
    }

    /// Detects knowledge-pack keys in raw JSON data without decoding them into the model.
    public static func rawJSONContainsKnowledgeKeys(_ data: Data) -> Bool {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        let knowledgeKeys = ["knowledge", "knowledgePackId", "knowledgePacks", "rag", "ragPackId"]
        return knowledgeKeys.contains { obj[$0] != nil }
    }

    /// Decodes `PersonaDocument`, notes ignored knowledge keys, and resolves.
    public static func resolve(
        jsonData: Data,
        library: any PersonaLibraryLookup
    ) throws -> ResolvedPersona {
        let document = try JSONDecoder().decode(PersonaDocument.self, from: jsonData)
        let hasKnowledge = rawJSONContainsKnowledgeKeys(jsonData)
        return try resolve(
            document,
            library: library,
            rawJSONContainedKnowledgeKeys: hasKnowledge
        )
    }

    // MARK: - Consent

    /// Voice consent binding: consent row must exist, verify content hash, and match
    /// the denormalized hash on the voice profile (K11).
    private static func verifyConsentHash(
        profile: VoiceProfileRecord,
        library: any PersonaLibraryLookup
    ) -> Bool {
        do {
            guard let consent = try library.consent(id: profile.consentRecordId) else {
                return false
            }
            guard try consent.verifyContentHash() else {
                return false
            }
            let profileHash = ConsentRecord.normalizeHash(profile.consentContentHash)
            let consentHash = ConsentRecord.normalizeHash(consent.contentHash)
            return profileHash == consentHash
        } catch {
            return false
        }
    }
}
