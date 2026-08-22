import BAMControlPlane
import Foundation

/// stdio MCP bridge → private BAM App RPC (design Appendix D).
///
/// Env:
/// - `BAM_SOCKET` optional path to `mcp.sock`
/// - `BAM_TOKEN` optional path to token file (default: sibling `mcp.token`)
@main
enum BuildAIMakerMCP {
    static func main() {
        let err = FileHandle.standardError
        func log(_ s: String) {
            if let d = (s + "\n").data(using: .utf8) {
                err.write(d)
            }
        }

        let env = ProcessInfo.processInfo.environment
        let defaultSock = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/BuildAIMaker/mcp.sock")
        let socketPath = URL(
            fileURLWithPath: env["BAM_SOCKET"] ?? defaultSock.path
        )
        let tokenPath: URL = {
            if let t = env["BAM_TOKEN"], !t.isEmpty {
                return URL(fileURLWithPath: t)
            }
            return socketPath.deletingLastPathComponent()
                .appendingPathComponent("mcp.token")
        }()

        var client: AppRPCClient?
        var frozenTools: [JSONValue]?

        func ensureClient() throws -> AppRPCClient {
            if let client { return client }
            let token = (try? String(contentsOf: tokenPath, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !token.isEmpty else {
                throw BridgeError("Missing token at \(tokenPath.path). Open BuildAIMaker first.")
            }
            let c = AppRPCClient(socketPath: socketPath, token: token)
            try c.connectAndHello(clientName: "buildaimaker-mcp")
            client = c
            return c
        }

        func appNotRunningResult(id: JSONValue) -> [String: Any] {
            [
                "jsonrpc": "2.0",
                "id": unwrap(id),
                "result": [
                    "content": [
                        [
                            "type": "text",
                            "text":
                                "APP_NOT_RUNNING: BuildAIMaker is not running or MCP socket is unavailable. Open the app, then retry.",
                        ],
                    ],
                    "isError": true,
                ],
            ]
        }

        // Frozen embedded fallback if app never connects at tools/list time.
        let fallbackTools: [JSONValue] = [
            tool("app_ping", "Health check"),
            tool("app_get_state", "Slim app state snapshot"),
            tool("app_list_actions", "List control-plane actions"),
            tool("app_confirm", "Resolve a confirmation (human UI; MCP self-confirm is denied)"),
            tool("character_list", "List characters"),
            tool("character_create", "Create a character; optionally import/bind a mind JSONL"),
            tool("character_get", "Get one character card"),
            tool("character_update", "Patch a character"),
            tool("character_delete", "Delete a character (needs in-app confirm)"),
            tool("character_open", "Show a character in the UI (edit/playground/train)"),
            tool("character_import_mind", "Import/update mind with identity policy"),
            tool("examples_propose", "Build or riff practice lines and write the mind"),
            tool("dataset_list", "List library datasets"),
            tool("dataset_get", "Get a dataset plus preview"),
            tool("dataset_import", "Import a chat JSONL into the library"),
            tool("dataset_delete", "Delete a dataset (needs in-app confirm)"),
            tool("model_list", "List installed models + Apple on-device"),
            tool("chat_send", "Send a Playground line as a character; optional speakReplies"),
            tool("playground_set", "Bind a Playground character and/or turn speak-replies on/off"),
            tool("persona_list", "List personas"),
            tool("voice_list", "List voice profiles"),
            tool("ui_guide", "Point the UI at a hand path and return numbered steps"),
            tool("nav_go", "Switch the visible sidebar screen"),
            tool("selection_set", "Set selected character/dataset/job ids"),
            tool("minds_dedupe", "Dedupe orphan mind datasets (dryRun default true)"),
            tool("finetune_start", "Enqueue fine-tune; returns jobId"),
            tool("job_get", "Poll job status"),
            tool("job_list", "List jobs"),
            tool("job_cancel", "Cancel a job"),
        ]

        let stdin = FileHandle.standardInput
        var inBuffer = Data()

        while true {
            let chunk = stdin.availableData
            if chunk.isEmpty {
                // EOF
                break
            }
            inBuffer.append(chunk)
            while let range = inBuffer.range(of: Data([0x0A])) {
                let line = inBuffer.subdata(in: inBuffer.startIndex..<range.lowerBound)
                inBuffer.removeSubrange(inBuffer.startIndex...range.lowerBound)
                guard !line.isEmpty,
                      let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
                else { continue }

                let id = obj["id"].map { JSONValue.fromAny($0) } ?? .null
                let method = obj["method"] as? String ?? ""

                let response: [String: Any]
                do {
                    response = try handle(
                        method: method,
                        id: id,
                        params: obj["params"] as? [String: Any] ?? [:],
                        ensureClient: ensureClient,
                        frozenTools: &frozenTools,
                        fallbackTools: fallbackTools,
                        log: log
                    )
                } catch let e as BridgeError where e.appDown {
                    if method == "tools/call" {
                        response = appNotRunningResult(id: id)
                    } else if method == "tools/list" {
                        let tools = frozenTools ?? fallbackTools
                        frozenTools = tools
                        response = [
                            "jsonrpc": "2.0",
                            "id": unwrap(id),
                            "result": [
                                "tools": tools.map { $0.toAny() },
                            ],
                        ]
                    } else if method.hasPrefix("notifications/") {
                        continue
                    } else {
                        response = [
                            "jsonrpc": "2.0",
                            "id": unwrap(id),
                            "error": [
                                "code": -32000,
                                "message": e.message,
                            ],
                        ]
                    }
                    client = nil
                } catch {
                    response = [
                        "jsonrpc": "2.0",
                        "id": unwrap(id),
                        "error": [
                            "code": -32000,
                            "message": error.localizedDescription,
                        ],
                    ]
                }

                if method.hasPrefix("notifications/") {
                    continue
                }
                writeJSON(response)
            }
        }
        client?.closeConnection()
    }

    static func handle(
        method: String,
        id: JSONValue,
        params: [String: Any],
        ensureClient: () throws -> AppRPCClient,
        frozenTools: inout [JSONValue]?,
        fallbackTools: [JSONValue],
        log: (String) -> Void
    ) throws -> [String: Any] {
        switch method {
        case "initialize":
            return [
                "jsonrpc": "2.0",
                "id": unwrap(id),
                "result": [
                    "protocolVersion": "2024-11-05",
                    "capabilities": ["tools": [:] as [String: Any]],
                    "serverInfo": [
                        "name": "buildaimaker",
                        "version": "0.1.0",
                    ],
                ],
            ]

        case "notifications/initialized", "notifications/cancelled":
            return [:] // ignored by caller

        case "ping":
            return ["jsonrpc": "2.0", "id": unwrap(id), "result": [:] as [String: Any]]

        case "tools/list":
            if frozenTools == nil {
                do {
                    let c = try ensureClient()
                    let res = try c.call(method: "ListTools")
                    if res.ok == true, let tools = res.result?["tools"], case .array(let arr) = tools {
                        frozenTools = arr
                    } else {
                        frozenTools = fallbackTools
                    }
                } catch {
                    log("tools/list fallback: \(error.localizedDescription)")
                    frozenTools = fallbackTools
                }
            }
            return [
                "jsonrpc": "2.0",
                "id": unwrap(id),
                "result": [
                    "tools": (frozenTools ?? fallbackTools).map { $0.toAny() },
                ],
            ]

        case "tools/call":
            let name = params["name"] as? String ?? ""
            let args = params["arguments"] as? [String: Any] ?? [:]
            let actionId = mcpNameToActionId(name)
            let c: AppRPCClient
            do {
                c = try ensureClient()
            } catch {
                throw BridgeError(error.localizedDescription, appDown: true)
            }
            let res: AppRPCEnvelope
            do {
                res = try c.call(
                    method: "Invoke",
                    params: .object([
                        "actionId": .string(actionId),
                        "params": JSONValue.fromAny(args),
                        "context": .object([
                            "clientId": .string("buildaimaker-mcp"),
                            "correlationId": .string(UUID().uuidString),
                        ]),
                    ])
                )
            } catch {
                throw BridgeError(error.localizedDescription, appDown: true)
            }
            let text: String
            if let result = res.result {
                if let data = try? JSONEncoder().encode(result),
                   let s = String(data: data, encoding: .utf8)
                {
                    text = s
                } else {
                    text = "{\"ok\":false}"
                }
            } else {
                text = res.error?.message ?? "empty result"
            }
            let isError = res.ok == false || (res.result?["ok"]?.boolValue == false)
            return [
                "jsonrpc": "2.0",
                "id": unwrap(id),
                "result": [
                    "content": [
                        ["type": "text", "text": text],
                    ],
                    "isError": isError,
                ],
            ]

        default:
            return [
                "jsonrpc": "2.0",
                "id": unwrap(id),
                "error": [
                    "code": -32601,
                    "message": "Method not found: \(method)",
                ],
            ]
        }
    }

    static func mcpNameToActionId(_ name: String) -> String {
        // app_get_state → app.getState (best-effort reverse of mcpToolName)
        let parts = name.split(separator: "_").map(String.init)
        guard let first = parts.first else { return name }
        if parts.count == 1 { return name }
        let rest = parts.dropFirst().map { part -> String in
            guard let c = part.first else { return part }
            return c.uppercased() + part.dropFirst()
        }.joined()
        // Prefer known map for multi-segment actions.
        let known: [String: String] = [
            "app_ping": "app.ping",
            "app_get_state": "app.getState",
            "app_list_actions": "app.listActions",
            "character_list": "character.list",
            "character_create": "character.create",
            "character_get": "character.get",
            "character_update": "character.update",
            "character_delete": "character.delete",
            "character_open": "character.open",
            "character_import_mind": "character.importMind",
            "examples_propose": "examples.propose",
            "dataset_list": "dataset.list",
            "dataset_get": "dataset.get",
            "dataset_import": "dataset.import",
            "dataset_delete": "dataset.delete",
            "model_list": "model.list",
            "chat_send": "chat.send",
            "playground_set": "playground.set",
            "persona_list": "persona.list",
            "voice_list": "voice.list",
            "ui_guide": "ui.guide",
            "nav_go": "nav.go",
            "selection_set": "selection.set",
            "minds_dedupe": "minds.dedupe",
            "finetune_start": "finetune.start",
            "job_get": "job.get",
            "job_list": "job.list",
            "job_cancel": "job.cancel",
            "app_confirm": "app.confirm",
        ]
        return known[name] ?? "\(first).\(rest.prefix(1).lowercased())\(rest.dropFirst())"
    }

    static func tool(_ name: String, _ description: String) -> JSONValue {
        .object([
            "name": .string(name),
            "description": .string(description),
            "inputSchema": .object([
                "type": .string("object"),
                "properties": .object([:]),
                "additionalProperties": .bool(true),
            ]),
        ])
    }

    static func writeJSON(_ obj: [String: Any]) {
        guard !obj.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: obj),
              var line = String(data: data, encoding: .utf8)
        else { return }
        line.append("\n")
        if let d = line.data(using: .utf8) {
            FileHandle.standardOutput.write(d)
        }
    }

    static func unwrap(_ v: JSONValue) -> Any {
        v.toAny()
    }
}

struct BridgeError: Error, LocalizedError {
    var message: String
    var appDown: Bool
    init(_ message: String, appDown: Bool = false) {
        self.message = message
        self.appDown = appDown
    }
    var errorDescription: String? { message }
}

extension JSONValue {
    static func fromAny(_ any: Any) -> JSONValue {
        switch any {
        case is NSNull: return .null
        case let n as NSNumber:
            // NSNumber bridges to Bool — check CFBoolean before treating 0/1 as bool.
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                return .bool(n.boolValue)
            }
            return .number(n.doubleValue)
        case let b as Bool: return .bool(b)
        case let i as Int: return .number(Double(i))
        case let d as Double: return .number(d)
        case let s as String: return .string(s)
        case let a as [Any]: return .array(a.map { fromAny($0) })
        case let o as [String: Any]: return .object(o.mapValues { fromAny($0) })
        default: return .string(String(describing: any))
        }
    }

    func toAny() -> Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return b
        case .number(let n): return n
        case .string(let s): return s
        case .array(let a): return a.map { $0.toAny() }
        case .object(let o): return o.mapValues { $0.toAny() }
        }
    }
}
