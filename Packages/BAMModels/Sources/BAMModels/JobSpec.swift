import Foundation

/// Absolute paths materialised for a job worker. Filesystem inputs live here — not on `JobSpec`.
public struct JobPaths: Codable, Sendable, Equatable {
    public var jobDir: String
    public var libraryRoot: String
    public var datasetPath: String?
    public var baseModelPath: String?
    /// Required non-null for `voiceClone`. Never put this free-form path on `JobSpec`.
    public var referenceAudioPath: String?
    public var outputPath: String
    public var checkpointPath: String
    public var cancelFlagPath: String
    public var logPath: String

    public init(
        jobDir: String,
        libraryRoot: String,
        datasetPath: String? = nil,
        baseModelPath: String? = nil,
        referenceAudioPath: String? = nil,
        outputPath: String,
        checkpointPath: String,
        cancelFlagPath: String,
        logPath: String
    ) {
        self.jobDir = jobDir
        self.libraryRoot = libraryRoot
        self.datasetPath = datasetPath
        self.baseModelPath = baseModelPath
        self.referenceAudioPath = referenceAudioPath
        self.outputPath = outputPath
        self.checkpointPath = checkpointPath
        self.cancelFlagPath = cancelFlagPath
        self.logPath = logPath
    }

    enum CodingKeys: String, CodingKey {
        case jobDir, libraryRoot, datasetPath, baseModelPath, referenceAudioPath
        case outputPath, checkpointPath, cancelFlagPath, logPath
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        jobDir = try c.decode(String.self, forKey: .jobDir)
        libraryRoot = try c.decode(String.self, forKey: .libraryRoot)
        datasetPath = try c.decodeIfPresent(String.self, forKey: .datasetPath)
        baseModelPath = try c.decodeIfPresent(String.self, forKey: .baseModelPath)
        // Explicit JSON null and missing key both become nil.
        if c.contains(.referenceAudioPath) {
            referenceAudioPath = try c.decodeIfPresent(String.self, forKey: .referenceAudioPath)
        } else {
            referenceAudioPath = nil
        }
        outputPath = try c.decode(String.self, forKey: .outputPath)
        checkpointPath = try c.decode(String.self, forKey: .checkpointPath)
        cancelFlagPath = try c.decode(String.self, forKey: .cancelFlagPath)
        logPath = try c.decode(String.self, forKey: .logPath)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(jobDir, forKey: .jobDir)
        try c.encode(libraryRoot, forKey: .libraryRoot)
        // Encode optional paths as JSON null when unused (design schema lists them).
        if let datasetPath {
            try c.encode(datasetPath, forKey: .datasetPath)
        } else {
            try c.encodeNil(forKey: .datasetPath)
        }
        if let baseModelPath {
            try c.encode(baseModelPath, forKey: .baseModelPath)
        } else {
            try c.encodeNil(forKey: .baseModelPath)
        }
        if let referenceAudioPath {
            try c.encode(referenceAudioPath, forKey: .referenceAudioPath)
        } else {
            try c.encodeNil(forKey: .referenceAudioPath)
        }
        try c.encode(outputPath, forKey: .outputPath)
        try c.encode(checkpointPath, forKey: .checkpointPath)
        try c.encode(cancelFlagPath, forKey: .cancelFlagPath)
        try c.encode(logPath, forKey: .logPath)
    }
}

/// LLM LoRA hyperparameters (JobSpec.hyperparameters).
public struct LLMHyperparameters: Codable, Sendable, Equatable {
    public var loraRank: Int
    public var loraAlpha: Int
    public var learningRate: Double
    public var epochs: Int
    public var batchSize: Int
    public var gradAccum: Int
    public var maxSeqLen: Int
    public var warmupRatio: Double

    public init(
        loraRank: Int = 16,
        loraAlpha: Int = 32,
        learningRate: Double = 1e-4,
        epochs: Int = 3,
        batchSize: Int = 1,
        gradAccum: Int = 4,
        maxSeqLen: Int = 2048,
        warmupRatio: Double = 0.03
    ) {
        self.loraRank = loraRank
        self.loraAlpha = loraAlpha
        self.learningRate = learningRate
        self.epochs = epochs
        self.batchSize = batchSize
        self.gradAccum = gradAccum
        self.maxSeqLen = maxSeqLen
        self.warmupRatio = warmupRatio
    }
}

/// Soft resource bounds for a job.
public struct JobResources: Codable, Sendable, Equatable {
    public var maxMemoryGB: Int
    public var threads: Int?

    public init(maxMemoryGB: Int, threads: Int? = nil) {
        self.maxMemoryGB = maxMemoryGB
        self.threads = threads
    }

    enum CodingKeys: String, CodingKey {
        case maxMemoryGB, threads
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        maxMemoryGB = try c.decode(Int.self, forKey: .maxMemoryGB)
        threads = try c.decodeIfPresent(Int.self, forKey: .threads)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(maxMemoryGB, forKey: .maxMemoryGB)
        try c.encodeIfPresent(threads, forKey: .threads)
    }
}

/// Checkpoint / output retention knobs (LLM).
public struct JobOutputs: Codable, Sendable, Equatable {
    public var saveEverySteps: Int
    public var keepLastNCheckpoints: Int

    public init(saveEverySteps: Int = 100, keepLastNCheckpoints: Int = 3) {
        self.saveEverySteps = saveEverySteps
        self.keepLastNCheckpoints = keepLastNCheckpoints
    }
}

/// Training job specification. Carries **ids only** for filesystem inputs —
/// absolute paths live exclusively on `JobPaths` (including `referenceAudioPath`).
///
/// ## Decode policy (v1)
/// - Unknown keys (including a legacy `referenceAudioPath` on the spec) are **dropped**
///   by `Codable` because they are not in `CodingKeys`. The supervisor path-jail
///   (PR-Jobs / PR-Protocol) must compare paths from the **raw prepare payload** or
///   a side-channel if it needs to reject JobSpec↔JobPaths mismatches (`BAM_PATH_ESCAPE`).
/// - Modality-specific required fields (e.g. `engineId` / `consentRecordId` for
///   `.voiceClone`) are **not** enforced at decode time; materializer/supervisor
///   validates before `prepare` / `run`.
public struct JobSpec: Codable, Sendable, Equatable {
    public var v: Int
    public var id: String
    public var modality: JobModality

    // MARK: LLM fields (modality == .llm)

    public var baseModelId: String?
    public var baseModelSourceKey: String?
    public var datasetVersionId: String?
    public var method: String?
    public var chatTemplateId: String?
    public var hyperparameters: LLMHyperparameters?
    public var outputs: JobOutputs?

    // MARK: Voice clone fields (modality == .voiceClone)

    public var engineId: String?
    public var consentRecordId: String?
    public var consentContentHash: String?
    public var language: String?
    public var sampleText: String?

    // MARK: Shared

    public var resources: JobResources?

    public static let protocolVersion: Int = 1

    public init(
        v: Int = JobSpec.protocolVersion,
        id: String,
        modality: JobModality,
        baseModelId: String? = nil,
        baseModelSourceKey: String? = nil,
        datasetVersionId: String? = nil,
        method: String? = nil,
        chatTemplateId: String? = nil,
        hyperparameters: LLMHyperparameters? = nil,
        outputs: JobOutputs? = nil,
        engineId: String? = nil,
        consentRecordId: String? = nil,
        consentContentHash: String? = nil,
        language: String? = nil,
        sampleText: String? = nil,
        resources: JobResources? = nil
    ) {
        self.v = v
        self.id = id
        self.modality = modality
        self.baseModelId = baseModelId
        self.baseModelSourceKey = baseModelSourceKey
        self.datasetVersionId = datasetVersionId
        self.method = method
        self.chatTemplateId = chatTemplateId
        self.hyperparameters = hyperparameters
        self.outputs = outputs
        self.engineId = engineId
        self.consentRecordId = consentRecordId
        self.consentContentHash = consentContentHash
        self.language = language
        self.sampleText = sampleText
        self.resources = resources
    }

    enum CodingKeys: String, CodingKey {
        case v, id, modality
        case baseModelId, baseModelSourceKey, datasetVersionId, method, chatTemplateId
        case hyperparameters, outputs
        case engineId, consentRecordId, consentContentHash, language, sampleText
        case resources
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        v = try c.decode(Int.self, forKey: .v)
        id = try c.decode(String.self, forKey: .id)
        modality = try c.decode(JobModality.self, forKey: .modality)
        baseModelId = try c.decodeIfPresent(String.self, forKey: .baseModelId)
        baseModelSourceKey = try c.decodeIfPresent(String.self, forKey: .baseModelSourceKey)
        datasetVersionId = try c.decodeIfPresent(String.self, forKey: .datasetVersionId)
        method = try c.decodeIfPresent(String.self, forKey: .method)
        chatTemplateId = try c.decodeIfPresent(String.self, forKey: .chatTemplateId)
        hyperparameters = try c.decodeIfPresent(LLMHyperparameters.self, forKey: .hyperparameters)
        outputs = try c.decodeIfPresent(JobOutputs.self, forKey: .outputs)
        engineId = try c.decodeIfPresent(String.self, forKey: .engineId)
        consentRecordId = try c.decodeIfPresent(String.self, forKey: .consentRecordId)
        consentContentHash = try c.decodeIfPresent(String.self, forKey: .consentContentHash)
        language = try c.decodeIfPresent(String.self, forKey: .language)
        sampleText = try c.decodeIfPresent(String.self, forKey: .sampleText)
        resources = try c.decodeIfPresent(JobResources.self, forKey: .resources)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(v, forKey: .v)
        try c.encode(id, forKey: .id)
        try c.encode(modality, forKey: .modality)
        try c.encodeIfPresent(baseModelId, forKey: .baseModelId)
        try c.encodeIfPresent(baseModelSourceKey, forKey: .baseModelSourceKey)
        try c.encodeIfPresent(datasetVersionId, forKey: .datasetVersionId)
        try c.encodeIfPresent(method, forKey: .method)
        try c.encodeIfPresent(chatTemplateId, forKey: .chatTemplateId)
        try c.encodeIfPresent(hyperparameters, forKey: .hyperparameters)
        try c.encodeIfPresent(outputs, forKey: .outputs)
        try c.encodeIfPresent(engineId, forKey: .engineId)
        try c.encodeIfPresent(consentRecordId, forKey: .consentRecordId)
        try c.encodeIfPresent(consentContentHash, forKey: .consentContentHash)
        try c.encodeIfPresent(language, forKey: .language)
        try c.encodeIfPresent(sampleText, forKey: .sampleText)
        try c.encodeIfPresent(resources, forKey: .resources)
    }

    /// Convenience constructor for an Apple Foundation adapter job.
    public static func foundationAdapter(
        id: String,
        datasetVersionId: String,
        method: String = "foundation_adapter",
        hyperparameters: LLMHyperparameters = LLMHyperparameters(learningRate: 1e-3, epochs: 3, batchSize: 4),
        resources: JobResources = JobResources(maxMemoryGB: 32, threads: 8),
        outputs: JobOutputs = JobOutputs()
    ) -> JobSpec {
        JobSpec(
            id: id,
            modality: .foundationAdapter,
            baseModelId: "apple-foundation",
            baseModelSourceKey: "apple/system-language-model",
            datasetVersionId: datasetVersionId,
            method: method,
            chatTemplateId: nil,
            hyperparameters: hyperparameters,
            outputs: outputs,
            resources: resources
        )
    }

    /// Convenience constructor for an LLM LoRA job.
    public static func llm(
        id: String,
        baseModelId: String,
        baseModelSourceKey: String,
        datasetVersionId: String,
        method: String = "lora",
        chatTemplateId: String = "qwen2.5-instruct",
        hyperparameters: LLMHyperparameters = LLMHyperparameters(),
        resources: JobResources = JobResources(maxMemoryGB: 24, threads: 8),
        outputs: JobOutputs = JobOutputs()
    ) -> JobSpec {
        JobSpec(
            id: id,
            modality: .llm,
            baseModelId: baseModelId,
            baseModelSourceKey: baseModelSourceKey,
            datasetVersionId: datasetVersionId,
            method: method,
            chatTemplateId: chatTemplateId,
            hyperparameters: hyperparameters,
            outputs: outputs,
            resources: resources
        )
    }

    /// Convenience constructor for a voice-clone job.
    /// Reference audio path is supplied only via `JobPaths.referenceAudioPath`.
    public static func voiceClone(
        id: String,
        engineId: String = "f5-tts",
        consentRecordId: String,
        consentContentHash: String,
        language: String = "en",
        sampleText: String = "Hello, this is a preview of my voice.",
        resources: JobResources = JobResources(maxMemoryGB: 16)
    ) -> JobSpec {
        JobSpec(
            id: id,
            modality: .voiceClone,
            engineId: engineId,
            consentRecordId: consentRecordId,
            consentContentHash: consentContentHash,
            language: language,
            sampleText: sampleText,
            resources: resources
        )
    }
}
