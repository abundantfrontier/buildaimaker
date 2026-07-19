import BAMConsent
import BAMCore
import BAMJobs
import BAMModels
import BAMPersistence
import Foundation

/// Product orchestration for voice profiles: import reference audio, require consent,
/// materialize `JobPaths.referenceAudioPath` only, enqueue clone jobs, register rows.
public final class VoiceCloneService: @unchecked Sendable {
    public let libraryRoot: URL
    public let profileStore: VoiceProfileStore
    public let consentService: ConsentService
    public let queue: JobQueueController
    public let fileManager: FileManager

    private let idGenerator: @Sendable () -> String
    private let nowISO8601: @Sendable () -> String

    public init(
        libraryRoot: URL,
        profileStore: VoiceProfileStore,
        consentService: ConsentService,
        queue: JobQueueController,
        fileManager: FileManager = .default,
        idGenerator: @escaping @Sendable () -> String = { BAMID.generate() },
        nowISO8601: @escaping @Sendable () -> String = { ConsentService.currentTimestamp() }
    ) {
        self.libraryRoot = libraryRoot
        self.profileStore = profileStore
        self.consentService = consentService
        self.queue = queue
        self.fileManager = fileManager
        self.idGenerator = idGenerator
        self.nowISO8601 = nowISO8601
    }

    /// Default product service: library DB, consent store, composite fake+stub runner.
    public static func makeDefault() throws -> VoiceCloneService {
        let db = try LibraryDatabase.openDefault()
        let libraryRoot = LibraryPaths.libraryRoot
        try FileManager.default.createDirectory(at: libraryRoot, withIntermediateDirectories: true)

        let consentStore = ConsentStore(
            database: db,
            consentDirectory: LibraryPaths.consent,
            writeJSONFiles: true
        )
        let consent = ConsentService(store: consentStore)
        let profiles = VoiceProfileStore(database: db)
        let jobStore = JobStore(database: db)

        let runner = CompositeTrainingRunner(
            llm: FakeTrainingRunner(
                config: FakeRunnerConfig(
                    stepCount: 20,
                    stepInterval: .milliseconds(200),
                    heartbeatEverySteps: 2,
                    prepareDelay: .milliseconds(100)
                )
            ),
            voice: StubVoiceCloneRunner(
                config: StubVoiceCloneRunnerConfig(
                    stepCount: 8,
                    stepInterval: .milliseconds(120),
                    prepareDelay: .milliseconds(50)
                )
            )
        )
        let controller = JobQueueController(
            store: jobStore,
            runner: runner,
            libraryRoot: libraryRoot,
            heartbeatTimeout: HeartbeatMonitor.defaultTimeoutSeconds
        )
        return VoiceCloneService(
            libraryRoot: libraryRoot,
            profileStore: profiles,
            consentService: consent,
            queue: controller
        )
    }

    /// In-memory stack for unit tests (temp library root + stub voice runner only).
    public static func makeInMemoryForTesting(
        runnerConfig: StubVoiceCloneRunnerConfig = .testing,
        heartbeatTimeout: TimeInterval = 2
    ) throws -> (
        service: VoiceCloneService,
        database: LibraryDatabase,
        libraryRoot: URL,
        queue: JobQueueController
    ) {
        let db = try LibraryDatabase.openInMemory()
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("bam-voice-svc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        let consentDir = tmp.appendingPathComponent("consent", isDirectory: true)
        try FileManager.default.createDirectory(at: consentDir, withIntermediateDirectories: true)

        let consent = ConsentService(
            store: ConsentStore(database: db, consentDirectory: consentDir, writeJSONFiles: false)
        )
        let profiles = VoiceProfileStore(database: db)
        let jobStore = JobStore(database: db)
        let runner = StubVoiceCloneRunner(config: runnerConfig)
        let controller = JobQueueController(
            store: jobStore,
            runner: runner,
            libraryRoot: tmp,
            heartbeatTimeout: heartbeatTimeout
        )
        let service = VoiceCloneService(
            libraryRoot: tmp,
            profileStore: profiles,
            consentService: consent,
            queue: controller
        )
        return (service, db, tmp, controller)
    }

    // MARK: - Profiles

    public func listProfiles() throws -> [VoiceProfileRecord] {
        try profileStore.fetchAll()
    }

    public func fetchProfile(id: String) throws -> VoiceProfileRecord? {
        try profileStore.fetch(id: id)
    }

    // MARK: - Import reference audio

    /// Copies a user-selected WAV into `voices/staging/<id>/ref.wav` under the library root.
    ///
    /// The returned absolute path is the only filesystem input for the clone job
    /// (`JobPaths.referenceAudioPath`). Source path may be outside the library.
    @discardableResult
    public func importReferenceAudio(
        from sourceURL: URL,
        stagingId: String? = nil
    ) throws -> ImportedReferenceAudio {
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            throw BAMError(
                code: .datasetInvalid,
                message: "Reference audio not found: \(sourceURL.path)"
            )
        }

        let id = stagingId ?? idGenerator()
        let stagingDir = libraryRoot
            .appendingPathComponent("voices", isDirectory: true)
            .appendingPathComponent("staging", isDirectory: true)
            .appendingPathComponent(LibraryPaths.sanitizedPathComponent(id), isDirectory: true)
        try fileManager.createDirectory(at: stagingDir, withIntermediateDirectories: true)

        let dest = stagingDir.appendingPathComponent("ref.wav", isDirectory: false)
        if fileManager.fileExists(atPath: dest.path) {
            try fileManager.removeItem(at: dest)
        }
        try fileManager.copyItem(at: sourceURL, to: dest)

        // Ensure path is under library root (jail for JobPaths).
        try VoiceCloneMaterializer.validateVoicePaths(
            JobPathsFactory.make(
                jobId: "validate-staging",
                libraryRoot: libraryRoot,
                referenceAudioPath: dest.path
            )
        )

        return ImportedReferenceAudio(
            stagingId: id,
            referenceAudioPath: dest.path,
            fileURL: dest
        )
    }

    // MARK: - Start clone job

    /// Validates consent binding, materializes `JobPaths` with **only**
    /// `referenceAudioPath` as a free-form input path, and enqueues a `voiceClone` job.
    ///
    /// - Parameter referenceAudioPath: Absolute path under `libraryRoot` (typically from
    ///   `importReferenceAudio`). Never written onto `JobSpec`.
    /// - Parameter voiceProfileId: Library voice id (defaults to a new BAMID).
    @discardableResult
    public func startCloneJob(
        referenceAudioPath: String,
        consentRecordId: String,
        voiceProfileId: String? = nil,
        language: String = "en",
        sampleText: String = "Hello, this is a preview of my voice.",
        engineId: String = VoiceCloneMaterializer.defaultEngineId
    ) async throws -> StartedCloneJob {
        // Consent required + hash binding (K11).
        let consent = try consentService.fetchAndVerify(id: consentRecordId)
        let expectedHash = consent.contentHash
        guard try consentService.isValidBinding(id: consentRecordId, expectedHash: expectedHash) else {
            throw BAMError(
                code: .consentTamper,
                message: "Consent binding failed for \(consentRecordId)"
            )
        }

        try VoiceCloneMaterializer.assertEngineAllowed(engineId)

        // Use a single id for job + voice profile so the stub runner writes
        // `voices/<id>/` without a side channel. Callers may still pass an explicit id.
        let profileId = voiceProfileId ?? idGenerator()
        let jobId = profileId
        let hashPrefixed: String = {
            let n = ConsentRecord.normalizeHash(expectedHash)
            return n.hasPrefix("sha256:") ? n : "sha256:\(n)"
        }()

        let spec = JobSpec.voiceClone(
            id: jobId,
            engineId: engineId,
            consentRecordId: consent.id,
            consentContentHash: hashPrefixed,
            language: language,
            sampleText: sampleText
        )

        // Materialize paths: referenceAudioPath only (no free paths on JobSpec).
        let paths = try VoiceCloneMaterializer.makePaths(
            job: spec,
            libraryRoot: libraryRoot,
            referenceAudioPath: referenceAudioPath,
            validate: true
        )

        // Assert JobSpec JSON has no referenceAudioPath key before enqueue.
        let encoded = try JSONEncoder().encode(spec)
        if let obj = try JSONSerialization.jsonObject(with: encoded) as? [String: Any],
           obj["referenceAudioPath"] != nil
        {
            throw BAMError(
                code: .pathEscape,
                message: "JobSpec must not carry referenceAudioPath; use JobPaths only"
            )
        }

        let job = try await queue.enqueue(spec: spec, paths: paths)

        return StartedCloneJob(
            job: job,
            spec: spec,
            paths: paths,
            voiceProfileId: profileId,
            consentRecordId: consent.id,
            consentContentHash: hashPrefixed
        )
    }

    /// After a clone job succeeds, upsert the `voice_profiles` row from on-disk artifact.
    ///
    /// The stub runner writes `voices/<jobId>/profile.json` + `reference.wav`.
    @discardableResult
    public func finalizeSucceededJob(
        jobId: String,
        voiceProfileId: String? = nil
    ) async throws -> VoiceProfileRecord {
        let listed = try await queue.listJobs()
        guard let job = listed.first(where: { $0.id == jobId }) else {
            throw BAMError(code: .schemaInvalid, message: "Job not found: \(jobId)")
        }
        guard job.status == .succeeded else {
            throw BAMError(
                code: .schemaInvalid,
                message: "Job \(jobId) is not succeeded (status=\(job.status.rawValue))"
            )
        }
        guard job.modality == .voiceClone else {
            throw BAMError(
                code: .schemaInvalid,
                message: "Job modality is \(job.modality.rawValue), expected voiceClone"
            )
        }

        let data = Data(job.configJSON.utf8)
        let spec = try JSONDecoder().decode(JobSpec.self, from: data)
        let profileId = voiceProfileId ?? jobId

        let targetDir = libraryRoot
            .appendingPathComponent("voices", isDirectory: true)
            .appendingPathComponent(LibraryPaths.sanitizedPathComponent(profileId), isDirectory: true)

        let profileJSON = targetDir.appendingPathComponent(
            VoiceCloneMaterializer.profileFileName,
            isDirectory: false
        )
        if !fileManager.fileExists(atPath: profileJSON.path) {
            let artifact = libraryRoot
                .appendingPathComponent("jobs", isDirectory: true)
                .appendingPathComponent(LibraryPaths.sanitizedPathComponent(jobId), isDirectory: true)
                .appendingPathComponent("artifacts/voice_profile", isDirectory: true)
            let artifactProfile = artifact.appendingPathComponent(
                VoiceCloneMaterializer.profileFileName,
                isDirectory: false
            )
            if fileManager.fileExists(atPath: artifactProfile.path) {
                if fileManager.fileExists(atPath: targetDir.path) {
                    try fileManager.removeItem(at: targetDir)
                }
                try fileManager.copyItem(at: artifact, to: targetDir)
            } else {
                throw BAMError(
                    code: .schemaInvalid,
                    message: "voice_profile artifact missing for job \(jobId)"
                )
            }
        }

        guard let consentId = spec.consentRecordId, let consentHash = spec.consentContentHash else {
            throw BAMError(code: .consentRequired, message: "JobSpec missing consent fields")
        }

        let record = VoiceProfileRecord(
            id: profileId,
            engineId: spec.engineId ?? VoiceCloneMaterializer.defaultEngineId,
            localPath: targetDir.path,
            consentRecordId: consentId,
            consentContentHash: ConsentRecord.normalizeHash(consentHash),
            createdAt: nowISO8601()
        )
        try profileStore.upsert(record)
        return record
    }

    /// Poll until job leaves active statuses or timeout (tests / UI await).
    public func waitForJob(
        jobId: String,
        timeout: Duration = .seconds(10),
        poll: Duration = .milliseconds(20)
    ) async throws -> JobRecord {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            let jobs = try await queue.listJobs()
            if let job = jobs.first(where: { $0.id == jobId }) {
                switch job.status {
                case .succeeded, .failed, .cancelled, .interrupted:
                    return job
                default:
                    break
                }
            }
            try await Task.sleep(for: poll)
        }
        throw BAMError(code: .workerHung, message: "Timed out waiting for job \(jobId)")
    }
}

// MARK: - DTOs

public struct ImportedReferenceAudio: Sendable, Equatable {
    public var stagingId: String
    public var referenceAudioPath: String
    public var fileURL: URL

    public init(stagingId: String, referenceAudioPath: String, fileURL: URL) {
        self.stagingId = stagingId
        self.referenceAudioPath = referenceAudioPath
        self.fileURL = fileURL
    }
}

public struct StartedCloneJob: Sendable, Equatable {
    public var job: JobRecord
    public var spec: JobSpec
    public var paths: JobPaths
    public var voiceProfileId: String
    public var consentRecordId: String
    public var consentContentHash: String

    public init(
        job: JobRecord,
        spec: JobSpec,
        paths: JobPaths,
        voiceProfileId: String,
        consentRecordId: String,
        consentContentHash: String
    ) {
        self.job = job
        self.spec = spec
        self.paths = paths
        self.voiceProfileId = voiceProfileId
        self.consentRecordId = consentRecordId
        self.consentContentHash = consentContentHash
    }
}
