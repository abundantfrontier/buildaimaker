import Foundation

/// Facade wiring registry, state store, and event bus (in-process control plane).
public final class ControlPlane: @unchecked Sendable {
    public let registry: ActionRegistry
    public let stateStore: StateStore
    public let eventBus: EventBus
    public let box: ActionRegistryBox
    public let confirmationGate: ConfirmationGate

    public init(
        registry: ActionRegistry = ActionRegistry(),
        stateStore: StateStore? = nil,
        eventBus: EventBus = EventBus(),
        confirmationGate: ConfirmationGate = ConfirmationGate()
    ) {
        self.registry = registry
        self.eventBus = eventBus
        self.stateStore = stateStore ?? StateStore(eventBus: eventBus)
        self.box = ActionRegistryBox(registry: registry)
        self.confirmationGate = confirmationGate
    }

    /// Register built-in app.* / session actions (PR1–2 baseline).
    public func installBuiltins() async {
        await registry.register(AppPingHandler())
        await registry.register(AppGetStateHandler(stateStore: stateStore))
        await registry.register(AppListActionsHandler(registry: registry))
        await registry.register(NavGoHandler(stateStore: stateStore))
        await registry.register(SelectionSetHandler(stateStore: stateStore))
        await registry.register(
            AppConfirmHandler(
                allow: { [weak self] token in
                    guard let self else {
                        return .failure(
                            .internalError,
                            message: "Control plane gone",
                            context: .ui()
                        )
                    }
                    return await self.allowConfirmation(token)
                },
                deny: { [weak self] token in
                    guard let self else {
                        return .failure(
                            .internalError,
                            message: "Control plane gone",
                            context: .ui()
                        )
                    }
                    return await self.denyConfirmation(token)
                }
            )
        )
    }

    public func invoke(
        _ id: ActionID,
        params: JSONValue = .object([:]),
        context: ActionContext
    ) async -> ActionOutcome {
        eventBus.publish(
            BusEvent(
                kind: .actionInvoked,
                correlationId: context.correlationId,
                actionId: id.rawValue,
                payload: params
            )
        )

        if let gated = await gateIfNeeded(id: id, params: params, context: context) {
            publishOutcome(gated, actionId: id, context: context)
            return gated
        }

        let outcome = await registry.invoke(id, params: params, context: context)
        publishOutcome(outcome, actionId: id, context: context)
        return outcome
    }

    /// Human Allow on a pending MCP/CLI challenge — runs the stored action.
    public func allowConfirmation(_ token: String) async -> ActionOutcome {
        guard let pending = await confirmationGate.pending(token: token) else {
            return .failure(
                .notFound,
                message: "No pending confirmation for that token",
                context: .ui()
            )
        }
        if pending.challenge.expiresAt <= Date() {
            await confirmationGate.remove(token: token)
            await publishPendingCount()
            return .failure(
                .needsConfirmation,
                message: "Confirmation expired. Request the action again.",
                context: pending.context
            )
        }
        var ctx = pending.context
        ctx.confirmToken = token
        let outcome = await invoke(pending.actionId, params: pending.params, context: ctx)
        eventBus.publish(
            BusEvent(
                kind: .confirmResolved,
                correlationId: ctx.correlationId,
                actionId: pending.actionId.rawValue,
                payload: .object(["allowed": .bool(true), "token": .string(token)])
            )
        )
        await publishPendingCount()
        return outcome
    }

    /// Human Deny — action does not run.
    public func denyConfirmation(_ token: String) async -> ActionOutcome {
        guard let pending = await confirmationGate.remove(token: token) else {
            return .failure(
                .notFound,
                message: "No pending confirmation for that token",
                context: .ui()
            )
        }
        eventBus.publish(
            BusEvent(
                kind: .confirmResolved,
                correlationId: pending.context.correlationId,
                actionId: pending.actionId.rawValue,
                payload: .object(["allowed": .bool(false), "token": .string(token)])
            )
        )
        await publishPendingCount()
        return .success(
            data: .object([
                "token": .string(token),
                "allowed": .bool(false),
                "actionId": .string(pending.actionId.rawValue),
            ]),
            context: pending.context
        )
    }

    /// Seed session projection (route/flags) after app launch.
    public func bootstrapSession(
        route: String? = "home",
        flags: [String: Bool] = [:],
        capabilities: [String: JSONValue] = [:]
    ) async {
        await stateStore.apply { state in
            if let route { state.route = route }
            state.flags = flags
            state.capabilities = capabilities
        }
    }

    // MARK: - Confirmation gate

    private func gateIfNeeded(
        id: ActionID,
        params: JSONValue,
        context: ActionContext
    ) async -> ActionOutcome? {
        guard let def = await registry.definition(for: id) else { return nil }
        guard ConfirmationPolicy.requiresHumanConfirm(
            definition: def,
            params: params,
            source: context.source
        ) else { return nil }

        if let token = context.confirmToken, !token.isEmpty {
            let consumed = await confirmationGate.consume(
                token: token,
                actionId: id,
                params: params
            )
            if consumed {
                return nil
            }
            return .failure(
                .denied,
                message: "Invalid or expired confirmation token",
                remediation: "Request the action again and approve in the app banner.",
                context: context
            )
        }

        do {
            let challenge = try await confirmationGate.issue(
                actionId: id,
                params: params,
                context: context,
                risk: def.risk,
                summary: ConfirmationPolicy.summary(for: id, params: params, risk: def.risk)
            )
            eventBus.publish(
                BusEvent(
                    kind: .confirmRequired,
                    correlationId: context.correlationId,
                    actionId: id.rawValue,
                    payload: .object([
                        "token": .string(challenge.token),
                        "summary": .string(challenge.summary),
                        "risk": .string(challenge.risk.rawValue),
                    ])
                )
            )
            await publishPendingCount()
            return .failure(
                .needsConfirmation,
                message: "Human confirmation required before this action runs.",
                remediation:
                    "Approve in the BuildAIMaker confirmation banner. Agents cannot self-confirm.",
                details: .object([
                    "actionId": .string(id.rawValue),
                    "risk": .string(def.risk.rawValue),
                ]),
                confirmation: challenge,
                context: context
            )
        } catch {
            return .failure(
                .denied,
                message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription,
                context: context
            )
        }
    }

    private func publishOutcome(
        _ outcome: ActionOutcome,
        actionId: ActionID,
        context: ActionContext
    ) {
        eventBus.publish(
            BusEvent(
                kind: outcome.ok ? .actionCompleted : .actionFailed,
                correlationId: context.correlationId,
                actionId: actionId.rawValue,
                payload: outcome.data
                    ?? (outcome.error.map {
                        .object([
                            "code": .string($0.code),
                            "message": .string($0.message),
                        ])
                    } ?? .null)
            )
        )
    }

    private func publishPendingCount() async {
        let n = await confirmationGate.pendingCount
        await stateStore.apply { state in
            state.counts["pendingConfirmations"] = n
        }
    }
}
