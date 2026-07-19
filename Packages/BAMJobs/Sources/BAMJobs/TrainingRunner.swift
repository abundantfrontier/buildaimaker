import BAMModels
import Foundation

/// Training backend abstraction (aligned with Runner Protocol v1).
///
/// Process supervisor / real workers land in `BAMRunners` (PR-Protocol).
/// This PR ships the protocol surface plus `FakeTrainingRunner` for queue plumbing.
public protocol TrainingRunner: Sendable {
    var id: String { get }
    var protocolVersion: Int { get }

    func capabilities() async throws -> RunnerCapabilities
    func prepare(job: JobSpec, paths: JobPaths) async throws
    func run(job: JobSpec, paths: JobPaths) -> AsyncThrowingStream<RunnerEvent, Error>
    func resume(job: JobSpec, paths: JobPaths, checkpoint: CheckpointRef)
        -> AsyncThrowingStream<RunnerEvent, Error>
    func cancel(jobId: String) async
}
