import Foundation

// MARK: - app.getState

public struct AppGetStateHandler: ActionHandler {
    public static let id = ActionID("app.getState")

    private let stateStore: StateStore
    private let budgetBytes: Int

    public init(stateStore: StateStore, budgetBytes: Int = StateStore.slimBudgetBytes) {
        self.stateStore = stateStore
        self.budgetBytes = budgetBytes
    }

    public var definition: ActionDefinition {
        ActionDefinition(
            id: Self.id,
            title: "Get app state",
            description:
                "Return a slim structured snapshot (route, selection, job summaries, counts, capabilities). Use list actions for catalogs. Keep under host output size limits.",
            risk: .read,
            timeoutClass: .short,
            exposeToMCP: true,
            exposeToCLI: true,
            exposeToUI: true
        )
    }

    public func execute(params: JSONValue, context: ActionContext) async -> ActionOutcome {
        var paths: [String] = []
        if let arr = params["paths"], case .array(let items) = arr {
            paths = items.compactMap(\.stringValue)
        }
        let windowId = params["windowId"]?.stringValue
        let query = StateQuery(paths: paths, windowId: windowId)
        let snap = await stateStore.snapshot(query: query)
        let json = snap.asJSONValue(paths: paths)
        let bytes = (try? json.jsonData().count) ?? 0
        if bytes > budgetBytes {
            return .failure(
                .truncated,
                message: "State snapshot is \(bytes) bytes (budget \(budgetBytes)).",
                remediation: "Pass narrower paths or use character.list / job.list.",
                details: .object([
                    "bytes": .number(Double(bytes)),
                    "budget": .number(Double(budgetBytes)),
                ]),
                stateRevision: snap.revision,
                context: context
            )
        }
        return .success(data: json, stateRevision: snap.revision, context: context)
    }
}

// MARK: - app.listActions

public struct AppListActionsHandler: ActionHandler {
    public static let id = ActionID("app.listActions")

    private let registry: ActionRegistry

    public init(registry: ActionRegistry) {
        self.registry = registry
    }

    public var definition: ActionDefinition {
        ActionDefinition(
            id: Self.id,
            title: "List actions",
            description: "List registered control-plane actions and their risk / MCP exposure.",
            risk: .read,
            exposeToMCP: true,
            exposeToCLI: true,
            exposeToUI: true
        )
    }

    public func execute(params: JSONValue, context: ActionContext) async -> ActionOutcome {
        let mcpOnly = params["mcpOnly"]?.boolValue ?? false
        let filter = ActionFilter(mcpOnly: mcpOnly)
        let defs = await registry.list(filter: filter)
        let items: [JSONValue] = defs.map { def in
            .object([
                "id": .string(def.id.rawValue),
                "version": .number(Double(def.version)),
                "title": .string(def.title),
                "description": .string(def.description),
                "risk": .string(def.risk.rawValue),
                "timeoutClass": .string(def.timeoutClass.rawValue),
                "mcpToolName": .string(def.mcpToolName),
                "exposeToMCP": .bool(def.exposeToMCP),
                "exposeToCLI": .bool(def.exposeToCLI),
                "exposeToUI": .bool(def.exposeToUI),
            ])
        }
        return .success(
            data: .object([
                "actions": .array(items),
                "count": .number(Double(items.count)),
            ]),
            context: context
        )
    }
}

// MARK: - app.ping

public struct AppPingHandler: ActionHandler {
    public static let id = ActionID("app.ping")

    public init() {}

    public var definition: ActionDefinition {
        ActionDefinition(
            id: Self.id,
            title: "Ping",
            description: "Health check for the control plane.",
            risk: .read,
            exposeToMCP: true,
            exposeToCLI: true,
            exposeToUI: false
        )
    }

    public func execute(params: JSONValue, context: ActionContext) async -> ActionOutcome {
        .success(
            data: .object([
                "pong": .bool(true),
                "source": .string(context.source.rawValue),
            ]),
            context: context
        )
    }
}

// MARK: - nav.go / selection.set (session)

public struct NavGoHandler: ActionHandler {
    public static let id = ActionID("nav.go")

    private let stateStore: StateStore

    public init(stateStore: StateStore) {
        self.stateStore = stateStore
    }

    public var definition: ActionDefinition {
        ActionDefinition(
            id: Self.id,
            title: "Navigate",
            description:
                "Switch the visible sidebar screen. Optional: characterId, datasetId, open (edit|playground|train|create), highlight, guideTitle, guideSteps.",
            risk: .session,
            exposeToMCP: true,
            exposeToCLI: true,
            exposeToUI: true
        )
    }

    public func execute(params: JSONValue, context: ActionContext) async -> ActionOutcome {
        guard let route = params["route"]?.stringValue, !route.isEmpty else {
            return .failure(
                .validationError,
                message: "Missing required string param: route",
                remediation: "Pass { \"route\": \"characters\" } or similar.",
                context: context
            )
        }
        await stateStore.apply { state in
            let previous = state.route
            state.route = route
            if SessionReveal.shouldReveal(params) {
                SessionReveal.mergeParams(params, into: &state)
                state.route = route
            }
            // Leaving a screen should not keep another screen's coach card.
            let keepingGuide = params["guideTitle"]?.stringValue != nil
            if previous != route, !keepingGuide {
                SessionReveal.clearGuide(from: &state)
            }
            // Sidebar clicks must not revive a leftover MCP "open" intent
            // (create/edit sheet) from a previous guide.
            if params["open"] == nil, !SessionReveal.shouldReveal(params) {
                state.selection.removeValue(forKey: "open")
            }
        }
        let snap = await stateStore.snapshot()
        return .success(
            data: .object([
                "route": .string(route),
                "selection": .object(snap.selection.mapValues { .string($0) }),
            ]),
            stateRevision: snap.revision,
            context: context
        )
    }
}

/// Resolve a confirmation challenge (human UI / CLI). MCP cannot self-confirm.
public struct AppConfirmHandler: ActionHandler {
    public static let id = ActionID("app.confirm")

    private let allow: @Sendable (String) async -> ActionOutcome
    private let deny: @Sendable (String) async -> ActionOutcome

    public init(
        allow: @escaping @Sendable (String) async -> ActionOutcome,
        deny: @escaping @Sendable (String) async -> ActionOutcome
    ) {
        self.allow = allow
        self.deny = deny
    }

    public var definition: ActionDefinition {
        ActionDefinition(
            id: Self.id,
            title: "Confirm pending action",
            description:
                "Allow or deny a NEEDS_CONFIRMATION challenge. Human UI only for expensive/destructive.",
            risk: .write,
            exposeToMCP: true,
            exposeToCLI: true,
            exposeToUI: true
        )
    }

    public func execute(params: JSONValue, context: ActionContext) async -> ActionOutcome {
        guard let token = params["token"]?.stringValue, !token.isEmpty else {
            return .failure(
                .validationError,
                message: "Missing token",
                remediation: "Pass { \"token\": \"conf_…\", \"allow\": true }",
                context: context
            )
        }
        if context.source == .mcp {
            return .failure(
                .denied,
                message: "Agents cannot self-confirm expensive or destructive actions.",
                remediation: "Approve or deny in the BuildAIMaker confirmation banner.",
                context: context
            )
        }
        let allowFlag = params["allow"]?.boolValue ?? false
        if allowFlag {
            return await allow(token)
        }
        return await deny(token)
    }
}

public struct SelectionSetHandler: ActionHandler {
    public static let id = ActionID("selection.set")

    private let stateStore: StateStore

    public init(stateStore: StateStore) {
        self.stateStore = stateStore
    }

    public var definition: ActionDefinition {
        ActionDefinition(
            id: Self.id,
            title: "Set selection",
            description: "Merge key/value selection (characterId, datasetId, …). Prefer explicit IDs on writes.",
            risk: .session,
            exposeToMCP: true,
            exposeToCLI: true,
            exposeToUI: true
        )
    }

    public func execute(params: JSONValue, context: ActionContext) async -> ActionOutcome {
        guard let obj = params.objectValue, !obj.isEmpty else {
            return .failure(
                .validationError,
                message: "Expected object of string selection keys",
                context: context
            )
        }
        var merged: [String: String] = [:]
        for (k, v) in obj {
            guard let s = v.stringValue else {
                return .failure(
                    .validationError,
                    message: "selection.\(k) must be a string",
                    context: context
                )
            }
            merged[k] = s
        }
        let toMerge = merged
        await stateStore.apply { state in
            for (k, v) in toMerge {
                state.selection[k] = v
            }
            if SessionReveal.shouldReveal(params) {
                state.selection["sessionNonce"] = UUID().uuidString
            }
        }
        let snap = await stateStore.snapshot()
        return .success(
            data: .object([
                "selection": .object(snap.selection.mapValues { .string($0) }),
            ]),
            stateRevision: snap.revision,
            context: context
        )
    }
}
