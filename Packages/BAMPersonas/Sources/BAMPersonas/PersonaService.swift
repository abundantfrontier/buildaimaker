import BAMCore
import BAMModels
import BAMPersistence
import Foundation

/// Product orchestration: create/list personas, resolve, pack export/import.
public final class PersonaService: @unchecked Sendable {
    public let store: PersonaStore
    public let library: any PersonaLibraryLookup
    public let libraryRoot: URL
    public let fileManager: FileManager
    private let idGenerator: @Sendable () -> String
    private let nowISO8601: @Sendable () -> String
    private let consentPersister: (@Sendable (ConsentRecord) throws -> Void)?
    private let voicePersister: (@Sendable (VoiceProfileRecord) throws -> Void)?

    public init(
        store: PersonaStore,
        library: any PersonaLibraryLookup,
        libraryRoot: URL,
        fileManager: FileManager = .default,
        idGenerator: @escaping @Sendable () -> String = { BAMID.generate() },
        nowISO8601: @escaping @Sendable () -> String = {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime]
            f.timeZone = TimeZone(secondsFromGMT: 0)
            return f.string(from: Date())
        },
        consentPersister: (@Sendable (ConsentRecord) throws -> Void)? = nil,
        voicePersister: (@Sendable (VoiceProfileRecord) throws -> Void)? = nil
    ) {
        self.store = store
        self.library = library
        self.libraryRoot = libraryRoot
        self.fileManager = fileManager
        self.idGenerator = idGenerator
        self.nowISO8601 = nowISO8601
        self.consentPersister = consentPersister
        self.voicePersister = voicePersister
    }

    /// In-memory stack for unit tests.
    public static func makeInMemoryForTesting(
        libraryRoot: URL? = nil
    ) throws -> (
        service: PersonaService,
        database: LibraryDatabase,
        library: InMemoryPersonaLibrary,
        libraryRoot: URL
    ) {
        let db = try LibraryDatabase.openInMemory()
        let root = libraryRoot
            ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("bam-persona-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let mem = InMemoryPersonaLibrary()
        let store = PersonaStore(database: db)
        let service = PersonaService(
            store: store,
            library: mem,
            libraryRoot: root,
            consentPersister: { consent in
                mem.upsert(consent: consent)
            },
            voicePersister: { voice in
                mem.upsert(voice: voice)
            }
        )
        return (service, db, mem, root)
    }

    // MARK: - CRUD

    public func list() throws -> [PersonaIndexRecord] {
        try store.fetchAll()
    }

    public func fetch(id: String) throws -> PersonaDocument? {
        try store.fetchDocument(id: id)
    }

    /// Creates a new persona document and persists the index row.
    @discardableResult
    public func create(
        name: String,
        version: String = "1.0.0",
        llm: PersonaLLMComponents? = nil,
        voice: PersonaVoiceComponents? = nil,
        systemPrompt: String? = nil,
        sampling: PersonaSampling? = nil,
        id: String? = nil
    ) throws -> PersonaDocument {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw BAMError(code: .schemaInvalid, message: "Persona name is required")
        }
        let hasLLM = llm?.hasLLM == true
        let hasVoice = voice?.hasVoice == true
        if !hasLLM && !hasVoice {
            throw PersonaUnresolvedError(
                codes: [.emptyPersona],
                messages: ["Cannot create empty persona (EMPTY_PERSONA)"]
            )
        }

        let now = nowISO8601()
        let doc = PersonaDocument(
            id: id ?? idGenerator(),
            name: trimmed,
            version: version,
            llm: llm,
            voice: voice,
            systemPrompt: systemPrompt,
            sampling: sampling
        )
        try save(document: doc, createdAt: now, updatedAt: now)
        return doc
    }

    /// Upserts a full document (import / edit).
    @discardableResult
    public func save(document: PersonaDocument, createdAt: String? = nil, updatedAt: String? = nil) throws -> PersonaIndexRecord {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(document)
        guard let json = String(data: data, encoding: .utf8) else {
            throw BAMError(code: .schemaInvalid, message: "Could not encode PersonaDocument")
        }
        let now = nowISO8601()
        let existing = try store.fetch(id: document.id)
        let record = PersonaIndexRecord(
            id: document.id,
            name: document.name,
            version: document.version,
            json: json,
            createdAt: createdAt ?? existing?.createdAt ?? now,
            updatedAt: updatedAt ?? now
        )
        try store.upsert(record)
        return record
    }

    public func delete(id: String) throws {
        try store.delete(id: id)
    }

    // MARK: - Resolve

    public func resolve(id: String) throws -> ResolvedPersona {
        guard let doc = try store.fetchDocument(id: id) else {
            throw BAMError(code: .personaUnresolved, message: "Persona not found: \(id)")
        }
        return try PersonaResolver.resolve(doc, library: library)
    }

    public func resolve(_ document: PersonaDocument) throws -> ResolvedPersona {
        try PersonaResolver.resolve(document, library: library)
    }

    // MARK: - Pack export / import

    /// Exports a stored persona to a Pack Format v1 zip.
    @discardableResult
    public func exportPack(
        personaId: String,
        to zipURL: URL,
        adapterDirectory: URL? = nil,
        voiceReferenceURL: URL? = nil,
        baseModelLicenseText: String? = nil,
        voiceEngineLicenseText: String? = nil
    ) throws -> PersonaPackExporter.ExportResult {
        let resolved = try resolve(id: personaId)
        var consent: ConsentRecord?
        if let voice = resolved.voice {
            consent = try library.consent(id: voice.consentRecordId)
        }
        // Prefer adapter path from artifact record when not provided.
        var adapterDir = adapterDirectory
        if adapterDir == nil, let path = resolved.adapter?.localPath, !path.isEmpty {
            adapterDir = URL(fileURLWithPath: path, isDirectory: true)
        }
        var voiceRef = voiceReferenceURL
        if voiceRef == nil, let path = resolved.voice?.localPath {
            let dir = URL(fileURLWithPath: path, isDirectory: true)
            let candidate = dir.appendingPathComponent("reference.wav")
            if fileManager.fileExists(atPath: candidate.path) {
                voiceRef = candidate
            }
        }

        let staging = libraryRoot
            .appendingPathComponent("personas", isDirectory: true)
            .appendingPathComponent(LibraryPaths.sanitizedPathComponent(personaId), isDirectory: true)
            .appendingPathComponent("export-staging", isDirectory: true)

        let exporter = PersonaPackExporter(fileManager: fileManager)
        return try exporter.export(
            context: PersonaPackExporter.ExportContext(
                resolved: resolved,
                consent: consent,
                adapterDirectory: adapterDir,
                voiceReferenceURL: voiceRef,
                baseModelLicenseText: baseModelLicenseText,
                voiceEngineLicenseText: voiceEngineLicenseText,
                createdAt: nowISO8601()
            ),
            stagingDirectory: staging,
            zipURL: zipURL
        )
    }

    /// Imports a Pack Format v1 zip into the library (persona row + optional consent/voice embeds).
    @discardableResult
    public func importPack(from zipURL: URL, replaceExisting: Bool = true) throws -> PersonaDocument {
        let staging = libraryRoot
            .appendingPathComponent("personas", isDirectory: true)
            .appendingPathComponent("import-staging-\(UUID().uuidString)", isDirectory: true)

        let importer = PersonaPackImporter(fileManager: fileManager)
        let result = try importer.importPack(zipURL: zipURL, stagingDirectory: staging)

        // Persist consent when present (import-safe: same-hash no-op; hash conflict fails).
        if let consent = result.consent {
            if let existing = try library.consent(id: consent.id) {
                let existingHash = ConsentRecord.normalizeHash(existing.contentHash)
                let incomingHash = ConsentRecord.normalizeHash(consent.contentHash)
                if existingHash != incomingHash {
                    throw BAMError(
                        code: .consentTamper,
                        message:
                            "Pack consent conflicts with existing record \(consent.id) (contentHash mismatch)"
                    )
                }
                // Same hash — keep existing evidence; do not re-insert.
            } else {
                try consentPersister?(consent)
            }
            if let mem = library as? InMemoryPersonaLibrary {
                mem.upsert(consent: consent)
            }
        }

        // Persist voice profile snapshot + copy reference audio into library voices/.
        if let packVoice = result.voiceProfile {
            let voiceDir = libraryRoot
                .appendingPathComponent("voices", isDirectory: true)
                .appendingPathComponent(
                    LibraryPaths.sanitizedPathComponent(packVoice.id),
                    isDirectory: true
                )
            try fileManager.createDirectory(at: voiceDir, withIntermediateDirectories: true)
            if let rel = packVoice.referenceRelativePath,
               let src = result.embeddedFiles[rel]
                ?? Optional(staging.appendingPathComponent(rel)),
               fileManager.fileExists(atPath: src.path)
            {
                let dest = voiceDir.appendingPathComponent("reference.wav")
                if fileManager.fileExists(atPath: dest.path) {
                    try fileManager.removeItem(at: dest)
                }
                try fileManager.copyItem(at: src, to: dest)
            }

            let voiceRecord = VoiceProfileRecord(
                id: packVoice.id,
                engineId: packVoice.engineId,
                localPath: voiceDir.path,
                consentRecordId: packVoice.consentRecordId,
                consentContentHash: packVoice.consentContentHash,
                createdAt: packVoice.createdAt
            )
            try voicePersister?(voiceRecord)
            if let mem = library as? InMemoryPersonaLibrary {
                mem.upsert(voice: voiceRecord)
            }
        }

        // Optional adapter embed → models/adapters/<id>/
        if let adapterId = result.document.llm?.adapterArtifactId {
            let adapterSrc = staging.appendingPathComponent("llm/adapter", isDirectory: true)
            if fileManager.fileExists(atPath: adapterSrc.path) {
                let dest = libraryRoot
                    .appendingPathComponent("models/adapters", isDirectory: true)
                    .appendingPathComponent(
                        LibraryPaths.sanitizedPathComponent(adapterId),
                        isDirectory: true
                    )
                if fileManager.fileExists(atPath: dest.path) {
                    try fileManager.removeItem(at: dest)
                }
                try fileManager.createDirectory(
                    at: dest.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try fileManager.copyItem(at: adapterSrc, to: dest)

                let artifact = ArtifactRecord(
                    id: adapterId,
                    kind: .loraAdapter,
                    jobId: nil,
                    baseModelId: result.document.llm?.baseModelId,
                    localPath: dest.path,
                    metricsJSON: nil,
                    createdAt: nowISO8601()
                )
                if let mem = library as? InMemoryPersonaLibrary {
                    mem.upsert(artifact: artifact)
                }
                if let grdb = library as? GRDBPersonaLibrary {
                    try grdb.upsertArtifact(artifact)
                }
            }
        }

        // Base ref → models table (path may be empty placeholder until weights present).
        if let baseRef = result.baseRef {
            let model = ModelRecord(
                id: baseRef.baseModelId,
                sourceKey: baseRef.sourceKey,
                contentHash: baseRef.contentHash,
                name: baseRef.name ?? baseRef.sourceKey ?? baseRef.baseModelId,
                kind: .base,
                license: baseRef.license,
                localPath: LibraryPaths.baseModelDirectory(id: baseRef.baseModelId).path,
                metaJSON: "{}"
            )
            if let mem = library as? InMemoryPersonaLibrary {
                // Keep existing localPath if already registered with a real path.
                if mem.models[model.id] == nil {
                    mem.upsert(model: model)
                }
            }
            if let grdb = library as? GRDBPersonaLibrary {
                if try grdb.model(id: model.id) == nil {
                    try grdb.upsertModel(model)
                }
            }
        }

        if !replaceExisting, try store.fetch(id: result.document.id) != nil {
            throw BAMError(
                code: .schemaInvalid,
                message: "Persona already exists: \(result.document.id)"
            )
        }
        try save(document: result.document)
        return result.document
    }
}
