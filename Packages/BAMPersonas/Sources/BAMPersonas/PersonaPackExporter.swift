import BAMCore
import BAMModels
import CryptoKit
import Foundation

/// Builds Pack Format v1 zip from a resolved persona + optional embedded files.
public struct PersonaPackExporter: Sendable {
    public var fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// Export inputs: resolved persona plus optional on-disk embeds.
    public struct ExportContext: Sendable {
        public var resolved: ResolvedPersona
        public var consent: ConsentRecord?
        /// Absolute path to adapter directory to embed under `llm/adapter/` (optional open LoRA).
        public var adapterDirectory: URL?
        /// Absolute path to Foundation adapter directory to embed under `llm/foundation_adapter/`.
        public var foundationAdapterDirectory: URL?
        /// Absolute path to reference wav to embed as `voice/reference.wav` (optional).
        public var voiceReferenceURL: URL?
        /// License text files: base_model / voice_engine.
        public var baseModelLicenseText: String?
        public var voiceEngineLicenseText: String?
        public var createdAt: String

        public init(
            resolved: ResolvedPersona,
            consent: ConsentRecord? = nil,
            adapterDirectory: URL? = nil,
            foundationAdapterDirectory: URL? = nil,
            voiceReferenceURL: URL? = nil,
            baseModelLicenseText: String? = nil,
            voiceEngineLicenseText: String? = nil,
            createdAt: String = ISO8601DateFormatter().string(from: Date())
        ) {
            self.resolved = resolved
            self.consent = consent
            self.adapterDirectory = adapterDirectory
            self.foundationAdapterDirectory = foundationAdapterDirectory
            self.voiceReferenceURL = voiceReferenceURL
            self.baseModelLicenseText = baseModelLicenseText
            self.voiceEngineLicenseText = voiceEngineLicenseText
            self.createdAt = createdAt
        }
    }

    public struct ExportResult: Sendable, Equatable {
        public var zipURL: URL
        public var manifest: PersonaPackManifest
        public var stagingDirectory: URL

        public init(zipURL: URL, manifest: PersonaPackManifest, stagingDirectory: URL) {
            self.zipURL = zipURL
            self.manifest = manifest
            self.stagingDirectory = stagingDirectory
        }
    }

    /// Materializes pack contents into `stagingDirectory`, zips to `zipURL`.
    @discardableResult
    public func export(
        context: ExportContext,
        stagingDirectory: URL,
        zipURL: URL
    ) throws -> ExportResult {
        let fm = fileManager
        if fm.fileExists(atPath: stagingDirectory.path) {
            try fm.removeItem(at: stagingDirectory)
        }
        try fm.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)

        let doc = context.resolved.document
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]

        // persona.json — nested composition (ids; no absolute host paths; no knowledge keys).
        let personaData = try encoder.encode(doc)
        try write(personaData, relative: "persona.json", under: stagingDirectory)

        // llm/base_ref.json
        if let base = context.resolved.base {
            let ref = PersonaPackBaseRef(
                baseModelId: base.id,
                sourceKey: base.sourceKey,
                contentHash: base.contentHash,
                name: base.name,
                license: base.license
            )
            try write(try encoder.encode(ref), relative: "llm/base_ref.json", under: stagingDirectory)
        } else if let baseId = doc.llm?.baseModelId {
            let ref = PersonaPackBaseRef(baseModelId: baseId)
            try write(try encoder.encode(ref), relative: "llm/base_ref.json", under: stagingDirectory)
        }

        // llm/adapter/ (optional open LoRA embed)
        if let adapterDir = context.adapterDirectory,
           fm.fileExists(atPath: adapterDir.path)
        {
            let dest = stagingDirectory.appendingPathComponent("llm/adapter", isDirectory: true)
            try copyDirectoryContents(from: adapterDir, to: dest)
        }

        // llm/foundation_adapter/ + foundation_ref.json (optional Apple FM embed)
        if let foundationDir = context.foundationAdapterDirectory,
           fm.fileExists(atPath: foundationDir.path)
        {
            let dest = stagingDirectory.appendingPathComponent("llm/foundation_adapter", isDirectory: true)
            try copyDirectoryContents(from: foundationDir, to: dest)
            let artId = doc.llm?.foundationAdapterArtifactId
                ?? foundationDir.lastPathComponent
            let packageRel: String?
            if fm.fileExists(atPath: dest.appendingPathComponent("adapter.fmadapter").path) {
                packageRel = "llm/foundation_adapter/adapter.fmadapter"
            } else {
                packageRel = "llm/foundation_adapter"
            }
            let ref = PersonaPackFoundationRef(
                foundationAdapterArtifactId: artId,
                baseModelSignature: doc.llm?.baseModelSignature,
                packageRelativePath: packageRel
            )
            try write(try encoder.encode(ref), relative: "llm/foundation_ref.json", under: stagingDirectory)
        } else if let artId = doc.llm?.foundationAdapterArtifactId {
            let ref = PersonaPackFoundationRef(
                foundationAdapterArtifactId: artId,
                baseModelSignature: doc.llm?.baseModelSignature
            )
            try write(try encoder.encode(ref), relative: "llm/foundation_ref.json", under: stagingDirectory)
        }

        // voice/profile.json + optional reference
        if let voice = context.resolved.voice {
            var refRel: String?
            if let refURL = context.voiceReferenceURL, fm.fileExists(atPath: refURL.path) {
                refRel = "voice/reference.wav"
                let dest = stagingDirectory.appendingPathComponent(refRel!)
                try fm.createDirectory(
                    at: dest.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try fm.copyItem(at: refURL, to: dest)
            }
            let packVoice = PersonaPackVoiceProfile(
                id: voice.id,
                engineId: voice.engineId,
                consentRecordId: voice.consentRecordId,
                consentContentHash: voice.consentContentHash,
                createdAt: voice.createdAt,
                referenceRelativePath: refRel
            )
            try write(
                try encoder.encode(packVoice),
                relative: "voice/profile.json",
                under: stagingDirectory
            )
        }

        // consent/consent.json
        var exportAllowed = true
        var consentHash: String?
        if let consent = context.consent {
            guard try consent.verifyContentHash() else {
                throw BAMError(
                    code: .consentTamper,
                    message: "Cannot export: consent contentHash invalid"
                )
            }
            try write(
                try encoder.encode(consent),
                relative: "consent/consent.json",
                under: stagingDirectory
            )
            consentHash = ConsentRecord.normalizeHash(consent.contentHash)
            if consent.scope == .personalUse {
                exportAllowed = false
            }
        }

        // licenses/
        if let text = context.baseModelLicenseText, !text.isEmpty {
            try write(
                Data(text.utf8),
                relative: "licenses/base_model.txt",
                under: stagingDirectory
            )
        }
        if let text = context.voiceEngineLicenseText, !text.isEmpty {
            try write(
                Data(text.utf8),
                relative: "licenses/voice_engine.txt",
                under: stagingDirectory
            )
        }

        // File digests (everything except manifest itself)
        let digests = try hashAllFiles(under: stagingDirectory)
        let manifest = PersonaPackManifest(
            formatVersion: PersonaPackManifest.formatVersionV1,
            personaId: doc.id,
            personaName: doc.name,
            personaVersion: doc.version,
            files: digests,
            exportAllowed: exportAllowed,
            createdAt: context.createdAt,
            consentContentHash: consentHash
        )
        try write(try encoder.encode(manifest), relative: "manifest.json", under: stagingDirectory)

        // Re-hash including manifest for the on-disk zip integrity list
        // Design: manifest includes SHA-256 of each file (not including itself typically).
        // Keep digests as pre-manifest files; import verifies those paths.

        try ZipArchive.createZip(ofContentsOf: stagingDirectory, to: zipURL)
        return ExportResult(zipURL: zipURL, manifest: manifest, stagingDirectory: stagingDirectory)
    }

    // MARK: - Internals

    private func write(_ data: Data, relative: String, under root: URL) throws {
        let url = root.appendingPathComponent(relative)
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }

    private func copyDirectoryContents(from source: URL, to dest: URL) throws {
        try fileManager.createDirectory(at: dest, withIntermediateDirectories: true)
        let items = try fileManager.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        for item in items {
            let target = dest.appendingPathComponent(item.lastPathComponent)
            if fileManager.fileExists(atPath: target.path) {
                try fileManager.removeItem(at: target)
            }
            try fileManager.copyItem(at: item, to: target)
        }
    }

    private func hashAllFiles(under root: URL) throws -> [String: String] {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return [:]
        }
        var result: [String: String] = [:]
        let rootPath = root.standardizedFileURL.path
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(rootPath) else { continue }
            var rel = String(path.dropFirst(rootPath.count))
            if rel.hasPrefix("/") { rel = String(rel.dropFirst()) }
            guard !rel.isEmpty, rel != "manifest.json" else { continue }
            result[rel] = try Self.sha256Hex(of: url)
        }
        return result
    }

    public static func sha256Hex(of url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return sha256Hex(data)
    }

    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
