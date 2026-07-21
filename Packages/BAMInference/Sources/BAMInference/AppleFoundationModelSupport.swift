import BAMCore
import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Status of Apple’s on-device Foundation Model (system Language Model).
public enum AppleFoundationModelStatus: String, Sendable, Equatable, Codable {
    /// Framework present and `SystemLanguageModel` reports available.
    case available
    /// Framework present but model not ready (waitlist, download, AI off, region, …).
    case unavailable
    /// OS/SDK has no FoundationModels framework (CI / older macOS).
    case unsupported
    /// Probed too early / unknown shape on a beta.
    case unknown

    public var isUsable: Bool { self == .available }

    public var title: String {
        switch self {
        case .available: return "Apple on-device model ready"
        case .unavailable: return "Apple on-device model not ready"
        case .unsupported: return "Apple Foundation Models not on this OS"
        case .unknown: return "Apple model status unknown"
        }
    }

    public var detail: String {
        switch self {
        case .available:
            return "SystemLanguageModel is available. Playground can use it by default (no HF download)."
        case .unavailable:
            return "Enable Apple Intelligence & finish any model download. Siri AI (Beta) waitlist is separate from Writing Tools / FM API."
        case .unsupported:
            return "Needs a recent macOS with the FoundationModels framework (Apple Intelligence era)."
        case .unknown:
            return "Could not determine status on this beta."
        }
    }
}

/// Probe + optional generate via Apple Foundation Models (system on-device LLM).
///
/// Distinct from open MLX weights under `models/base`. Does not install Apple’s
/// model — the OS does when Apple Intelligence is enabled.
public enum AppleFoundationModelSupport: Sendable {
    public static let backendId = "apple-foundation"

    /// Whether this process can import the framework (compile-time + runtime).
    public static var frameworkPresent: Bool {
        #if canImport(FoundationModels)
        true
        #else
        false
        #endif
    }

    /// Best-effort availability probe (main-thread safe; cheap).
    public static func probeStatus() -> AppleFoundationModelStatus {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let model = SystemLanguageModel.default
            switch model.availability {
            case .available:
                return .available
            case .unavailable:
                return .unavailable
            @unknown default:
                return .unknown
            }
        }
        return .unsupported
        #else
        return .unsupported
        #endif
    }

    /// Human-readable reason when unavailable (beta-dependent).
    public static func unavailableReasonDescription() -> String? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let model = SystemLanguageModel.default
            if case .unavailable(let reason) = model.availability {
                return String(describing: reason)
            }
        }
        #endif
        return nil
    }
}

/// LLM backend that calls Apple’s on-device `SystemLanguageModel` via FoundationModels.
public struct AppleFoundationLLMBackend: LLMBackend, Sendable {
    public static let id = AppleFoundationModelSupport.backendId

    public var backendId: String { Self.id }

    public init() {}

    public static func makeIfAvailable() -> AppleFoundationLLMBackend? {
        AppleFoundationModelSupport.probeStatus() == .available
            ? AppleFoundationLLMBackend()
            : nil
    }

    public func complete(_ request: LLMCompletionRequest) async throws -> LLMCompletionResult {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let status = AppleFoundationModelSupport.probeStatus()
            guard status == .available else {
                throw BAMError(
                    code: .capabilityUnsupported,
                    message: "Apple Foundation Model not available (\(status.rawValue)). Enable Apple Intelligence / finish model download."
                )
            }

            let start = Date()
            let prompt = Self.formatPrompt(messages: request.messages)
            let model = SystemLanguageModel.default
            let session = LanguageModelSession(model: model)
            let response = try await session.respond(to: prompt)
            let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                throw BAMError(
                    code: .capabilityUnsupported,
                    message: "Apple Foundation Model returned empty text."
                )
            }
            let elapsed = Date().timeIntervalSince(start) * 1000
            return LLMCompletionResult(
                assistantMessage: .assistant(text),
                backendId: backendId,
                latencyMs: elapsed,
                isStub: false,
                detail: "SystemLanguageModel.default"
            )
        }
        #endif
        throw BAMError(
            code: .capabilityUnsupported,
            message: "Apple Foundation Models framework not available in this build/OS."
        )
    }

    /// Flatten chat messages into a single prompt the system model can handle.
    static func formatPrompt(messages: [InferenceChatMessage]) -> String {
        var systemBits: [String] = []
        var turns: [String] = []
        for m in messages {
            let content = m.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { continue }
            switch m.role.lowercased() {
            case "system":
                systemBits.append(content)
            case "user":
                turns.append("User: \(content)")
            case "assistant":
                turns.append("Assistant: \(content)")
            default:
                turns.append("\(m.role): \(content)")
            }
        }
        var parts: [String] = []
        if !systemBits.isEmpty {
            parts.append("Instructions:\n" + systemBits.joined(separator: "\n"))
        }
        if !turns.isEmpty {
            parts.append(turns.joined(separator: "\n"))
        }
        parts.append("Assistant:")
        return parts.joined(separator: "\n\n")
    }
}
