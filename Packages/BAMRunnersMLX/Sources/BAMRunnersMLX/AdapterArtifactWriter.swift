import BAMCore
import BAMModels
import Foundation

/// Result of publishing a LoRA adapter into `models/adapters/<id>/`.
public struct AdapterPublishResult: Sendable, Equatable {
    public var artifactId: String
    public var adapterDirectory: URL
    public var jobArtifactDirectory: URL
    public var modelCardURL: URL
    public var record: ArtifactRecord
    public var fakeTrain: Bool

    public init(
        artifactId: String,
        adapterDirectory: URL,
        jobArtifactDirectory: URL,
        modelCardURL: URL,
        record: ArtifactRecord,
        fakeTrain: Bool
    ) {
        self.artifactId = artifactId
        self.adapterDirectory = adapterDirectory
        self.jobArtifactDirectory = jobArtifactDirectory
        self.modelCardURL = modelCardURL
        self.record = record
        self.fakeTrain = fakeTrain
    }
}

/// Writes / copies LoRA adapter files from a job's `artifacts/adapter` into the
/// library tree at `models/adapters/<artifactId>/` (K6 default export).
public struct AdapterArtifactWriter: @unchecked Sendable {
    /// Not Sendable in the SDK; treat as effectively immutable for our use.
    public var fileManager: FileManager

    public static let jobRelativeAdapterDir = "artifacts/adapter"
    public static let adapterConfigFileName = "adapter_config.json"
    public static let weightsFileName = "adapters.safetensors"

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// Absolute job-local adapter directory (`…/jobs/<id>/artifacts/adapter`).
    public static func jobAdapterDirectory(paths: JobPaths) -> URL {
        URL(fileURLWithPath: paths.outputPath, isDirectory: true)
            .appendingPathComponent("adapter", isDirectory: true)
    }

    /// Ensures a complete stub adapter exists under the job artifacts dir
    /// (used by CI-safe fake train and by post-process when the worker only
    /// announced the path).
    @discardableResult
    public func ensureJobAdapterStub(
        paths: JobPaths,
        spec: JobSpec,
        holdOutLoss: Double = 1.25,
        trainLoss: Double = 0.85,
        fakeTrain: Bool = true
    ) throws -> URL {
        let dir = Self.jobAdapterDirectory(paths: paths)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)

        let configURL = dir.appendingPathComponent(Self.adapterConfigFileName)
        if !fileManager.fileExists(atPath: configURL.path) {
            let config: [String: Any] = [
                "peft_type": "LORA",
                "r": spec.hyperparameters?.loraRank ?? 16,
                "lora_alpha": spec.hyperparameters?.loraAlpha ?? 32,
                "target_modules": ["q_proj", "v_proj"],
                "base_model_name_or_path": spec.baseModelSourceKey ?? "",
                "bam_fake": fakeTrain,
            ]
            let data = try JSONSerialization.data(
                withJSONObject: config,
                options: [.sortedKeys, .prettyPrinted]
            )
            try data.write(to: configURL, options: .atomic)
        }

        let weightsURL = dir.appendingPathComponent(Self.weightsFileName)
        if !fileManager.fileExists(atPath: weightsURL.path) {
            // Tiny non-empty stub — not a real safetensors payload.
            try Data("BAM_LORA_STUB\n".utf8).write(to: weightsURL, options: .atomic)
        }

        let card = ModelCardContent(
            title: "LoRA Adapter",
            baseModelId: spec.baseModelId,
            baseModelSourceKey: spec.baseModelSourceKey,
            method: spec.method ?? "lora",
            jobId: spec.id,
            holdOutLoss: holdOutLoss,
            trainLoss: trainLoss,
            sampleGenerations: ModelCardContent.stubSamples(),
            hyperparametersSummary: hyperparametersLine(spec),
            notes: fakeTrain
                ? [
                    "Produced by CI-safe fake train (`BAM_LORA_FAKE=1` or mlx-lm missing).",
                    "Replace with real mlx-lm adapter when the managed training runtime is installed.",
                ]
                : ["Produced by mlx-lm LoRA train."],
            fakeTrain: fakeTrain
        )
        try ModelCardWriter.write(content: card, toDirectory: dir, fileManager: fileManager)
        return dir
    }

    /// Copies job adapter files into `libraryRoot/models/adapters/<artifactId>/`
    /// and rewrites the model card with the assigned artifact id.
    public func publishToLibrary(
        paths: JobPaths,
        spec: JobSpec,
        artifactId: String = BAMID.generate(),
        holdOutLoss: Double? = nil,
        trainLoss: Double? = nil,
        fakeTrain: Bool = false,
        createdAt: String = ISO8601DateFormatter().string(from: Date())
    ) throws -> AdapterPublishResult {
        let jobAdapter = Self.jobAdapterDirectory(paths: paths)
        if !fileManager.fileExists(atPath: jobAdapter.path) {
            try ensureJobAdapterStub(
                paths: paths,
                spec: spec,
                holdOutLoss: holdOutLoss ?? 1.25,
                trainLoss: trainLoss ?? 0.85,
                fakeTrain: fakeTrain
            )
        }

        let libraryRoot = URL(fileURLWithPath: paths.libraryRoot, isDirectory: true)
        let dest = libraryRoot
            .appendingPathComponent("models/adapters", isDirectory: true)
            .appendingPathComponent(LibraryPaths.sanitizedPathComponent(artifactId), isDirectory: true)

        if fileManager.fileExists(atPath: dest.path) {
            try fileManager.removeItem(at: dest)
        }
        try fileManager.createDirectory(at: dest, withIntermediateDirectories: true)
        // mlx-lm writes step checkpoints (`0000100_adapters.safetensors`, …) next to
        // the final weights. Copy only the usable pair — a full-folder copy is
        // hundreds of MB and froze Teach on every visit.
        for name in [Self.adapterConfigFileName, Self.weightsFileName] {
            let src = jobAdapter.appendingPathComponent(name)
            guard fileManager.fileExists(atPath: src.path) else { continue }
            try fileManager.copyItem(at: src, to: dest.appendingPathComponent(name))
        }

        // Refresh model card with library artifact id.
        var resolvedHoldOut = holdOutLoss
        var resolvedTrain = trainLoss
        if resolvedHoldOut == nil || resolvedTrain == nil,
           let metrics = readMetrics(in: dest)
        {
            if resolvedHoldOut == nil, let v = metrics["holdOutLoss"] as? Double {
                resolvedHoldOut = v
            }
            if resolvedTrain == nil, let v = metrics["trainLoss"] as? Double {
                resolvedTrain = v
            }
        }

        let card = ModelCardContent(
            title: "LoRA Adapter",
            baseModelId: spec.baseModelId,
            baseModelSourceKey: spec.baseModelSourceKey,
            method: spec.method ?? "lora",
            jobId: spec.id,
            adapterArtifactId: artifactId,
            holdOutLoss: resolvedHoldOut,
            trainLoss: resolvedTrain,
            sampleGenerations: ModelCardContent.stubSamples(),
            hyperparametersSummary: hyperparametersLine(spec),
            notes: fakeTrain
                ? ["Library copy of CI-safe fake adapter."]
                : ["Library copy of mlx-lm LoRA adapter."],
            fakeTrain: fakeTrain
        )
        let cardURL = try ModelCardWriter.write(
            content: card,
            toDirectory: dest,
            fileManager: fileManager
        )

        let metricsJSON: String?
        if let data = try? JSONSerialization.data(
            withJSONObject: card.metricsDictionary(),
            options: [.sortedKeys]
        ) {
            metricsJSON = String(data: data, encoding: .utf8)
        } else {
            metricsJSON = nil
        }

        let record = ArtifactRecord(
            id: artifactId,
            kind: .loraAdapter,
            jobId: spec.id,
            baseModelId: spec.baseModelId,
            localPath: dest.path,
            metricsJSON: metricsJSON,
            createdAt: createdAt
        )

        return AdapterPublishResult(
            artifactId: artifactId,
            adapterDirectory: dest,
            jobArtifactDirectory: jobAdapter,
            modelCardURL: cardURL,
            record: record,
            fakeTrain: fakeTrain
        )
    }

    // MARK: - Private

    private func hyperparametersLine(_ spec: JobSpec) -> String {
        guard let h = spec.hyperparameters else { return "_defaults_" }
        return
            "rank=\(h.loraRank), alpha=\(h.loraAlpha), lr=\(h.learningRate), "
            + "epochs=\(h.epochs), batch=\(h.batchSize), gradAccum=\(h.gradAccum), "
            + "maxSeqLen=\(h.maxSeqLen)"
    }

    private func readMetrics(in directory: URL) -> [String: Any]? {
        let url = directory.appendingPathComponent(ModelCardWriter.metricsFileName)
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj
    }
}
