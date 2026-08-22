import Foundation

/// Supervisor-facing spawn gate: resolve a `bam-*-worker` helper and run L1
/// `WorkerTrust` **before** any `Process` launch.
///
/// All UI / supervisor paths **must** call `prepareHelperLaunch` (or
/// `prepareExecutableURL`) so L1 cannot be skipped. Never TeamID-check the
/// managed venv / CPython — only `Helpers/bam-*-worker` entry binaries.
public enum WorkerSpawn: Sendable {
    public static let llmWorkerName = "bam-llm-worker"
    public static let voiceWorkerName = "bam-voice-worker"
    public static let echoWorkerName = "bam-echo-worker"

    /// Result of a successful L1 prepare: URL ready for `Process.executableURL`.
    public struct PreparedHelper: Sendable, Equatable {
        public var url: URL
        public var name: String
        public var mode: WorkerTrust.Mode

        public init(url: URL, name: String, mode: WorkerTrust.Mode) {
            self.url = url
            self.name = name
            self.mode = mode
        }
    }

    /// Resolve + L1-verify a helper. Does **not** start a process.
    ///
    /// Resolution order:
    /// 1. If `bundleURL` is set → `Contents/Helpers/<name>` (Helpers jail enforced).
    /// 2. Else if `explicitHelperURL` is set → use it (basename still must match policy;
    ///    Helpers jail only if `bundleURL` also set).
    /// 3. Else search nearby `swift build` products / PATH-style dev locations.
    public static func prepareHelperLaunch(
        helperName: String = llmWorkerName,
        bundleURL: URL? = nil,
        explicitHelperURL: URL? = nil,
        mode: WorkerTrust.Mode = WorkerTrust.defaultMode,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) throws -> PreparedHelper {
        guard WorkerTrust.isAllowedHelperBasename(helperName) else {
            throw BAMError(
                code: .runtimeIntegrity,
                message: "helper name not allowed: \(helperName) (expected bam-*-worker)"
            )
        }

        let helperURL: URL
        if let bundleURL {
            helperURL = try WorkerTrust.helperURL(named: helperName, inBundle: bundleURL)
        } else if let explicitHelperURL {
            helperURL = explicitHelperURL
        } else if let dev = resolveDevelopmentHelper(
            named: helperName,
            environment: environment,
            fileManager: fileManager
        ) {
            helperURL = dev
        } else {
            throw BAMError(
                code: .runtimeIntegrity,
                message: "helper binary not found: \(helperName)"
            )
        }

        // Basename on disk must match policy (blocks python3 / arbitrary paths).
        let basename = helperURL.lastPathComponent
        guard WorkerTrust.isAllowedHelperBasename(basename) else {
            throw BAMError(
                code: .runtimeIntegrity,
                message: "refusing non-helper executable: \(basename) (only bam-*-worker; never venv/CPython)"
            )
        }

        try WorkerTrust.verifyHelperLaunch(
            helperURL: helperURL,
            mode: mode,
            expectedBundleURL: bundleURL,
            requireHelpersDirectory: bundleURL != nil,
            environment: environment,
            fileManager: fileManager
        )

        return PreparedHelper(url: helperURL, name: helperName, mode: mode)
    }

    /// L1-verify an already-resolved helper URL (e.g. from env override).
    ///
    /// Rejects non-`bam-*-worker` basenames so callers cannot pass managed
    /// Python or system interpreters.
    public static func prepareExecutableURL(
        _ executableURL: URL,
        mode: WorkerTrust.Mode = WorkerTrust.defaultMode,
        bundleURL: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) throws -> PreparedHelper {
        let name = executableURL.lastPathComponent
        return try prepareHelperLaunch(
            helperName: name,
            bundleURL: bundleURL,
            explicitHelperURL: executableURL,
            mode: mode,
            environment: environment,
            fileManager: fileManager
        )
    }

    /// Environment overlay every worker process should inherit.
    ///
    /// Always sets `BAM_REDACT_SAMPLES=1` unless the caller already set it
    /// (including explicit `0` for debug).
    public static func workerEnvironment(
        base: [String: String] = ProcessInfo.processInfo.environment,
        extra: [String: String] = [:]
    ) -> [String: String] {
        var env = base
        if env[LibraryPaths.EnvironmentKey.redactSamples] == nil {
            env[LibraryPaths.EnvironmentKey.redactSamples] = "1"
        }
        for (k, v) in extra {
            env[k] = v
        }
        return env
    }

    /// Development-only resolution: `.build/debug|release/<name>`, env override,
    /// or walk-up from CWD.
    public static func resolveDevelopmentHelper(
        named name: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL? {
        if let override = environment["BAM_HELPER_PATH"], !override.isEmpty {
            let url = URL(fileURLWithPath: override)
            if url.lastPathComponent == name || WorkerTrust.isAllowedHelperBasename(url.lastPathComponent) {
                return url
            }
        }

        let roots = RuntimePaths.processSearchRoots(fileManager: fileManager)
        for start in roots {
            let sibling = start.appendingPathComponent(name, isDirectory: false)
            if fileManager.fileExists(atPath: sibling.path) {
                return sibling
            }
            var dir = start
            for _ in 0..<10 {
                for config in ["debug", "release"] {
                    let candidate = dir
                        .appendingPathComponent(".build", isDirectory: true)
                        .appendingPathComponent(config, isDirectory: true)
                        .appendingPathComponent(name, isDirectory: false)
                    if fileManager.isExecutableFile(atPath: candidate.path)
                        || fileManager.fileExists(atPath: candidate.path)
                    {
                        return candidate
                    }
                    // Apple Silicon triple path used by SwiftPM
                    let archCandidate = dir
                        .appendingPathComponent(".build", isDirectory: true)
                        .appendingPathComponent("arm64-apple-macosx", isDirectory: true)
                        .appendingPathComponent(config, isDirectory: true)
                        .appendingPathComponent(name, isDirectory: false)
                    if fileManager.fileExists(atPath: archCandidate.path) {
                        return archCandidate
                    }
                }
                let parent = dir.deletingLastPathComponent()
                if parent.path == dir.path { break }
                dir = parent
            }
        }
        return nil
    }
}
