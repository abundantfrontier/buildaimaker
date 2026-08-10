import Foundation

/// K25 MVP model-card payload: hold-out loss + sample generations (not a full eval suite).
public struct ModelCardSampleGeneration: Sendable, Equatable, Codable {
    public var prompt: String
    public var completion: String

    public init(prompt: String, completion: String) {
        self.prompt = prompt
        self.completion = completion
    }
}

/// Fields written into `model_card.md` (and optionally `metrics.json`) after LoRA train.
public struct ModelCardContent: Sendable, Equatable, Codable {
    public var title: String
    public var baseModelId: String?
    public var baseModelSourceKey: String?
    public var method: String
    public var jobId: String?
    public var adapterArtifactId: String?
    public var holdOutLoss: Double?
    public var trainLoss: Double?
    public var sampleGenerations: [ModelCardSampleGeneration]
    public var hyperparametersSummary: String?
    public var notes: [String]
    public var fakeTrain: Bool

    public init(
        title: String = "LoRA Adapter",
        baseModelId: String? = nil,
        baseModelSourceKey: String? = nil,
        method: String = "lora",
        jobId: String? = nil,
        adapterArtifactId: String? = nil,
        holdOutLoss: Double? = nil,
        trainLoss: Double? = nil,
        sampleGenerations: [ModelCardSampleGeneration] = [],
        hyperparametersSummary: String? = nil,
        notes: [String] = [],
        fakeTrain: Bool = false
    ) {
        self.title = title
        self.baseModelId = baseModelId
        self.baseModelSourceKey = baseModelSourceKey
        self.method = method
        self.jobId = jobId
        self.adapterArtifactId = adapterArtifactId
        self.holdOutLoss = holdOutLoss
        self.trainLoss = trainLoss
        self.sampleGenerations = sampleGenerations
        self.hyperparametersSummary = hyperparametersSummary
        self.notes = notes
        self.fakeTrain = fakeTrain
    }

    /// Deterministic stub samples used by CI-safe fake train (K25 shape).
    public static func stubSamples() -> [ModelCardSampleGeneration] {
        [
            ModelCardSampleGeneration(
                prompt: "Hello!",
                completion: "Hi — this is a stub generation from a CI-safe LoRA adapter."
            ),
            ModelCardSampleGeneration(
                prompt: "Summarize BuildAIMaker in one sentence.",
                completion:
                    "BuildAIMaker is a local-first Mac app for LoRA fine-tunes and voice personas."
            ),
        ]
    }

    /// Renders Markdown for `model_card.md`.
    public func renderMarkdown() -> String {
        var lines: [String] = [
            "# Model Card — \(title)",
            "",
            "## Identity",
            "",
            "- Method: `\(method)`",
        ]
        if let jobId {
            lines.append("- Job id: `\(jobId)`")
        }
        if let adapterArtifactId {
            lines.append("- Adapter artifact id: `\(adapterArtifactId)`")
        }
        if let baseModelId {
            lines.append("- Base model id: `\(baseModelId)`")
        }
        if let baseModelSourceKey {
            lines.append("- Base model source: `\(baseModelSourceKey)`")
        }
        if fakeTrain {
            lines.append("- Train mode: **fake** (`BAM_LORA_FAKE` or mlx-lm unavailable)")
        } else {
            lines.append("- Train mode: **mlx-lm**")
        }
        lines.append("")
        lines.append("## Hyperparameters")
        lines.append("")
        lines.append(hyperparametersSummary ?? "_not recorded_")
        lines.append("")
        lines.append("## Evaluation (MVP / K25)")
        lines.append("")
        lines.append(
            "Job “done” for MVP = **hold-out validation loss** (when available) + **sample generations**."
        )
        lines.append("")
        if let trainLoss {
            lines.append(String(format: "- Final train loss: `%.6f`", trainLoss))
        }
        if let holdOutLoss {
            lines.append(String(format: "- Hold-out validation loss: `%.6f`", holdOutLoss))
        } else {
            lines.append("- Hold-out validation loss: _n/a_ (no val split)")
        }
        lines.append("")
        lines.append("### Sample generations")
        lines.append("")
        if sampleGenerations.isEmpty {
            lines.append("_none_")
        } else {
            for (idx, sample) in sampleGenerations.enumerated() {
                lines.append("\(idx + 1). **Prompt:** \(sample.prompt)")
                lines.append("   **Completion:** \(sample.completion)")
                lines.append("")
            }
        }
        if !notes.isEmpty {
            lines.append("## Notes")
            lines.append("")
            for note in notes {
                lines.append("- \(note)")
            }
            lines.append("")
        }
        lines.append("## Artifacts")
        lines.append("")
        lines.append("- `adapter_config.json`")
        lines.append("- `adapters.safetensors` (weights; stub in fake mode)")
        lines.append("- `metrics.json`")
        lines.append("- `model_card.md` (this file)")
        lines.append("")
        return lines.joined(separator: "\n")
    }

    /// Compact metrics JSON for library / UI.
    public func metricsDictionary() -> [String: Any] {
        var d: [String: Any] = [
            "method": method,
            "fakeTrain": fakeTrain,
            "sampleGenerationCount": sampleGenerations.count,
        ]
        if let holdOutLoss { d["holdOutLoss"] = holdOutLoss }
        if let trainLoss { d["trainLoss"] = trainLoss }
        if let jobId { d["jobId"] = jobId }
        if let adapterArtifactId { d["adapterArtifactId"] = adapterArtifactId }
        if let baseModelId { d["baseModelId"] = baseModelId }
        if let baseModelSourceKey { d["baseModelSourceKey"] = baseModelSourceKey }
        d["sampleGenerations"] = sampleGenerations.map {
            ["prompt": $0.prompt, "completion": $0.completion]
        }
        return d
    }
}

/// Writes / loads `model_card.md` (+ optional `metrics.json`) under an adapter directory.
public enum ModelCardWriter: Sendable {
    public static let modelCardFileName = "model_card.md"
    public static let metricsFileName = "metrics.json"

    @discardableResult
    public static func write(
        content: ModelCardContent,
        toDirectory directory: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let cardURL = directory.appendingPathComponent(modelCardFileName, isDirectory: false)
        try Data(content.renderMarkdown().utf8).write(to: cardURL, options: .atomic)

        let metricsURL = directory.appendingPathComponent(metricsFileName, isDirectory: false)
        let metricsData = try JSONSerialization.data(
            withJSONObject: content.metricsDictionary(),
            options: [.sortedKeys, .prettyPrinted]
        )
        try metricsData.write(to: metricsURL, options: .atomic)
        return cardURL
    }

    /// Load model-card content from an adapter directory (`metrics.json` preferred).
    ///
    /// Falls back to a minimal card if only `model_card.md` exists (no samples).
    public static func load(
        fromDirectory directory: URL,
        fileManager: FileManager = .default
    ) -> ModelCardContent? {
        let metricsURL = directory.appendingPathComponent(metricsFileName, isDirectory: false)
        if fileManager.fileExists(atPath: metricsURL.path),
           let data = try? Data(contentsOf: metricsURL),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            return ModelCardContent(metricsDictionary: obj, fallbackTitle: directory.lastPathComponent)
        }
        let cardURL = directory.appendingPathComponent(modelCardFileName, isDirectory: false)
        guard fileManager.fileExists(atPath: cardURL.path) else { return nil }
        return ModelCardContent(
            title: directory.lastPathComponent,
            notes: ["metrics.json missing; only model_card.md present."]
        )
    }
}

extension ModelCardContent {
    /// Reconstructs from `metrics.json` dictionary shape written by `metricsDictionary()`.
    public init(metricsDictionary d: [String: Any], fallbackTitle: String = "LoRA Adapter") {
        let samples: [ModelCardSampleGeneration]
        if let arr = d["sampleGenerations"] as? [[String: Any]] {
            samples = arr.compactMap { row in
                guard let prompt = row["prompt"] as? String,
                      let completion = row["completion"] as? String
                else { return nil }
                return ModelCardSampleGeneration(prompt: prompt, completion: completion)
            }
        } else {
            samples = []
        }
        self.init(
            title: fallbackTitle,
            baseModelId: d["baseModelId"] as? String,
            baseModelSourceKey: d["baseModelSourceKey"] as? String,
            method: (d["method"] as? String) ?? "lora",
            jobId: d["jobId"] as? String,
            adapterArtifactId: d["adapterArtifactId"] as? String,
            holdOutLoss: Self.double(from: d["holdOutLoss"]),
            trainLoss: Self.double(from: d["trainLoss"]),
            sampleGenerations: samples,
            hyperparametersSummary: d["hyperparametersSummary"] as? String,
            notes: [],
            fakeTrain: (d["fakeTrain"] as? Bool) ?? false
        )
    }

    private static func double(from value: Any?) -> Double? {
        switch value {
        case let d as Double: return d
        case let i as Int: return Double(i)
        case let n as NSNumber: return n.doubleValue
        default: return nil
        }
    }
}
