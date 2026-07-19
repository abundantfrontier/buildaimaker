import BAMCore
import BAMModels
import Foundation

/// Imports Pack Format v1 zip: verify digests + consent, return staged composition.
public struct PersonaPackImporter: Sendable {
    public var fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public struct ImportResult: Sendable, Equatable {
        public var document: PersonaDocument
        public var manifest: PersonaPackManifest
        public var consent: ConsentRecord?
        public var voiceProfile: PersonaPackVoiceProfile?
        public var baseRef: PersonaPackBaseRef?
        public var stagingDirectory: URL
        public var hadKnowledgeKeys: Bool
        /// Relative pack path → absolute URL for embedded files (adapter, wav, licenses).
        public var embeddedFiles: [String: URL]

        public init(
            document: PersonaDocument,
            manifest: PersonaPackManifest,
            consent: ConsentRecord? = nil,
            voiceProfile: PersonaPackVoiceProfile? = nil,
            baseRef: PersonaPackBaseRef? = nil,
            stagingDirectory: URL,
            hadKnowledgeKeys: Bool = false,
            embeddedFiles: [String: URL] = [:]
        ) {
            self.document = document
            self.manifest = manifest
            self.consent = consent
            self.voiceProfile = voiceProfile
            self.baseRef = baseRef
            self.stagingDirectory = stagingDirectory
            self.hadKnowledgeKeys = hadKnowledgeKeys
            self.embeddedFiles = embeddedFiles
        }
    }

    /// Unpacks `zipURL` into `stagingDirectory`, verifies hashes + consent integrity.
    public func importPack(
        zipURL: URL,
        stagingDirectory: URL
    ) throws -> ImportResult {
        let fm = fileManager
        if fm.fileExists(atPath: stagingDirectory.path) {
            try fm.removeItem(at: stagingDirectory)
        }
        try fm.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        try ZipArchive.extractZip(at: zipURL, to: stagingDirectory)

        let manifestURL = stagingDirectory.appendingPathComponent("manifest.json")
        guard fm.fileExists(atPath: manifestURL.path) else {
            throw BAMError(code: .schemaInvalid, message: "Pack missing manifest.json")
        }
        let manifestData = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(PersonaPackManifest.self, from: manifestData)
        guard manifest.formatVersion == ProtocolVersions.personaPackFormat else {
            throw BAMError(
                code: .protocolMismatch,
                message: "Unsupported persona pack formatVersion \(manifest.formatVersion)"
            )
        }

        // Verify listed file digests
        for (rel, expected) in manifest.files {
            if rel.contains("..") || rel.hasPrefix("/") {
                throw BAMError(code: .pathEscape, message: "Unsafe path in manifest: \(rel)")
            }
            let fileURL = stagingDirectory.appendingPathComponent(rel)
            guard fm.fileExists(atPath: fileURL.path) else {
                throw BAMError(
                    code: .schemaInvalid,
                    message: "Pack missing file listed in manifest: \(rel)"
                )
            }
            let actual = try PersonaPackExporter.sha256Hex(of: fileURL)
            if ConsentRecord.normalizeHash(actual) != ConsentRecord.normalizeHash(expected) {
                throw BAMError(
                    code: .schemaInvalid,
                    message: "Hash mismatch for \(rel)"
                )
            }
        }

        let personaURL = stagingDirectory.appendingPathComponent("persona.json")
        guard fm.fileExists(atPath: personaURL.path) else {
            throw BAMError(code: .schemaInvalid, message: "Pack missing persona.json")
        }
        let personaData = try Data(contentsOf: personaURL)
        let hadKnowledge = PersonaResolver.rawJSONContainsKnowledgeKeys(personaData)
        let document = try JSONDecoder().decode(PersonaDocument.self, from: personaData)

        // Consent
        var consent: ConsentRecord?
        let consentURL = stagingDirectory.appendingPathComponent("consent/consent.json")
        if fm.fileExists(atPath: consentURL.path) {
            let c = try JSONDecoder().decode(
                ConsentRecord.self,
                from: try Data(contentsOf: consentURL)
            )
            guard try c.verifyContentHash() else {
                throw BAMError(
                    code: .consentTamper,
                    message: "Pack consent contentHash verification failed"
                )
            }
            if let expected = manifest.consentContentHash {
                let a = ConsentRecord.normalizeHash(c.contentHash)
                let b = ConsentRecord.normalizeHash(expected)
                if a != b {
                    throw BAMError(
                        code: .consentTamper,
                        message: "Pack consent hash does not match manifest"
                    )
                }
            }
            consent = c
        }

        // Voice profile snapshot
        var voiceProfile: PersonaPackVoiceProfile?
        let voiceURL = stagingDirectory.appendingPathComponent("voice/profile.json")
        if fm.fileExists(atPath: voiceURL.path) {
            voiceProfile = try JSONDecoder().decode(
                PersonaPackVoiceProfile.self,
                from: try Data(contentsOf: voiceURL)
            )
            if let vp = voiceProfile, let c = consent {
                let a = ConsentRecord.normalizeHash(vp.consentContentHash)
                let b = ConsentRecord.normalizeHash(c.contentHash)
                if a != b {
                    throw BAMError(
                        code: .consentTamper,
                        message: "Voice profile consent hash does not match pack consent"
                    )
                }
            }
        }

        // Base ref
        var baseRef: PersonaPackBaseRef?
        let baseURL = stagingDirectory.appendingPathComponent("llm/base_ref.json")
        if fm.fileExists(atPath: baseURL.path) {
            baseRef = try JSONDecoder().decode(
                PersonaPackBaseRef.self,
                from: try Data(contentsOf: baseURL)
            )
        }

        // Index embedded files of interest
        var embedded: [String: URL] = [:]
        let interestingPrefixes = ["llm/adapter/", "voice/", "licenses/", "samples/"]
        if let enumerator = fm.enumerator(
            at: stagingDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            let rootPath = stagingDirectory.standardizedFileURL.path
            for case let url as URL in enumerator {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey])
                guard values.isRegularFile == true else { continue }
                let path = url.standardizedFileURL.path
                guard path.hasPrefix(rootPath) else { continue }
                var rel = String(path.dropFirst(rootPath.count))
                if rel.hasPrefix("/") { rel = String(rel.dropFirst()) }
                if interestingPrefixes.contains(where: { rel.hasPrefix($0) }) {
                    embedded[rel] = url
                }
            }
        }

        return ImportResult(
            document: document,
            manifest: manifest,
            consent: consent,
            voiceProfile: voiceProfile,
            baseRef: baseRef,
            stagingDirectory: stagingDirectory,
            hadKnowledgeKeys: hadKnowledge,
            embeddedFiles: embedded
        )
    }
}
