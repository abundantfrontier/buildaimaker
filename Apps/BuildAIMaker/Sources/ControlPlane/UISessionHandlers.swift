import BAMCharacterStudio
import BAMControlPlane
import BAMCore
import BAMDatasets
import BAMInference
import BAMModelCatalog
import BAMModels
import BAMPersistence
import BAMPersonas
import BAMRunnersVoice
import Foundation

// MARK: - ui.guide

struct UIGuideHandler: ActionHandler {
    static let id = ActionID("ui.guide")

    private let stateStore: StateStore

    init(stateStore: StateStore) {
        self.stateStore = stateStore
    }

    var definition: ActionDefinition {
        ActionDefinition(
            id: Self.id,
            title: "Show how (UI guide)",
            description:
                "Navigate the app and show numbered steps so a human can do the task by hand. Pass task (createCharacter, editCharacter, importMind, pickModel, hearVoice, openPlayground, pickCharacter, chat, openTrain, startFinetune, installModel, listJobs, dedupeMinds) and optional characterId.",
            risk: .session,
            exposeToMCP: true,
            exposeToCLI: true,
            exposeToUI: true
        )
    }

    func execute(params: JSONValue, context: ActionContext) async -> ActionOutcome {
        if params["listTasks"]?.boolValue == true || params["task"] == nil {
            let tasks: [JSONValue] = UIGuideCatalog.all.map { r in
                .object([
                    "task": .string(r.task),
                    "title": .string(r.title),
                    "route": .string(r.route),
                ])
            }
            if params["task"] == nil, params["listTasks"]?.boolValue != false {
                return .success(
                    data: .object([
                        "tasks": .array(tasks),
                        "count": .number(Double(tasks.count)),
                        "hint": .string("Pass { \"task\": \"createCharacter\" } to point the UI at that flow."),
                    ]),
                    context: context
                )
            }
        }

        guard let task = params["task"]?.stringValue, let recipe = UIGuideCatalog.recipe(for: task) else {
            return .failure(
                .validationError,
                message: "Unknown or missing task",
                remediation:
                    "Use createCharacter | editCharacter | importMind | pickModel | hearVoice | openPlayground | chat | openTrain | startFinetune | installModel | listJobs | dedupeMinds — or omit task to list them.",
                context: context
            )
        }

        await stateStore.apply { state in
            SessionReveal.apply(
                to: &state,
                route: recipe.route,
                characterId: params["characterId"]?.stringValue,
                datasetId: params["datasetId"]?.stringValue,
                open: recipe.open,
                highlight: recipe.highlight,
                guideTitle: recipe.title,
                guideSteps: recipe.steps,
                wizardStep: recipe.wizardStep
            )
        }
        let rev = await stateStore.revision
        return .success(
            data: .object([
                "task": .string(recipe.task),
                "title": .string(recipe.title),
                "route": .string(recipe.route),
                "highlight": .string(recipe.highlight),
                "open": recipe.open.map { .string($0) } ?? .null,
                "manualSteps": .array(recipe.steps.map { .string($0) }),
                "didPerform": .bool(false),
            ]),
            stateRevision: rev,
            context: context
        )
    }
}

// MARK: - character.get / update / delete / open

enum CharacterPayload {
    static func json(_ d: CharacterDraft, exampleLimit: Int = 6) -> JSONValue {
        let preview = Array(d.examples.prefix(exampleLimit)).map { ex in
            JSONValue.object([
                "id": .string(ex.id),
                "user": .string(ex.user),
                "assistant": .string(ex.assistant),
            ])
        }
        return .object([
            "id": .string(d.id),
            "name": .string(d.displayTitle),
            "isComplete": .bool(d.isComplete),
            "speciesPreset": .string(d.speciesPreset.rawValue),
            "customSpecies": .string(d.customSpecies),
            "resolvedSpecies": .string(d.resolvedSpecies),
            "vibe": .string(d.vibe),
            "storyPaste": .string(d.storyPaste),
            "datasetId": d.datasetId.map { .string($0) } ?? .null,
            "exampleCount": .number(Double(d.examples.count)),
            "examplesPreview": .array(preview),
            "baseModelName": d.baseModelName.map { .string($0) } ?? .null,
            "baseModelPath": d.baseModelPath.map { .string($0) } ?? .null,
            "baseModelId": d.baseModelId.map { .string($0) } ?? .null,
            "baseModelSourceKey": d.baseModelSourceKey.map { .string($0) } ?? .null,
            "adapterId": d.adapterId.map { .string($0) } ?? .null,
            "adapterPath": d.adapterPath.map { .string($0) } ?? .null,
            "adapterName": d.adapterName.map { .string($0) } ?? .null,
            "voicePreset": .string(d.voicePreset),
            "voiceRegister": .string(d.voiceRegister),
            "systemPrompt": d.bible.map { .string($0.systemPrompt) } ?? .null,
            "wizardStepRaw": .number(Double(d.wizardStepRaw)),
            "updatedAt": .string(d.updatedAt),
        ])
    }
}

struct CharacterGetHandler: ActionHandler {
    static let id = ActionID("character.get")

    var definition: ActionDefinition {
        ActionDefinition(
            id: Self.id,
            title: "Get character",
            description: "Load one character card (identity, model, mind summary, system prompt).",
            risk: .read,
            exposeToMCP: true,
            exposeToCLI: true,
            exposeToUI: true
        )
    }

    func execute(params: JSONValue, context: ActionContext) async -> ActionOutcome {
        guard let id = params["characterId"]?.stringValue, !id.isEmpty else {
            return .failure(
                .validationError,
                message: "Missing characterId",
                context: context
            )
        }
        do {
            let draft = try CharacterLibraryStore().load(id: id)
            return .success(data: CharacterPayload.json(draft), context: context)
        } catch {
            return .failure(.notFound, message: "Character not found: \(id)", context: context)
        }
    }
}

struct CharacterUpdateHandler: ActionHandler {
    static let id = ActionID("character.update")

    private let stateStore: StateStore

    init(stateStore: StateStore) {
        self.stateStore = stateStore
    }

    var definition: ActionDefinition {
        ActionDefinition(
            id: Self.id,
            title: "Update character",
            description:
                "Patch a character (name, vibe, storyPaste, species, model, voice, systemPrompt, complete).",
            risk: .write,
            exposeToMCP: true,
            exposeToCLI: true,
            exposeToUI: true
        )
    }

    func execute(params: JSONValue, context: ActionContext) async -> ActionOutcome {
        guard let id = params["characterId"]?.stringValue, !id.isEmpty else {
            return .failure(.validationError, message: "Missing characterId", context: context)
        }
        do {
            let store = CharacterLibraryStore()
            var draft = try store.load(id: id)
            if let name = params["name"]?.stringValue { draft.name = name }
            if let vibe = params["vibe"]?.stringValue { draft.vibe = vibe }
            if let story = params["storyPaste"]?.stringValue { draft.storyPaste = story }
            if let speciesRaw = params["speciesPreset"]?.stringValue,
               let species = CreatureSpeciesPreset(rawValue: speciesRaw)
            {
                draft.speciesPreset = species
            }
            if let custom = params["customSpecies"]?.stringValue {
                draft.customSpecies = custom
                if !custom.isEmpty { draft.speciesPreset = .custom }
            }
            if let voice = params["voicePreset"]?.stringValue { draft.voicePreset = voice }
            if let register = params["voiceRegister"]?.stringValue { draft.voiceRegister = register }
            if let path = params["baseModelPath"]?.stringValue {
                draft.baseModelPath = path
                draft.baseModelId = params["baseModelId"]?.stringValue
                    ?? URL(fileURLWithPath: path).lastPathComponent
                draft.baseModelName = params["baseModelName"]?.stringValue ?? draft.baseModelId
                draft.baseModelSourceKey = params["baseModelSourceKey"]?.stringValue
            }
            if params["useAppleFoundation"]?.boolValue == true {
                DefaultOpenModelBinder.bindAppleFoundation(to: &draft)
            }
            if let complete = params["complete"]?.boolValue {
                draft.isComplete = complete
            }
            if let override = params["systemPrompt"]?.stringValue {
                if var bible = draft.bible {
                    bible.systemPromptOverride = override
                    bible.sourceNotes = override
                    draft.bible = bible
                } else {
                    draft.bible = CharacterBible(
                        name: draft.displayTitle,
                        species: draft.resolvedSpecies,
                        vibe: draft.vibe,
                        sourceNotes: override,
                        generator: "import-v1",
                        systemPromptOverride: override
                    )
                }
            }
            if let datasetId = params["datasetId"]?.stringValue {
                draft.datasetId = datasetId
            }
            try store.save(draft)

            if SessionReveal.shouldReveal(params) {
                await stateStore.apply { state in
                    SessionReveal.apply(
                        to: &state,
                        route: "characters",
                        characterId: draft.id,
                        datasetId: draft.datasetId,
                        highlight: "characters.row",
                        guideTitle: "Updated \(draft.displayTitle)",
                        guideSteps: [
                            "Characters is showing “\(draft.displayTitle)”.",
                            "Click Edit to review the change in the wizard.",
                        ]
                    )
                }
            }
            let rev = await stateStore.revision
            return .success(data: CharacterPayload.json(draft), stateRevision: rev, context: context)
        } catch {
            return .failure(.notFound, message: error.localizedDescription, context: context)
        }
    }
}

struct CharacterDeleteHandler: ActionHandler {
    static let id = ActionID("character.delete")

    private let stateStore: StateStore

    init(stateStore: StateStore) {
        self.stateStore = stateStore
    }

    var definition: ActionDefinition {
        ActionDefinition(
            id: Self.id,
            title: "Delete character",
            description: "Permanently remove a character card and its on-disk assets.",
            risk: .destructive,
            exposeToMCP: true,
            exposeToCLI: true,
            exposeToUI: true
        )
    }

    func execute(params: JSONValue, context: ActionContext) async -> ActionOutcome {
        guard let id = params["characterId"]?.stringValue, !id.isEmpty else {
            return .failure(.validationError, message: "Missing characterId", context: context)
        }
        do {
            let store = CharacterLibraryStore()
            let existing = try? store.load(id: id)
            try store.delete(id: id)
            let count = (try? store.list())?.count ?? 0
            await stateStore.apply { state in
                state.counts["characters"] = count
                if state.selection["characterId"] == id {
                    state.selection["characterId"] = nil
                    state.selection["open"] = nil
                }
                if SessionReveal.shouldReveal(params) {
                    SessionReveal.apply(
                        to: &state,
                        route: "characters",
                        highlight: "characters.create",
                        guideTitle: "Removed \(existing?.displayTitle ?? "character")",
                        guideSteps: ["The character is gone from Characters."]
                    )
                }
            }
            let rev = await stateStore.revision
            return .success(
                data: .object([
                    "characterId": .string(id),
                    "deleted": .bool(true),
                    "name": existing.map { .string($0.displayTitle) } ?? .null,
                ]),
                stateRevision: rev,
                context: context
            )
        } catch {
            return .failure(.internalError, message: error.localizedDescription, context: context)
        }
    }
}

struct CharacterOpenHandler: ActionHandler {
    static let id = ActionID("character.open")

    private let stateStore: StateStore

    init(stateStore: StateStore) {
        self.stateStore = stateStore
    }

    var definition: ActionDefinition {
        ActionDefinition(
            id: Self.id,
            title: "Open character in UI",
            description:
                "Show a character on screen. destination: characters | edit | voice | playground | train | create.",
            risk: .session,
            exposeToMCP: true,
            exposeToCLI: true,
            exposeToUI: true
        )
    }

    func execute(params: JSONValue, context: ActionContext) async -> ActionOutcome {
        let dest = params["destination"]?.stringValue ?? "characters"
        let characterId = params["characterId"]?.stringValue

        if dest != "create" {
            guard let characterId, !characterId.isEmpty else {
                return .failure(
                    .validationError,
                    message: "characterId required unless destination is create",
                    context: context
                )
            }
            do {
                _ = try CharacterLibraryStore().load(id: characterId)
            } catch {
                return .failure(.notFound, message: "Character not found: \(characterId)", context: context)
            }
        }

        let route: String
        let open: String?
        let highlight: String
        let wizardStep: String?
        switch dest {
        case "create":
            route = "characters"; open = "create"; highlight = "characters.create"; wizardStep = nil
        case "edit":
            route = "characters"; open = "edit"; highlight = "characters.edit"; wizardStep = nil
        case "voice":
            route = "characters"; open = "edit"; highlight = "wizard.hear"; wizardStep = "voice"
        case "playground":
            route = "playground"; open = "playground"; highlight = "playground.send"; wizardStep = nil
        case "train":
            route = "train"; open = "train"; highlight = "train.start"; wizardStep = nil
        default:
            route = "characters"; open = nil; highlight = "characters.row"; wizardStep = nil
        }

        if dest == "voice", let characterId {
            let store = CharacterLibraryStore()
            if var draft = try? store.load(id: characterId) {
                draft.wizardStepRaw = 3
                try? store.save(draft)
            }
        }

        let name: String
        if let characterId, let draft = try? CharacterLibraryStore().load(id: characterId) {
            name = draft.displayTitle
        } else {
            name = "character"
        }

        await stateStore.apply { state in
            SessionReveal.apply(
                to: &state,
                route: route,
                characterId: characterId,
                open: open,
                highlight: highlight,
                guideTitle: dest == "create" ? "Create a character" : "Opened \(name)",
                guideSteps: UIGuideCatalog.recipe(for: dest == "create" ? "createCharacter" : dest == "playground" ? "openPlayground" : dest == "train" ? "openTrain" : dest == "voice" ? "hearVoice" : "editCharacter")?.steps,
                wizardStep: wizardStep
            )
        }
        let rev = await stateStore.revision
        return .success(
            data: .object([
                "characterId": characterId.map { .string($0) } ?? .null,
                "destination": .string(dest),
                "route": .string(route),
            ]),
            stateRevision: rev,
            context: context
        )
    }
}

// MARK: - dataset.get / delete

struct DatasetGetHandler: ActionHandler {
    static let id = ActionID("dataset.get")

    var definition: ActionDefinition {
        ActionDefinition(
            id: Self.id,
            title: "Get dataset",
            description: "Dataset record plus a short message preview.",
            risk: .read,
            exposeToMCP: true,
            exposeToCLI: true,
            exposeToUI: true
        )
    }

    func execute(params: JSONValue, context: ActionContext) async -> ActionOutcome {
        guard let id = params["datasetId"]?.stringValue, !id.isEmpty else {
            return .failure(.validationError, message: "Missing datasetId", context: context)
        }
        do {
            let service = try DatasetLibraryService.openDefault()
            guard let rec = try service.dataset(id: id) else {
                return .failure(.notFound, message: "Dataset not found: \(id)", context: context)
            }
            let latest = try service.latestVersion(datasetId: id)
            let preview = try? service.preview(datasetId: id, maxExamples: 6)
            let examples: [JSONValue] = (preview?.examples ?? []).map { ex in
                .object([
                    "messages": .array(ex.messages.map { m in
                        .object([
                            "role": .string(m.role),
                            "content": .string(m.content),
                        ])
                    }),
                ])
            }
            return .success(
                data: .object([
                    "id": .string(rec.id),
                    "name": .string(rec.name),
                    "status": .string(rec.status.rawValue),
                    "importMode": .string(rec.importMode.rawValue),
                    "createdAt": .string(rec.createdAt),
                    "rowCount": latest?.rowCount.map { .number(Double($0)) } ?? .null,
                    "preview": .array(examples),
                ]),
                context: context
            )
        } catch {
            return .failure(.internalError, message: error.localizedDescription, context: context)
        }
    }
}

struct DatasetDeleteHandler: ActionHandler {
    static let id = ActionID("dataset.delete")

    private let stateStore: StateStore

    init(stateStore: StateStore) {
        self.stateStore = stateStore
    }

    var definition: ActionDefinition {
        ActionDefinition(
            id: Self.id,
            title: "Delete dataset",
            description: "Remove a library dataset (copy-mode files are deleted).",
            risk: .destructive,
            exposeToMCP: true,
            exposeToCLI: true,
            exposeToUI: true
        )
    }

    func execute(params: JSONValue, context: ActionContext) async -> ActionOutcome {
        guard let id = params["datasetId"]?.stringValue, !id.isEmpty else {
            return .failure(.validationError, message: "Missing datasetId", context: context)
        }
        do {
            let service = try DatasetLibraryService.openDefault()
            guard try service.dataset(id: id) != nil else {
                return .failure(.notFound, message: "Dataset not found: \(id)", context: context)
            }
            try service.deleteDataset(id: id)
            await stateStore.apply { state in
                if state.selection["datasetId"] == id {
                    state.selection["datasetId"] = nil
                }
                if SessionReveal.shouldReveal(params) {
                    SessionReveal.apply(
                        to: &state,
                        route: "datasets",
                        highlight: "datasets.import",
                        guideTitle: "Dataset removed",
                        guideSteps: ["Advanced → Datasets no longer lists that file."]
                    )
                }
            }
            let rev = await stateStore.revision
            return .success(
                data: .object(["datasetId": .string(id), "deleted": .bool(true)]),
                stateRevision: rev,
                context: context
            )
        } catch {
            return .failure(.internalError, message: error.localizedDescription, context: context)
        }
    }
}

// MARK: - model.list

struct ModelListHandler: ActionHandler {
    static let id = ActionID("model.list")

    var definition: ActionDefinition {
        ActionDefinition(
            id: Self.id,
            title: "List models",
            description: "Installed open models plus Apple on-device status.",
            risk: .read,
            exposeToMCP: true,
            exposeToCLI: true,
            exposeToUI: true
        )
    }

    func execute(params: JSONValue, context: ActionContext) async -> ActionOutcome {
        var items: [JSONValue] = []
        let apple = AppleFoundationModelSupport.probeStatus()
        items.append(
            .object([
                "id": .string("apple-foundation"),
                "name": .string(CharacterDraft.appleFoundationDisplayName),
                "path": .string(CharacterDraft.appleFoundationPath),
                "sourceKey": .string(CharacterDraft.appleFoundationSourceKey),
                "kind": .string("appleFoundation"),
                "usable": .bool(apple.isUsable),
                "status": .string(apple.rawValue),
            ])
        )
        let scanned = (try? LocalModelScanner().scan()) ?? []
        for scan in scanned {
            let meta = ModelInstallService.installMetadata(at: URL(fileURLWithPath: scan.localPath))
            items.append(
                .object([
                    "id": .string(scan.directoryName),
                    "name": .string(meta?.name ?? scan.displayName),
                    "path": .string(scan.localPath),
                    "sourceKey": meta?.sourceKey.map { .string($0) } ?? .null,
                    "kind": .string("open"),
                    "usable": .bool(true),
                    "isFixture": .bool(scan.directoryName == FixtureModel.installDirectoryName),
                ])
            )
        }
        return .success(
            data: .object([
                "models": .array(items),
                "count": .number(Double(items.count)),
            ]),
            context: context
        )
    }
}

// MARK: - examples.propose

struct ExamplesProposeHandler: ActionHandler {
    static let id = ActionID("examples.propose")

    private let stateStore: StateStore

    init(stateStore: StateStore) {
        self.stateStore = stateStore
    }

    var definition: ActionDefinition {
        ActionDefinition(
            id: Self.id,
            title: "Propose examples",
            description:
                "Build or riff practice lines for a character (same as Build how they talk / Riff) and write the mind.",
            risk: .write,
            timeoutClass: .long,
            exposeToMCP: true,
            exposeToCLI: true,
            exposeToUI: true
        )
    }

    func execute(params: JSONValue, context: ActionContext) async -> ActionOutcome {
        guard let id = params["characterId"]?.stringValue, !id.isEmpty else {
            return .failure(.validationError, message: "Missing characterId", context: context)
        }
        let extra = min(12, max(0, params["extra"]?.intValue ?? 3))
        do {
            let store = CharacterLibraryStore()
            var draft = try store.load(id: id)
            let builder = CorpusBuilder()
            let result: CorpusBuildResult
            if let bible = draft.bible, !draft.examples.isEmpty {
                let current = CorpusBuildResult(
                    bible: bible,
                    examples: draft.examples,
                    jsonl: MindJSONLCodec.encode(draft: draft)
                )
                result = extra > 0 ? builder.riff(result: current, extra: extra) : current
            } else {
                result = builder.build(
                    name: draft.displayTitle,
                    species: draft.resolvedSpecies,
                    vibe: draft.vibe,
                    paste: draft.storyPaste.isEmpty
                        ? "I am \(draft.displayTitle), a \(draft.resolvedSpecies). \(draft.vibe)"
                        : draft.storyPaste,
                    styleTags: Set(draft.styleTags),
                    riffExtra: extra
                )
            }
            draft.bible = result.bible
            draft.examples = result.examples
            let service = try DatasetLibraryService.openDefault()
            let upsert = try service.upsertMindJSONL(
                jsonl: result.jsonl,
                name: "\(draft.displayTitle) mind",
                existingDatasetId: draft.datasetId,
                policy: .mergeByStableId
            )
            draft.datasetId = upsert.datasetId
            try store.save(draft)

            if SessionReveal.shouldReveal(params) {
                await stateStore.apply { state in
                    SessionReveal.apply(
                        to: &state,
                        route: "characters",
                        characterId: draft.id,
                        datasetId: draft.datasetId,
                        open: "edit",
                        highlight: "wizard.buildMind",
                        guideTitle: "Mind updated for \(draft.displayTitle)",
                        guideSteps: [
                            "The Story step now has \(result.rowCount) practice lines.",
                            "Continue → Voice, or open Playground to try them.",
                        ],
                        wizardStep: "mind"
                    )
                }
            }
            let rev = await stateStore.revision
            return .success(
                data: .object([
                    "characterId": .string(draft.id),
                    "datasetId": .string(upsert.datasetId),
                    "rowCount": .number(Double(upsert.rowCount)),
                    "exampleCount": .number(Double(draft.examples.count)),
                    "created": .bool(upsert.created),
                ]),
                stateRevision: rev,
                context: context
            )
        } catch {
            return .failure(.internalError, message: error.localizedDescription, context: context)
        }
    }
}

// MARK: - chat.send

struct ChatSendHandler: ActionHandler {
    static let id = ActionID("chat.send")

    private let stateStore: StateStore

    init(stateStore: StateStore) {
        self.stateStore = stateStore
    }

    var definition: ActionDefinition {
        ActionDefinition(
            id: Self.id,
            title: "Send Playground chat",
            description:
                "Send a user line as a character and show it in Playground. Params: characterId, text, optional speakReplies (character voice on/off).",
            risk: .write,
            timeoutClass: .long,
            exposeToMCP: true,
            exposeToCLI: true,
            exposeToUI: true
        )
    }

    func execute(params: JSONValue, context: ActionContext) async -> ActionOutcome {
        let text = params["text"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else {
            return .failure(
                .validationError,
                message: "Missing text",
                remediation: "Pass { \"characterId\": \"…\", \"text\": \"Hello\" }",
                context: context
            )
        }
        let characterId = params["characterId"]?.stringValue
        var system = params["systemPrompt"]?.stringValue ?? ""
        var basePath = params["baseModelPath"]?.stringValue
        var adapterPath = params["adapterPath"]?.stringValue
        var allowsSystem = params["useAppleFoundation"]?.boolValue ?? false
        var name = "character"

        if let characterId {
            do {
                let draft = try CharacterLibraryStore().load(id: characterId)
                name = draft.displayTitle
                if system.isEmpty { system = draft.bible?.systemPrompt ?? "You are \(name)." }
                if basePath == nil { basePath = draft.baseModelPath }
                if adapterPath == nil { adapterPath = draft.adapterPath }
                if draft.usesAppleFoundationModel { allowsSystem = true }
            } catch {
                return .failure(.notFound, message: "Character not found: \(characterId)", context: context)
            }
        }
        if system.isEmpty { system = "You are a helpful assistant." }

        let backend: any LLMBackend
        if let apple = AppleFoundationLLMBackend.makeIfAvailable() {
            backend = apple
            allowsSystem = true
        } else if let path = basePath, path != CharacterDraft.appleFoundationPath,
                  let mlx = MLXGenerateBackend.makeIfAvailable()
        {
            backend = mlx
        } else {
            backend = EchoLLMBackend()
        }

        var session = PlaygroundSession(
            systemPrompt: system,
            messages: [],
            baseModelPath: (basePath == CharacterDraft.appleFoundationPath) ? nil : basePath,
            adapterPath: adapterPath,
            adapterEnabled: adapterPath != nil,
            allowsSystemModel: allowsSystem || backend is AppleFoundationLLMBackend || backend is EchoLLMBackend
        )
        do {
            let result = try await session.send(userText: text, backend: backend)
            let reply = session.messages.last(where: { $0.role == "assistant" })?.content
                ?? result.assistantMessage.content
            let speak = params["speakReplies"]?.boolValue
            if SessionReveal.shouldReveal(params) {
                await stateStore.apply { state in
                    SessionReveal.clearGuide(from: &state)
                    SessionReveal.apply(
                        to: &state,
                        route: "playground",
                        characterId: characterId,
                        open: "playground",
                        highlight: "playground.send",
                        chatUser: text,
                        chatAssistant: reply,
                        speakReplies: speak
                    )
                }
            }
            let rev = await stateStore.revision
            return .success(
                data: .object([
                    "characterId": characterId.map { .string($0) } ?? .null,
                    "user": .string(text),
                    "assistant": .string(reply),
                    "backendId": .string(result.backendId),
                    "isStub": .bool(result.isStub),
                    "latencyMs": .number(result.latencyMs),
                    "speakReplies": speak.map { .bool($0) } ?? .null,
                    "adapterPath": adapterPath.map { .string($0) } ?? .null,
                    "baseModelPath": basePath.map { .string($0) } ?? .null,
                ]),
                stateRevision: rev,
                context: context
            )
        } catch {
            return .failure(.internalError, message: error.localizedDescription, context: context)
        }
    }
}

// MARK: - playground.set

struct PlaygroundSetHandler: ActionHandler {
    static let id = ActionID("playground.set")

    private let stateStore: StateStore

    init(stateStore: StateStore) {
        self.stateStore = stateStore
    }

    var definition: ActionDefinition {
        ActionDefinition(
            id: Self.id,
            title: "Set Playground",
            description:
                "Open Playground, bind a character, and/or turn Speak replies (character voice) on or off.",
            risk: .session,
            exposeToMCP: true,
            exposeToCLI: true,
            exposeToUI: true
        )
    }

    func execute(params: JSONValue, context: ActionContext) async -> ActionOutcome {
        let characterId = params["characterId"]?.stringValue
        var name = "Playground"
        if let characterId {
            do {
                let draft = try CharacterLibraryStore().load(id: characterId)
                name = draft.displayTitle
            } catch {
                return .failure(.notFound, message: "Character not found: \(characterId)", context: context)
            }
        }
        let speak = params["speakReplies"]?.boolValue
        await stateStore.apply { state in
            SessionReveal.clearGuide(from: &state)
            SessionReveal.apply(
                to: &state,
                route: "playground",
                characterId: characterId,
                open: "playground",
                highlight: characterId == nil ? "playground.character" : "playground.send",
                speakReplies: speak
            )
        }
        let rev = await stateStore.revision
        return .success(
            data: .object([
                "characterId": characterId.map { .string($0) } ?? .null,
                "characterName": characterId == nil ? .null : .string(name),
                "speakReplies": speak.map { .bool($0) } ?? .null,
                "route": .string("playground"),
            ]),
            stateRevision: rev,
            context: context
        )
    }
}

// MARK: - persona.list / voice.list

struct PersonaListHandler: ActionHandler {
    static let id = ActionID("persona.list")

    var definition: ActionDefinition {
        ActionDefinition(
            id: Self.id,
            title: "List personas",
            description: "Persona library index.",
            risk: .read,
            exposeToMCP: true,
            exposeToCLI: true,
            exposeToUI: true
        )
    }

    func execute(params: JSONValue, context: ActionContext) async -> ActionOutcome {
        do {
            let db = try LibraryDatabase.openDefault()
            let rows = try PersonaStore(database: db).fetchAll()
            let items: [JSONValue] = rows.map { p in
                .object([
                    "id": .string(p.id),
                    "name": .string(p.name),
                    "version": .string(p.version),
                    "updatedAt": .string(p.updatedAt),
                ])
            }
            return .success(
                data: .object([
                    "personas": .array(items),
                    "count": .number(Double(items.count)),
                ]),
                context: context
            )
        } catch {
            return .failure(.internalError, message: error.localizedDescription, context: context)
        }
    }
}

struct VoiceListHandler: ActionHandler {
    static let id = ActionID("voice.list")

    var definition: ActionDefinition {
        ActionDefinition(
            id: Self.id,
            title: "List voice profiles",
            description: "Cloned / imported voice profiles in the library.",
            risk: .read,
            exposeToMCP: true,
            exposeToCLI: true,
            exposeToUI: true
        )
    }

    func execute(params: JSONValue, context: ActionContext) async -> ActionOutcome {
        do {
            let db = try LibraryDatabase.openDefault()
            let rows = try VoiceProfileStore(database: db).fetchAll()
            let items: [JSONValue] = rows.map { v in
                .object([
                    "id": .string(v.id),
                    "engineId": .string(v.engineId),
                    "localPath": .string(v.localPath),
                    "createdAt": .string(v.createdAt),
                ])
            }
            return .success(
                data: .object([
                    "voices": .array(items),
                    "count": .number(Double(items.count)),
                ]),
                context: context
            )
        } catch {
            return .failure(.internalError, message: error.localizedDescription, context: context)
        }
    }
}
