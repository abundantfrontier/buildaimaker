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
///
/// **Repair path:** delete managed env root, then re-run install stub / future
/// real install. Pin mismatches surface as `BAM_RUNTIME_INTEGRITY` via
/// `recheckIntegrity()` / `status().lastError` — Settings CTA is always
/// ``RuntimeRecovery/repairActionTitle``.
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
        let recheck = recheckIntegrity(fileManager: fileManager)
        if !recheck.isOK {
            lastError = recheck.detail
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

    /// Explicit L2 re-check for Settings / recovery UX.
    ///
    /// When pins are missing (dev tree not present), returns OK with a soft
    /// detail so install CTA still works. Hard failures use
    /// `BAM_RUNTIME_INTEGRITY`.
    public func recheckIntegrity(
        fileManager: FileManager = .default
    ) -> RuntimeIntegrityRecheckResult {
        let root = envRoot()
        let pins = loadPins()
        guard let pins else {
            return RuntimeIntegrityRecheckResult(
                isOK: true,
                detail: "runtime-pins.json not resolved (dev / not bundled yet)"
            )
        }
        guard let pinsRoot = pinsRoot ?? RuntimePaths.resolvePinsRoot() else {
            return RuntimeIntegrityRecheckResult(
                isOK: true,
                detail: "pins root not resolved"
            )
        }

        let interpreterRel = pins.interpreterRelativePath
        let interpreter = root.appendingPathComponent(interpreterRel, isDirectory: false)
        let installed = fileManager.fileExists(atPath: interpreter.path)

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
            return .ok
        } catch let error as BAMError {
            return RuntimeIntegrityRecheckResult(
                isOK: false,
                detail: error.errorDescription ?? error.code.rawValue,
                code: error.code
            )
        } catch {
            return RuntimeIntegrityRecheckResult(
                isOK: false,
                detail: String(describing: error),
                code: .runtimeIntegrity
            )
        }
    }

    /// Delete the managed env root for this app version (repair step 1).
    ///
    /// Safe to call when the env is missing. Does **not** touch pins under the
    /// app / repo tree.
    public func wipeManagedEnv(fileManager: FileManager = .default) throws {
        let root = envRoot()
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDir) else {
            return
        }
        // Refuse to wipe anything outside Application Support envs tree.
        let envsRoot = LibraryPaths.pythonEnvs.resolvingSymlinksInPath().standardizedFileURL
        let rootReal = root.resolvingSymlinksInPath().standardizedFileURL
        guard RuntimeIntegrity.isPath(rootReal, under: envsRoot) else {
            throw BAMError(
                code: .pathEscape,
                message: "refusing to wipe env outside managed python envs: \(root.path)"
            )
        }
        try fileManager.removeItem(at: root)
    }

    /// Repair = wipe managed env + reinstall from lock (stub install in CI).
    ///
    /// Real multi-GB download still deferred; this wires the product recovery
    /// path end-to-end so UI / tests can exercise wipe + re-check.
    public func repair(
        onProgress: @Sendable (RuntimeInstallProgress) -> Void = { _ in },
        fileManager: FileManager = .default
    ) async -> Result<Void, BAMError> {
        let pins = loadPins()
        let budget = pins?.effectiveSizeBudgetBytes ?? RuntimePins.defaultSizeBudgetBytes
        let label = pins?.effectiveSizeBudgetLabel ?? "3–8 GB"

        onProgress(RuntimeInstallProgress(
            phase: .preparing,
            bytesReceived: 0,
            bytesExpected: budget,
            message: "Repair: removing managed environment…"
        ))

        do {
            try wipeManagedEnv(fileManager: fileManager)
        } catch let error as BAMError {
            return .failure(error)
        } catch {
            return .failure(BAMError(
                code: .runtimeIntegrity,
                message: "repair wipe failed: \(error.localizedDescription)"
            ))
        }

        onProgress(RuntimeInstallProgress(
            phase: .downloading,
            bytesReceived: 0,
            bytesExpected: budget,
            message: "Repair: reinstalling managed Python (\(label))…"
        ))

        return await installStub(onProgress: onProgress)
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
