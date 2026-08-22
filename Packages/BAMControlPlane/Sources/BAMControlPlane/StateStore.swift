import Foundation

/// Query for `app.getState` / snapshot (slim by default).
public struct StateQuery: Sendable, Equatable {
    /// Optional subset keys, e.g. `selection`, `jobsSummary`, `capabilities`.
    public var paths: [String]
    public var windowId: String?

    public init(paths: [String] = [], windowId: String? = nil) {
        self.paths = paths
        self.windowId = windowId
    }

    public static let slim = StateQuery()
}

/// Logical app state projection (read model — not domain SoT).
public struct StateSnapshot: Sendable, Equatable, Codable {
    public var schemaVersion: Int
    public var revision: Int
    public var route: String?
    public var selection: [String: String]
    public var counts: [String: Int]
    public var jobsSummary: [String: JSONValue]
    public var capabilities: [String: JSONValue]
    public var flags: [String: Bool]
    /// Session chrome for the running UI (highlight, guide banner, pending chat).
    public var ui: [String: JSONValue]
    public var updatedAt: Date

    public init(
        schemaVersion: Int = 1,
        revision: Int = 0,
        route: String? = nil,
        selection: [String: String] = [:],
        counts: [String: Int] = [:],
        jobsSummary: [String: JSONValue] = [:],
        capabilities: [String: JSONValue] = [:],
        flags: [String: Bool] = [:],
        ui: [String: JSONValue] = [:],
        updatedAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.revision = revision
        self.route = route
        self.selection = selection
        self.counts = counts
        self.jobsSummary = jobsSummary
        self.capabilities = capabilities
        self.flags = flags
        self.ui = ui
        self.updatedAt = updatedAt
    }

    /// Default slim payload for MCP/CLI (size-budget friendly).
    public func asJSONValue(paths: [String] = []) -> JSONValue {
        var full: [String: JSONValue] = [
            "schemaVersion": .number(Double(schemaVersion)),
            "revision": .number(Double(revision)),
            "updatedAt": .string(ISO8601DateFormatter().string(from: updatedAt)),
        ]
        if let route {
            full["route"] = .string(route)
        }
        full["selection"] = .object(selection.mapValues { .string($0) })
        full["counts"] = .object(counts.mapValues { .number(Double($0)) })
        full["jobsSummary"] = .object(jobsSummary)
        full["capabilities"] = .object(capabilities)
        full["flags"] = .object(flags.mapValues { .bool($0) })
        full["ui"] = .object(ui)

        guard !paths.isEmpty else {
            return .object(full)
        }
        var filtered: [String: JSONValue] = [
            "schemaVersion": full["schemaVersion"]!,
            "revision": full["revision"]!,
        ]
        for p in paths {
            if let v = full[p] { filtered[p] = v }
        }
        return .object(filtered)
    }

    /// Soft size estimate for host budgets (UTF-8 JSON bytes).
    public func estimatedJSONBytes(paths: [String] = []) -> Int {
        (try? asJSONValue(paths: paths).jsonData().count) ?? 0
    }
}

public protocol StateStoreProtocol: Sendable {
    var revision: Int { get async }
    func snapshot(query: StateQuery) async -> StateSnapshot
    func apply(_ transform: @Sendable (inout StateSnapshot) -> Void) async
}

/// In-memory session + projection store (domain still owns persistence).
public actor StateStore: StateStoreProtocol {
    /// Soft budget for MCP default snapshots (design: ~12KB).
    public static let slimBudgetBytes = 12_288

    private var state: StateSnapshot
    private let eventBus: EventBus?

    public init(initial: StateSnapshot = StateSnapshot(), eventBus: EventBus? = nil) {
        self.state = initial
        self.eventBus = eventBus
    }

    public var revision: Int {
        state.revision
    }

    public func snapshot(query: StateQuery = .slim) async -> StateSnapshot {
        var snap = state
        if let windowId = query.windowId {
            snap.selection["windowId"] = windowId
        }
        return snap
    }

    public func apply(_ transform: @Sendable (inout StateSnapshot) -> Void) async {
        transform(&state)
        state.revision += 1
        state.updatedAt = Date()
        eventBus?.publish(
            BusEvent(
                kind: .stateChanged,
                payload: .object([
                    "revision": .number(Double(state.revision)),
                ])
            )
        )
    }

    public func replace(_ snapshot: StateSnapshot) async {
        state = snapshot
        eventBus?.publish(
            BusEvent(
                kind: .stateChanged,
                payload: .object([
                    "revision": .number(Double(state.revision)),
                ])
            )
        )
    }
}
