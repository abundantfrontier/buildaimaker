import Foundation

/// Pure domain session for text playground: history, A/B adapter toggle, export.
///
/// UI holds a view-model wrapper; this type stays free of SwiftUI.
public struct PlaygroundSession: Sendable, Equatable {
    public var systemPrompt: String
    public var messages: [InferenceChatMessage]
    public var baseModelPath: String?
    public var adapterPath: String?
    /// A/B: when false, completions run against base only.
    public var adapterEnabled: Bool
    public var templateId: String
    public var lastBackendId: String?
    public var lastLatencyMs: Double?
    public var lastWasStub: Bool?

    public init(
        systemPrompt: String = "",
        messages: [InferenceChatMessage] = [],
        baseModelPath: String? = nil,
        adapterPath: String? = nil,
        adapterEnabled: Bool = true,
        templateId: String = ChatPromptFormatter.chatML
    ) {
        self.systemPrompt = systemPrompt
        self.messages = messages
        self.baseModelPath = baseModelPath
        self.adapterPath = adapterPath
        self.adapterEnabled = adapterEnabled
        self.templateId = templateId
        self.lastBackendId = nil
        self.lastLatencyMs = nil
        self.lastWasStub = nil
    }

    /// Whether a user turn can be sent (base model selected, not empty draft later).
    public var canChat: Bool {
        baseModelPath != nil && !(baseModelPath?.isEmpty ?? true)
    }

    public mutating func clearTranscript() {
        messages = []
        lastBackendId = nil
        lastLatencyMs = nil
        lastWasStub = nil
    }

    /// Append user message, call backend, append assistant reply.
    public mutating func send(
        userText: String,
        backend: any LLMBackend
    ) async throws -> LLMCompletionResult {
        let trimmed = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw CocoaError(.userCancelled)
        }
        guard canChat else {
            throw CocoaError(.fileNoSuchFile)
        }

        messages.append(.user(trimmed))

        let forCompletion = ChatPromptFormatter.messagesForCompletion(
            history: messages,
            systemOverride: systemPrompt.isEmpty ? nil : systemPrompt
        )
        let request = LLMCompletionRequest(
            messages: forCompletion,
            baseModelPath: baseModelPath,
            adapterPath: adapterPath,
            adapterEnabled: adapterEnabled,
            templateId: templateId
        )
        let result = try await backend.complete(request)
        messages.append(result.assistantMessage)
        lastBackendId = result.backendId
        lastLatencyMs = result.latencyMs
        lastWasStub = result.isStub
        return result
    }

    /// Transcript including optional system prompt as first message for export.
    public func exportMessages() -> [InferenceChatMessage] {
        var out: [InferenceChatMessage] = []
        let trimmedSystem = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSystem.isEmpty {
            out.append(.system(trimmedSystem))
        }
        // Avoid double system if history already starts with same system.
        let rest: [InferenceChatMessage]
        if let first = messages.first, first.role == "system" {
            rest = Array(messages.dropFirst())
        } else {
            rest = messages
        }
        out.append(contentsOf: rest)
        return out
    }
}
