import BAMCore
import BAMModels
import Foundation

/// Result of installing a base model into the library.
public struct ModelInstallResult: Sendable, Equatable {
    public var modelRecord: ModelRecord
    /// True when the destination already existed and files were replaced / verified.
    public var alreadyPresent: Bool

    public init(modelRecord: ModelRecord, alreadyPresent: Bool) {
        self.modelRecord = modelRecord
        self.alreadyPresent = alreadyPresent
    }
}

/// Installs base models into `LibraryPaths.modelsBase` (offline fixture or optional HF Hub).
///
/// **Default path (CI / offline):** copy the bundled tiny fixture into
/// `models/base/tiny-qwen-mlx-fixture/`. No network.
///
/// **Optional HF path:** only when `hfHubDownloadEnabled` is true; uses
/// `HFHubClient` + token from `HFTokenStore`. Unit tests never enable this.
public struct ModelInstallService: Sendable {
    public let modelsBaseURL: URL
    public let fixtureSourceURL: URL
    public let hfHubDownloadEnabled: Bool
    public let tokenStore: any HFTokenStore
    public let hubClient: any HFHubClient

    public init(
        modelsBaseURL: URL = LibraryPaths.modelsBase,
        fixtureSourceURL: URL? = nil,
        hfHubDownloadEnabled: Bool = false,
        tokenStore: any HFTokenStore = InMemoryHFTokenStore(),
        hubClient: any HFHubClient = NoopHFHubClient()
    ) {
        self.modelsBaseURL = modelsBaseURL
        self.fixtureSourceURL = fixtureSourceURL ?? Self.bundledFixtureURL()
        self.hfHubDownloadEnabled = hfHubDownloadEnabled
        self.tokenStore = tokenStore
        self.hubClient = hubClient
    }

    // MARK: - Offline fixture

    /// Destination directory for the fixture under `models/base`.
    public var fixtureInstallDirectory: URL {
        modelsBaseURL.appendingPathComponent(FixtureModel.installDirectoryName, isDirectory: true)
    }

    /// Whether the fixture appears installed (required files present under install dir).
    public func isFixtureInstalled() -> Bool {
        Self.layoutLooksValid(at: fixtureInstallDirectory)
    }

    /// Copies the bundled tiny fixture into `models/base/tiny-qwen-mlx-fixture/`.
    ///
    /// - Parameter overwrite: When true, replaces an existing install. Default true.
    /// - Returns: `ModelRecord` pointing at the install path.
    /// - Throws: `BAM_MODEL_NOT_FOUND` if the fixture source is missing;
    ///   `BAM_PATH_ESCAPE` if the destination escapes `modelsBaseURL`.
    public func installFixture(overwrite: Bool = true) throws -> ModelInstallResult {
        let fm = FileManager.default
        let source = fixtureSourceURL
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: source.path, isDirectory: &isDir), isDir.boolValue else {
            throw BAMError(
                code: .modelNotFound,
                message: "Fixture source missing at \(source.path)"
            )
        }
        guard Self.layoutLooksValid(at: source) else {
            throw BAMError(
                code: .modelNotFound,
                message: "Fixture source incomplete at \(source.path) (missing required files)"
            )
        }

        let dest = fixtureInstallDirectory
        try ensureDestinationUnderModelsBase(dest)

        let alreadyPresent = fm.fileExists(atPath: dest.path)
        if alreadyPresent {
            if !overwrite {
                let record = makeFixtureRecord(localPath: dest.path)
                return ModelInstallResult(modelRecord: record, alreadyPresent: true)
            }
            try fm.removeItem(at: dest)
        }

        try fm.createDirectory(at: modelsBaseURL, withIntermediateDirectories: true)
        try fm.copyItem(at: source, to: dest)

        // Path jail after copy (symlink escape defense).
        let resolvedDest = dest.resolvingSymlinksInPath().standardizedFileURL
        let resolvedBase = modelsBaseURL.resolvingSymlinksInPath().standardizedFileURL
        guard LocalModelScanner.isPath(resolvedDest, under: resolvedBase) else {
            try? fm.removeItem(at: dest)
            throw BAMError(
                code: .pathEscape,
                message: "Installed fixture resolved outside models/base"
            )
        }

        guard Self.layoutLooksValid(at: dest) else {
            throw BAMError(
                code: .modelNotFound,
                message: "Fixture install incomplete at \(dest.path)"
            )
        }

        let record = makeFixtureRecord(localPath: dest.path)
        return ModelInstallResult(modelRecord: record, alreadyPresent: alreadyPresent)
    }

    // MARK: - Optional HF Hub

    /// Downloads a catalog model from Hugging Face Hub when `hfHubDownloadEnabled`.
    ///
    /// **Not used in CI.** Throws `BAM_CAPABILITY_UNSUPPORTED` when the flag is off.
    public func downloadFromHub(
        sourceKey: String,
        modelID: String = BAMID.generate()
    ) async throws -> ModelInstallResult {
        guard hfHubDownloadEnabled else {
            throw BAMError(
                code: .capabilityUnsupported,
                message: "HF Hub download is disabled (ff.hfHubDownload is off). Use installFixture() for offline CI."
            )
        }

        let trimmed = sourceKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw BAMError(code: .schemaInvalid, message: "Empty sourceKey for HF download")
        }

        guard let dirName = LibraryPaths.validatedPathComponent(modelID) else {
            throw BAMError(code: .pathEscape, message: "Invalid model id for install path")
        }

        let dest = modelsBaseURL.appendingPathComponent(dirName, isDirectory: true)
        try ensureDestinationUnderModelsBase(dest)

        let fm = FileManager.default
        try fm.createDirectory(at: modelsBaseURL, withIntermediateDirectories: true)
        if fm.fileExists(atPath: dest.path) {
            try fm.removeItem(at: dest)
        }
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)

        let token = try tokenStore.loadToken()
        do {
            try await hubClient.download(
                sourceKey: trimmed,
                destinationDirectory: dest,
                token: token
            )
        } catch let error as BAMError {
            try? fm.removeItem(at: dest)
            throw error
        } catch {
            try? fm.removeItem(at: dest)
            throw BAMError(
                code: .downloadFailed,
                message: "HF download failed for \(trimmed): \(error.localizedDescription)"
            )
        }

        let record = ModelRecord(
            id: modelID,
            sourceKey: trimmed,
            name: trimmed,
            kind: .base,
            localPath: dest.path,
            metaJSON: #"{"source":"huggingface_hub"}"#
        )
        return ModelInstallResult(modelRecord: record, alreadyPresent: false)
    }

    // MARK: - Bundle / workers paths

    /// URL of the fixture directory embedded in the BAMModelCatalog module bundle.
    public static func bundledFixtureURL() -> URL {
        if let url = Bundle.module.url(
            forResource: FixtureModel.bundleResourceDirectory,
            withExtension: nil,
            subdirectory: "fixtures"
        ) {
            return url
        }
        // Some SPM layouts flatten copy resources.
        if let url = Bundle.module.url(
            forResource: FixtureModel.bundleResourceDirectory,
            withExtension: nil
        ) {
            return url
        }
        // Fallback path relative to resources (still may not exist — install will error clearly).
        return Bundle.module.bundleURL
            .appendingPathComponent("fixtures", isDirectory: true)
            .appendingPathComponent(FixtureModel.bundleResourceDirectory, isDirectory: true)
    }

    /// Locates the living `Workers/fixtures/models/tiny-qwen-mlx` by walking up from a file path.
    public static func workersFixtureURL(startingAt filePath: String = #filePath) -> URL? {
        var url = URL(fileURLWithPath: filePath)
        for _ in 0..<10 {
            url = url.deletingLastPathComponent()
            let candidate = url
                .appendingPathComponent("Workers/fixtures/models/tiny-qwen-mlx", isDirectory: true)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    // MARK: - Helpers

    private func makeFixtureRecord(localPath: String) -> ModelRecord {
        ModelRecord(
            id: FixtureModel.stableModelID,
            sourceKey: FixtureModel.sourceKey,
            name: FixtureModel.displayName,
            kind: .base,
            archFamily: FixtureModel.archFamily,
            paramCountB: 0.001,
            quantBits: 16,
            license: FixtureModel.license,
            localPath: localPath,
            metaJSON: #"{"fixture":true,"weightsIncluded":false}"#
        )
    }

    private func ensureDestinationUnderModelsBase(_ dest: URL) throws {
        let resolvedDest = dest.standardizedFileURL
        let resolvedBase = modelsBaseURL.resolvingSymlinksInPath().standardizedFileURL
        // Before create: planned path's parent must be models base.
        let parent = resolvedDest.deletingLastPathComponent().standardizedFileURL
        let baseStd = modelsBaseURL.standardizedFileURL
        guard parent.path == baseStd.path || parent.path == resolvedBase.path
                || LocalModelScanner.isPath(parent, under: resolvedBase)
                || LocalModelScanner.isPath(parent, under: baseStd)
        else {
            throw BAMError(
                code: .pathEscape,
                message: "Install destination \(dest.path) is not under models/base"
            )
        }
        guard LibraryPaths.validatedPathComponent(dest.lastPathComponent) != nil else {
            throw BAMError(
                code: .pathEscape,
                message: "Invalid install directory name \(dest.lastPathComponent)"
            )
        }
    }

    /// True when required fixture / model metadata files exist at `directory`.
    public static func layoutLooksValid(at directory: URL) -> Bool {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: directory.path, isDirectory: &isDir), isDir.boolValue else {
            return false
        }
        for name in FixtureModel.requiredFiles {
            let file = directory.appendingPathComponent(name, isDirectory: false)
            if !fm.fileExists(atPath: file.path) {
                return false
            }
        }
        return true
    }
}
