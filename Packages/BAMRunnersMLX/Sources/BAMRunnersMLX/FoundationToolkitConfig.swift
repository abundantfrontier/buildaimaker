import Foundation

/// User-configured path to Apple’s Adapter Training Toolkit (external download).
///
/// Stored in UserDefaults so Train UI can re-use it across launches. The toolkit
/// is **not** shipped with BuildAIMaker (Apple Developer Program download).
public struct FoundationToolkitConfig: Sendable, Equatable {
    public static let userDefaultsKey = "bam.foundationToolkitRoot"
    public static let pythonUserDefaultsKey = "bam.foundationToolkitPython"

    /// Absolute path to toolkit root (contains `examples/`, `export/`, `requirements.txt`).
    public var toolkitRoot: String?
    /// Optional Python executable (default: `python3` on PATH).
    public var pythonExecutable: String?

    public init(toolkitRoot: String? = nil, pythonExecutable: String? = nil) {
        self.toolkitRoot = toolkitRoot
        self.pythonExecutable = pythonExecutable
    }

    public static func load(defaults: UserDefaults = .standard) -> FoundationToolkitConfig {
        FoundationToolkitConfig(
            toolkitRoot: defaults.string(forKey: userDefaultsKey),
            pythonExecutable: defaults.string(forKey: pythonUserDefaultsKey)
        )
    }

    public func save(defaults: UserDefaults = .standard) {
        if let toolkitRoot, !toolkitRoot.isEmpty {
            defaults.set(toolkitRoot, forKey: Self.userDefaultsKey)
        } else {
            defaults.removeObject(forKey: Self.userDefaultsKey)
        }
        if let pythonExecutable, !pythonExecutable.isEmpty {
            defaults.set(pythonExecutable, forKey: Self.pythonUserDefaultsKey)
        } else {
            defaults.removeObject(forKey: Self.pythonUserDefaultsKey)
        }
    }

    /// Whether the configured root looks like Apple’s adapter training toolkit.
    public func isInstalled(fileManager: FileManager = .default) -> Bool {
        guard let root = toolkitRoot, !root.isEmpty else { return false }
        let url = URL(fileURLWithPath: root, isDirectory: true)
        let markers = [
            "examples/train_adapter.py",
            "export/export_fmadapter.py",
            "requirements.txt",
        ]
        return markers.contains { rel in
            fileManager.fileExists(atPath: url.appendingPathComponent(rel).path)
        }
    }

    public var resolvedPython: String {
        let trimmed = pythonExecutable?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "python3" : trimmed
    }
}

/// Probe result for Train UI.
public struct FoundationToolkitProbe: Sendable, Equatable {
    public var config: FoundationToolkitConfig
    public var installed: Bool
    public var detail: String

    public init(config: FoundationToolkitConfig, installed: Bool, detail: String) {
        self.config = config
        self.installed = installed
        self.detail = detail
    }

    public static func probe(
        config: FoundationToolkitConfig = .load(),
        fileManager: FileManager = .default
    ) -> FoundationToolkitProbe {
        if config.toolkitRoot == nil || config.toolkitRoot?.isEmpty == true {
            return FoundationToolkitProbe(
                config: config,
                installed: false,
                detail: "No toolkit path set. Download Apple’s Adapter Training Toolkit and point Train at its folder."
            )
        }
        if config.isInstalled(fileManager: fileManager) {
            return FoundationToolkitProbe(
                config: config,
                installed: true,
                detail: "Toolkit detected at \(config.toolkitRoot ?? "")"
            )
        }
        return FoundationToolkitProbe(
            config: config,
            installed: false,
            detail: "Path set but toolkit markers missing (need examples/train_adapter.py). Check the folder."
        )
    }
}
