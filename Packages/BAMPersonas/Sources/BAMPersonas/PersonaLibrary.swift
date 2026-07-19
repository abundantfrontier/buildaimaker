import BAMModels
import Foundation

/// Library lookups required by `PersonaResolver` (models, adapters, voices, consent).
public protocol PersonaLibraryLookup: Sendable {
    func model(id: String) throws -> ModelRecord?
    func artifact(id: String) throws -> ArtifactRecord?
    func voiceProfile(id: String) throws -> VoiceProfileRecord?
    /// Returns the consent record for a voice profile, or `nil` if missing.
    func consent(id: String) throws -> ConsentRecord?
}

/// In-memory library for unit tests and dry-run resolution.
public final class InMemoryPersonaLibrary: PersonaLibraryLookup, @unchecked Sendable {
    public var models: [String: ModelRecord]
    public var artifacts: [String: ArtifactRecord]
    public var voices: [String: VoiceProfileRecord]
    public var consents: [String: ConsentRecord]

    public init(
        models: [String: ModelRecord] = [:],
        artifacts: [String: ArtifactRecord] = [:],
        voices: [String: VoiceProfileRecord] = [:],
        consents: [String: ConsentRecord] = [:]
    ) {
        self.models = models
        self.artifacts = artifacts
        self.voices = voices
        self.consents = consents
    }

    public func model(id: String) throws -> ModelRecord? { models[id] }
    public func artifact(id: String) throws -> ArtifactRecord? { artifacts[id] }
    public func voiceProfile(id: String) throws -> VoiceProfileRecord? { voices[id] }
    public func consent(id: String) throws -> ConsentRecord? { consents[id] }

    public func upsert(model: ModelRecord) { models[model.id] = model }
    public func upsert(artifact: ArtifactRecord) { artifacts[artifact.id] = artifact }
    public func upsert(voice: VoiceProfileRecord) { voices[voice.id] = voice }
    public func upsert(consent: ConsentRecord) { consents[consent.id] = consent }
}
