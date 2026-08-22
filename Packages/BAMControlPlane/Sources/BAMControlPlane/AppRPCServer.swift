import Foundation
import Darwin

/// Minimal Unix-domain NDJSON App RPC server (design Appendix D).
///
/// Auth: first message must be `Hello` with matching token.
public final class AppRPCServer: @unchecked Sendable {
    public let socketPath: URL
    public let tokenPath: URL
    public let pidPath: URL
    public let token: String
    public let appVersion: String

    private let plane: ControlPlane
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private let acceptQueue = DispatchQueue(label: "bam.apprpc.accept")
    /// Per-connection work must not sit on the accept queue — a long-lived MCP
    /// bridge would otherwise block Hello from a second client (CLI / tests).
    private let connectionQueue = DispatchQueue(
        label: "bam.apprpc.connections",
        attributes: .concurrent
    )
    private var running = false

    public init(
        plane: ControlPlane,
        socketPath: URL,
        tokenPath: URL,
        pidPath: URL,
        token: String = UUID().uuidString.replacingOccurrences(of: "-", with: ""),
        appVersion: String = "0.1.0"
    ) {
        self.plane = plane
        self.socketPath = socketPath
        self.tokenPath = tokenPath
        self.pidPath = pidPath
        self.token = token
        self.appVersion = appVersion
    }

    /// Write token + pid, bind socket, start accept loop.
    public func start() throws {
        guard !running else { return }
        let fm = FileManager.default
        try fm.createDirectory(
            at: socketPath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        // Stale socket cleanup.
        if fm.fileExists(atPath: socketPath.path) {
            try? fm.removeItem(at: socketPath)
        }
        try token.write(to: tokenPath, atomically: true, encoding: .utf8)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenPath.path)

        let pid = "\(ProcessInfo.processInfo.processIdentifier)\n"
        try pid.write(to: pidPath, atomically: true, encoding: .utf8)

        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else {
            throw AppRPCError(message: "socket() failed: \(errno)")
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let path = socketPath.path
        let maxLen = 104 // sockaddr_un.sun_path typical size on Darwin
        guard path.utf8.count + 1 < maxLen else {
            close(listenFD)
            listenFD = -1
            throw AppRPCError(message: "Socket path too long")
        }
        path.withCString { cstr in
            withUnsafeMutableBytes(of: &addr.sun_path) { buf in
                guard let base = buf.baseAddress?.assumingMemoryBound(to: CChar.self) else { return }
                _ = strncpy(base, cstr, maxLen - 1)
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(listenFD, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            let e = errno
            close(listenFD)
            listenFD = -1
            throw AppRPCError(message: "bind(\(path)) failed: \(e)")
        }
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)

        guard listen(listenFD, 8) == 0 else {
            let e = errno
            close(listenFD)
            listenFD = -1
            throw AppRPCError(message: "listen failed: \(e)")
        }

        let source = DispatchSource.makeReadSource(fileDescriptor: listenFD, queue: acceptQueue)
        source.setEventHandler { [weak self] in
            self?.acceptOne()
        }
        source.setCancelHandler { [weak self] in
            if let fd = self?.listenFD, fd >= 0 {
                close(fd)
                self?.listenFD = -1
            }
        }
        acceptSource = source
        source.resume()
        running = true
    }

    public func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        if listenFD >= 0 {
            close(listenFD)
            listenFD = -1
        }
        running = false
        try? FileManager.default.removeItem(at: socketPath)
    }

    private func acceptOne() {
        var addr = sockaddr_un()
        var len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let client = withUnsafeMutablePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                accept(listenFD, sockPtr, &len)
            }
        }
        guard client >= 0 else { return }
        connectionQueue.async {
            self.handleConnection(fd: client)
        }
    }

    private func handleConnection(fd: Int32) {
        defer { close(fd) }
        var authed = false
        var buffer = Data()
        var tmp = [UInt8](repeating: 0, count: 16_384)

        while true {
            let n = read(fd, &tmp, tmp.count)
            if n <= 0 { break }
            buffer.append(contentsOf: tmp[0..<n])
            if buffer.count > AppRPCProtocol.maxMessageBytes {
                _ = try? writeEnvelope(
                    fd: fd,
                    AppRPCEnvelope.responseError(
                        id: "?",
                        error: ActionErrorDTO(
                            code: .protocolMismatch,
                            message: "Message too large"
                        )
                    )
                )
                break
            }

            while let range = buffer.range(of: Data([0x0A])) {
                let line = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
                buffer.removeSubrange(buffer.startIndex...range.lowerBound)
                guard !line.isEmpty else { continue }
                let response = processLine(line, authed: &authed)
                if let response {
                    _ = try? writeEnvelope(fd: fd, response)
                    if response.ok == false,
                       response.error?.code == ActionErrorCode.authFailed.rawValue
                        || response.error?.code == ActionErrorCode.protocolMismatch.rawValue
                    {
                        return
                    }
                }
            }
        }
    }

    private func processLine(_ line: Data, authed: inout Bool) -> AppRPCEnvelope? {
        let env: AppRPCEnvelope
        do {
            env = try AppRPCEnvelope.parseLine(line)
        } catch {
            return .responseError(
                id: "?",
                error: ActionErrorDTO(code: .protocolMismatch, message: "Invalid JSON line")
            )
        }

        guard env.type == "req", let method = env.method else {
            return .responseError(
                id: env.id,
                error: ActionErrorDTO(code: .validationError, message: "Expected type=req with method")
            )
        }

        if method == "Hello" {
            return handleHello(env, authed: &authed)
        }
        if !authed {
            return .responseError(
                id: env.id,
                error: ActionErrorDTO(
                    code: .authFailed,
                    message: "Hello required before \(method)",
                    remediation: "Send Hello with token first"
                )
            )
        }

        switch method {
        case "Ping":
            return handlePing(env)
        case "ListActions", "ListTools":
            return handleList(env, toolsOnly: method == "ListTools")
        case "Invoke":
            return handleInvokeSync(env)
        case "Goodbye":
            return .responseOK(id: env.id, result: .object([:]))
        default:
            return .responseError(
                id: env.id,
                error: ActionErrorDTO(code: .notFound, message: "Unknown method: \(method)")
            )
        }
    }

    private func handleHello(_ env: AppRPCEnvelope, authed: inout Bool) -> AppRPCEnvelope {
        let params = env.params?.objectValue ?? [:]
        let presented = params["token"]?.stringValue ?? ""
        let clientProto = params["protocolVersion"]?.intValue ?? 0
        if clientProto != 0, clientProto != AppRPCProtocol.version {
            return .responseError(
                id: env.id,
                error: ActionErrorDTO(
                    code: .protocolMismatch,
                    message: "protocolVersion \(clientProto) != \(AppRPCProtocol.version)"
                )
            )
        }
        guard presented == token else {
            return .responseError(
                id: env.id,
                error: ActionErrorDTO(
                    code: .authFailed,
                    message: "Invalid token",
                    remediation: "Read mcp.token next to the socket"
                )
            )
        }
        authed = true
        let fmt = ISO8601DateFormatter()
        return .responseOK(
            id: env.id,
            result: .object([
                "sessionId": .string(UUID().uuidString),
                "protocolVersion": .number(Double(AppRPCProtocol.version)),
                "appVersion": .string(appVersion),
                "serverTime": .string(fmt.string(from: Date())),
                "capabilities": .object([
                    "confirm": .bool(true),
                    "jobs": .bool(true),
                    "slimState": .bool(true),
                    "notifications": .bool(false),
                ]),
            ])
        )
    }

    private func handlePing(_ env: AppRPCEnvelope) -> AppRPCEnvelope {
        let sem = DispatchSemaphore(value: 0)
        var rev = 0
        Task {
            rev = await plane.stateStore.revision
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 5)
        return .responseOK(id: env.id, result: .object(["revision": .number(Double(rev))]))
    }

    private func handleList(_ env: AppRPCEnvelope, toolsOnly: Bool) -> AppRPCEnvelope {
        let sem = DispatchSemaphore(value: 0)
        var payload: JSONValue = .object([:])
        Task {
            let defs = await plane.registry.list(filter: toolsOnly ? .mcp : .all)
            if toolsOnly {
                payload = .object([
                    "tools": .array(defs.map { $0.asMCPTool() }),
                ])
            } else {
                payload = .object([
                    "actions": .array(defs.map { $0.asJSONValue() }),
                ])
            }
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 10)
        return .responseOK(id: env.id, result: payload)
    }

    private func handleInvokeSync(_ env: AppRPCEnvelope) -> AppRPCEnvelope {
        let params = env.params?.objectValue ?? [:]
        guard let actionId = params["actionId"]?.stringValue, !actionId.isEmpty else {
            return .responseError(
                id: env.id,
                error: ActionErrorDTO(code: .validationError, message: "Missing actionId")
            )
        }
        let actionParams = params["params"] ?? .object([:])
        let ctxObj = params["context"]?.objectValue ?? [:]
        let context = ActionContext(
            source: .mcp,
            clientId: ctxObj["clientId"]?.stringValue ?? "mcp",
            correlationId: ctxObj["correlationId"]?.stringValue ?? env.id,
            windowId: ctxObj["windowId"]?.stringValue,
            confirmToken: ctxObj["confirmToken"]?.stringValue,
            clientMutationId: ctxObj["clientMutationId"]?.stringValue,
            expectedRevision: ctxObj["expectedRevision"]?.intValue
        )

        let sem = DispatchSemaphore(value: 0)
        var outcome = ActionOutcome.failure(
            .internalError,
            message: "Invoke timed out",
            context: context
        )
        Task {
            outcome = await plane.invoke(
                ActionID(actionId),
                params: actionParams,
                context: context
            )
            sem.signal()
        }
        // Long actions return jobId quickly; allow headroom for import.
        _ = sem.wait(timeout: .now() + 120)
        return .responseOK(id: env.id, result: outcome.asJSONValue())
    }

    private func writeEnvelope(fd: Int32, _ env: AppRPCEnvelope) throws {
        let data = try env.jsonLine()
        data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            var written = 0
            while written < data.count {
                let n = write(fd, base.advanced(by: written), data.count - written)
                if n <= 0 { break }
                written += n
            }
        }
    }
}

public struct AppRPCError: Error, LocalizedError {
    public var message: String
    public init(message: String) { self.message = message }
    public var errorDescription: String? { message }
}

// MARK: - Client (for bridge + tests)

public final class AppRPCClient: @unchecked Sendable {
    public let socketPath: URL
    public let token: String
    private var fd: Int32 = -1
    private var buffer = Data()

    public init(socketPath: URL, token: String) {
        self.socketPath = socketPath
        self.token = token
    }

    public func connectAndHello(clientName: String = "buildaimaker-mcp") throws {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw AppRPCError(message: "socket() failed") }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let path = socketPath.path
        let maxLen = 104
        path.withCString { cstr in
            withUnsafeMutableBytes(of: &addr.sun_path) { buf in
                guard let base = buf.baseAddress?.assumingMemoryBound(to: CChar.self) else { return }
                _ = strncpy(base, cstr, maxLen - 1)
            }
        }
        let ok = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard ok == 0 else {
            close(fd)
            fd = -1
            throw AppRPCError(message: "connect(\(path)) failed — is BuildAIMaker running?")
        }

        let res = try call(
            method: "Hello",
            params: .object([
                "token": .string(token),
                "clientName": .string(clientName),
                "clientVersion": .string("0.1.0"),
                "protocolVersion": .number(Double(AppRPCProtocol.version)),
            ])
        )
        guard res.ok == true else {
            throw AppRPCError(message: res.error?.message ?? "Hello failed")
        }
    }

    public func call(method: String, params: JSONValue? = nil) throws -> AppRPCEnvelope {
        guard fd >= 0 else { throw AppRPCError(message: "Not connected") }
        let id = UUID().uuidString
        let req = AppRPCEnvelope.request(id: id, method: method, params: params)
        let data = try req.jsonLine()
        let written = data.withUnsafeBytes { raw -> Int in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return -1 }
            return write(fd, base, data.count)
        }
        guard written == data.count else {
            throw AppRPCError(message: "write failed")
        }

        // Read until newline for this id (v1 single-flight).
        var tmp = [UInt8](repeating: 0, count: 16_384)
        while true {
            if let range = buffer.range(of: Data([0x0A])) {
                let line = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
                buffer.removeSubrange(buffer.startIndex...range.lowerBound)
                let env = try AppRPCEnvelope.parseLine(line)
                if env.id == id { return env }
                // skip unexpected
                continue
            }
            let n = read(fd, &tmp, tmp.count)
            if n <= 0 {
                throw AppRPCError(message: "Connection closed (APP_NOT_RUNNING?)")
            }
            buffer.append(contentsOf: tmp[0..<n])
        }
    }

    public func closeConnection() {
        if fd >= 0 {
            close(fd)
            fd = -1
        }
    }

    deinit { closeConnection() }
}
