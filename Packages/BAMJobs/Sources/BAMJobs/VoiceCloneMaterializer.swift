import BAMCore
import BAMModels
import CryptoKit
import Foundation

/// Materializes voice-clone `JobPaths` + job layout, and can write a **stub**
/// `voice_profile` directory from a reference WAV (no F5-TTS / multi-GB download).
///
/// Product UI is out of scope (PR-Voice-UI). This type is the spike/CLI-adjacent
/// path used by unit tests and future supervisor prepare.
public enum VoiceCloneMaterializer: Sendable {
    public static let defaultEngineId = "f5-tts"
    public static let profileFileName = "profile.json"
    public static let referenceFileName = "reference.wav"
    public static let engineCacheDirectoryName = "engine_cache"

    /// AGPL / non-default engine ids — never write job.json or profiles with these.
    public static let blockedEngineIds: Set<String> = [
        "xtts",
        "xtts-v2",
        "coqui-xtts",
    ]

    /// Result of materializing a voice-clone job workspace.
    public struct JobMaterialization: Sendable, Equatable {
        public var spec: JobSpec
        public var paths: JobPaths

        public init(spec: JobSpec, paths: JobPaths) {
            self.spec = spec
            self.paths = paths
        }
    }

    /// Result of writing a stub voice_profile artifact directory.
    public struct VoiceProfileMaterialization: Sendable, Equatable {
        public var voiceProfileDir: String
        public var profilePath: String
        public var referenceWavPath: String
        public var referenceAudioHash: String
        public var engineId: String
        public var stub: Bool

        public init(
            voiceProfileDir: String,
            profilePath: String,
            referenceWavPath: String,
            referenceAudioHash: String,
            engineId: String,
            stub: Bool
        ) {
            self.voiceProfileDir = voiceProfileDir
            self.profilePath = profilePath
            self.referenceWavPath = referenceWavPath
            self.referenceAudioHash = referenceAudioHash
            self.engineId = engineId
            self.stub = stub
        }
    }

    // MARK: - Engine license gate (ADR 0002)

    /// Effective engine id for a job (explicit `engineId` or default `f5-tts`).
    public static func resolvedEngineId(for job: JobSpec) -> String {
        if let engineId = job.engineId, !engineId.isEmpty {
            return engineId
        }
        return defaultEngineId
    }

    /// True when engine id is on the non-default / AGPL denylist (case-insensitive).
    public static func isBlockedEngine(_ engineId: String) -> Bool {
        blockedEngineIds.contains(engineId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    /// Throw `BAM_LICENSE_BLOCK` before any mkdir/write when engine is blocked.
    public static func assertEngineAllowed(_ engineId: String) throws {
        guard !isBlockedEngine(engineId) else {
            throw BAMError(
                code: .licenseBlock,
                message: "engine \(engineId) is AGPL / non-default; use engineId \(defaultEngineId) (ADR 0002)"
            )
        }
    }

    /// Reject blocked `job.engineId` (or defaulted engine) early.
    public static func assertJobEngineAllowed(_ job: JobSpec) throws {
        try assertEngineAllowed(resolvedEngineId(for: job))
    }

    // MARK: - JobSpec / JobPaths

    /// Build jailed `JobPaths` for a voice-clone job. Does not touch the filesystem.
    ///
    /// - Throws: `BAMError.schemaInvalid` if modality is not `voiceClone`.
    /// - Throws: `BAMError.licenseBlock` if `job.engineId` is XTTS family.
    /// - Throws: `BAMError.pathEscape` / modality validation failures from `PathJail` when
    ///   `validate` is true (default).
    public static func makePaths(
        job: JobSpec,
        libraryRoot: URL,
        referenceAudioPath: String,
        validate: Bool = true
    ) throws -> JobPaths {
        guard job.modality == .voiceClone else {
            throw BAMError(
                code: .schemaInvalid,
                message: "VoiceCloneMaterializer requires modality voiceClone, got \(job.modality.rawValue)"
            )
        }
        try assertJobEngineAllowed(job)

        let paths = JobPathsFactory.make(
            jobId: job.id,
            libraryRoot: libraryRoot,
            datasetPath: nil,
            baseModelPath: nil,
            referenceAudioPath: referenceAudioPath
        )

        if validate {
            // PathJail lives in BAMRunners; re-implement minimal checks here so BAMJobs
            // does not depend on BAMRunners. Callers that already use PathJail can pass
            // validate: false and jail externally.
            try validateVoicePaths(paths)
        }
        return paths
    }

    /// Create jobDir / artifacts / checkpoints / logs and write `job.json`.
    ///
    /// License gate runs **before** mkdir so blocked engines leave no partial tree.
    public static func materializeJobLayout(
        job: JobSpec,
        paths: JobPaths,
        fileManager: FileManager = .default
    ) throws {
        guard job.modality == .voiceClone else {
            throw BAMError(
                code: .schemaInvalid,
                message: "VoiceCloneMaterializer requires modality voiceClone"
            )
        }
        try assertJobEngineAllowed(job)
        try validateVoicePaths(paths)

        let dirs = [paths.jobDir, paths.outputPath, paths.checkpointPath, paths.logPath]
        for path in dirs {
            try fileManager.createDirectory(
                atPath: path,
                withIntermediateDirectories: true
            )
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(job)
        try data.write(to: JobPathsFactory.jobJSONURL(paths: paths), options: .atomic)
    }

    /// Convenience: paths + on-disk job layout in one call.
    public static func materialize(
        job: JobSpec,
        libraryRoot: URL,
        referenceAudioPath: String,
        fileManager: FileManager = .default
    ) throws -> JobMaterialization {
        // License gate first — before paths/mkdir — so XTTS never creates job dirs.
        try assertJobEngineAllowed(job)
        let paths = try makePaths(
            job: job,
            libraryRoot: libraryRoot,
            referenceAudioPath: referenceAudioPath,
            validate: true
        )
        try materializeJobLayout(job: job, paths: paths, fileManager: fileManager)
        return JobMaterialization(spec: job, paths: paths)
    }

    // MARK: - Stub voice_profile

    /// Copy reference WAV into `outDir` and write `profile.json` (stub — no F5-TTS).
    ///
    /// Layout:
    /// ```text
    /// outDir/
    ///   profile.json
    ///   reference.wav
    ///   engine_cache/
    /// ```
    public static func writeStubVoiceProfile(
        referenceWavURL: URL,
        outDir: URL,
        engineId: String = defaultEngineId,
        consentRecordId: String? = nil,
        consentContentHash: String? = nil,
        language: String = "en",
        sampleText: String? = "Hello, this is a preview of my voice.",
        fileManager: FileManager = .default
    ) throws -> VoiceProfileMaterialization {
        try assertEngineAllowed(engineId)

        guard fileManager.fileExists(atPath: referenceWavURL.path) else {
            throw BAMError(
                code: .datasetInvalid,
                message: "reference wav not found: \(referenceWavURL.path)"
            )
        }

        try fileManager.createDirectory(at: outDir, withIntermediateDirectories: true)
        let cacheDir = outDir.appendingPathComponent(engineCacheDirectoryName, isDirectory: true)
        try fileManager.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        let destWav = outDir.appendingPathComponent(referenceFileName, isDirectory: false)
        if fileManager.fileExists(atPath: destWav.path) {
            try fileManager.removeItem(at: destWav)
        }
        try fileManager.copyItem(at: referenceWavURL, to: destWav)

        let hashHex = try sha256Hex(ofFileAt: destWav)
        let hashPrefixed = "sha256:\(hashHex)"

        var profile: [String: Any] = [
            "v": 1,
            "kind": "voice_profile",
            "engineId": engineId,
            "language": language,
            "referenceAudioHash": hashPrefixed,
            "createdAt": isoNow(),
            "stub": true,
            "note": "Stub profile from PR-VoiceSpike; no F5-TTS model was loaded or downloaded.",
        ]
        if let consentRecordId {
            profile["consentRecordId"] = consentRecordId
        }
        if let consentContentHash {
            profile["consentContentHash"] = consentContentHash
        }
        if let sampleText {
            profile["sampleText"] = sampleText
        }

        let profileURL = outDir.appendingPathComponent(profileFileName, isDirectory: false)
        let data = try JSONSerialization.data(withJSONObject: profile, options: [.sortedKeys, .prettyPrinted])
        try data.write(to: profileURL, options: .atomic)

        return VoiceProfileMaterialization(
            voiceProfileDir: outDir.path,
            profilePath: profileURL.path,
            referenceWavPath: destWav.path,
            referenceAudioHash: hashPrefixed,
            engineId: engineId,
            stub: true
        )
    }

    /// Materialize job layout and a stub voice_profile under `paths.outputPath`.
    ///
    /// License gate runs before any filesystem mutation (via `materialize`).
    public static func materializeWithStubProfile(
        job: JobSpec,
        libraryRoot: URL,
        referenceAudioPath: String,
        voiceProfileId: String? = nil,
        fileManager: FileManager = .default
    ) throws -> (JobMaterialization, VoiceProfileMaterialization) {
        try assertJobEngineAllowed(job)
        let jobMat = try materialize(
            job: job,
            libraryRoot: libraryRoot,
            referenceAudioPath: referenceAudioPath,
            fileManager: fileManager
        )

        let profileId = voiceProfileId ?? job.id
        let profileDir = libraryRoot
            .appendingPathComponent("voices", isDirectory: true)
            .appendingPathComponent(LibraryPaths.sanitizedPathComponent(profileId), isDirectory: true)

        // Also place a copy under job artifacts for runner-shaped output.
        let artifactProfileDir = URL(fileURLWithPath: jobMat.paths.outputPath, isDirectory: true)
            .appendingPathComponent("voice_profile", isDirectory: true)

        let refURL = URL(fileURLWithPath: referenceAudioPath)
        let artifactProfile = try writeStubVoiceProfile(
            referenceWavURL: refURL,
            outDir: artifactProfileDir,
            engineId: job.engineId ?? defaultEngineId,
            consentRecordId: job.consentRecordId,
            consentContentHash: job.consentContentHash,
            language: job.language ?? "en",
            sampleText: job.sampleText,
            fileManager: fileManager
        )

        // Library-facing voice dir (same content).
        _ = try writeStubVoiceProfile(
            referenceWavURL: refURL,
            outDir: profileDir,
            engineId: job.engineId ?? defaultEngineId,
            consentRecordId: job.consentRecordId,
            consentContentHash: job.consentContentHash,
            language: job.language ?? "en",
            sampleText: job.sampleText,
            fileManager: fileManager
        )

        return (jobMat, artifactProfile)
    }

    // MARK: - Validation (BAMJobs-local; mirrors PathJail voice rules)

    /// Ensures voice paths are absolute, under libraryRoot, and reference audio is set.
    public static func validateVoicePaths(_ paths: JobPaths) throws {
        try assertUnderRoot(paths.libraryRoot, root: paths.libraryRoot, label: "libraryRoot")
        try assertUnderRoot(paths.jobDir, root: paths.libraryRoot, label: "jobDir")
        try assertUnderRoot(paths.outputPath, root: paths.jobDir, label: "outputPath")
        try assertUnderRoot(paths.checkpointPath, root: paths.jobDir, label: "checkpointPath")
        try assertUnderRoot(paths.cancelFlagPath, root: paths.jobDir, label: "cancelFlagPath")
        try assertUnderRoot(paths.logPath, root: paths.jobDir, label: "logPath")

        guard let ref = paths.referenceAudioPath, !ref.isEmpty else {
            throw BAMError(
                code: .pathEscape,
                message: "voiceClone requires non-null JobPaths.referenceAudioPath"
            )
        }
        try assertUnderRoot(ref, root: paths.libraryRoot, label: "referenceAudioPath")
    }

    private static func assertUnderRoot(_ path: String, root: String, label: String) throws {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw BAMError(code: .pathEscape, message: "\(label) is empty")
        }
        guard trimmed.hasPrefix("/") else {
            throw BAMError(code: .pathEscape, message: "\(label) must be absolute: \(trimmed)")
        }
        let rootURL = URL(fileURLWithPath: root, isDirectory: true)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let pathURL = URL(fileURLWithPath: trimmed)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let rootPath = rootURL.path
        let resolvedPath = pathURL.path
        if resolvedPath == rootPath { return }
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard resolvedPath.hasPrefix(prefix) else {
            throw BAMError(
                code: .pathEscape,
                message: "\(label) escapes root \(rootPath): \(resolvedPath)"
            )
        }
    }

    private static func sha256Hex(ofFileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func isoNow() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: Date())
    }
}
