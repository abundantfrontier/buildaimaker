import BAMCore
import BAMJobs
import BAMModels
import Foundation

// MARK: - Remote types (interface preservation — K22)

/// Backend kind for remote training.
///
/// Only `.fake` is implemented in v1. Real SSH / cloud API kinds are post-PMF.
public enum RemoteRunnerKind: String, Codable, Sendable, Equatable, CaseIterable {
    /// In-process emulator (`FakeRemoteRunner`). No network, no SSH.
    case fake
    // Future (post-PMF, not in v1):
    // case ssh
    // case cloudAPI
}

/// Lifecycle phase of a job on a remote backend.
///
/// Fake emulator walks: pending → uploading → queued → running → downloading → terminal.
public enum RemoteJobPhase: String, Codable, Sendable, Equatable, CaseIterable {
    case pending
    case uploading
    case queued
    case running
    case downloading
    case succeeded
    case failed
    case cancelled

    public var isTerminal: Bool {
        switch self {
        case .succeeded, .failed, .cancelled: return true
        default: return false
        }
    }
}

/// Opaque handle returned after remote submit.
public struct RemoteJobHandle: Codable, Sendable, Equatable, Hashable {
    /// Identifier assigned by the remote backend.
    public var remoteJobId: String
    /// Local `JobSpec.id` that was submitted.
    public var localJobId: String

    public init(remoteJobId: String, localJobId: String) {
        self.remoteJobId = remoteJobId
        self.localJobId = localJobId
    }
}

/// Advertised remote endpoint metadata (no real network addresses in v1).
public struct RemoteEndpointInfo: Codable, Sendable, Equatable {
    public var id: String
    public var displayName: String
    public var kind: RemoteRunnerKind

    public init(id: String, displayName: String, kind: RemoteRunnerKind) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
    }

    /// Built-in fake endpoint used by `FakeRemoteRunner`.
    public static let fake = RemoteEndpointInfo(
        id: "fake-remote",
        displayName: "Fake Remote (in-process)",
        kind: .fake
    )
}

// MARK: - Protocol

/// Remote training backend abstraction.
///
/// **K22 / v1 — interface preservation only.** No real cloud or SSH pilot.
/// Product code must keep `ff.cloudRunner` **off** (see `CloudPolicy`).
/// Tests and future post-PMF backends implement this protocol; `FakeRemoteRunner`
/// emulates the full remote job lifecycle in-process.
///
/// Inherits `TrainingRunner` so a remote backend can plug into `JobQueueController`
/// when the feature flag is eventually enabled.
public protocol RemoteRunner: TrainingRunner {
    /// Concrete backend kind (always `.fake` in v1).
    var kind: RemoteRunnerKind { get }

    /// Endpoint metadata (display / diagnostics).
    var endpoint: RemoteEndpointInfo { get }

    /// `true` after a successful `connect()` and before `disconnect()`.
    func isConnected() async -> Bool

    /// Establish a (fake) session to the remote backend.
    func connect() async throws

    /// Tear down the remote session. Idempotent.
    func disconnect() async

    /// Submit a job for remote execution. Requires an active connection.
    /// Fake emulates upload/queue without network I/O.
    func submit(job: JobSpec, paths: JobPaths) async throws -> RemoteJobHandle

    /// Current remote phase for a previously submitted job.
    func remoteStatus(handle: RemoteJobHandle) async throws -> RemoteJobPhase

    /// Pull result artifacts into local job paths (fake materializes stubs).
    func fetchArtifacts(handle: RemoteJobHandle, paths: JobPaths) async throws -> [RunnerArtifactRef]
}
