import Foundation

/// Private BAM App RPC protocol version.
public enum AppRPCProtocol {
    public static let version = 1
    public static let maxMessageBytes = 1_048_576
}

/// Wire envelope for NDJSON App RPC.
public struct AppRPCEnvelope: Codable, Sendable, Equatable {
    public var v: Int
    public var id: String
    public var type: String
    public var method: String?
    public var params: JSONValue?
    public var ok: Bool?
    public var result: JSONValue?
    public var error: ActionErrorDTO?

    public init(
        v: Int = AppRPCProtocol.version,
        id: String,
        type: String,
        method: String? = nil,
        params: JSONValue? = nil,
        ok: Bool? = nil,
        result: JSONValue? = nil,
        error: ActionErrorDTO? = nil
    ) {
        self.v = v
        self.id = id
        self.type = type
        self.method = method
        self.params = params
        self.ok = ok
        self.result = result
        self.error = error
    }

    public static func request(id: String, method: String, params: JSONValue? = nil) -> AppRPCEnvelope {
        AppRPCEnvelope(id: id, type: "req", method: method, params: params)
    }

    public static func responseOK(id: String, result: JSONValue) -> AppRPCEnvelope {
        AppRPCEnvelope(id: id, type: "res", ok: true, result: result)
    }

    public static func responseError(id: String, error: ActionErrorDTO) -> AppRPCEnvelope {
        AppRPCEnvelope(id: id, type: "res", ok: false, error: error)
    }

    public func jsonLine() throws -> Data {
        var data = try JSONEncoder().encode(self)
        data.append(0x0A) // newline
        return data
    }

    public static func parseLine(_ line: Data) throws -> AppRPCEnvelope {
        try JSONDecoder().decode(AppRPCEnvelope.self, from: line)
    }
}

/// Encode ActionOutcome as JSONValue for App RPC / MCP bridge.
public extension ActionOutcome {
    func asJSONValue() -> JSONValue {
        var obj: [String: JSONValue] = [
            "schemaVersion": .number(Double(schemaVersion)),
            "ok": .bool(ok),
            "correlationId": .string(correlationId),
        ]
        if let data { obj["data"] = data }
        if let error {
            obj["error"] = .object([
                "code": .string(error.code),
                "message": .string(error.message),
                "remediation": error.remediation.map { .string($0) } ?? .null,
            ])
        }
        if let jobId { obj["jobId"] = .string(jobId) }
        if let stateRevision { obj["stateRevision"] = .number(Double(stateRevision)) }
        if let clientMutationId { obj["clientMutationId"] = .string(clientMutationId) }
        if let confirmation {
            let fmt = ISO8601DateFormatter()
            obj["confirmation"] = .object([
                "token": .string(confirmation.token),
                "actionId": .string(confirmation.actionId),
                "risk": .string(confirmation.risk.rawValue),
                "summary": .string(confirmation.summary),
                "expiresAt": .string(fmt.string(from: confirmation.expiresAt)),
                "uiRequired": .bool(confirmation.uiRequired),
            ])
        }
        return .object(obj)
    }
}

public extension ActionDefinition {
    func asJSONValue() -> JSONValue {
        .object([
            "id": .string(id.rawValue),
            "version": .number(Double(version)),
            "title": .string(title),
            "description": .string(description),
            "risk": .string(risk.rawValue),
            "timeoutClass": .string(timeoutClass.rawValue),
            "mcpToolName": .string(mcpToolName),
            "exposeToMCP": .bool(exposeToMCP),
            "exposeToCLI": .bool(exposeToCLI),
            "exposeToUI": .bool(exposeToUI),
        ])
    }

    /// MCP tools/list entry shape.
    func asMCPTool() -> JSONValue {
        .object([
            "name": .string(mcpToolName),
            "description": .string(description),
            "inputSchema": .object([
                "type": .string("object"),
                "properties": .object([:]),
                "additionalProperties": .bool(true),
            ]),
        ])
    }
}
