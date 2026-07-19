import Foundation

/// Install / repair state for the managed training runtime (spike).
///
/// Does **not** download multi-GB wheels. Real install lands with training PRs.
public enum RuntimeInstallPhase: String, Sendable, Equatable, Codable {
    case idle
    case preparing
    case downloading
    case verifying
    case complete
    case failed
}

/// Progress snapshot for Settings UI.
public struct RuntimeInstallProgress: Sendable, Equatable {
    public var phase: RuntimeInstallPhase
    public var bytesReceived: Int64
    public var bytesExpected: Int64
    public var message: String

    public init(
        phase: RuntimeInstallPhase = .idle,
        bytesReceived: Int64 = 0,
        bytesExpected: Int64 = RuntimePins.defaultSizeBudgetBytes,
        message: String = ""
    ) {
        self.phase = phase
        self.bytesReceived = bytesReceived
        self.bytesExpected = bytesExpected
        self.message = message
    }

    public var fractionCompleted: Double {
        guard bytesExpected > 0 else { return 0 }
        return min(1.0, Double(bytesReceived) / Double(bytesExpected))
    }
}

/// Describes whether the managed env is present and pin-consistent.
public struct RuntimeInstallStatus: Sendable, Equatable {
    public var isInstalled: Bool
    public var appVersion: String
    public var envRoot: URL
    public var sizeBudgetLabel: String
    public var sizeBudgetBytes: Int64
    public var lastError: String?

    public init(
        isInstalled: Bool,
        appVersion: String,
        envRoot: URL,
        sizeBudgetLabel: String,
        sizeBudgetBytes: Int64,
        lastError: String? = nil
    ) {
        self.isInstalled = isInstalled
        self.appVersion = appVersion
        self.envRoot = envRoot
        self.sizeBudgetLabel = sizeBudgetLabel
        self.sizeBudgetBytes = sizeBudgetBytes
        self.lastError = lastError
    }
}

/// Spike installer: probes paths, reports size budget, never downloads wheels.
public struct RuntimeInstaller: Sendable {
    public var appVersion: String
    public var pinsRoot: URL?

    public init(appVersion: String = RuntimePaths.spikeAppVersion, pinsRoot: URL? = nil) {
        self.appVersion = appVersion
        self.pinsRoot = pinsRoot
    }

    public func envRoot() -> URL {
        RuntimePaths.managedEnvRoot(appVersion: appVersion)
    }

    /// Load pins when available; fall back to documented budget defaults.
    public func loadPins() -> RuntimePins? {
        guard let root = pinsRoot ?? RuntimePaths.resolvePinsRoot() else { return nil }
        return try? RuntimePins.load(from: RuntimePaths.pinsFile(in: root))
    }

    public func status(fileManager: FileManager = .default) -> RuntimeInstallStatus {
        let pins = loadPins()
        let budgetLabel = pins?.effectiveSizeBudgetLabel ?? "3–8 GB"
        let budgetBytes = pins?.effectiveSizeBudgetBytes ?? RuntimePins.defaultSizeBudgetBytes
        let root = envRoot()
        let interpreterRel = pins?.interpreterRelativePath ?? "bin/python3"
        let interpreter = root.appendingPathComponent(interpreterRel, isDirectory: false)
        let installed = fileManager.fileExists(atPath: interpreter.path)

        var lastError: String?
        if let pins, let pinsRoot = pinsRoot ?? RuntimePaths.resolvePinsRoot() {
            do {
                try RuntimeIntegrity.verify(
                    pins: pins,
                    pinsRoot: pinsRoot,
                    options: RuntimeIntegrity.VerificationOptions(
                        requireInterpreterPresent: installed,
                        managedEnvRoot: root
                    ),
                    fileManager: fileManager
                )
            } catch let error as BAMError {
                lastError = error.errorDescription
            } catch {
                lastError = String(describing: error)
            }
        }

        return RuntimeInstallStatus(
            isInstalled: installed,
            appVersion: appVersion,
            envRoot: root,
            sizeBudgetLabel: budgetLabel,
            sizeBudgetBytes: budgetBytes,
            lastError: lastError
        )
    }

    /// Simulated install for UI wiring. Does not download.
    ///
    /// Reports progress callbacks then returns `.cancelled` so Settings can show
    /// size budget + progress chrome without CI cost. **Does not** use
    /// `BAM_RUNTIME_INTEGRITY` (reserved for pin/path/signature failures).
    public func installStub(
        onProgress: @Sendable (RuntimeInstallProgress) -> Void = { _ in }
    ) async -> Result<Void, BAMError> {
        let pins = loadPins()
        let budget = pins?.effectiveSizeBudgetBytes ?? RuntimePins.defaultSizeBudgetBytes
        let label = pins?.effectiveSizeBudgetLabel ?? "3–8 GB"

        onProgress(RuntimeInstallProgress(
            phase: .preparing,
            bytesReceived: 0,
            bytesExpected: budget,
            message: "Preparing managed Python environment (\(label))…"
        ))

        try? await Task.sleep(nanoseconds: 50_000_000)

        onProgress(RuntimeInstallProgress(
            phase: .downloading,
            bytesReceived: 0,
            bytesExpected: budget,
            message: "Download deferred in this spike (budget \(label))."
        ))

        return .failure(BAMError(
            code: .cancelled,
            message: "training runtime install is a stub; multi-GB wheel download not performed (budget \(label))"
        ))
    }
}
