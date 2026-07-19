import Foundation

/// CI-safe chat completion that echoes the system prompt + last user message.
///
/// Deterministic and offline — used when mlx-lm generate is unavailable and in
/// all unit tests. Response shape makes A/B adapter state visible in the text.
public struct EchoLLMBackend: LLMBackend, Sendable {
    public static let id = "echo"

    public var backendId: String { Self.id }

    /// Optional fixed latency for tests (milliseconds).
    public var simulatedLatencyMs: Double

    public init(simulatedLatencyMs: Double = 0) {
        self.simulatedLatencyMs = simulatedLatencyMs
    }

    public func complete(_ request: LLMCompletionRequest) async throws -> LLMCompletionResult {
        let start = Date()
        if simulatedLatencyMs > 0 {
            let ns = UInt64(simulatedLatencyMs * 1_000_000)
            try? await Task.sleep(nanoseconds: ns)
        }

        let system = ChatPromptFormatter.systemPrompt(from: request.messages) ?? ""
        let lastUser = ChatPromptFormatter.lastUserMessage(from: request.messages) ?? ""
        let adapterLabel: String = {
            if let path = request.effectiveAdapterPath, !path.isEmpty {
                return "on (\(URL(fileURLWithPath: path).lastPathComponent))"
            }
            return "off"
        }()
        let baseLabel = request.baseModelPath.map {
            URL(fileURLWithPath: $0).lastPathComponent
        } ?? "none"

        var lines: [String] = [
            "[echo] base=\(baseLabel) adapter=\(adapterLabel)",
        ]
        if !system.isEmpty {
            lines.append("system: \(system)")
        }
        lines.append("user: \(lastUser)")

        let content = lines.joined(separator: "\n")
        let elapsed = Date().timeIntervalSince(start) * 1000
        return LLMCompletionResult(
            assistantMessage: .assistant(content),
            backendId: backendId,
            latencyMs: max(elapsed, simulatedLatencyMs),
            isStub: true,
            detail: ChatPromptFormatter.formatPlain(request.messages)
        )
    }
}
