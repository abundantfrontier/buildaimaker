import BAMCore
import BAMJobs
import BAMModels
import Foundation

/// Path jail: all job filesystem inputs must resolve under `libraryRoot`,
/// with job-local outputs nested under `jobDir`.
///
/// Uses `resolvingSymlinksInPath` so symlink escape cannot bypass the root check.
public enum PathJail: Sendable {
    /// Asserts `path` (after symlink resolve) is equal to or nested under `root`.
    ///
    /// - Throws: `BAMError(code: .pathEscape, …)` on empty path, relative path, or escape.
    public static func assertUnderRoot(
        _ path: String,
        root: String,
        label: String = "path"
    ) throws {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw BAMError(code: .pathEscape, message: "\(label) is empty")
        }
        guard trimmed.hasPrefix("/") else {
            throw BAMError(
                code: .pathEscape,
                message: "\(label) must be absolute: \(trimmed)"
            )
        }

        let rootURL = URL(fileURLWithPath: root, isDirectory: true)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let pathURL = URL(fileURLWithPath: trimmed)
            .resolvingSymlinksInPath()
            .standardizedFileURL

        let rootPath = rootURL.path
        let resolvedPath = pathURL.path

        if resolvedPath == rootPath { return }

        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard resolvedPath.hasPrefix(prefix) else {
            throw BAMError(
                code: .pathEscape,
                message: "\(label) escapes root \(rootPath): \(resolvedPath)"
            )
        }
    }

    /// Validates every non-null field on `JobPaths`:
    /// - all under `libraryRoot`
    /// - job-local dirs (`outputPath`, `checkpointPath`, `cancelFlagPath`, `logPath`) under `jobDir`
    public static func validate(paths: JobPaths) throws {
        try assertUnderRoot(paths.libraryRoot, root: paths.libraryRoot, label: "libraryRoot")
        try assertUnderRoot(paths.jobDir, root: paths.libraryRoot, label: "jobDir")

        // Job-local layout under jobDir (and therefore under libraryRoot).
        try assertUnderRoot(paths.outputPath, root: paths.jobDir, label: "outputPath")
        try assertUnderRoot(paths.checkpointPath, root: paths.jobDir, label: "checkpointPath")
        try assertUnderRoot(paths.cancelFlagPath, root: paths.jobDir, label: "cancelFlagPath")
        try assertUnderRoot(paths.logPath, root: paths.jobDir, label: "logPath")

        if let datasetPath = paths.datasetPath {
            try assertUnderRoot(datasetPath, root: paths.libraryRoot, label: "datasetPath")
        }
        if let baseModelPath = paths.baseModelPath {
            try assertUnderRoot(baseModelPath, root: paths.libraryRoot, label: "baseModelPath")
        }
        if let referenceAudioPath = paths.referenceAudioPath {
            try assertUnderRoot(
                referenceAudioPath,
                root: paths.libraryRoot,
                label: "referenceAudioPath"
            )
        }
    }

    /// Voice clone requires non-null jailed `referenceAudioPath`.
    public static func validateModalityRequirements(job: JobSpec, paths: JobPaths) throws {
        if job.modality == .voiceClone {
            guard let ref = paths.referenceAudioPath, !ref.isEmpty else {
                throw BAMError(
                    code: .pathEscape,
                    message: "voiceClone requires non-null JobPaths.referenceAudioPath"
                )
            }
            try assertUnderRoot(ref, root: paths.libraryRoot, label: "referenceAudioPath")
        }
    }

    /// Jail a resume checkpoint path under `paths.checkpointPath` (and libraryRoot).
    /// Relative paths are resolved against `jobDir`.
    public static func validateCheckpoint(_ checkpoint: CheckpointRef, paths: JobPaths) throws {
        let absolute = resolvePath(checkpoint.path, relativeToJobDir: paths.jobDir)
        try assertUnderRoot(absolute, root: paths.libraryRoot, label: "checkpoint.path")
        try assertUnderRoot(absolute, root: paths.checkpointPath, label: "checkpoint.path")
    }

    /// Resolve relative worker paths against jobDir; leave absolute paths as-is.
    public static func resolvePath(_ path: String, relativeToJobDir jobDir: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("/") {
            return trimmed
        }
        return URL(fileURLWithPath: jobDir, isDirectory: true)
            .appendingPathComponent(trimmed)
            .path
    }

    /// Rejects free-form path keys that may appear on a **raw** JobSpec JSON payload
    /// (e.g. legacy `referenceAudioPath`) unless they equal the jailed JobPaths value.
    ///
    /// Standard `JobSpec` Codable drops unknown keys; callers **must** pass the original
    /// on-disk / store payload — never re-encoded Codable output (that is a no-op side-channel).
    public static func validateRawJobSpecPaths(
        rawSpecJSON: Data,
        paths: JobPaths
    ) throws {
        guard let obj = try JSONSerialization.jsonObject(with: rawSpecJSON) as? [String: Any] else {
            throw BAMError(code: .schemaInvalid, message: "JobSpec is not a JSON object")
        }

        let pathKeys = [
            "referenceAudioPath",
            "datasetPath",
            "baseModelPath",
            "jobDir",
            "libraryRoot",
            "outputPath",
            "checkpointPath",
            "cancelFlagPath",
            "logPath",
        ]

        for key in pathKeys {
            guard let value = obj[key] else { continue }
            if value is NSNull { continue }
            guard let stringValue = value as? String else {
                throw BAMError(
                    code: .pathEscape,
                    message: "JobSpec.\(key) must be a string path when present"
                )
            }
            try assertPathKeyMatches(key: key, value: stringValue, paths: paths)
        }
    }

    private static func assertPathKeyMatches(
        key: String,
        value: String,
        paths: JobPaths
    ) throws {
        let expected: String?
        switch key {
        case "referenceAudioPath": expected = paths.referenceAudioPath
        case "datasetPath": expected = paths.datasetPath
        case "baseModelPath": expected = paths.baseModelPath
        case "jobDir": expected = paths.jobDir
        case "libraryRoot": expected = paths.libraryRoot
        case "outputPath": expected = paths.outputPath
        case "checkpointPath": expected = paths.checkpointPath
        case "cancelFlagPath": expected = paths.cancelFlagPath
        case "logPath": expected = paths.logPath
        default: expected = nil
        }

        // Always require the path itself to be under libraryRoot when present.
        try assertUnderRoot(value, root: paths.libraryRoot, label: "JobSpec.\(key)")

        if let expected {
            let a = URL(fileURLWithPath: value).resolvingSymlinksInPath().standardizedFileURL.path
            let b = URL(fileURLWithPath: expected).resolvingSymlinksInPath().standardizedFileURL.path
            guard a == b else {
                throw BAMError(
                    code: .pathEscape,
                    message: "JobSpec.\(key) does not match JobPaths.\(key)"
                )
            }
        } else if key == "referenceAudioPath", paths.referenceAudioPath == nil {
            throw BAMError(
                code: .pathEscape,
                message: "JobSpec.referenceAudioPath set but JobPaths.referenceAudioPath is null"
            )
        }
    }
}
