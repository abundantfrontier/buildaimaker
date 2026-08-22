import BAMCore
import Foundation

/// Paths and a copy-paste Grok MCP snippet (same as Docs/mcp-bridge.md).
enum MCPClientConfig {
    static var socketPath: String { LibraryPaths.mcpSocket.path }
    static var tokenPath: String { LibraryPaths.mcpToken.path }

    static var socketExists: Bool {
        FileManager.default.fileExists(atPath: socketPath)
    }

    static var tokenExists: Bool {
        FileManager.default.fileExists(atPath: tokenPath)
    }

    static func resolveBridgeBinary() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let guesses = [
            home.appendingPathComponent("Documents/GitHub/buildaimaker/.build/debug/buildaimaker-mcp"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(".build/debug/buildaimaker-mcp"),
        ]
        for url in guesses where FileManager.default.isExecutableFile(atPath: url.path) {
            return url.path
        }
        return "/path/to/buildaimaker/.build/debug/buildaimaker-mcp"
    }

    static func grokSnippet() -> String {
        let command = resolveBridgeBinary()
        return """
        # ~/.grok/config.toml — BuildAIMaker (app must be running)
        [[mcp_servers]]
        name = "buildaimaker"
        command = "\(command)"
        # optional:
        # env = { BAM_SOCKET = "\(socketPath)", BAM_TOKEN = "\(tokenPath)" }
        """
    }
}
