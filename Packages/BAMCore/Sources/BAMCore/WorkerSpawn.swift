import Foundation

/// Supervisor-facing spawn gate: resolve a `bam-*-worker` helper and run L1
/// `WorkerTrust` **before** any `Process` launch.
///
/// Real process supervision lands in a later PR; all UI/supervisor paths must
/// call `prepareHelperLaunch` so L1 cannot be skipped by accident.
public enum WorkerSpawn: Sendable {
    public static let llmWorkerName = "bam-llm-worker"
    public static let voiceWorkerName = "bam-voice-worker"

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

        let cwd = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
        var dir = cwd
        for _ in 0..<8 {
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
        return nil
    }
}
