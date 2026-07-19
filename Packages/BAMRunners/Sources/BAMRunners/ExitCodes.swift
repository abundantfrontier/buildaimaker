import Foundation

/// Documented worker process exit codes (Runner Protocol v1).
///
/// Design table lists 130 for “SIGTERM path”. On macOS/POSIX, `Process.terminate()`
/// typically yields **143** (`128 + SIGTERM`). Both are classified as `.sigterm`.
/// 130 is more commonly associated with SIGINT (`128 + 2`).
public enum WorkerExitCode: Int, Sendable, CaseIterable {
    /// Clean protocol completion (including cancelled result).
    case success = 0
    /// Handled failure (error event already sent).
    case handledFailure = 1
    /// Protocol / usage error.
    case protocolError = 2
    /// Design-table SIGTERM path code (see also POSIX 143).
    case sigterm = 130
    /// SIGKILL / OOM killer suspected (`128 + 9`).
    case sigkill = 137

    /// POSIX `128 + SIGTERM` as observed from `Process.terminate()` on macOS.
    public static let posixSigtermStatus: Int = 143

    public var meaning: String {
        switch self {
        case .success: return "Clean protocol completion (incl. cancelled result)"
        case .handledFailure: return "Handled failure (error event already sent)"
        case .protocolError: return "Protocol/usage error"
        case .sigterm: return "SIGTERM path (design 130; POSIX Process.terminate often 143)"
        case .sigkill: return "SIGKILL / OOM killer suspected"
        }
    }

    /// Maps an arbitrary process termination status to a known code or `nil`.
    public static func classify(_ status: Int32) -> WorkerExitCode? {
        switch Int(status) {
        case 0: return .success
        case 1: return .handledFailure
        case 2: return .protocolError
        case 130, posixSigtermStatus: return .sigterm
        case 137: return .sigkill
        default: return nil
        }
    }

    /// True when status indicates a signaled cooperative/forced stop.
    public static func isSignaledStop(_ status: Int32) -> Bool {
        switch classify(status) {
        case .sigterm, .sigkill: return true
        default: return false
        }
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
