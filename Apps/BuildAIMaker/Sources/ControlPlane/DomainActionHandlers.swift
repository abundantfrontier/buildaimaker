import BAMAudioFX
import BAMCharacterStudio
import BAMControlPlane
import BAMCore
import BAMDatasets
import BAMJobs
import BAMModels
import BAMPersistence
import BAMRunnersMLX
import BAMRunnersVoice
import Foundation

// MARK: - Shared helpers

/// Allowed roots for MCP/CLI `sourceURI` (library, temp, user Documents/Downloads/Desktop, home JSONL).
enum ImportPathPolicy {
    static func isAllowed(_ path: String) -> Bool {
        let std = URL(fileURLWithPath: path).standardizedFileURL.path
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.standardizedFileURL.path
        var roots = [
            LibraryPaths.libraryRoot.path,
            fm.temporaryDirectory.path,
            NSTemporaryDirectory(),
        ]
        let userDirs: [FileManager.SearchPathDirectory] = [
            .documentDirectory, .downloadsDirectory, .desktopDirectory,
        ]
        for dir in userDirs {
            if let url = fm.urls(for: dir, in: .userDomainMask).first {
                roots.append(url.path)
            }
        }
        if roots.contains(where: { isUnder(std, root: $0) }) {
            return true
        }
        let ext = URL(fileURLWithPath: std).pathExtension.lowercased()
        return isUnder(std, root: home) && (ext == "jsonl" || ext == "json")
    }

    private static func isUnder(_ path: String, root: String) -> Bool {
        let r = URL(fileURLWithPath: root).standardizedFileURL.path
        return path == r || path.hasPrefix(r.hasSuffix("/") ? r : r + "/")
    }
}

enum MindJSONLCodec {
    static func encode(draft: CharacterDraft) -> String {
        let system = draft.bible?.systemPrompt
        var lines: [String] = []
        for ex in draft.examples {
            var messages: [[String: String]] = []
            if let system {
                messages.append(["role": "system", "content": system])
            }
            messages.append(["role": "user", "content": ex.user])
            messages.append(["role": "assistant", "content": ex.assistant])
            let row: [String: Any] = ["messages": messages]
            if let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]),
               let line = String(data: data, encoding: .utf8)
            {
                lines.append(line)
            }
        }
        return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }

    static func dialogueExamples(from jsonl: String, limit: Int = 2_000) -> [DialogueExample] {
        let chats = JSONLChatParser.preview(contents: jsonl, maxExamples: max(1, limit))
        var out: [DialogueExample] = []
        out.reserveCapacity(min(chats.count, limit))
        for chat in chats {
            guard let pair = chat.lastUserAssistant else { continue }
            out.append(DialogueExample(user: pair.user, assistant: pair.assistant))
            if out.count >= limit { break }
        }
        return out
    }

    static func firstSystemPrompt(from jsonl: String) -> String? {
        let chats = JSONLChatParser.preview(contents: jsonl, maxExamples: 8)
        for chat in chats {
            if let sys = chat.systemPrompt?.trimmingCharacters(in: .whitespacesAndNewlines),
               !sys.isEmpty
            {
                return sys
            }
        }
        return nil
    }

    static func apply(
        jsonl: String,
        to draft: inout CharacterDraft,
        name: String,
        species: String,
        vibe: String
    ) {
        let examples = dialogueExamples(from: jsonl)
        if !examples.isEmpty {
            draft.examples = examples
        }
        let system = firstSystemPrompt(from: jsonl)
        if draft.storyPaste.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let system
        {
            draft.storyPaste = system
        }
        if let system {
            if var bible = draft.bible {
                if bible.systemPromptOverride == nil {
                    bible.systemPromptOverride = system
                    bible.sourceNotes = system
                    draft.bible = bible
                }
            } else {
                draft.bible = CharacterBible(
                    name: name,
                    species: species,
                    vibe: vibe,
                    speechRules: [
                        "Speak in short, direct sentences.",
                    ],
                    sourceNotes: system,
                    generator: "import-v1",
                    systemPromptOverride: system
                )
            }
        }
    }
}

enum DefaultOpenModelBinder {
    static func gemma4LibraryPath() -> URL {
        LibraryPaths.modelsBase
            .appendingPathComponent("mlx-community--gemma-4-12B-it-qat-4bit", isDirectory: true)
    }

    static func bindIfPresent(to draft: inout CharacterDraft) {
        let url = gemma4LibraryPath()
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
              isDir.boolValue
        else { return }
        draft.baseModelId = url.lastPathComponent
        draft.baseModelPath = url.path
        draft.baseModelName = "Gemma 4 12B IT QAT 4bit"
        draft.baseModelSourceKey = "mlx-community/gemma-4-12B-it-qat-4bit"
    }

    static func bindAppleFoundation(to draft: inout CharacterDraft) {
        draft.baseModelId = "apple-foundation"
        draft.baseModelPath = CharacterDraft.appleFoundationPath
        draft.baseModelName = CharacterDraft.appleFoundationDisplayName
        draft.baseModelSourceKey = CharacterDraft.appleFoundationSourceKey
    }
}

// MARK: - character.list

struct CharacterListHandler: ActionHandler {
    static let id = ActionID("character.list")

    var definition: ActionDefinition {
        ActionDefinition(
            id: Self.id,
            title: "List characters",
            description: "Paginated character catalog (id, name, model, dataset, complete).",
            risk: .read,
            exposeToMCP: true,
            exposeToCLI: true,
            exposeToUI: true
        )
    }

    func execute(params: JSONValue, context: ActionContext) async -> ActionOutcome {
        let limit = min(100, max(1, params["limit"]?.intValue ?? 50))
        let cursor = params["cursor"]?.stringValue
        do {
            let store = CharacterLibraryStore()
            var drafts = try store.list()
            if let cursor, let idx = drafts.firstIndex(where: { $0.id == cursor }) {
                let next = drafts.index(after: idx)
                drafts = Array(drafts[next...])
            }
            let page = Array(drafts.prefix(limit))
            let nextCursor = page.count == limit ? page.last?.id : nil
            let items: [JSONValue] = page.map { d in
                .object([
                    "id": .string(d.id),
                    "name": .string(d.displayTitle),
                    "isComplete": .bool(d.isComplete),
                    "datasetId": d.datasetId.map { .string($0) } ?? .null,
                    "baseModelName": d.baseModelName.map { .string($0) } ?? .null,
                    "baseModelPath": d.baseModelPath.map { .string($0) } ?? .null,
                    "exampleCount": .number(Double(d.examples.count)),
                    "updatedAt": .string(d.updatedAt),
                ])
            }
            return .success(
                data: .object([
                    "characters": .array(items),
                    "count": .number(Double(items.count)),
                    "nextCursor": nextCursor.map { .string($0) } ?? .null,
                ]),
                context: context
            )
        } catch {
            return .failure(
                .internalError,
                message: error.localizedDescription,
                context: context
            )
        }
    }
}

// MARK: - character.create

struct CharacterCreateHandler: ActionHandler {
    static let id = ActionID("character.create")

    private let stateStore: StateStore

    init(stateStore: StateStore) {
        self.stateStore = stateStore
    }

    var definition: ActionDefinition {
        ActionDefinition(
            id: Self.id,
            title: "Create character",
            description:
                "Create a character draft and optionally bind or import a mind JSONL (sourceURI or jsonl).",
            risk: .write,
            timeoutClass: .long,
            exposeToMCP: true,
            exposeToCLI: true,
            exposeToUI: true
        )
    }

    func execute(params: JSONValue, context: ActionContext) async -> ActionOutcome {
        let name = params["name"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !name.isEmpty else {
            return .failure(
                .validationError,
                message: "Missing required name",
                remediation: "Pass { \"name\": \"Rocky\" }",
                context: context
            )
        }

        let reuseByName = params["reuseByName"]?.boolValue ?? false
        let charStore = CharacterLibraryStore()

        do {
            var reused = false
            var draft: CharacterDraft
            if reuseByName,
               let existing = try charStore.list().first(where: {
                   $0.displayTitle.compare(name, options: [.caseInsensitive, .diacriticInsensitive])
                       == .orderedSame
               })
            {
                draft = existing
                reused = true
            } else {
                draft = CharacterDraft(name: name)
            }

            if let speciesRaw = params["speciesPreset"]?.stringValue,
               let species = CreatureSpeciesPreset(rawValue: speciesRaw)
            {
                draft.speciesPreset = species
                draft.voicePreset = species.voicePresetRawValue
            }
            if let custom = params["customSpecies"]?.stringValue {
                draft.customSpecies = custom
                if !custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    draft.speciesPreset = .custom
                }
            }
            if let vibe = params["vibe"]?.stringValue {
                draft.vibe = vibe
            } else if draft.vibe.isEmpty {
                draft.vibe = draft.speciesPreset.suggestedVibe
            }
            if let story = params["storyPaste"]?.stringValue {
                draft.storyPaste = story
            }
            if let register = params["voiceRegister"]?.stringValue, !register.isEmpty {
                draft.voiceRegister = register
            }
            if let voicePreset = params["voicePreset"]?.stringValue, !voicePreset.isEmpty {
                draft.voicePreset = voicePreset
            }
            if !reused, let vp = CreatureVoicePreset(rawValue: draft.voicePreset) {
                let reg = VoiceRegister(rawValue: draft.voiceRegister) ?? vp.defaultRegister
                let p = CreatureFXParams.fromPreset(vp, register: reg)
                draft.voiceRegister = p.register.rawValue
                draft.size = p.size
                draft.grit = p.grit
                draft.atmosphere = p.atmosphere
                draft.formant = p.formant
                draft.metallic = p.metallic
                draft.tremble = p.tremble
                draft.breath = p.breath
                draft.speed = p.speed
                draft.robotize = p.robotize
                draft.textureIdSet = Set(p.textures.map(\.rawValue))
                draft.textureLevels = p.textureMix
            }

            if params["useAppleFoundation"]?.boolValue == true {
                DefaultOpenModelBinder.bindAppleFoundation(to: &draft)
            } else if let path = params["baseModelPath"]?.stringValue, !path.isEmpty {
                draft.baseModelPath = path
                draft.baseModelId = params["baseModelId"]?.stringValue
                    ?? URL(fileURLWithPath: path).lastPathComponent
                draft.baseModelName = params["baseModelName"]?.stringValue ?? draft.baseModelId
                draft.baseModelSourceKey = params["baseModelSourceKey"]?.stringValue
            } else if !draft.hasSelectedBaseModel {
                DefaultOpenModelBinder.bindIfPresent(to: &draft)
                if !draft.hasSelectedBaseModel {
                    DefaultOpenModelBinder.bindAppleFoundation(to: &draft)
                }
            }

            if let override = params["systemPrompt"]?.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !override.isEmpty
            {
                if var bible = draft.bible {
                    bible.systemPromptOverride = override
                    bible.sourceNotes = override
                    bible.name = name
                    draft.bible = bible
                } else {
                    draft.bible = CharacterBible(
                        name: name,
                        species: draft.resolvedSpecies,
                        vibe: draft.vibe,
                        sourceNotes: override,
                        generator: "import-v1",
                        systemPromptOverride: override
                    )
                }
                if draft.storyPaste.isEmpty {
                    draft.storyPaste = override
                }
            }

            let policyRaw = params["identityPolicy"]?.stringValue
                ?? MindIdentityPolicy.mergeByStableId.rawValue
            guard let policy = MindIdentityPolicy(rawValue: policyRaw) else {
                return .failure(
                    .validationError,
                    message: "Invalid identityPolicy: \(policyRaw)",
                    context: context
                )
            }

            var importResult: MindUpsertResult?
            if let content = params["jsonl"]?.stringValue, !content.isEmpty {
                MindJSONLCodec.apply(
                    jsonl: content,
                    to: &draft,
                    name: name,
                    species: draft.resolvedSpecies,
                    vibe: draft.vibe
                )
                let service = try DatasetLibraryService.openDefault()
                importResult = try service.upsertMindJSONL(
                    jsonl: content,
                    name: params["datasetName"]?.stringValue ?? "\(name) mind",
                    existingDatasetId: draft.datasetId,
                    policy: policy
                )
                draft.datasetId = importResult?.datasetId
            } else if let path = params["sourceURI"]?.stringValue, !path.isEmpty {
                guard ImportPathPolicy.isAllowed(path) else {
                    return .failure(
                        .pathNotAllowed,
                        message: "sourceURI outside allowed roots: \(path)",
                        remediation:
                            "Use a JSONL under Documents, Downloads, Desktop, the app library, or temp.",
                        context: context
                    )
                }
                let jsonl = try String(contentsOfFile: path, encoding: .utf8)
                guard !jsonl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return .failure(
                        .preconditionFailed,
                        message: "sourceURI is empty",
                        context: context
                    )
                }
                MindJSONLCodec.apply(
                    jsonl: jsonl,
                    to: &draft,
                    name: name,
                    species: draft.resolvedSpecies,
                    vibe: draft.vibe
                )
                let service = try DatasetLibraryService.openDefault()
                importResult = try service.upsertMindJSONL(
                    jsonl: jsonl,
                    name: params["datasetName"]?.stringValue ?? "\(name) mind",
                    existingDatasetId: draft.datasetId,
                    policy: policy
                )
                draft.datasetId = importResult?.datasetId
            } else if let datasetId = params["datasetId"]?.stringValue, !datasetId.isEmpty {
                let service = try DatasetLibraryService.openDefault()
                guard let record = try service.dataset(id: datasetId) else {
                    return .failure(
                        .notFound,
                        message: "Dataset not found: \(datasetId)",
                        context: context
                    )
                }
                draft.datasetId = datasetId
                let access = try service.resolveSourceAccess(for: record)
                defer { access.stop() }
                if let jsonl = try? String(contentsOf: access.url, encoding: .utf8) {
                    MindJSONLCodec.apply(
                        jsonl: jsonl,
                        to: &draft,
                        name: name,
                        species: draft.resolvedSpecies,
                        vibe: draft.vibe
                    )
                }
            }

            let markComplete = params["complete"]?.boolValue
                ?? (draft.datasetId != nil && !draft.examples.isEmpty)
            draft.isComplete = markComplete
            draft.wizardStepRaw = markComplete ? 4 : (draft.datasetId != nil ? 2 : 1)
            try charStore.save(draft)

            let charCount = (try? charStore.list())?.count ?? 0
            await stateStore.apply { state in
                state.counts["characters"] = charCount
                state.selection["characterId"] = draft.id
                if let datasetId = draft.datasetId {
                    state.selection["datasetId"] = datasetId
                }
                if SessionReveal.shouldReveal(params) {
                    SessionReveal.apply(
                        to: &state,
                        route: "characters",
                        characterId: draft.id,
                        datasetId: draft.datasetId,
                        highlight: "characters.row",
                        guideTitle: reused
                            ? "Opened \(draft.displayTitle)"
                            : "Created \(draft.displayTitle)",
                        guideSteps: [
                            "You’re on Characters. “\(draft.displayTitle)” is selected.",
                            "Click Edit to change name, model, story, or voice.",
                            "Use → Playground to chat, or Train to fine-tune.",
                        ]
                    )
                }
            }
            let rev = await stateStore.revision

            var data: [String: JSONValue] = [
                "characterId": .string(draft.id),
                "name": .string(draft.displayTitle),
                "reused": .bool(reused),
                "isComplete": .bool(draft.isComplete),
                "datasetId": draft.datasetId.map { .string($0) } ?? .null,
                "exampleCount": .number(Double(draft.examples.count)),
                "baseModelName": draft.baseModelName.map { .string($0) } ?? .null,
                "baseModelPath": draft.baseModelPath.map { .string($0) } ?? .null,
            ]
            if let importResult {
                data["versionId"] = .string(importResult.versionId)
                data["createdDataset"] = .bool(importResult.created)
                data["unchanged"] = .bool(importResult.unchanged)
                data["rowCount"] = .number(Double(importResult.rowCount))
                data["datasetName"] = .string(importResult.name)
            }
            return .success(data: .object(data), stateRevision: rev, context: context)
        } catch let err as BAMError {
            let code: ActionErrorCode =
                err.code == .pathEscape ? .pathNotAllowed
                : err.code == .datasetInvalid ? .validationError
                : .internalError
            return .failure(code, message: err.errorDescription ?? err.code.rawValue, context: context)
        } catch {
            return .failure(.internalError, message: error.localizedDescription, context: context)
        }
    }
}

// MARK: - character.importMind

struct CharacterImportMindHandler: ActionHandler {
    static let id = ActionID("character.importMind")

    private let stateStore: StateStore

    init(stateStore: StateStore) {
        self.stateStore = stateStore
    }

    var definition: ActionDefinition {
        ActionDefinition(
            id: Self.id,
            title: "Import mind",
            description:
                "Import or reimport a character mind JSONL with identity policy (prevents duplicate “X mind” datasets).",
            risk: .write,
            timeoutClass: .long,
            exposeToMCP: true,
            exposeToCLI: true,
            exposeToUI: true
        )
    }

    func execute(params: JSONValue, context: ActionContext) async -> ActionOutcome {
        guard let characterId = params["characterId"]?.stringValue, !characterId.isEmpty else {
            return .failure(
                .validationError,
                message: "Missing required characterId",
                remediation: "Pass { \"characterId\": \"…\" }",
                context: context
            )
        }
        let policyRaw = params["identityPolicy"]?.stringValue ?? MindIdentityPolicy.mergeByStableId.rawValue
        guard let policy = MindIdentityPolicy(rawValue: policyRaw) else {
            return .failure(
                .validationError,
                message: "Invalid identityPolicy: \(policyRaw)",
                remediation:
                    "Use mergeByStableId | mergeByContentHash | alwaysCreate | replaceExisting",
                context: context
            )
        }

        do {
            let charStore = CharacterLibraryStore()
            let loaded = try charStore.load(id: characterId)

            let jsonl: String
            if let content = params["jsonl"]?.stringValue, !content.isEmpty {
                jsonl = content
            } else if let path = params["sourceURI"]?.stringValue, !path.isEmpty {
                guard ImportPathPolicy.isAllowed(path) else {
                    return .failure(
                        .pathNotAllowed,
                        message: "sourceURI outside allowed roots: \(path)",
                        remediation:
                            "Use a JSONL under Documents, Downloads, Desktop, the app library, or temp — or pass jsonl inline.",
                        context: context
                    )
                }
                jsonl = try String(contentsOfFile: path, encoding: .utf8)
            } else {
                // Default: encode current draft examples.
                jsonl = MindJSONLCodec.encode(draft: loaded)
            }

            guard !jsonl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .failure(
                    .preconditionFailed,
                    message: "No mind content to import (empty examples / JSONL).",
                    remediation: "Build teaching examples first.",
                    context: context
                )
            }

            let name = params["name"]?.stringValue
                ?? "\(loaded.displayTitle) mind"
            let service = try DatasetLibraryService.openDefault()
            let result = try service.upsertMindJSONL(
                jsonl: jsonl,
                name: name,
                existingDatasetId: loaded.datasetId,
                policy: policy
            )
            var draft = loaded
            draft.datasetId = result.datasetId
            MindJSONLCodec.apply(
                jsonl: jsonl,
                to: &draft,
                name: draft.displayTitle,
                species: draft.resolvedSpecies,
                vibe: draft.vibe
            )
            try charStore.save(draft)
            let savedDatasetId = result.datasetId
            let charCount = (try? charStore.list())?.count ?? 0

            await stateStore.apply { state in
                state.counts["characters"] = charCount
                state.selection["characterId"] = characterId
                state.selection["datasetId"] = savedDatasetId
                if SessionReveal.shouldReveal(params) {
                    SessionReveal.apply(
                        to: &state,
                        route: "characters",
                        characterId: characterId,
                        datasetId: savedDatasetId,
                        highlight: "characters.row",
                        guideTitle: "Mind imported for \(draft.displayTitle)",
                        guideSteps: [
                            "“\(draft.displayTitle)” now uses this mind dataset.",
                            "Edit → Story to preview lines, or Train to fine-tune.",
                        ]
                    )
                }
            }
            let rev = await stateStore.revision

            return .success(
                data: .object([
                    "characterId": .string(characterId),
                    "datasetId": .string(result.datasetId),
                    "versionId": .string(result.versionId),
                    "created": .bool(result.created),
                    "unchanged": .bool(result.unchanged),
                    "contentHash": .string(result.contentHash),
                    "rowCount": .number(Double(result.rowCount)),
                    "name": .string(result.name),
                    "identityPolicy": .string(policy.rawValue),
                ]),
                stateRevision: rev,
                context: context
            )
        } catch let err as BAMError {
            let code: ActionErrorCode =
                err.code == .pathEscape ? .pathNotAllowed
                : err.code == .datasetInvalid ? .validationError
                : .internalError
            return .failure(code, message: err.errorDescription ?? err.code.rawValue, context: context)
        } catch {
            return .failure(.internalError, message: error.localizedDescription, context: context)
        }
    }

}

// MARK: - dataset.list

struct DatasetListHandler: ActionHandler {
    static let id = ActionID("dataset.list")

    var definition: ActionDefinition {
        ActionDefinition(
            id: Self.id,
            title: "List datasets",
            description: "Paginated dataset library (id, name, status, rowCount).",
            risk: .read,
            exposeToMCP: true,
            exposeToCLI: true,
            exposeToUI: true
        )
    }

    func execute(params: JSONValue, context: ActionContext) async -> ActionOutcome {
        let limit = min(200, max(1, params["limit"]?.intValue ?? 50))
        let cursor = params["cursor"]?.stringValue
        let query = params["nameContains"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        do {
            let service = try DatasetLibraryService.openDefault()
            var records = try service.listDatasets()
            if let query, !query.isEmpty {
                records = records.filter { $0.name.lowercased().contains(query) }
            }
            if let cursor, let idx = records.firstIndex(where: { $0.id == cursor }) {
                let next = records.index(after: idx)
                records = Array(records[next...])
            }
            let page = Array(records.prefix(limit))
            let nextCursor = page.count == limit ? page.last?.id : nil
            var items: [JSONValue] = []
            items.reserveCapacity(page.count)
            for rec in page {
                let latest = try? service.latestVersion(datasetId: rec.id)
                items.append(
                    .object([
                        "id": .string(rec.id),
                        "name": .string(rec.name),
                        "status": .string(rec.status.rawValue),
                        "importMode": .string(rec.importMode.rawValue),
                        "createdAt": .string(rec.createdAt),
                        "rowCount": latest?.rowCount.map { .number(Double($0)) } ?? .null,
                        "version": latest.map { .number(Double($0.version)) } ?? .null,
                    ])
                )
            }
            return .success(
                data: .object([
                    "datasets": .array(items),
                    "count": .number(Double(items.count)),
                    "nextCursor": nextCursor.map { .string($0) } ?? .null,
                ]),
                context: context
            )
        } catch {
            return .failure(.internalError, message: error.localizedDescription, context: context)
        }
    }
}

// MARK: - dataset.import

struct DatasetImportHandler: ActionHandler {
    static let id = ActionID("dataset.import")

    private let stateStore: StateStore

    init(stateStore: StateStore) {
        self.stateStore = stateStore
    }

    var definition: ActionDefinition {
        ActionDefinition(
            id: Self.id,
            title: "Import dataset",
            description:
                "Copy a chat JSONL into the library (sourceURI or jsonl). Optionally bind to a character.",
            risk: .write,
            timeoutClass: .long,
            exposeToMCP: true,
            exposeToCLI: true,
            exposeToUI: true
        )
    }

    func execute(params: JSONValue, context: ActionContext) async -> ActionOutcome {
        let policyRaw = params["identityPolicy"]?.stringValue
            ?? MindIdentityPolicy.mergeByStableId.rawValue
        guard let policy = MindIdentityPolicy(rawValue: policyRaw) else {
            return .failure(
                .validationError,
                message: "Invalid identityPolicy: \(policyRaw)",
                context: context
            )
        }

        do {
            let jsonl: String
            if let content = params["jsonl"]?.stringValue, !content.isEmpty {
                jsonl = content
            } else if let path = params["sourceURI"]?.stringValue, !path.isEmpty {
                guard ImportPathPolicy.isAllowed(path) else {
                    return .failure(
                        .pathNotAllowed,
                        message: "sourceURI outside allowed roots: \(path)",
                        remediation:
                            "Use a JSONL under Documents, Downloads, Desktop, the app library, or temp.",
                        context: context
                    )
                }
                jsonl = try String(contentsOfFile: path, encoding: .utf8)
            } else {
                return .failure(
                    .validationError,
                    message: "Missing jsonl or sourceURI",
                    remediation: "Pass { \"sourceURI\": \"/path/to/file.jsonl\" }",
                    context: context
                )
            }

            guard !jsonl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .failure(
                    .preconditionFailed,
                    message: "No dataset content to import (empty JSONL).",
                    context: context
                )
            }

            var existingId = params["datasetId"]?.stringValue
            var charDraft: CharacterDraft?
            let charId = params["characterId"]?.stringValue
            let charStore = CharacterLibraryStore()
            if let charId {
                let loaded = try charStore.load(id: charId)
                charDraft = loaded
                if existingId == nil {
                    existingId = loaded.datasetId
                }
            }

            let defaultName: String
            if let explicit = params["name"]?.stringValue, !explicit.isEmpty {
                defaultName = explicit
            } else if let charDraft {
                defaultName = "\(charDraft.displayTitle) mind"
            } else {
                defaultName = "Imported mind"
            }

            let service = try DatasetLibraryService.openDefault()
            let result = try service.upsertMindJSONL(
                jsonl: jsonl,
                name: defaultName,
                existingDatasetId: existingId,
                policy: policy
            )

            if var draft = charDraft, let charId {
                draft.datasetId = result.datasetId
                MindJSONLCodec.apply(
                    jsonl: jsonl,
                    to: &draft,
                    name: draft.displayTitle,
                    species: draft.resolvedSpecies,
                    vibe: draft.vibe
                )
                try charStore.save(draft)
            }

            await stateStore.apply { state in
                state.selection["datasetId"] = result.datasetId
                if let charId {
                    state.selection["characterId"] = charId
                }
                if SessionReveal.shouldReveal(params) {
                    SessionReveal.apply(
                        to: &state,
                        route: "datasets",
                        characterId: charId,
                        datasetId: result.datasetId,
                        highlight: "datasets.import",
                        guideTitle: "Imported \(result.name)",
                        guideSteps: [
                            "Advanced → Datasets lists “\(result.name)”.",
                            "Select it to preview messages.",
                        ]
                    )
                }
            }
            let rev = await stateStore.revision

            return .success(
                data: .object([
                    "datasetId": .string(result.datasetId),
                    "versionId": .string(result.versionId),
                    "created": .bool(result.created),
                    "unchanged": .bool(result.unchanged),
                    "contentHash": .string(result.contentHash),
                    "rowCount": .number(Double(result.rowCount)),
                    "name": .string(result.name),
                    "characterId": charId.map { .string($0) } ?? .null,
                    "identityPolicy": .string(policy.rawValue),
                ]),
                stateRevision: rev,
                context: context
            )
        } catch let err as BAMError {
            let code: ActionErrorCode =
                err.code == .pathEscape ? .pathNotAllowed
                : err.code == .datasetInvalid ? .validationError
                : .internalError
            return .failure(code, message: err.errorDescription ?? err.code.rawValue, context: context)
        } catch {
            return .failure(.internalError, message: error.localizedDescription, context: context)
        }
    }
}

// MARK: - minds.dedupe

struct MindsDedupeHandler: ActionHandler {
    static let id = ActionID("minds.dedupe")

    private let stateStore: StateStore

    init(stateStore: StateStore) {
        self.stateStore = stateStore
    }

    var definition: ActionDefinition {
        ActionDefinition(
            id: Self.id,
            title: "Dedupe mind datasets",
            description:
                "Remove orphan duplicate mind datasets (e.g. many “Robby mind” rows). dryRun defaults to true.",
            risk: .destructive,
            timeoutClass: .long,
            exposeToMCP: true,
            exposeToCLI: true,
            exposeToUI: true
        )
    }

    func execute(params: JSONValue, context: ActionContext) async -> ActionOutcome {
        let dryRun = params["dryRun"]?.boolValue ?? true
        let suffix = params["nameSuffix"]?.stringValue ?? " mind"
        do {
            let chars = try CharacterLibraryStore().list()
            let referenced = Set(chars.compactMap(\.datasetId))
            let service = try DatasetLibraryService.openDefault()
            let result = try service.dedupeMindDatasets(
                referencedDatasetIds: referenced,
                nameSuffix: suffix,
                dryRun: dryRun
            )
            await stateStore.apply { state in
                state.counts["mindDatasetsDeletedLast"] = result.deleted.count
                state.counts["mindDatasetsKeptLast"] = result.kept.count
            }
            let rev = await stateStore.revision
            return .success(
                data: .object([
                    "dryRun": .bool(result.dryRun),
                    "examined": .number(Double(result.examined)),
                    "kept": .array(result.kept.map { .string($0) }),
                    "deleted": .array(result.deleted.map { .string($0) }),
                    "deletedCount": .number(Double(result.deleted.count)),
                    "reasons": .object(result.reasons.mapValues { .string($0) }),
                ]),
                stateRevision: rev,
                context: context
            )
        } catch {
            return .failure(.internalError, message: error.localizedDescription, context: context)
        }
    }
}

// MARK: - finetune.start

struct FinetuneStartHandler: ActionHandler {
    static let id = ActionID("finetune.start")

    private let jobQueue: JobQueueController
    private let stateStore: StateStore

    init(jobQueue: JobQueueController, stateStore: StateStore) {
        self.jobQueue = jobQueue
        self.stateStore = stateStore
    }

    var definition: ActionDefinition {
        ActionDefinition(
            id: Self.id,
            title: "Start fine-tune",
            description:
                "Enqueue a fine-tune job for a character; returns jobId immediately. recipe: mlx_lora | apple_adapter.",
            risk: .expensive,
            timeoutClass: .long,
            exposeToMCP: true,
            exposeToCLI: true,
            exposeToUI: true
        )
    }

    func execute(params: JSONValue, context: ActionContext) async -> ActionOutcome {
        guard let characterId = params["characterId"]?.stringValue, !characterId.isEmpty else {
            return .failure(
                .validationError,
                message: "Missing characterId",
                context: context
            )
        }
        let recipe = params["recipe"]?.stringValue ?? "mlx_lora"

        do {
            let charStore = CharacterLibraryStore()
            let draft = try charStore.load(id: characterId)
            guard let datasetId = params["datasetId"]?.stringValue ?? draft.datasetId else {
                return .failure(
                    .preconditionFailed,
                    message: "Character has no mind dataset. Import mind first.",
                    remediation: "Call character.importMind then retry.",
                    context: context
                )
            }

            let datasets = try DatasetLibraryService.openDefault()
            guard try datasets.dataset(id: datasetId) != nil else {
                return .failure(
                    .notFound,
                    message: "Dataset not found: \(datasetId)",
                    context: context
                )
            }
            guard let version = try datasets.latestVersion(datasetId: datasetId) else {
                return .failure(
                    .preconditionFailed,
                    message: "Dataset has no versions: \(datasetId)",
                    context: context
                )
            }

            let jobId = BAMID.generate()
            let access = try datasets.resolveSourceAccess(
                for: try datasets.dataset(id: datasetId)!
            )
            defer { access.stop() }

            let paths: JobPaths
            let spec: JobSpec

            switch recipe {
            case "apple_adapter":
                spec = .foundationAdapter(
                    id: jobId,
                    datasetVersionId: version.id
                )
                paths = JobPathsFactory.make(
                    jobId: jobId,
                    libraryRoot: LibraryPaths.libraryRoot,
                    datasetPath: access.url.path,
                    baseModelPath: nil
                )
            case "mlx_lora":
                let basePath = params["baseModelPath"]?.stringValue ?? draft.baseModelPath
                guard let basePath, !basePath.isEmpty,
                      basePath != CharacterDraft.appleFoundationPath
                else {
                    return .failure(
                        .preconditionFailed,
                        message: "mlx_lora requires an open base model path on the character.",
                        remediation: "Select an open MLX model under Model, or use recipe apple_adapter.",
                        context: context
                    )
                }
                let baseId = draft.baseModelId ?? URL(fileURLWithPath: basePath).lastPathComponent
                let sourceKey = draft.baseModelSourceKey ?? baseId
                spec = .llm(
                    id: jobId,
                    baseModelId: baseId,
                    baseModelSourceKey: sourceKey,
                    datasetVersionId: version.id
                )
                paths = JobPathsFactory.make(
                    jobId: jobId,
                    libraryRoot: LibraryPaths.libraryRoot,
                    datasetPath: access.url.path,
                    baseModelPath: basePath
                )
            default:
                return .failure(
                    .validationError,
                    message: "Unknown recipe: \(recipe)",
                    remediation: "Use mlx_lora or apple_adapter",
                    context: context
                )
            }

            let record = try await jobQueue.enqueue(spec: spec, paths: paths)
            await stateStore.apply { state in
                state.selection["characterId"] = characterId
                state.selection["lastJobId"] = jobId
                state.jobsSummary["lastEnqueued"] = .object([
                    "jobId": .string(jobId),
                    "status": .string(record.status.rawValue),
                    "modality": .string(record.modality.rawValue),
                ])
                if SessionReveal.shouldReveal(params) {
                    SessionReveal.apply(
                        to: &state,
                        route: "jobs",
                        characterId: characterId,
                        datasetId: datasetId,
                        jobId: jobId,
                        highlight: "jobs.list",
                        guideTitle: "Fine-tune queued",
                        guideSteps: [
                            "Jobs shows the new job (\(jobId.prefix(8))…).",
                            "Approve the orange banner if this was started by an agent.",
                            "When it finishes, open Playground to try the adapter.",
                        ]
                    )
                }
            }
            let rev = await stateStore.revision
            return .success(
                data: .object([
                    "jobId": .string(jobId),
                    "status": .string(record.status.rawValue),
                    "recipe": .string(recipe),
                    "characterId": .string(characterId),
                    "datasetId": .string(datasetId),
                    "datasetVersionId": .string(version.id),
                ]),
                jobId: jobId,
                stateRevision: rev,
                context: context
            )
        } catch {
            return .failure(
                .internalError,
                message: error.localizedDescription,
                context: context
            )
        }
    }
}

// MARK: - job.get / job.list / job.cancel

struct JobGetHandler: ActionHandler {
    static let id = ActionID("job.get")

    private let jobQueue: JobQueueController

    init(jobQueue: JobQueueController) {
        self.jobQueue = jobQueue
    }

    var definition: ActionDefinition {
        ActionDefinition(
            id: Self.id,
            title: "Get job",
            description: "Poll job status and optional progress.",
            risk: .read,
            exposeToMCP: true,
            exposeToCLI: true,
            exposeToUI: true
        )
    }

    func execute(params: JSONValue, context: ActionContext) async -> ActionOutcome {
        guard let jobId = params["jobId"]?.stringValue, !jobId.isEmpty else {
            return .failure(.validationError, message: "Missing jobId", context: context)
        }
        do {
            guard let job = try await jobQueue.store.fetch(id: jobId) else {
                return .failure(.notFound, message: "Job not found: \(jobId)", context: context)
            }
            var obj: [String: JSONValue] = [
                "jobId": .string(job.id),
                "status": .string(job.status.rawValue),
                "modality": .string(job.modality.rawValue),
                "createdAt": .string(job.createdAt),
                "updatedAt": .string(job.updatedAt),
            ]
            if let code = job.errorCode {
                obj["errorCode"] = .string(code)
            }
            if let msg = job.errorMessage {
                obj["errorMessage"] = .string(msg)
            }
            if let progress = await jobQueue.progress(for: jobId) {
                var frac: JSONValue = .null
                if let total = progress.totalSteps, total > 0 {
                    frac = .number(Double(progress.step) / Double(total))
                }
                obj["progress"] = .object([
                    "fraction": frac,
                    "message": progress.message.map { .string($0) } ?? .null,
                    "step": .number(Double(progress.step)),
                    "totalSteps": progress.totalSteps.map { .number(Double($0)) } ?? .null,
                    "loss": progress.loss.map { .number($0) } ?? .null,
                ])
            }
            return .success(data: .object(obj), jobId: jobId, context: context)
        } catch {
            return .failure(.internalError, message: error.localizedDescription, context: context)
        }
    }
}

struct JobListHandler: ActionHandler {
    static let id = ActionID("job.list")

    private let jobQueue: JobQueueController

    init(jobQueue: JobQueueController) {
        self.jobQueue = jobQueue
    }

    var definition: ActionDefinition {
        ActionDefinition(
            id: Self.id,
            title: "List jobs",
            description: "List recent training jobs.",
            risk: .read,
            exposeToMCP: true,
            exposeToCLI: true,
            exposeToUI: true
        )
    }

    func execute(params: JSONValue, context: ActionContext) async -> ActionOutcome {
        let limit = min(100, max(1, params["limit"]?.intValue ?? 50))
        do {
            let jobs = try await jobQueue.listJobs()
            let page = Array(jobs.prefix(limit))
            let items: [JSONValue] = page.map { job in
                .object([
                    "jobId": .string(job.id),
                    "status": .string(job.status.rawValue),
                    "modality": .string(job.modality.rawValue),
                    "updatedAt": .string(job.updatedAt),
                ])
            }
            return .success(
                data: .object([
                    "jobs": .array(items),
                    "count": .number(Double(items.count)),
                ]),
                context: context
            )
        } catch {
            return .failure(.internalError, message: error.localizedDescription, context: context)
        }
    }
}

struct JobCancelHandler: ActionHandler {
    static let id = ActionID("job.cancel")

    private let jobQueue: JobQueueController

    init(jobQueue: JobQueueController) {
        self.jobQueue = jobQueue
    }

    var definition: ActionDefinition {
        ActionDefinition(
            id: Self.id,
            title: "Cancel job",
            description: "Request cancel for a queued or running job.",
            risk: .write,
            exposeToMCP: true,
            exposeToCLI: true,
            exposeToUI: true
        )
    }

    func execute(params: JSONValue, context: ActionContext) async -> ActionOutcome {
        guard let jobId = params["jobId"]?.stringValue, !jobId.isEmpty else {
            return .failure(.validationError, message: "Missing jobId", context: context)
        }
        do {
            try await jobQueue.cancel(jobId: jobId)
            return .success(
                data: .object([
                    "jobId": .string(jobId),
                    "cancelRequested": .bool(true),
                ]),
                jobId: jobId,
                context: context
            )
        } catch {
            return .failure(
                .preconditionFailed,
                message: error.localizedDescription,
                context: context
            )
        }
    }
}
