import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import BAMCore
import BAMModels
import BAMPersistence
import BAMPersonas
import BAMRunnersVoice
import BAMConsent

/// Observable façade for Personas: list/create/export/import packs.
@MainActor
final class PersonasViewModel: ObservableObject {
    @Published private(set) var personas: [PersonaIndexRecord] = []
    @Published private(set) var voiceProfiles: [VoiceProfileRecord] = []
    @Published private(set) var baseModels: [ModelOption] = []
    @Published private(set) var adapters: [AdapterOption] = []

    @Published var statusMessage: String?
    @Published var errorMessage: String?
    @Published private(set) var isBusy = false

    // Create form
    @Published var draftName: String = ""
    @Published var draftVersion: String = "1.0.0"
    @Published var draftSystemPrompt: String = ""
    @Published var selectedBaseModelId: String?
    @Published var selectedAdapterId: String?
    @Published var selectedVoiceId: String?
    @Published var selectedPersonaId: String?

    struct ModelOption: Identifiable, Equatable, Sendable {
        var id: String
        var name: String
        var localPath: String
    }

    struct AdapterOption: Identifiable, Equatable, Sendable {
        var id: String
        var name: String
        var localPath: String
    }

    private let service: PersonaService
    private let voiceStore: VoiceProfileStore?
    private let libraryRoot: URL

    init(
        service: PersonaService,
        voiceStore: VoiceProfileStore? = nil,
        libraryRoot: URL
    ) {
        self.service = service
        self.voiceStore = voiceStore
        self.libraryRoot = libraryRoot
    }

    static func makeDefault() throws -> PersonasViewModel {
        let db = try LibraryDatabase.openDefault()
        let root = LibraryPaths.libraryRoot
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let consentStore = ConsentStore(
            database: db,
            consentDirectory: LibraryPaths.consent,
            writeJSONFiles: true
        )
        let consentService = ConsentService(store: consentStore)
        let grdbLib = GRDBPersonaLibrary(
            database: db,
            consentLoader: { id in try consentService.fetch(id: id) }
        )
        let store = PersonaStore(database: db)
        let service = PersonaService(
            store: store,
            library: grdbLib,
            libraryRoot: root,
            consentPersister: { record in
                _ = try consentService.persist(record)
            },
            voicePersister: { profile in
                try VoiceProfileStore(database: db).upsert(profile)
            }
        )
        return PersonasViewModel(
            service: service,
            voiceStore: VoiceProfileStore(database: db),
            libraryRoot: root
        )
    }

    func refresh() {
        errorMessage = nil
        do {
            personas = try service.list()
            voiceProfiles = try voiceStore?.fetchAll() ?? []
            baseModels = try Self.scanBaseModels(libraryRoot: libraryRoot)
            adapters = try Self.scanAdapters(libraryRoot: libraryRoot)
            if selectedBaseModelId == nil {
                selectedBaseModelId = baseModels.first?.id
            }
            if selectedVoiceId == nil {
                selectedVoiceId = voiceProfiles.first?.id
            }
            if personas.isEmpty {
                statusMessage = "Create a persona or import a .bam.persona.zip pack."
            } else {
                statusMessage = "\(personas.count) persona(s)."
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func createPersona() {
        guard !isBusy else { return }
        let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            errorMessage = "Name is required."
            return
        }

        var llm: PersonaLLMComponents?
        if let base = selectedBaseModelId, !base.isEmpty {
            llm = PersonaLLMComponents(
                baseModelId: base,
                adapterArtifactId: selectedAdapterId
            )
        } else if let adapter = selectedAdapterId, !adapter.isEmpty {
            llm = PersonaLLMComponents(baseModelId: nil, adapterArtifactId: adapter)
        }

        var voice: PersonaVoiceComponents?
        if let vid = selectedVoiceId, !vid.isEmpty {
            voice = PersonaVoiceComponents(voiceProfileId: vid)
        }

        isBusy = true
        defer { isBusy = false }
        do {
            // Ensure base model is registered for resolution when scanned from disk.
            if let baseId = selectedBaseModelId,
               let option = baseModels.first(where: { $0.id == baseId }),
               let grdb = service.library as? GRDBPersonaLibrary,
               try grdb.model(id: baseId) == nil
            {
                try grdb.upsertModel(
                    ModelRecord(
                        id: baseId,
                        sourceKey: option.name,
                        name: option.name,
                        kind: .base,
                        localPath: option.localPath,
                        metaJSON: "{}"
                    )
                )
            }
            if let adapterId = selectedAdapterId,
               let option = adapters.first(where: { $0.id == adapterId }),
               let grdb = service.library as? GRDBPersonaLibrary,
               try grdb.artifact(id: adapterId) == nil
            {
                try grdb.upsertArtifact(
                    ArtifactRecord(
                        id: adapterId,
                        kind: .loraAdapter,
                        baseModelId: selectedBaseModelId,
                        localPath: option.localPath,
                        createdAt: ISO8601DateFormatter().string(from: Date())
                    )
                )
            }

            let doc = try service.create(
                name: name,
                version: draftVersion.isEmpty ? "1.0.0" : draftVersion,
                llm: llm,
                voice: voice,
                systemPrompt: draftSystemPrompt.isEmpty ? nil : draftSystemPrompt
            )
            // Best-effort resolve for status feedback.
            if let resolved = try? service.resolve(doc) {
                statusMessage = "Created \(doc.name) (\(resolved.mode.rawValue))."
            } else {
                statusMessage = "Created \(doc.name) (components may be unresolved)."
            }
            draftName = ""
            draftSystemPrompt = ""
            selectedPersonaId = doc.id
            refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteSelected() {
        guard let id = selectedPersonaId else { return }
        do {
            try service.delete(id: id)
            selectedPersonaId = nil
            statusMessage = "Deleted persona."
            refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func exportSelected() {
        guard let id = selectedPersonaId else {
            errorMessage = "Select a persona to export."
            return
        }
        guard let doc = try? service.fetch(id: id) else {
            errorMessage = "Persona not found."
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [Self.personaPackType]
        panel.nameFieldStringValue = "\(Self.sanitizeFilename(doc.name))-\(doc.version).bam.persona.zip"
        panel.canCreateDirectories = true
        panel.title = "Export Persona Pack"
        guard panel.runModal() == .OK, let url = panel.url else {
            statusMessage = "Export cancelled."
            return
        }

        isBusy = true
        defer { isBusy = false }
        do {
            _ = try service.exportPack(personaId: id, to: url)
            statusMessage = "Exported pack to \(url.lastPathComponent)"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func importPack(from url: URL) {
        isBusy = true
        defer { isBusy = false }
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
        }
        do {
            let doc = try service.importPack(from: url)
            selectedPersonaId = doc.id
            statusMessage = "Imported \(doc.name) v\(doc.version)"
            refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func resolveSummary(for record: PersonaIndexRecord) -> String {
        do {
            let resolved = try service.resolve(id: record.id)
            let warns = resolved.warnings.map(\.rawValue).joined(separator: ", ")
            if warns.isEmpty {
                return resolved.mode.rawValue
            }
            return "\(resolved.mode.rawValue) (\(warns))"
        } catch let error as PersonaUnresolvedError {
            return error.codes.map(\.rawValue).joined(separator: ",")
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: - Scanning

    private static func scanBaseModels(libraryRoot: URL) throws -> [ModelOption] {
        let base = libraryRoot.appendingPathComponent("models/base", isDirectory: true)
        guard FileManager.default.fileExists(atPath: base.path) else { return [] }
        let dirs = try FileManager.default.contentsOfDirectory(
            at: base,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        return dirs.compactMap { url -> ModelOption? in
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
                  isDir.boolValue
            else { return nil }
            // Prefer directory name as stable id when it looks like a UUID; else use name.
            let name = url.lastPathComponent
            let id = BAMID.isValid(name) ? name.lowercased() : name
            return ModelOption(id: id, name: name, localPath: url.path)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func scanAdapters(libraryRoot: URL) throws -> [AdapterOption] {
        let base = libraryRoot.appendingPathComponent("models/adapters", isDirectory: true)
        guard FileManager.default.fileExists(atPath: base.path) else { return [] }
        let dirs = try FileManager.default.contentsOfDirectory(
            at: base,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        return dirs.compactMap { url -> AdapterOption? in
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
                  isDir.boolValue
            else { return nil }
            let name = url.lastPathComponent
            return AdapterOption(id: name, name: name, localPath: url.path)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func sanitizeFilename(_ raw: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let cleaned = raw.components(separatedBy: invalid).joined(separator: "-")
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "persona" : trimmed
    }

    static var personaPackType: UTType {
        UTType(filenameExtension: "zip") ?? .zip
    }
}
