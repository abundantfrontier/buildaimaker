import Foundation

/// Paths for managed Python runtime install + pin files.
///
/// Env lives under Application Support; pin artifacts ship with the app (or repo
/// tree in development) and are **not** the same tree as the venv.
public enum RuntimePaths: Sendable {
    /// Repo-relative / bundle-relative root for lockfile + entry modules.
    public static let pythonPinsDirectoryName = "Workers/python"

    public static let lockfileName = "requirements.lock"
    public static let pinsFileName = "runtime-pins.json"
    public static let pinsSchemaFileName = "runtime-pins.schema.json"

    /// Default app version used when CFBundleShortVersionString is unavailable (spike).
    public static let spikeAppVersion = "0.1.0"

    /// Managed venv root for an app version:
    /// `~/Library/Application Support/BuildAIMaker/envs/python/<appVersion>/`
    public static func managedEnvRoot(appVersion: String = spikeAppVersion) -> URL {
        LibraryPaths.pythonEnvDirectory(appVersion: appVersion)
    }

    /// Expected interpreter under the managed env (`bin/python3` by default).
    public static func managedInterpreter(
        appVersion: String = spikeAppVersion,
        relativePath: String = "bin/python3"
    ) -> URL {
        managedEnvRoot(appVersion: appVersion).appendingPathComponent(relativePath, isDirectory: false)
    }

    /// Resolve pins root: explicit override, else `BAM_PYTHON_PINS_ROOT`, else
    /// sibling `Workers/python` relative to CWD / package layout heuristics.
    public static func resolvePinsRoot(
        override: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL? {
        if let override { return override.standardizedFileURL }

        if let envPath = environment["BAM_PYTHON_PINS_ROOT"], !envPath.isEmpty {
            return URL(fileURLWithPath: envPath, isDirectory: true).standardizedFileURL
        }

        // Walk from CWD upward looking for Workers/python/runtime-pins.json
        var dir = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
        for _ in 0..<8 {
            let candidate = dir
                .appendingPathComponent("Workers/python", isDirectory: true)
            let pins = candidate.appendingPathComponent(pinsFileName, isDirectory: false)
            if fileManager.fileExists(atPath: pins.path) {
                return candidate.standardizedFileURL
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        return nil
    }

    public static func pinsFile(in pinsRoot: URL) -> URL {
        pinsRoot.appendingPathComponent(pinsFileName, isDirectory: false)
    }

    public static func lockfile(in pinsRoot: URL) -> URL {
        pinsRoot.appendingPathComponent(lockfileName, isDirectory: false)
    }

    /// Environment keys used by the helper / installer.
    public enum EnvironmentKey {
        public static let pythonPinsRoot = "BAM_PYTHON_PINS_ROOT"
        public static let managedEnvRoot = "BAM_MANAGED_ENV_ROOT"
        /// When `1`, helper skips interpreter-exists check (CI / unit paths).
        public static let skipInterpreterCheck = "BAM_SKIP_INTERPRETER_CHECK"
    }
}
