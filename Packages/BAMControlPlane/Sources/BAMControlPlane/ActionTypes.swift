import Foundation

/// Stable action identifier, e.g. `app.getState`, `character.importMind`.
public struct ActionID: Hashable, Codable, Sendable, RawRepresentable, ExpressibleByStringLiteral {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.rawValue = value
    }
}

/// Risk class for confirmation policy and allowlists.
public enum ActionRisk: String, Codable, Sendable, CaseIterable {
    /// Pure read / snapshot.
    case read
    /// Session UI state (route, selection) — not domain SoT.
    case session
    /// Domain mutation.
    case write
    /// Irreversible or bulk delete.
    case destructive
    /// Costly (train, multi-GB download, long model call).
    case expensive
    /// Network / external side effects.
    case external
}

/// Who invoked the action.
public enum ActionSource: String, Codable, Sendable {
    case ui
    case mcp
    case cli
    case test
    case system
}

/// Invocation context (correlation, confirmation, CAS).
public struct ActionContext: Sendable, Equatable {
    public var source: ActionSource
    public var clientId: String?
    public var correlationId: String
    public var windowId: String?
    public var confirmToken: String?
    public var clientMutationId: String?
    public var expectedRevision: Int?

    public init(
        source: ActionSource,
        clientId: String? = nil,
        correlationId: String = UUID().uuidString,
        windowId: String? = nil,
        confirmToken: String? = nil,
        clientMutationId: String? = nil,
        expectedRevision: Int? = nil
    ) {
        self.source = source
        self.clientId = clientId
        self.correlationId = correlationId
        self.windowId = windowId
        self.confirmToken = confirmToken
        self.clientMutationId = clientMutationId
        self.expectedRevision = expectedRevision
    }

    public static func ui(correlationId: String = UUID().uuidString) -> ActionContext {
        ActionContext(source: .ui, correlationId: correlationId)
    }

    public static func test(correlationId: String = UUID().uuidString) -> ActionContext {
        ActionContext(source: .test, clientId: "test", correlationId: correlationId)
    }
}

/// Catalog metadata for one action (MCP/CLI/UI projections).
public struct ActionDefinition: Sendable, Equatable, Codable {
    public var id: ActionID
    public var version: Int
    public var title: String
    public var description: String
    public var risk: ActionRisk
    /// Rough timeout class for hosts (short vs long-running).
    public var timeoutClass: TimeoutClass
    public var exposeToMCP: Bool
    public var exposeToCLI: Bool
    public var exposeToUI: Bool

    public enum TimeoutClass: String, Codable, Sendable {
        case short
        case long
    }

    public init(
        id: ActionID,
        version: Int = 1,
        title: String,
        description: String,
        risk: ActionRisk,
        timeoutClass: TimeoutClass = .short,
        exposeToMCP: Bool = true,
        exposeToCLI: Bool = true,
        exposeToUI: Bool = true
    ) {
        self.id = id
        self.version = version
        self.title = title
        self.description = description
        self.risk = risk
        self.timeoutClass = timeoutClass
        self.exposeToMCP = exposeToMCP
        self.exposeToCLI = exposeToCLI
        self.exposeToUI = exposeToUI
    }

    /// MCP tool name segment, e.g. `app.getState` → `app_get_state`.
    public var mcpToolName: String {
        Self.mcpToolName(for: id.rawValue)
    }

    /// `character.importMind` → `character_import_mind`.
    public static func mcpToolName(for actionId: String) -> String {
        let parts = actionId.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        return parts.map(camelCaseToSnake).joined(separator: "_")
    }

    private static func camelCaseToSnake(_ s: String) -> String {
        var out = ""
        for (i, ch) in s.enumerated() {
            if ch.isUppercase {
                if i > 0 { out.append("_") }
                out.append(ch.lowercased())
            } else {
                out.append(ch)
            }
        }
        return out
    }
}

/// Filter for listing actions.
public struct ActionFilter: Sendable, Equatable {
    public var mcpOnly: Bool
    public var cliOnly: Bool
    public var uiOnly: Bool
    public var risk: ActionRisk?

    public init(
        mcpOnly: Bool = false,
        cliOnly: Bool = false,
        uiOnly: Bool = false,
        risk: ActionRisk? = nil
    ) {
        self.mcpOnly = mcpOnly
        self.cliOnly = cliOnly
        self.uiOnly = uiOnly
        self.risk = risk
    }

    public static let all = ActionFilter()
    public static let mcp = ActionFilter(mcpOnly: true)
}

/// Canonical action error codes (design Appendix B).
public enum ActionErrorCode: String, Codable, Sendable {
    case validationError = "VALIDATION_ERROR"
    case preconditionFailed = "PRECONDITION_FAILED"
    case notFound = "NOT_FOUND"
    case conflict = "CONFLICT"
    case needsConfirmation = "NEEDS_CONFIRMATION"
    case denied = "DENIED"
    case appNotRunning = "APP_NOT_RUNNING"
    case instanceConflict = "INSTANCE_CONFLICT"
    case timeout = "TIMEOUT"
    case jobFailed = "JOB_FAILED"
    case authFailed = "AUTH_FAILED"
    case protocolMismatch = "PROTOCOL_MISMATCH"
    case pathNotAllowed = "PATH_NOT_ALLOWED"
    case truncated = "TRUNCATED"
    case unknownAction = "UNKNOWN_ACTION"
    case internalError = "INTERNAL"
}

public struct ActionErrorDTO: Codable, Sendable, Equatable {
    public var code: String
    public var message: String
    public var details: JSONValue?
    public var remediation: String?

    public init(
        code: ActionErrorCode,
        message: String,
        details: JSONValue? = nil,
        remediation: String? = nil
    ) {
        self.code = code.rawValue
        self.message = message
        self.details = details
        self.remediation = remediation
    }

    public init(
        code: String,
        message: String,
        details: JSONValue? = nil,
        remediation: String? = nil
    ) {
        self.code = code
        self.message = message
        self.details = details
        self.remediation = remediation
    }
}

public struct ConfirmationChallenge: Codable, Sendable, Equatable {
    public var token: String
    public var actionId: String
    public var risk: ActionRisk
    public var summary: String
    public var expiresAt: Date
    public var uiRequired: Bool

    public init(
        token: String = UUID().uuidString,
        actionId: String,
        risk: ActionRisk,
        summary: String,
        expiresAt: Date = Date().addingTimeInterval(300),
        uiRequired: Bool = true
    ) {
        self.token = token
        self.actionId = actionId
        self.risk = risk
        self.summary = summary
        self.expiresAt = expiresAt
        self.uiRequired = uiRequired
    }
}

/// Structured outcome for every invoke (UI / MCP / CLI share this envelope).
public struct ActionOutcome: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var ok: Bool
    public var data: JSONValue?
    public var error: ActionErrorDTO?
    public var jobId: String?
    public var stateRevision: Int?
    public var confirmation: ConfirmationChallenge?
    public var correlationId: String
    public var clientMutationId: String?

    public init(
        schemaVersion: Int = 1,
        ok: Bool,
        data: JSONValue? = nil,
        error: ActionErrorDTO? = nil,
        jobId: String? = nil,
        stateRevision: Int? = nil,
        confirmation: ConfirmationChallenge? = nil,
        correlationId: String,
        clientMutationId: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.ok = ok
        self.data = data
        self.error = error
        self.jobId = jobId
        self.stateRevision = stateRevision
        self.confirmation = confirmation
        self.correlationId = correlationId
        self.clientMutationId = clientMutationId
    }

    public static func success(
        data: JSONValue? = nil,
        jobId: String? = nil,
        stateRevision: Int? = nil,
        context: ActionContext
    ) -> ActionOutcome {
        ActionOutcome(
            ok: true,
            data: data,
            jobId: jobId,
            stateRevision: stateRevision,
            correlationId: context.correlationId,
            clientMutationId: context.clientMutationId
        )
    }

    public static func failure(
        _ code: ActionErrorCode,
        message: String,
        remediation: String? = nil,
        details: JSONValue? = nil,
        confirmation: ConfirmationChallenge? = nil,
        stateRevision: Int? = nil,
        context: ActionContext
    ) -> ActionOutcome {
        ActionOutcome(
            ok: false,
            error: ActionErrorDTO(
                code: code,
                message: message,
                details: details,
                remediation: remediation
            ),
            stateRevision: stateRevision,
            confirmation: confirmation,
            correlationId: context.correlationId,
            clientMutationId: context.clientMutationId
        )
    }
}
