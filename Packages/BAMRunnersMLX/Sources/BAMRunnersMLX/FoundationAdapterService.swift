import BAMCore
import BAMModels
import Foundation

/// Installed Apple Foundation adapter under `models/foundation-adapters/<id>/`.
public struct FoundationAdapterRecord: Sendable, Equatable, Identifiable {
    public var id: String
    public var directoryURL: URL
    /// Absolute path to `.fmadapter` package (or placeholder).
    public var packagePath: String
    public var displayName: String
    public var baseModelSignature: String?
    public var source: FoundationAdapterSource
    public var isFake: Bool
    public var characterName: String?
    public var datasetId: String?

    public init(
        id: String,
        directoryURL: URL,
        packagePath: String,
        displayName: String,
        baseModelSignature: String? = nil,
        source: FoundationAdapterSource,
        isFake: Bool,
        characterName: String? = nil,
        datasetId: String? = nil
    ) {
        self.id = id
        self.directoryURL = directoryURL
        self.packagePath = packagePath
        self.displayName = displayName
        self.baseModelSignature = baseModelSignature
        self.source = source
        self.isFake = isFake
        self.characterName = characterName
        self.datasetId = datasetId
    }
}

public enum FoundationAdapterSource: String, Codable, Sendable, Equatable {
    case importPackage = "import"
    case fake
    case toolkit
}

public struct FoundationAdapterPublishResult: Sendable, Equatable {
    public var artifactId: String
    public var directoryURL: URL
    public var packageURL: URL
    public var metadataURL: URL
    public var record: ArtifactRecord
    public var isFake: Bool

    public init(
        artifactId: String,
        directoryURL: URL,
        packageURL: URL,
        metadataURL: URL,
        record: ArtifactRecord,
        isFake: Bool
    ) {
        self.artifactId = artifactId
        self.directoryURL = directoryURL
        self.packageURL = packageURL
        self.metadataURL = metadataURL
        self.record = record
        self.isFake = isFake
    }
}

public struct FoundationToolkitExportResult: Sendable, Equatable {
    public var exportDirectory: URL
    public var trainJSONLURL: URL
    public var evalJSONLURL: URL
    public var readmeURL: URL
    public var trainRowCount: Int
    public var evalRowCount: Int

    public init(
        exportDirectory: URL,
        trainJSONLURL: URL,
        evalJSONLURL: URL,
        readmeURL: URL,
        trainRowCount: Int,
        evalRowCount: Int
    ) {
        self.exportDirectory = exportDirectory
        self.trainJSONLURL = trainJSONLURL
        self.evalJSONLURL = evalJSONLURL
        self.readmeURL = readmeURL
        self.trainRowCount = trainRowCount
        self.evalRowCount = evalRowCount
    }
}

/// Library helpers for Apple Foundation Models adapters (export / import / stub / list).
///
/// Real training uses Apple’s external Adapter Training Toolkit; this service
/// prepares mind datasets, registers `.fmadapter` packages, and publishes CI-safe stubs.
public struct FoundationAdapterService: @unchecked Sendable {
    public var libraryRoot: URL
    public var fileManager: FileManager

    public static let packageFileName = "adapter.fmadapter"
    public static let metadataFileName = "foundation_adapter.json"
    public static let cardFileName = "model_card.md"

    public init(
        libraryRoot: URL = LibraryPaths.libraryRoot,
        fileManager: FileManager = .default
    ) {
        self.libraryRoot = libraryRoot
        self.fileManager = fileManager
    }

    public var foundationAdaptersRoot: URL {
        libraryRoot.appendingPathComponent("models/foundation-adapters", isDirectory: true)
    }

    // MARK: - Signature

    /// Best-effort system model signature for OS-revision coupling.
    public static func currentSystemSignature() -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            // No stable public revision API across betas — encode OS version.
            let v = ProcessInfo.processInfo.operatingSystemVersion
            return String(format: "macos-%d.%d.%d", v.majorVersion, v.minorVersion, v.patchVersion)
        }
        #endif
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return String(format: "host-%d.%d.%d", v.majorVersion, v.minorVersion, v.patchVersion)
    }

    /// Compare stored adapter signature to the current host.
    /// Returns nil when signatures match or either side is missing; otherwise a user-facing warning.
    public static func signatureMismatchWarning(
        stored: String?,
        current: String = currentSystemSignature()
    ) -> String? {
        guard let stored, !stored.isEmpty else { return nil }
        // Compare major.minor when both use macos-/host- prefixes.
        let storedKey = signatureCompatibilityKey(stored)
        let currentKey = signatureCompatibilityKey(current)
        if storedKey == currentKey { return nil }
        return """
        Foundation adapter was built for \(stored) but this Mac reports \(current). \
        OS updates can invalidate Apple adapters — retrain or re-import for this system model revision.
        """
    }

    /// Coarse key so patch bumps alone are less noisy (macos-26.0.x → macos-26.0).
    public static func signatureCompatibilityKey(_ signature: String) -> String {
        let parts = signature.split(separator: ".")
        if parts.count >= 2 {
            return parts.prefix(2).joined(separator: ".")
        }
        return signature
    }

    /// Read metadata from an adapter directory (or package path’s parent).
    public func metadata(at adapterPath: String) -> FoundationAdapterRecord? {
        let url = URL(fileURLWithPath: adapterPath)
        var isDir: ObjCBool = false
        if fileManager.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            return try? loadRecord(directory: url)
        }
        // Package file → parent directory.
        let parent = url.deletingLastPathComponent()
        return try? loadRecord(directory: parent)
    }

    // MARK: - Export for Apple toolkit

    /// Convert OpenAI-messages JSONL into toolkit-friendly train/eval splits + README.
    public func exportDatasetForToolkit(
        sourceJSONLURL: URL,
        outputDirectory: URL,
        evalFraction: Double = 0.15
    ) throws -> FoundationToolkitExportResult {
        try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let raw = try String(contentsOf: sourceJSONLURL, encoding: .utf8)
        let lines = raw
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !lines.isEmpty else {
            throw BAMError(code: .schemaInvalid, message: "Dataset JSONL is empty — nothing to export for Apple toolkit.")
        }

        // Stable split: last ~evalFraction rows → eval (at least 1 when n≥2).
        let n = lines.count
        let evalCount: Int
        if n < 2 {
            evalCount = 0
        } else {
            evalCount = max(1, min(n - 1, Int((Double(n) * evalFraction).rounded(.up))))
        }
        let trainCount = n - evalCount
        let trainLines = Array(lines.prefix(trainCount))
        let evalLines = Array(lines.suffix(evalCount))

        let trainURL = outputDirectory.appendingPathComponent("train.jsonl")
        let evalURL = outputDirectory.appendingPathComponent("valid.jsonl")
        let readmeURL = outputDirectory.appendingPathComponent("README-apple-adapter.md")

        try (trainLines.joined(separator: "\n") + "\n").write(to: trainURL, atomically: true, encoding: .utf8)
        try (evalLines.joined(separator: "\n") + (evalLines.isEmpty ? "" : "\n"))
            .write(to: evalURL, atomically: true, encoding: .utf8)

        let readme = """
        # Apple Foundation adapter — BuildAIMaker export

        Exported for use with Apple’s **Adapter Training Toolkit**
        (https://developer.apple.com/apple-intelligence/foundation-models-adapter/).

        ## Files

        - `train.jsonl` — \(trainLines.count) rows (OpenAI-style messages)
        - `valid.jsonl` — \(evalLines.count) rows (eval/hold-out)

        Basic toolkit schema is prompt/response pairs; your character mind corpus is
        already multi-turn messages. Convert or map roles as the toolkit Schema.md requires.

        ## Example train command (after installing the toolkit)

        ```
        python -m examples.train_adapter \\
          --train-data \(trainURL.path) \\
          --eval-data \(evalURL.path) \\
          --epochs 5 \\
          --learning-rate 1e-3 \\
          --batch-size 4 \\
          --checkpoint-dir ./checkpoints/
        ```

        ## Export package

        ```
        python -m export.export_fmadapter \\
          --adapter-name my_character \\
          --checkpoint ./checkpoints/adapter-final.pt \\
          --output-dir ./exports/
        ```

        Then in BuildAIMaker: **Train → Apple Foundation Adapter → Import .fmadapter**.

        System signature at export: \(Self.currentSystemSignature())
        """
        try readme.write(to: readmeURL, atomically: true, encoding: .utf8)

        return FoundationToolkitExportResult(
            exportDirectory: outputDirectory,
            trainJSONLURL: trainURL,
            evalJSONLURL: evalURL,
            readmeURL: readmeURL,
            trainRowCount: trainLines.count,
            evalRowCount: evalLines.count
        )
    }

    // MARK: - Import / stub publish

    /// Copy a `.fmadapter` (file or package directory) into the library.
    public func importFMAdapter(
        sourceURL: URL,
        artifactId: String = BAMID.generate(),
        displayName: String? = nil,
        characterName: String? = nil,
        datasetId: String? = nil,
        baseModelSignature: String? = nil
    ) throws -> FoundationAdapterPublishResult {
        let name = displayName
            ?? sourceURL.deletingPathExtension().lastPathComponent
        return try publishPackage(
            sourcePackageURL: sourceURL,
            artifactId: artifactId,
            displayName: name,
            source: .importPackage,
            isFake: false,
            characterName: characterName,
            datasetId: datasetId,
            baseModelSignature: baseModelSignature ?? Self.currentSystemSignature()
        )
    }

    /// CI/dogfood stub when the Apple toolkit is not run in-app.
    public func publishStub(
        artifactId: String = BAMID.generate(),
        displayName: String = "Foundation adapter (stub)",
        characterName: String? = nil,
        datasetId: String? = nil
    ) throws -> FoundationAdapterPublishResult {
        let dir = foundationAdaptersRoot
            .appendingPathComponent(LibraryPaths.sanitizedPathComponent(artifactId), isDirectory: true)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)

        let packageURL = dir.appendingPathComponent(Self.packageFileName)
        let payload = """
        BAM_FOUNDATION_ADAPTER_STUB
        signature=\(Self.currentSystemSignature())
        character=\(characterName ?? "")
        dataset=\(datasetId ?? "")
        """
        try Data(payload.utf8).write(to: packageURL, options: .atomic)

        return try finalizePublish(
            artifactId: artifactId,
            directory: dir,
            packageURL: packageURL,
            displayName: displayName,
            source: .fake,
            isFake: true,
            characterName: characterName,
            datasetId: datasetId,
            baseModelSignature: Self.currentSystemSignature()
        )
    }

    // MARK: - List

    public func listInstalled() throws -> [FoundationAdapterRecord] {
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: foundationAdaptersRoot.path, isDirectory: &isDir),
              isDir.boolValue
        else {
            return []
        }
        let contents = try fileManager.contentsOfDirectory(
            at: foundationAdaptersRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        var out: [FoundationAdapterRecord] = []
        for url in contents {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
            guard values?.isDirectory == true else { continue }
            let id = url.lastPathComponent
            guard LibraryPaths.validatedPathComponent(id) != nil else { continue }
            if let rec = try? loadRecord(directory: url) {
                out.append(rec)
            } else {
                let pkg = findPackage(in: url)
                out.append(
                    FoundationAdapterRecord(
                        id: id,
                        directoryURL: url,
                        packagePath: pkg?.path ?? url.path,
                        displayName: id,
                        baseModelSignature: nil,
                        source: .importPackage,
                        isFake: false
                    )
                )
            }
        }
        return out.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    // MARK: - Private

    private func publishPackage(
        sourcePackageURL: URL,
        artifactId: String,
        displayName: String,
        source: FoundationAdapterSource,
        isFake: Bool,
        characterName: String?,
        datasetId: String?,
        baseModelSignature: String
    ) throws -> FoundationAdapterPublishResult {
        guard fileManager.fileExists(atPath: sourcePackageURL.path) else {
            throw BAMError(
                code: .schemaInvalid,
                message: "Adapter package not found: \(sourcePackageURL.path)"
            )
        }
        let dir = foundationAdaptersRoot
            .appendingPathComponent(LibraryPaths.sanitizedPathComponent(artifactId), isDirectory: true)
        if fileManager.fileExists(atPath: dir.path) {
            try fileManager.removeItem(at: dir)
        }
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)

        let destPackage = dir.appendingPathComponent(preferredPackageName(for: sourcePackageURL))
        if isDirectory(sourcePackageURL) {
            try fileManager.copyItem(at: sourcePackageURL, to: destPackage)
        } else {
            try fileManager.copyItem(at: sourcePackageURL, to: destPackage)
        }

        return try finalizePublish(
            artifactId: artifactId,
            directory: dir,
            packageURL: destPackage,
            displayName: displayName,
            source: source,
            isFake: isFake,
            characterName: characterName,
            datasetId: datasetId,
            baseModelSignature: baseModelSignature
        )
    }

    private func finalizePublish(
        artifactId: String,
        directory: URL,
        packageURL: URL,
        displayName: String,
        source: FoundationAdapterSource,
        isFake: Bool,
        characterName: String?,
        datasetId: String?,
        baseModelSignature: String
    ) throws -> FoundationAdapterPublishResult {
        let metaURL = directory.appendingPathComponent(Self.metadataFileName)
        var clean: [String: Any] = [
            "kind": ArtifactKind.foundationAdapter.rawValue,
            "artifactId": artifactId,
            "displayName": displayName,
            "source": source.rawValue,
            "fake": isFake,
            "baseModelSignature": baseModelSignature,
            "packageFile": packageURL.lastPathComponent,
            "createdAt": ISO8601DateFormatter().string(from: Date()),
        ]
        if let characterName { clean["characterName"] = characterName }
        if let datasetId { clean["datasetId"] = datasetId }
        let data = try JSONSerialization.data(withJSONObject: clean, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: metaURL, options: .atomic)

        let card = """
        # \(displayName)

        - **Kind:** Apple Foundation adapter
        - **Artifact id:** \(artifactId)
        - **Source:** \(source.rawValue)\(isFake ? " (stub)" : "")
        - **System signature:** \(baseModelSignature)
        - **Package:** \(packageURL.lastPathComponent)

        Load in Playground with backend **Apple on-device** and this adapter selected.
        Real adapters require a matching OS / system model revision.
        """
        try card.write(
            to: directory.appendingPathComponent(Self.cardFileName),
            atomically: true,
            encoding: .utf8
        )

        let record = ArtifactRecord(
            id: artifactId,
            kind: .foundationAdapter,
            jobId: nil,
            baseModelId: "apple-foundation",
            localPath: directory.path,
            metricsJSON: nil,
            createdAt: ISO8601DateFormatter().string(from: Date())
        )

        return FoundationAdapterPublishResult(
            artifactId: artifactId,
            directoryURL: directory,
            packageURL: packageURL,
            metadataURL: metaURL,
            record: record,
            isFake: isFake
        )
    }

    private func loadRecord(directory: URL) throws -> FoundationAdapterRecord {
        let metaURL = directory.appendingPathComponent(Self.metadataFileName)
        let data = try Data(contentsOf: metaURL)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let id = obj["artifactId"] as? String ?? directory.lastPathComponent
        let display = obj["displayName"] as? String ?? id
        let sourceRaw = obj["source"] as? String ?? FoundationAdapterSource.importPackage.rawValue
        let source = FoundationAdapterSource(rawValue: sourceRaw) ?? .importPackage
        let fake = obj["fake"] as? Bool ?? false
        let signature = obj["baseModelSignature"] as? String
        let packageFile = obj["packageFile"] as? String
        let packageURL: URL
        if let packageFile {
            packageURL = directory.appendingPathComponent(packageFile)
        } else {
            packageURL = findPackage(in: directory) ?? directory
        }
        return FoundationAdapterRecord(
            id: id,
            directoryURL: directory,
            packagePath: packageURL.path,
            displayName: display,
            baseModelSignature: signature,
            source: source,
            isFake: fake,
            characterName: obj["characterName"] as? String,
            datasetId: obj["datasetId"] as? String
        )
    }

    private func findPackage(in directory: URL) -> URL? {
        let preferred = directory.appendingPathComponent(Self.packageFileName)
        if fileManager.fileExists(atPath: preferred.path) { return preferred }
        let contents = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return contents.first { $0.pathExtension.lowercased() == "fmadapter" }
    }

    private func preferredPackageName(for source: URL) -> String {
        if source.pathExtension.lowercased() == "fmadapter" {
            return source.lastPathComponent
        }
        if isDirectory(source) {
            return source.lastPathComponent.hasSuffix(".fmadapter")
                ? source.lastPathComponent
                : "\(source.lastPathComponent).fmadapter"
        }
        return Self.packageFileName
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }
}
