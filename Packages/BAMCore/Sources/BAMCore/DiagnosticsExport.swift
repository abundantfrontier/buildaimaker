import Foundation

/// Options for a local diagnostics bundle (support / bug reports).
public struct DiagnosticsExportOptions: Sendable, Equatable {
    /// Maximum number of recent job directories to include (by mtime).
    public var maxJobs: Int
    /// When true, rewrite `events.jsonl` log lines through `LogRedaction`.
    public var redactEventLogs: Bool
    /// Include `worker.stderr.log` when present (still redacted line-wise).
    public var includeWorkerStderr: Bool

    public init(
        maxJobs: Int = 20,
        redactEventLogs: Bool = true,
        includeWorkerStderr: Bool = true
    ) {
        self.maxJobs = maxJobs
        self.redactEventLogs = redactEventLogs
        self.includeWorkerStderr = includeWorkerStderr
    }

    public static let `default` = DiagnosticsExportOptions()
}

/// Manifest written as `diagnostics-manifest.json`.
public struct DiagnosticsManifest: Codable, Sendable, Equatable {
    public static let formatVersionV1 = 1

    public var formatVersion: Int
    public var exportedAt: String
    public var appName: String
    public var runnerProtocolVersion: Int
    public var librarySchemaVersion: Int
    public var personaPackFormat: Int
    public var appVersionPin: String
    public var includedJobIds: [String]
    public var notes: [String]

    public init(
        formatVersion: Int = DiagnosticsManifest.formatVersionV1,
        exportedAt: String,
        appName: String = AppIdentity.displayName,
        runnerProtocolVersion: Int = ProtocolVersions.runnerProtocolVersion,
        librarySchemaVersion: Int = ProtocolVersions.librarySchemaVersion,
        personaPackFormat: Int = ProtocolVersions.personaPackFormat,
        appVersionPin: String = RuntimePaths.spikeAppVersion,
        includedJobIds: [String],
        notes: [String]
    ) {
        self.formatVersion = formatVersion
        self.exportedAt = exportedAt
        self.appName = appName
        self.runnerProtocolVersion = runnerProtocolVersion
        self.librarySchemaVersion = librarySchemaVersion
        self.personaPackFormat = personaPackFormat
        self.appVersionPin = appVersionPin
        self.includedJobIds = includedJobIds
        self.notes = notes
    }
}

/// Outcome of a successful diagnostics export.
public struct DiagnosticsExportResult: Sendable, Equatable {
    public var destinationURL: URL
    public var includedJobIds: [String]
    public var manifest: DiagnosticsManifest
    public var filesWritten: [String]

    public init(
        destinationURL: URL,
        includedJobIds: [String],
        manifest: DiagnosticsManifest,
        filesWritten: [String]
    ) {
        self.destinationURL = destinationURL
        self.includedJobIds = includedJobIds
        self.manifest = manifest
        self.filesWritten = filesWritten
    }
}

/// Builds a redacted diagnostics folder: versions, runtime status, job events.
///
/// Does **not** include dataset files or model weights. Event log lines are
/// passed through `LogRedaction` by default.
public enum DiagnosticsExporter: Sendable {
    public static let manifestFileName = "diagnostics-manifest.json"
    public static let versionsFileName = "versions.json"
    public static let runtimeStatusFileName = "runtime-status.json"
    public static let featureFlagsFileName = "feature-flags.json"

    /// Export diagnostics under `destinationURL` (created if needed).
    ///
    /// - Parameters:
    ///   - libraryRoot: Application Support library root (or test fixture).
    ///   - destinationURL: Empty or new directory for the bundle.
    ///   - options: Job limit + redaction.
    ///   - featureFlags: Snapshot written to `feature-flags.json`.
    ///   - appVersion: Managed env pin version.
    ///   - now: Clock for timestamps.
    @discardableResult
    public static func export(
        libraryRoot: URL,
        to destinationURL: URL,
        options: DiagnosticsExportOptions = .default,
        featureFlags: FeatureFlags = .default,
        appVersion: String = RuntimePaths.spikeAppVersion,
        fileManager: FileManager = .default,
        now: Date = Date(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> DiagnosticsExportResult {
        try fileManager.createDirectory(at: destinationURL, withIntermediateDirectories: true)

        var filesWritten: [String] = []
        let exportedAt = iso8601(now)

        // versions.json
        let versions: [String: Any] = [
            "appName": AppIdentity.displayName,
            "bundleIDPlaceholder": AppIdentity.bundleIDPlaceholder,
            "runnerProtocolVersion": ProtocolVersions.runnerProtocolVersion,
            "librarySchemaVersion": ProtocolVersions.librarySchemaVersion,
            "personaPackFormat": ProtocolVersions.personaPackFormat,
            "appVersionPin": appVersion,
            "exportedAt": exportedAt,
            "minimumUnifiedMemoryGB": AppIdentity.minimumUnifiedMemoryGB,
        ]
        try writeJSONObject(versions, to: destinationURL.appendingPathComponent(versionsFileName))
        filesWritten.append(versionsFileName)

        // runtime-status.json
        let installer = RuntimeInstaller(appVersion: appVersion)
        let status = installer.status(fileManager: fileManager)
        let integrity = installer.recheckIntegrity(fileManager: fileManager)
        let runtimePayload: [String: Any] = [
            "isInstalled": status.isInstalled,
            "appVersion": status.appVersion,
            "envRoot": status.envRoot.path,
            "sizeBudgetLabel": status.sizeBudgetLabel,
            "sizeBudgetBytes": status.sizeBudgetBytes,
            "lastError": status.lastError as Any,
            "integrityOK": integrity.isOK,
            "integrityDetail": integrity.detail as Any,
            "repairAction": RuntimeRecovery.repairActionTitle,
            "settingsPath": RuntimeRecovery.settingsPathHint,
        ]
        try writeJSONObject(
            runtimePayload,
            to: destinationURL.appendingPathComponent(runtimeStatusFileName)
        )
        filesWritten.append(runtimeStatusFileName)

        // feature-flags.json
        var flagsDict: [String: Bool] = [:]
        for key in FeatureFlags.Key.allCases {
            flagsDict[key.rawValue] = featureFlags.isEnabled(key)
        }
        try writeJSONObject(
            flagsDict,
            to: destinationURL.appendingPathComponent(featureFlagsFileName)
        )
        filesWritten.append(featureFlagsFileName)

        // jobs/<id>/events.jsonl (+ optional logs)
        let jobIds = try copyRecentJobs(
            libraryRoot: libraryRoot,
            destination: destinationURL,
            options: options,
            fileManager: fileManager,
            environment: environment,
            filesWritten: &filesWritten
        )

        var notes = [
            "Dataset files and model weights are intentionally omitted.",
            "Log lines redacted with BAM_REDACT_SAMPLES policy when redactEventLogs is true.",
            "On BAM_RUNTIME_INTEGRITY: \(RuntimeRecovery.shortCTA)",
        ]
        if !integrity.isOK {
            notes.append("Runtime integrity check failed at export time.")
        }

        let manifest = DiagnosticsManifest(
            exportedAt: exportedAt,
            appVersionPin: appVersion,
            includedJobIds: jobIds,
            notes: notes
        )
        let manifestURL = destinationURL.appendingPathComponent(manifestFileName)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(manifest).write(to: manifestURL, options: .atomic)
        filesWritten.append(manifestFileName)

        return DiagnosticsExportResult(
            destinationURL: destinationURL,
            includedJobIds: jobIds,
            manifest: manifest,
            filesWritten: filesWritten
        )
    }

    // MARK: - Jobs

    private static func copyRecentJobs(
        libraryRoot: URL,
        destination: URL,
        options: DiagnosticsExportOptions,
        fileManager: FileManager,
        environment: [String: String],
        filesWritten: inout [String]
    ) throws -> [String] {
        let jobsRoot = libraryRoot.appendingPathComponent("jobs", isDirectory: true)
        guard fileManager.fileExists(atPath: jobsRoot.path) else { return [] }

        let contents = (try? fileManager.contentsOfDirectory(
            at: jobsRoot,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        struct JobDir {
            var id: String
            var url: URL
            var mtime: Date
        }

        var dirs: [JobDir] = []
        for url in contents {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
            guard values?.isDirectory == true else { continue }
            let id = url.lastPathComponent
            guard LibraryPaths.validatedPathComponent(id) != nil else { continue }
            dirs.append(JobDir(id: id, url: url, mtime: values?.contentModificationDate ?? .distantPast))
        }
        dirs.sort { $0.mtime > $1.mtime }
        let selected = Array(dirs.prefix(max(0, options.maxJobs)))

        let outJobs = destination.appendingPathComponent("jobs", isDirectory: true)
        try fileManager.createDirectory(at: outJobs, withIntermediateDirectories: true)

        var ids: [String] = []
        for job in selected {
            ids.append(job.id)
            let destJob = outJobs.appendingPathComponent(job.id, isDirectory: true)
            try fileManager.createDirectory(at: destJob, withIntermediateDirectories: true)

            // job.json (paths only — no sample text expected)
            let jobJSON = job.url.appendingPathComponent("job.json")
            if fileManager.fileExists(atPath: jobJSON.path) {
                let dest = destJob.appendingPathComponent("job.json")
                try? fileManager.copyItem(at: jobJSON, to: dest)
                filesWritten.append("jobs/\(job.id)/job.json")
            }

            // events.jsonl — redacted
            let eventsSrc = job.url.appendingPathComponent("events.jsonl")
            if fileManager.fileExists(atPath: eventsSrc.path) {
                let dest = destJob.appendingPathComponent("events.jsonl")
                if options.redactEventLogs {
                    try writeRedactedEvents(
                        from: eventsSrc,
                        to: dest,
                        environment: environment
                    )
                } else {
                    try fileManager.copyItem(at: eventsSrc, to: dest)
                }
                filesWritten.append("jobs/\(job.id)/events.jsonl")
            }

            // heartbeat.json
            let hb = job.url.appendingPathComponent("heartbeat.json")
            if fileManager.fileExists(atPath: hb.path) {
                let dest = destJob.appendingPathComponent("heartbeat.json")
                try? fileManager.copyItem(at: hb, to: dest)
                filesWritten.append("jobs/\(job.id)/heartbeat.json")
            }

            if options.includeWorkerStderr {
                let stderr = job.url
                    .appendingPathComponent("logs", isDirectory: true)
                    .appendingPathComponent("worker.stderr.log")
                if fileManager.fileExists(atPath: stderr.path) {
                    let logsDir = destJob.appendingPathComponent("logs", isDirectory: true)
                    try fileManager.createDirectory(at: logsDir, withIntermediateDirectories: true)
                    let dest = logsDir.appendingPathComponent("worker.stderr.log")
                    if options.redactEventLogs {
                        try writeRedactedTextFile(
                            from: stderr,
                            to: dest,
                            environment: environment
                        )
                    } else {
                        try fileManager.copyItem(at: stderr, to: dest)
                    }
                    filesWritten.append("jobs/\(job.id)/logs/worker.stderr.log")
                }
            }
        }
        return ids
    }

    private static func writeRedactedEvents(
        from source: URL,
        to dest: URL,
        environment: [String: String]
    ) throws {
        let raw = try String(contentsOf: source, encoding: .utf8)
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false)
        var out: [String] = []
        out.reserveCapacity(lines.count)
        for line in lines {
            let s = String(line)
            if s.isEmpty {
                out.append(s)
                continue
            }
            out.append(redactEventsJSONLLine(s, environment: environment))
        }
        try out.joined(separator: "\n").write(to: dest, atomically: true, encoding: .utf8)
    }

    /// Best-effort: if line is JSON with a `message` field, redact that field.
    private static func redactEventsJSONLLine(
        _ line: String,
        environment: [String: String]
    ) -> String {
        guard let data = line.data(using: .utf8),
              var obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return LogRedaction.redactForDefaultLog(line, environment: environment)
        }
        if let msg = obj["message"] as? String {
            obj["message"] = LogRedaction.redactMessage(
                msg,
                level: (obj["level"] as? String) ?? "info",
                environment: environment
            )
        }
        guard let outData = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
              let out = String(data: outData, encoding: .utf8)
        else {
            return LogRedaction.redactForDefaultLog(line, environment: environment)
        }
        return out
    }

    private static func writeRedactedTextFile(
        from source: URL,
        to dest: URL,
        environment: [String: String]
    ) throws {
        let raw = try String(contentsOf: source, encoding: .utf8)
        let redacted = raw
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { LogRedaction.redactForDefaultLog(String($0), environment: environment) }
            .joined(separator: "\n")
        try redacted.write(to: dest, atomically: true, encoding: .utf8)
    }

    private static func writeJSONObject(_ object: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: url, options: .atomic)
    }

    private static func iso8601(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }
}
