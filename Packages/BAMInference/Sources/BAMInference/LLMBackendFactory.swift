import Foundation

/// Preferred inference stack for Playground / Talk.
public enum LLMBackendPreference: String, CaseIterable, Sendable, Identifiable {
    /// Apple on-device Foundation Model when available, else MLX, else echo.
    case automatic
    /// Force Apple Foundation Models only (errors if unavailable).
    case appleFoundation
    /// Force mlx-lm generate when Python+mlx_lm present.
    case mlx
    /// CI-safe echo stub.
    case echo

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .automatic: return "Automatic (Apple → MLX → Echo)"
        case .appleFoundation: return "Apple on-device model"
        case .mlx: return "Local MLX (open weights)"
        case .echo: return "Echo (stub)"
        }
    }
}

/// Resolves the preferred LLM backend.
///
/// Default product order:
/// 1. **Apple Foundation Models** (system on-device) when available  
/// 2. **mlx-lm** when managed/system Python has `mlx_lm` and real weights may exist  
/// 3. **Echo** stub for CI / offline demos  
public enum LLMBackendFactory: Sendable {
    /// Default product backend for playground.
    ///
    /// - Parameter preference: Which stack to try.
    /// - Parameter forceEcho: When true, always return the CI-safe echo backend.
    public static func makeDefault(
        preference: LLMBackendPreference = .automatic,
        forceEcho: Bool = false
    ) -> any LLMBackend {
        if forceEcho || preference == .echo {
            return EchoLLMBackend()
        }
        switch preference {
        case .echo:
            return EchoLLMBackend()
        case .appleFoundation:
            if let apple = AppleFoundationLLMBackend.makeIfAvailable() {
                return apple
            }
            return EchoLLMBackend()
        case .mlx:
            if let mlx = MLXGenerateBackend.makeIfAvailable() {
                return mlx
            }
            return EchoLLMBackend()
        case .automatic:
            if let apple = AppleFoundationLLMBackend.makeIfAvailable() {
                return apple
            }
            if let mlx = MLXGenerateBackend.makeIfAvailable() {
                return mlx
            }
            return EchoLLMBackend()
        }
    }

    /// Legacy signature used by older call sites.
    public static func makeDefault(
        preferMLX: Bool,
        forceEcho: Bool = false
    ) -> any LLMBackend {
        if forceEcho { return EchoLLMBackend() }
        if preferMLX {
            return makeDefault(preference: .automatic, forceEcho: false)
        }
        return makeDefault(preference: .echo, forceEcho: false)
    }

    /// Always-echo backend (unit tests / offline demos).
    public static func makeEcho(simulatedLatencyMs: Double = 0) -> EchoLLMBackend {
        EchoLLMBackend(simulatedLatencyMs: simulatedLatencyMs)
    }

    /// Snapshot of what is usable on this Mac right now.
    public static func probeAvailability() -> (
        apple: AppleFoundationModelStatus,
        mlx: Bool,
        preferredId: String
    ) {
        let apple = AppleFoundationModelSupport.probeStatus()
        let mlx = MLXGenerateBackend.isAvailable()
        let backend = makeDefault(preference: .automatic)
        return (apple, mlx, backend.backendId)
    }
}
