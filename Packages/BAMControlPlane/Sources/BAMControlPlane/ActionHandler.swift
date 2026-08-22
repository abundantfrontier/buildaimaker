import Foundation

/// One registered command implementation.
public protocol ActionHandler: Sendable {
    var definition: ActionDefinition { get }
    func execute(params: JSONValue, context: ActionContext) async -> ActionOutcome
}

/// In-memory registry with serial invoke (v1 concurrency: actor isolation).
public actor ActionRegistry {
    private var handlers: [String: any ActionHandler] = [:]
    /// Optional mutation-id dedupe: (clientId, mutationId) → outcome.
    private var mutationCache: [(key: String, outcome: ActionOutcome)] = []
    private let mutationCacheLimit = 1024

    public init() {}

    public func register(_ handler: any ActionHandler) {
        handlers[handler.definition.id.rawValue] = handler
    }

    public func definition(for id: ActionID) -> ActionDefinition? {
        handlers[id.rawValue]?.definition
    }

    public func list(filter: ActionFilter = .all) -> [ActionDefinition] {
        handlers.values
            .map(\.definition)
            .filter { def in
                if filter.mcpOnly, !def.exposeToMCP { return false }
                if filter.cliOnly, !def.exposeToCLI { return false }
                if filter.uiOnly, !def.exposeToUI { return false }
                if let risk = filter.risk, def.risk != risk { return false }
                return true
            }
            .sorted { $0.id.rawValue < $1.id.rawValue }
    }

    public func invoke(
        _ id: ActionID,
        params: JSONValue = .object([:]),
        context: ActionContext
    ) async -> ActionOutcome {
        if let mutationId = context.clientMutationId, !mutationId.isEmpty {
            let key = "\(context.clientId ?? "local")|\(mutationId)"
            if let hit = mutationCache.first(where: { $0.key == key }) {
                return hit.outcome
            }
        }

        guard let handler = handlers[id.rawValue] else {
            return .failure(
                .unknownAction,
                message: "Unknown action: \(id.rawValue)",
                remediation: "Call app.listActions or check the action id.",
                context: context
            )
        }

        let outcome = await handler.execute(params: params, context: context)

        if let mutationId = context.clientMutationId, !mutationId.isEmpty, outcome.ok {
            let key = "\(context.clientId ?? "local")|\(mutationId)"
            mutationCache.append((key, outcome))
            if mutationCache.count > mutationCacheLimit {
                mutationCache.removeFirst(mutationCache.count - mutationCacheLimit)
            }
        }

        return outcome
    }
}

// Non-actor convenience that holds an actor reference for UI/call sites.
public final class ActionRegistryBox: @unchecked Sendable {
    public let registry: ActionRegistry

    public init(registry: ActionRegistry = ActionRegistry()) {
        self.registry = registry
    }

    public func register(_ handler: any ActionHandler) async {
        await registry.register(handler)
    }

    public func invoke(
        _ id: ActionID,
        params: JSONValue = .object([:]),
        context: ActionContext
    ) async -> ActionOutcome {
        await registry.invoke(id, params: params, context: context)
    }

    public func list(filter: ActionFilter = .all) async -> [ActionDefinition] {
        await registry.list(filter: filter)
    }

    public func definition(for id: ActionID) async -> ActionDefinition? {
        await registry.definition(for: id)
    }
}
