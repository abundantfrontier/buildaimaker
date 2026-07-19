import BAMModels
import Foundation

/// Fully resolved persona ready for playground / Talk routing.
public struct ResolvedPersona: Sendable, Equatable {
    public var mode: PersonaMode
    public var document: PersonaDocument
    public var base: ModelRecord?
    public var adapter: ArtifactRecord?
    public var voice: VoiceProfileRecord?
    public var systemPrompt: String?
    public var sampling: PersonaSampling?
    public var warnings: [PersonaResolutionWarning]

    public init(
        mode: PersonaMode,
        document: PersonaDocument,
        base: ModelRecord? = nil,
        adapter: ArtifactRecord? = nil,
        voice: VoiceProfileRecord? = nil,
        systemPrompt: String? = nil,
        sampling: PersonaSampling? = nil,
        warnings: [PersonaResolutionWarning] = []
    ) {
        self.mode = mode
        self.document = document
        self.base = base
        self.adapter = adapter
        self.voice = voice
        self.systemPrompt = systemPrompt
        self.sampling = sampling
        self.warnings = warnings
    }
}
