import BAMCore
import BAMModels
import Foundation

/// Validates job lifecycle transitions for v1 (no pause).
///
/// ```
/// draft → queued → preparing → running → succeeded
///                    ↘         ↘
///              failed | cancelled | interrupted
/// interrupted → queued
/// ```
public enum JobStateMachine: Sendable {
    /// Allowed edges for the v1 state machine (no mid-epoch pause).
    public static let allowedTransitions: [JobStatus: Set<JobStatus>] = [
        .draft: [.queued, .cancelled],
        .queued: [.preparing, .cancelled],
        .preparing: [.running, .failed, .cancelled, .interrupted],
        .running: [.succeeded, .failed, .cancelled, .interrupted],
        .interrupted: [.queued],
        .succeeded: [],
        .failed: [],
        .cancelled: [],
    ]

    /// Terminal statuses that accept no further transitions.
    public static let terminalStatuses: Set<JobStatus> = [
        .succeeded, .failed, .cancelled,
    ]

    /// Statuses considered "active" for single-job concurrency.
    public static let activeStatuses: Set<JobStatus> = [
        .queued, .preparing, .running,
    ]

    public static func canTransition(from: JobStatus, to: JobStatus) -> Bool {
        allowedTransitions[from]?.contains(to) ?? false
    }

    /// Returns `to` when the edge is legal; otherwise throws `BAM_SCHEMA_INVALID`.
    @discardableResult
    public static func transition(from: JobStatus, to: JobStatus) throws -> JobStatus {
        guard canTransition(from: from, to: to) else {
            throw BAMError(
                code: .schemaInvalid,
                message: "Invalid job status transition \(from.rawValue) → \(to.rawValue)"
            )
        }
        return to
    }

    public static func isTerminal(_ status: JobStatus) -> Bool {
        terminalStatuses.contains(status)
    }

    public static func isActive(_ status: JobStatus) -> Bool {
        activeStatuses.contains(status)
    }
}
