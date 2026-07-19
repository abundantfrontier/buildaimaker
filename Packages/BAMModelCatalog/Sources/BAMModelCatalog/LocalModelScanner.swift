import BAMCore
import BAMModels
import Foundation

/// A base-model directory discovered under `models/base`.
public struct ScannedLocalModel: Sendable, Equatable, Identifiable {
    /// Directory name under `models/base` (typically a UUID or folder slug).
    public var directoryName: String
    /// Absolute path to the model directory.
    public var localPath: String
    /// True when `config.json` is present (HF / MLX layout).
    public var hasConfigJSON: Bool
    /// True when `adapter_config.json` is present (adapter-style layout).
    public var hasAdapterConfigJSON: Bool
    /// Best-effort display name (config `model_type` / folder name).
    public var displayName: String
    /// Optional architecture / model_type hint parsed from `config.json`.
    public var modelType: String?
    /// Optional license string if present in adjacent metadata files.
    public var license: String?

    public var id: String { localPath }

    public init(
        directoryName: String,
        localPath: String,
        hasConfigJSON: Bool,
        hasAdapterConfigJSON: Bool,
        displayName: String,
        modelType: String? = nil,
        license: String? = nil
    ) {
        self.directoryName = directoryName
        self.localPath = localPath
        self.hasConfigJSON = hasConfigJSON
        self.hasAdapterConfigJSON = hasAdapterConfigJSON
        self.displayName = displayName
        self.modelType = modelType
        self.license = license
    }

    /// Maps a scan hit into a lightweight `ModelRecord` for persistence later.
    public func asModelRecord(
        id: String = BAMID.generate(),
        sourceKey: String? = nil,
        kind: ModelKind = .base
    ) -> ModelRecord {
        ModelRecord(
            id: id,
            sourceKey: sourceKey,
            name: displayName,
            kind: kind,
            archFamily: modelType,
            license: license,
            localPath: localPath
        )
    }
}

/// Scans `LibraryPaths.modelsBase` (or an override) for on-disk base models.
///
/// Missing root directories yield an empty list (not an error) so first-launch
/// and unit tests against empty temps work without setup.
public struct LocalModelScanner: Sendable {
    public let modelsBaseURL: URL

    public init(modelsBaseURL: URL = LibraryPaths.modelsBase) {
        self.modelsBaseURL = modelsBaseURL
    }

    /// Enumerates immediate child directories under `modelsBaseURL`.
    ///
    /// - Returns: Sorted by directory name. Empty when the base path is missing
    ///   or contains no subdirectories.
    public func scan() throws -> [ScannedLocalModel] {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: modelsBaseURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            return []
        }

        let contents: [URL]
        do {
            contents = try fm.contentsOfDirectory(
                at: modelsBaseURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw BAMError(
                code: .modelNotFound,
                message: "Could not list models at \(modelsBaseURL.path): \(error.localizedDescription)"
            )
        }

        var results: [ScannedLocalModel] = []
        for url in contents {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
            guard values?.isDirectory == true else { continue }

            let name = url.lastPathComponent
            // Reject path-escape style folder names even if present on disk.
            guard LibraryPaths.validatedPathComponent(name) != nil else { continue }

            let configURL = url.appendingPathComponent("config.json", isDirectory: false)
            let adapterURL = url.appendingPathComponent("adapter_config.json", isDirectory: false)
            let hasConfig = fm.fileExists(atPath: configURL.path)
            let hasAdapter = fm.fileExists(atPath: adapterURL.path)

            var modelType: String?
            var license: String?
            var displayName = name

            if hasConfig, let meta = try? Self.readConfigHints(at: configURL) {
                modelType = meta.modelType
                license = meta.license
                if let modelType, !modelType.isEmpty {
                    displayName = modelType
                }
            }

            results.append(
                ScannedLocalModel(
                    directoryName: name,
                    localPath: url.path,
                    hasConfigJSON: hasConfig,
                    hasAdapterConfigJSON: hasAdapter,
                    displayName: displayName,
                    modelType: modelType,
                    license: license
                )
            )
        }

        return results.sorted { $0.directoryName.localizedCaseInsensitiveCompare($1.directoryName) == .orderedAscending }
    }

    // MARK: - config.json hints

    private struct ConfigHints {
        var modelType: String?
        var license: String?
    }

    /// Best-effort parse of common HF/MLX `config.json` keys (unknown keys ignored).
    private static func readConfigHints(at url: URL) throws -> ConfigHints {
        let data = try Data(contentsOf: url)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ConfigHints()
        }
        let modelType = (obj["model_type"] as? String)
            ?? (obj["architectures"] as? [String])?.first
        let license = obj["license"] as? String
        return ConfigHints(modelType: modelType, license: license)
    }
}
