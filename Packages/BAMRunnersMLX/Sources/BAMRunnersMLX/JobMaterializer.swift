import BAMCore
import BAMDatasets
import BAMJobs
import BAMModels
import BAMRunners
import Foundation

/// Inputs required to materialize an LLM training job on disk.
public struct LLMMaterializeRequest: Sendable, Equatable {
    public var jobId: String
    public var libraryRoot: URL
    /// Absolute path to the source JSONL (ShareGPT or OpenAI messages).
    public var sourceJSONLURL: URL
    /// Absolute path to the local base model directory.
    public var baseModelPath: URL
    public var baseModelId: String
    public var baseModelSourceKey: String
    public var datasetVersionId: String
    public var chatTemplateId: String
    public var hyperparameters: LLMHyperparameters
    public var resources: JobResources
    public var outputs: JobOutputs
    public var method: String

    public init(
        jobId: String = BAMID.generate(),
        libraryRoot: URL,
        sourceJSONLURL: URL,
        baseModelPath: URL,
        baseModelId: String,
        baseModelSourceKey: String,
        datasetVersionId: String,
        chatTemplateId: String = ChatTemplateRegistry.qwen25Instruct,
        hyperparameters: LLMHyperparameters = LLMHyperparameters(),
        resources: JobResources = JobResources(maxMemoryGB: 24, threads: 8),
        outputs: JobOutputs = JobOutputs(),
        method: String = "lora"
    ) {
        self.jobId = jobId
        self.libraryRoot = libraryRoot
        self.sourceJSONLURL = sourceJSONLURL
        self.baseModelPath = baseModelPath
        self.baseModelId = baseModelId
        self.baseModelSourceKey = baseModelSourceKey
        self.datasetVersionId = datasetVersionId
        self.chatTemplateId = chatTemplateId
        self.hyperparameters = hyperparameters
        self.resources = resources
        self.outputs = outputs
        self.method = method
    }
}

/// Result of materializing an LLM job directory.
public struct LLMMaterializeResult: Sendable, Equatable {
    public var spec: JobSpec
    public var paths: JobPaths
    /// Absolute path to the normalized OpenAI-messages JSONL (`data/train.jsonl`).
    public var normalizedJSONLURL: URL
    /// Absolute path to the template-applied JSONL (`data/templated.jsonl`).
    public var templatedJSONLURL: URL
    public var exampleCount: Int
    public var chatTemplateId: String

    public init(
        spec: JobSpec,
        paths: JobPaths,
        normalizedJSONLURL: URL,
        templatedJSONLURL: URL,
        exampleCount: Int,
        chatTemplateId: String
    ) {
        self.spec = spec
        self.paths = paths
        self.normalizedJSONLURL = normalizedJSONLURL
        self.templatedJSONLURL = templatedJSONLURL
        self.exampleCount = exampleCount
        self.chatTemplateId = chatTemplateId
    }
}

/// Writes normalized training data + resolved `JobPaths` for an LLM LoRA job.
///
/// Layout under `jobs/<jobId>/`:
/// ```
/// job.json
/// paths.json           # resolved JobPaths (includes cancelFlagPath placeholder path)
/// data/train.jsonl     # canonical OpenAI messages
/// data/templated.jsonl # ChatTemplateRegistry-applied text rows
/// artifacts/
/// checkpoints/
/// logs/
/// ```
///
/// `cancelFlagPath` is reserved on `JobPaths` / `paths.json` but the flag file is
/// **not** created at materialize time (creating it would trip `CancelFlag.exists`).
/// Real cancel writes `"1"` via `CancelFlag.write`.
///
/// Does **not** invoke the worker or update weights.
public struct JobMaterializer: @unchecked Sendable {
    /// Not Sendable in the SDK; treat as effectively immutable for our use.
    public var fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// Materialize job dir from an explicit request (tests / services).
    public func materialize(_ request: LLMMaterializeRequest) throws -> LLMMaterializeResult {
        try validateRequest(request)

        let paths = JobPathsFactory.make(
            jobId: request.jobId,
            libraryRoot: request.libraryRoot,
            datasetPath: nil,
            baseModelPath: request.baseModelPath.resolvingSymlinksInPath().path,
            referenceAudioPath: nil
        )

        // Job-local normalized dataset path (jailed under jobDir / libraryRoot).
        let dataDir = URL(fileURLWithPath: paths.jobDir, isDirectory: true)
            .appendingPathComponent("data", isDirectory: true)
        let trainURL = dataDir.appendingPathComponent("train.jsonl", isDirectory: false)
        let templatedURL = dataDir.appendingPathComponent("templated.jsonl", isDirectory: false)

        var resolved = paths
        resolved.datasetPath = trainURL.path

        try PathJail.validate(paths: resolved)

        let spec = JobSpec.llm(
            id: request.jobId,
            baseModelId: request.baseModelId,
            baseModelSourceKey: request.baseModelSourceKey,
            datasetVersionId: request.datasetVersionId,
            method: request.method,
            chatTemplateId: request.chatTemplateId,
            hyperparameters: request.hyperparameters,
            resources: request.resources,
            outputs: request.outputs
        )

        try PathJail.validateModalityRequirements(job: spec, paths: resolved)

        // Directories
        try createJobLayout(paths: resolved, dataDir: dataDir)

        // Normalized + templated JSONL
        let exampleCount = try writeNormalizedJSONL(
            source: request.sourceJSONLURL,
            trainURL: trainURL,
            templatedURL: templatedURL,
            templateId: request.chatTemplateId
        )
        guard exampleCount > 0 else {
            throw BAMError(
                code: .datasetInvalid,
                message: "No valid chat examples found in \(request.sourceJSONLURL.path)"
            )
        }

        // job.json + paths.json (cancelFlagPath reserved; file written only on cancel)
        try writeJobJSON(spec: spec, paths: resolved)
        try writePathsJSON(paths: resolved)

        return LLMMaterializeResult(
            spec: spec,
            paths: resolved,
            normalizedJSONLURL: trainURL,
            templatedJSONLURL: templatedURL,
            exampleCount: exampleCount,
            chatTemplateId: request.chatTemplateId
        )
    }

    // MARK: - Layout helpers

    /// Expected relative paths under `jobDir` after a successful materialize.
    /// (`cancel.flag` is reserved on JobPaths but created only when cancel is requested.)
    public static let expectedRelativeLayout: [String] = [
        "job.json",
        "paths.json",
        "data/train.jsonl",
        "data/templated.jsonl",
        "artifacts",
        "checkpoints",
        "logs",
    ]

    /// Asserts the on-disk layout matches materializer output (unit tests).
    public static func assertLayoutExists(jobDir: URL, fileManager: FileManager = .default) throws {
        for relative in expectedRelativeLayout {
            let url = jobDir.appendingPathComponent(relative)
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir) else {
                throw BAMError(
                    code: .schemaInvalid,
                    message: "Missing materialization artifact: \(relative)"
                )
            }
            let expectsDir = ["artifacts", "checkpoints", "logs"].contains(relative)
            if expectsDir, !isDir.boolValue {
                throw BAMError(
                    code: .schemaInvalid,
                    message: "Expected directory at \(relative)"
                )
            }
            if !expectsDir, isDir.boolValue {
                throw BAMError(
                    code: .schemaInvalid,
                    message: "Expected file at \(relative)"
                )
            }
        }
    }

    // MARK: - Private

    private func validateRequest(_ request: LLMMaterializeRequest) throws {
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: request.sourceJSONLURL.path, isDirectory: &isDir),
              !isDir.boolValue
        else {
            throw BAMError(
                code: .datasetInvalid,
                message: "Source JSONL not found: \(request.sourceJSONLURL.path)"
            )
        }

        isDir = false
        guard fileManager.fileExists(atPath: request.baseModelPath.path, isDirectory: &isDir),
              isDir.boolValue
        else {
            throw BAMError(
                code: .modelNotFound,
                message: "Base model directory not found: \(request.baseModelPath.path)"
            )
        }

        // Jail model path under library root when it already lives there; allow
        // external fixture paths only if they resolve under libraryRoot after copy
        // (caller is responsible for install). We still require absolute paths.
        let modelPath = request.baseModelPath.path
        guard modelPath.hasPrefix("/") else {
            throw BAMError(code: .pathEscape, message: "baseModelPath must be absolute")
        }
        let sourcePath = request.sourceJSONLURL.path
        guard sourcePath.hasPrefix("/") else {
            throw BAMError(code: .pathEscape, message: "sourceJSONLURL must be absolute")
        }
    }

    private func createJobLayout(paths: JobPaths, dataDir: URL) throws {
        let dirs = [
            paths.jobDir,
            paths.outputPath,
            paths.checkpointPath,
            paths.logPath,
            dataDir.path,
        ]
        for path in dirs {
            try fileManager.createDirectory(atPath: path, withIntermediateDirectories: true)
        }
    }

    private func writeJobJSON(spec: JobSpec, paths: JobPaths) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(spec)
        let url = JobPathsFactory.jobJSONURL(paths: paths)
        try data.write(to: url, options: .atomic)
    }

    private func writePathsJSON(paths: JobPaths) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(paths)
        let url = URL(fileURLWithPath: paths.jobDir)
            .appendingPathComponent("paths.json", isDirectory: false)
        try data.write(to: url, options: .atomic)
    }

    /// Streams the source file, validates rows, writes canonical + templated JSONL.
    /// - Returns: number of examples written.
    private func writeNormalizedJSONL(
        source: URL,
        trainURL: URL,
        templatedURL: URL,
        templateId: String
    ) throws -> Int {
        // Full validation first so we fail closed before writing partial outputs.
        let validation = try JSONLChatParser.validate(fileURL: source)
        guard validation.isValid else {
            let detail = validation.issues.prefix(3).map(\.message).joined(separator: "; ")
            throw BAMError(
                code: .datasetInvalid,
                message: "Dataset validation failed: \(detail)"
            )
        }

        let handle = try FileHandle(forReadingFrom: source)
        defer { try? handle.close() }

        var trainLines: [String] = []
        var templatedLines: [String] = []
        var lineNumber = 0
        var count = 0

        // Re-parse via public preview for small files is insufficient; stream via validate path.
        // Use FileHandle line reading mirrored from JSONLChatParser.preview pattern.
        while true {
            guard let lineData = try readLine(from: handle) else { break }
            lineNumber += 1
            let trimmed = String(data: lineData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if trimmed.isEmpty { continue }

            guard let example = parseExample(line: trimmed) else { continue }
            count += 1

            // Canonical OpenAI messages row
            let canonical = try encodeCanonical(example)
            trainLines.append(canonical)

            // Templated single-text row
            let like = ChatExampleLike(
                messages: example.messages.map { ChatMessageLike(role: $0.role, content: $0.content) }
            )
            let text = ChatTemplateRegistry.apply(templateId: templateId, example: like)
            let templatedObj: [String: Any] = [
                "text": text,
                "messages": example.messages.map { ["role": $0.role, "content": $0.content] },
            ]
            let templatedData = try JSONSerialization.data(
                withJSONObject: templatedObj,
                options: [.sortedKeys]
            )
            if let s = String(data: templatedData, encoding: .utf8) {
                templatedLines.append(s)
            }
        }

        let trainBody = trainLines.joined(separator: "\n") + (trainLines.isEmpty ? "" : "\n")
        let templatedBody =
            templatedLines.joined(separator: "\n") + (templatedLines.isEmpty ? "" : "\n")
        try Data(trainBody.utf8).write(to: trainURL, options: .atomic)
        try Data(templatedBody.utf8).write(to: templatedURL, options: .atomic)
        return count
    }

    private func encodeCanonical(_ example: ChatExample) throws -> String {
        let obj: [String: Any] = [
            "messages": example.messages.map { ["role": $0.role, "content": $0.content] },
        ]
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
        guard let s = String(data: data, encoding: .utf8) else {
            throw BAMError(code: .datasetInvalid, message: "Failed to encode canonical example")
        }
        return s
    }

    private func parseExample(line: String) -> ChatExample? {
        // Prefer reusing validation path: decode via JSONLChatParser preview of single line.
        let examples = JSONLChatParser.preview(contents: line + "\n", maxExamples: 1)
        return examples.first
    }

    private func readLine(from handle: FileHandle) throws -> Data? {
        var buffer = Data()
        while true {
            let chunk = try handle.read(upToCount: 1) ?? Data()
            if chunk.isEmpty {
                return buffer.isEmpty ? nil : buffer
            }
            if chunk[0] == UInt8(ascii: "\n") {
                return buffer
            }
            if chunk[0] != UInt8(ascii: "\r") {
                buffer.append(chunk)
            }
        }
    }
}
