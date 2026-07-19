import Foundation

/// Resolves the preferred LLM backend: mlx-lm generate when available, else echo.
public enum LLMBackendFactory: Sendable {
    /// Default product backend for playground.
    ///
    /// - Parameter preferMLX: When true (default), probe for `mlx_lm` and use it.
    /// - Parameter forceEcho: When true, always return the CI-safe echo backend.
    public static func makeDefault(
        preferMLX: Bool = true,
        forceEcho: Bool = false
    ) -> any LLMBackend {
        if forceEcho {
            return EchoLLMBackend()
        }
        if preferMLX, let mlx = MLXGenerateBackend.makeIfAvailable() {
            return mlx
        }
        return EchoLLMBackend()
    }

    /// Always-echo backend (unit tests / offline demos).
    public static func makeEcho(simulatedLatencyMs: Double = 0) -> EchoLLMBackend {
        EchoLLMBackend(simulatedLatencyMs: simulatedLatencyMs)
    }
}
