import Foundation

/// Documented worker process exit codes (Runner Protocol v1).
public enum WorkerExitCode: Int, Sendable, CaseIterable {
    /// Clean protocol completion (including cancelled result).
    case success = 0
    /// Handled failure (error event already sent).
    case handledFailure = 1
    /// Protocol / usage error.
    case protocolError = 2
    /// SIGTERM path.
    case sigterm = 130
    /// SIGKILL / OOM killer suspected.
    case sigkill = 137

    public var meaning: String {
        switch self {
        case .success: return "Clean protocol completion (incl. cancelled result)"
        case .handledFailure: return "Handled failure (error event already sent)"
        case .protocolError: return "Protocol/usage error"
        case .sigterm: return "SIGTERM path"
        case .sigkill: return "SIGKILL / OOM killer suspected"
        }
    }

    /// Maps an arbitrary process termination status to a known code or `nil`.
    public static func classify(_ status: Int32) -> WorkerExitCode? {
        WorkerExitCode(rawValue: Int(status))
    }
}

/// Timing / size constants for Runner Protocol v1.
public enum RunnerProtocolLimits: Sendable {
    /// Maximum UTF-8 line size (bytes). Exceed → worker fatal / supervisor crash.
    public static let maxLineBytes: Int = 8 * 1024 * 1024
    /// Worker should emit heartbeat at least this often while running.
    public static let heartbeatIntervalSeconds: TimeInterval = 5
    /// Supervisor marks hung if no heartbeat within this window.
    public static let heartbeatTimeoutSeconds: TimeInterval = 20
    /// First `hello` must arrive within this window after spawn.
    public static let helloDeadlineSeconds: TimeInterval = 30
    /// After cancel.flag / cancel cmd: wait this long for cooperative exit.
    public static let cancelGraceT1Seconds: TimeInterval = 10
    /// After SIGTERM: wait this long before SIGKILL.
    public static let cancelGraceT2Seconds: TimeInterval = 5
}
