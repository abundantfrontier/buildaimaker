import BAMCore
import BAMModels
import Foundation

/// Builds jailed `JobPaths` under a library root for a given job id.
public enum JobPathsFactory: Sendable {
    public static func make(
        jobId: String,
        libraryRoot: URL = LibraryPaths.libraryRoot,
        datasetPath: String? = nil,
        baseModelPath: String? = nil,
        referenceAudioPath: String? = nil
    ) -> JobPaths {
        let jobDir = libraryRoot
            .appendingPathComponent("jobs", isDirectory: true)
            .appendingPathComponent(LibraryPaths.sanitizedPathComponent(jobId), isDirectory: true)
        return JobPaths(
            jobDir: jobDir.path,
            libraryRoot: libraryRoot.path,
            datasetPath: datasetPath,
            baseModelPath: baseModelPath,
            referenceAudioPath: referenceAudioPath,
            outputPath: jobDir.appendingPathComponent("artifacts", isDirectory: true).path,
            checkpointPath: jobDir.appendingPathComponent("checkpoints", isDirectory: true).path,
            cancelFlagPath: jobDir.appendingPathComponent("cancel.flag", isDirectory: false).path,
            logPath: jobDir.appendingPathComponent("logs", isDirectory: true).path
        )
    }

    public static func heartbeatURL(paths: JobPaths) -> URL {
        URL(fileURLWithPath: paths.jobDir)
            .appendingPathComponent("heartbeat.json", isDirectory: false)
    }

    public static func jobJSONURL(paths: JobPaths) -> URL {
        URL(fileURLWithPath: paths.jobDir)
            .appendingPathComponent("job.json", isDirectory: false)
    }
}
