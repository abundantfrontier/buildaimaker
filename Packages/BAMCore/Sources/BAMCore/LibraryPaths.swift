import Foundation

/// Canonical on-disk layout under Application Support.
///
/// Root: `~/Library/Application Support/BuildAIMaker/`
public enum LibraryPaths: Sendable {
    public static let applicationSupportDirectoryName = "BuildAIMaker"

    /// `~/Library/Application Support/BuildAIMaker`
    public static var libraryRoot: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return appSupport.appendingPathComponent(applicationSupportDirectoryName, isDirectory: true)
    }

    public static var configFile: URL {
        libraryRoot.appendingPathComponent("config.json", isDirectory: false)
    }

    public static var libraryDatabase: URL {
        libraryRoot.appendingPathComponent("library.sqlite", isDirectory: false)
    }

    public static var libraryDatabaseBackup: URL {
        libraryRoot.appendingPathComponent("library.sqlite.bak", isDirectory: false)
    }

    public static var datasets: URL {
        libraryRoot.appendingPathComponent("datasets", isDirectory: true)
    }

    public static var modelsBase: URL {
        libraryRoot.appendingPathComponent("models/base", isDirectory: true)
    }

    public static var modelsAdapters: URL {
        libraryRoot.appendingPathComponent("models/adapters", isDirectory: true)
    }

    /// Apple Foundation Models adapter packages (`.fmadapter`), separate from open PEFT LoRA.
    public static var modelsFoundationAdapters: URL {
        libraryRoot.appendingPathComponent("models/foundation-adapters", isDirectory: true)
    }

    public static var voices: URL {
        libraryRoot.appendingPathComponent("voices", isDirectory: true)
    }

    public static var jobs: URL {
        libraryRoot.appendingPathComponent("jobs", isDirectory: true)
    }

    public static var personas: URL {
        libraryRoot.appendingPathComponent("personas", isDirectory: true)
    }

    public static var consent: URL {
        libraryRoot.appendingPathComponent("consent", isDirectory: true)
    }

    public static var pythonEnvs: URL {
        libraryRoot.appendingPathComponent("envs/python", isDirectory: true)
    }

    public static var downloadCache: URL {
        libraryRoot.appendingPathComponent("cache/downloads", isDirectory: true)
    }

    public static func datasetDirectory(id: String) -> URL {
        datasets.appendingPathComponent(sanitizedPathComponent(id), isDirectory: true)
    }

    public static func baseModelDirectory(id: String) -> URL {
        modelsBase.appendingPathComponent(sanitizedPathComponent(id), isDirectory: true)
    }

    public static func adapterDirectory(id: String) -> URL {
        modelsAdapters.appendingPathComponent(sanitizedPathComponent(id), isDirectory: true)
    }

    public static func foundationAdapterDirectory(id: String) -> URL {
        modelsFoundationAdapters.appendingPathComponent(sanitizedPathComponent(id), isDirectory: true)
    }

    public static func voiceDirectory(id: String) -> URL {
        voices.appendingPathComponent(sanitizedPathComponent(id), isDirectory: true)
    }

    public static func jobDirectory(id: String) -> URL {
        jobs.appendingPathComponent(sanitizedPathComponent(id), isDirectory: true)
    }

    public static func personaDirectory(id: String) -> URL {
        personas.appendingPathComponent(sanitizedPathComponent(id), isDirectory: true)
    }

    public static func pythonEnvDirectory(appVersion: String) -> URL {
        pythonEnvs.appendingPathComponent(sanitizedPathComponent(appVersion), isDirectory: true)
    }

    /// Returns a single safe path component, or `nil` if `raw` is empty, `.`, `..`,
    /// or contains path separators / null bytes.
    ///
    /// Callers that need hard rejection should use this before I/O; directory
    /// helpers fall back to `"_invalid"` so a bad id cannot escape its parent folder.
    public static func validatedPathComponent(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed != ".", trimmed != ".." else { return nil }
        guard !trimmed.contains("/"), !trimmed.contains("\\"), !trimmed.contains("\0") else {
            return nil
        }
        // Reject multi-segment inputs even if separators were encoded oddly.
        let asURLComponent = (trimmed as NSString).lastPathComponent
        guard asURLComponent == trimmed else { return nil }
        return trimmed
    }

    /// Sanitizes an id for use as a single path component under the library root.
    public static func sanitizedPathComponent(_ raw: String) -> String {
        validatedPathComponent(raw) ?? "_invalid"
    }

    /// Environment variable names pinned for workers.
    public enum EnvironmentKey {
        public static let libraryRoot = "BAM_LIBRARY_ROOT"
        public static let modelCache = "BAM_MODEL_CACHE"
        public static let redactSamples = "BAM_REDACT_SAMPLES"
    }
}
