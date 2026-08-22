import XCTest
@testable import BAMControlPlane

final class AppRPCTests: XCTestCase {
    /// Short path under /tmp — Unix socket sun_path is ~104 bytes.
    private func shortTempDir(prefix: String) throws -> URL {
        let dir = URL(fileURLWithPath: "/tmp/\(prefix)-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testHelloInvokeRoundTrip() async throws {
        let plane = ControlPlane()
        await plane.installBuiltins()

        let dir = try shortTempDir(prefix: "bam-rpc")
        defer { try? FileManager.default.removeItem(at: dir) }

        let sock = dir.appendingPathComponent("mcp.sock")
        let tokenURL = dir.appendingPathComponent("mcp.token")
        let pid = dir.appendingPathComponent("mcp.pid")
        let token = "test-token-abc"
        let server = AppRPCServer(
            plane: plane,
            socketPath: sock,
            tokenPath: tokenURL,
            pidPath: pid,
            token: token
        )
        try server.start()
        defer { server.stop() }

        // Allow listen to come up.
        try await Task.sleep(nanoseconds: 50_000_000)

        let client = AppRPCClient(socketPath: sock, token: token)
        try client.connectAndHello()
        let ping = try client.call(method: "Ping")
        XCTAssertEqual(ping.ok, true)

        let inv = try client.call(
            method: "Invoke",
            params: .object([
                "actionId": .string("app.ping"),
                "params": .object([:]),
                "context": .object(["clientId": .string("test")]),
            ])
        )
        XCTAssertEqual(inv.ok, true)
        XCTAssertEqual(inv.result?["ok"]?.boolValue, true)
        client.closeConnection()
    }

    func testBadTokenFailsHello() async throws {
        let plane = ControlPlane()
        await plane.installBuiltins()
        let dir = try shortTempDir(prefix: "bam-rpcb")
        defer { try? FileManager.default.removeItem(at: dir) }

        let sock = dir.appendingPathComponent("mcp.sock")
        let server = AppRPCServer(
            plane: plane,
            socketPath: sock,
            tokenPath: dir.appendingPathComponent("mcp.token"),
            pidPath: dir.appendingPathComponent("mcp.pid"),
            token: "good"
        )
        try server.start()
        defer { server.stop() }
        try await Task.sleep(nanoseconds: 50_000_000)

        let client = AppRPCClient(socketPath: sock, token: "bad")
        XCTAssertThrowsError(try client.connectAndHello())
    }
}
