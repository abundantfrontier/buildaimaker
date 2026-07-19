import Foundation

/// Request for a single chat completion turn.
public struct LLMCompletionRequest: Sendable, Equatable {
    /// Ordered messages (system / user / assistant). Last turn is typically user.
    public var messages: [InferenceChatMessage]
    /// Absolute path to base model directory (MLX / HF layout).
    public var baseModelPath: String?
    /// Absolute path to LoRA adapter directory when adapter A/B is **on**.
    public var adapterPath: String?
    /// When false, backends must ignore `adapterPath` (A/B baseline).
    public var adapterEnabled: Bool
    /// Optional template id (`chatml`, `qwen2.5-instruct`, …).
    public var templateId: String
    /// Soft max tokens hint (echo ignores; real backends may honor).
    public var maxTokens: Int

    public init(
        messages: [InferenceChatMessage],
        baseModelPath: String? = nil,
        adapterPath: String? = nil,
        adapterEnabled: Bool = true,
        templateId: String = ChatPromptFormatter.chatML,
        maxTokens: Int = 256
    ) {
        self.messages = messages
        self.baseModelPath = baseModelPath
        self.adapterPath = adapterPath
        self.adapterEnabled = adapterEnabled
        self.templateId = templateId
        self.maxTokens = maxTokens
    }

    /// Effective adapter path after A/B toggle.
    public var effectiveAdapterPath: String? {
        adapterEnabled ? adapterPath : nil
    }
}

/// Result of a chat completion turn.
public struct LLMCompletionResult: Sendable, Equatable {
    public var assistantMessage: InferenceChatMessage
    /// Backend id for diagnostics (`echo`, `mlx-generate`, …).
    public var backendId: String
    /// Wall-clock latency in milliseconds (best-effort).
    public var latencyMs: Double
    /// True when this was a stub/fake path (CI-safe echo or forced fake).
    public var isStub: Bool
    /// Optional diagnostic detail (prompt preview, stderr snippet, …).
    public var detail: String?

    public init(
        assistantMessage: InferenceChatMessage,
        backendId: String,
        latencyMs: Double = 0,
        isStub: Bool = false,
        detail: String? = nil
    ) {
        self.assistantMessage = assistantMessage
        self.backendId = backendId
        self.latencyMs = latencyMs
        self.isStub = isStub
        self.detail = detail
    }
}

/// Composable LLM inference backend (K17).
///
/// Implementations must be safe to call from the UI process for short turns;
/// heavy inference may spawn a subprocess but must not block the main actor
/// when used via `async`.
public protocol LLMBackend: Sendable {
    /// Stable backend identifier (e.g. `echo`, `mlx-generate`).
    var backendId: String { get }

    /// Complete one chat turn and return the assistant message.
    func complete(_ request: LLMCompletionRequest) async throws -> LLMCompletionResult
}

/// Optional STT backend protocol (Talk mode lands in PR-Talk; reserved here).
public protocol STTBackend: Sendable {
    var backendId: String { get }
}

/// Optional TTS backend protocol (Talk mode lands in PR-Talk; reserved here).
public protocol TTSBackend: Sendable {
    var backendId: String { get }
}
