import BAMCore
import BAMModels
import Foundation

/// Result of an Apple Foundation adapter train attempt (toolkit or stub).
public struct FoundationToolkitTrainResult: Sendable, Equatable {
    public var usedToolkit: Bool
    public var fakeTrain: Bool
    public var publish: FoundationAdapterPublishResult?
    public var export: FoundationToolkitExportResult?
    public var message: String
    public var logLines: [String]

    public init(
        usedToolkit: Bool,
        fakeTrain: Bool,
        publish: FoundationAdapterPublishResult?,
        export: FoundationToolkitExportResult?,
        message: String,
        logLines: [String] = []
    ) {
        self.usedToolkit = usedToolkit
        self.fakeTrain = fakeTrain
        self.publish = publish
        self.export = export
        self.message = message
        self.logLines = logLines
    }
}

/// Orchestrates export → (optional) Apple toolkit CLI → import/publish.
///
/// Real train requires a user-installed toolkit. Without it, or when
/// `forceFakeTrain` is true, publishes a library stub (CI / dogfood).
public struct FoundationToolkitTrainService: @unchecked Sendable {
    public var libraryRoot: URL
    public var adapterService: FoundationAdapterService
    public var config: FoundationToolkitConfig
    public var forceFakeTrain: Bool
    public var fileManager: FileManager
    /// Process runner timeout for each toolkit CLI step (seconds).
    public var processTimeoutSeconds: TimeInterval

    public init(
        libraryRoot: URL = LibraryPaths.libraryRoot,
        adapterService: FoundationAdapterService? = nil,
        config: FoundationToolkitConfig = .load(),
        forceFakeTrain: Bool = false,
        fileManager: FileManager = .default,
        processTimeoutSeconds: TimeInterval = 3_600
    ) {
        self.libraryRoot = libraryRoot
        self.adapterService = adapterService ?? FoundationAdapterService(libraryRoot: libraryRoot)
        self.config = config
        self.forceFakeTrain = forceFakeTrain
        self.fileManager = fileManager
        self.processTimeoutSeconds = processTimeoutSeconds
    }

    /// End-to-end: export mind JSONL, train via toolkit when available, publish adapter.
    public func train(
        sourceJSONLURL: URL,
        jobDir: URL,
        artifactId: String = BAMID.generate(),
        displayName: String = "Foundation adapter",
        characterName: String? = nil,
        datasetId: String? = nil,
        epochs: Int = 3,
        learningRate: Double = 1e-3,
        batchSize: Int = 4
    ) throws -> FoundationToolkitTrainResult {
        var logs: [String] = []
        let exportDir = jobDir.appendingPathComponent("foundation-export", isDirectory: true)
        let export = try adapterService.exportDatasetForToolkit(
            sourceJSONLURL: sourceJSONLURL,
            outputDirectory: exportDir
        )
        logs.append("Exported train=\(export.trainRowCount) eval=\(export.evalRowCount)")

        let probe = FoundationToolkitProbe.probe(config: config, fileManager: fileManager)
        let canToolkit = !forceFakeTrain && probe.installed

        if !canToolkit {
            let publish = try adapterService.publishStub(
                artifactId: artifactId,
                displayName: displayName + (forceFakeTrain ? " (stub)" : " (stub — no toolkit)"),
                characterName: characterName,
                datasetId: datasetId
            )
            logs.append(probe.detail)
            logs.append("Published stub adapter at \(publish.directoryURL.path)")
            return FoundationToolkitTrainResult(
                usedToolkit: false,
                fakeTrain: true,
                publish: publish,
                export: export,
                message: forceFakeTrain
                    ? "Forced stub train (no toolkit CLI)."
                    : "Toolkit not available — stub published. Export is ready for offline toolkit train.",
                logLines: logs
            )
        }

        // Toolkit path: train_adapter → export_fmadapter → import.
        let checkpointDir = jobDir.appendingPathComponent("checkpoints", isDirectory: true)
        let exportOut = jobDir.appendingPathComponent("fmadapter-export", isDirectory: true)
        try fileManager.createDirectory(at: checkpointDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: exportOut, withIntermediateDirectories: true)

        let root = URL(fileURLWithPath: config.toolkitRoot!, isDirectory: true)
        let python = config.resolvedPython
        let adapterName = LibraryPaths.sanitizedPathComponent(displayName.replacingOccurrences(of: " ", with: "_"))

        do {
            logs.append("Running examples.train_adapter…")
            let trainLog = try runPythonModule(
                python: python,
                module: "examples.train_adapter",
                arguments: [
                    "--train-data", export.trainJSONLURL.path,
                    "--eval-data", export.evalJSONLURL.path,
                    "--epochs", String(max(1, epochs)),
                    "--learning-rate", String(learningRate),
                    "--batch-size", String(max(1, batchSize)),
                    "--checkpoint-dir", checkpointDir.path,
                ],
                cwd: root
            )
            logs.append(contentsOf: trainLog.suffix(20))

            let checkpoint = preferCheckpoint(in: checkpointDir) ?? checkpointDir.appendingPathComponent("adapter-final.pt")
            logs.append("Exporting fmadapter from \(checkpoint.lastPathComponent)…")
            let exportLog = try runPythonModule(
                python: python,
                module: "export.export_fmadapter",
                arguments: [
                    "--adapter-name", adapterName,
                    "--checkpoint", checkpoint.path,
                    "--output-dir", exportOut.path,
                ],
                cwd: root
            )
            logs.append(contentsOf: exportLog.suffix(10))

            guard let package = findFMAdapter(in: exportOut) else {
                throw BAMError(
                    code: .capabilityUnsupported,
                    message: "Toolkit finished but no .fmadapter found under \(exportOut.path)"
                )
            }

            let publish = try adapterService.importFMAdapter(
                sourceURL: package,
                artifactId: artifactId,
                displayName: displayName,
                characterName: characterName,
                datasetId: datasetId,
                baseModelSignature: FoundationAdapterService.currentSystemSignature()
            )
            // Mark source as toolkit in metadata by re-writing source field.
            try rewriteSourceToToolkit(directory: publish.directoryURL)

            logs.append("Published toolkit adapter at \(publish.directoryURL.path)")
            return FoundationToolkitTrainResult(
                usedToolkit: true,
                fakeTrain: false,
                publish: publish,
                export: export,
                message: "Apple toolkit train succeeded.",
                logLines: logs
            )
        } catch {
            // Fall back to stub so the job can still complete for dogfood.
            logs.append("Toolkit CLI failed: \(error.localizedDescription)")
            let publish = try adapterService.publishStub(
                artifactId: artifactId,
                displayName: displayName + " (stub after toolkit error)",
                characterName: characterName,
                datasetId: datasetId
            )
            logs.append("Fell back to stub at \(publish.directoryURL.path)")
            return FoundationToolkitTrainResult(
                usedToolkit: false,
                fakeTrain: true,
                publish: publish,
                export: export,
                message: "Toolkit failed — stub published. See logs. Error: \(error.localizedDescription)",
                logLines: logs
            )
        }
    }

    // MARK: - Process helpers

    private func runPythonModule(
        python: String,
        module: String,
        arguments: [String],
        cwd: URL
    ) throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: which(python) ?? python)
        process.arguments = ["-m", module] + arguments
        process.currentDirectoryURL = cwd
        process.environment = ProcessInfo.processInfo.environment

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        try process.run()

        let deadline = Date().addingTimeInterval(processTimeoutSeconds)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.2)
        }
        if process.isRunning {
            process.terminate()
            throw BAMError(
                code: .workerHung,
                message: "Toolkit module \(module) timed out after \(Int(processTimeoutSeconds))s"
            )
        }

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        let combined = (String(data: outData, encoding: .utf8) ?? "")
            + (String(data: errData, encoding: .utf8) ?? "")
        let lines = combined
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.isEmpty }

        guard process.terminationStatus == 0 else {
            throw BAMError(
                code: .workerCrash,
                message: "python -m \(module) exit \(process.terminationStatus): \(lines.suffix(5).joined(separator: " | "))"
            )
        }
        return lines
    }

    private func which(_ name: String) -> String? {
        if name.contains("/") { return name }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [name]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (path?.isEmpty == false) ? path : nil
    }

    private func preferCheckpoint(in dir: URL) -> URL? {
        let names = ["adapter-final.pt", "adapter_final.pt", "final.pt"]
        for n in names {
            let u = dir.appendingPathComponent(n)
            if fileManager.fileExists(atPath: u.path) { return u }
        }
        let contents = (try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return contents.first { $0.pathExtension == "pt" || $0.pathExtension == "pth" }
    }

    private func findFMAdapter(in dir: URL) -> URL? {
        let contents = (try? fileManager.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        if let file = contents.first(where: { $0.pathExtension.lowercased() == "fmadapter" }) {
            return file
        }
        // Nested package directory ending in .fmadapter
        return contents.first { url in
            var isDir: ObjCBool = false
            return fileManager.fileExists(atPath: url.path, isDirectory: &isDir)
                && isDir.boolValue
                && url.lastPathComponent.lowercased().hasSuffix(".fmadapter")
        }
    }

    private func rewriteSourceToToolkit(directory: URL) throws {
        let metaURL = directory.appendingPathComponent(FoundationAdapterService.metadataFileName)
        guard let data = try? Data(contentsOf: metaURL),
              var obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        obj["source"] = FoundationAdapterSource.toolkit.rawValue
        obj["fake"] = false
        let out = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
        try out.write(to: metaURL, options: .atomic)
    }
}
