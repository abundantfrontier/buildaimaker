import BAMCore
import BAMDatasets
import BAMJobs
import BAMModels
import BAMRunners
import XCTest

@testable import BAMRunnersMLX

final class JobMaterializerTests: XCTestCase {
    private var libraryRoot: URL!
    private var fm: FileManager!

    override func setUpWithError() throws {
        fm = .default
        libraryRoot = fm.temporaryDirectory
            .appendingPathComponent("bam-mat-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: libraryRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: libraryRoot)
    }

    func testMaterializePathLayout() throws {
        let source = try writeFixtureJSONL()
        let modelDir = try writeFixtureModel()

        let jobId = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
        let request = LLMMaterializeRequest(
            jobId: jobId,
            libraryRoot: libraryRoot,
            sourceJSONLURL: source,
            baseModelPath: modelDir,
            baseModelId: DomainFixtures.baseModelId,
            baseModelSourceKey: "buildaimaker/tiny-qwen-mlx-fixture",
            datasetVersionId: DomainFixtures.datasetVersionId,
            chatTemplateId: ChatTemplateRegistry.qwen25Instruct
        )

        let materializer = JobMaterializer(fileManager: fm)
        let result = try materializer.materialize(request)

        // Spec / paths linkage
        XCTAssertEqual(result.spec.id, jobId)
        XCTAssertEqual(result.spec.modality, .llm)
        XCTAssertEqual(result.spec.chatTemplateId, ChatTemplateRegistry.qwen25Instruct)
        XCTAssertEqual(result.paths.libraryRoot, libraryRoot.path)
        XCTAssertTrue(result.paths.jobDir.hasPrefix(libraryRoot.path))
        XCTAssertEqual(result.paths.datasetPath, result.normalizedJSONLURL.path)
        XCTAssertEqual(result.paths.baseModelPath, modelDir.path)
        XCTAssertNil(result.paths.referenceAudioPath)
        XCTAssertGreaterThan(result.exampleCount, 0)

        // Path jail
        try PathJail.validate(paths: result.paths)
        try PathJail.validateModalityRequirements(job: result.spec, paths: result.paths)

        // On-disk layout
        let jobDir = URL(fileURLWithPath: result.paths.jobDir, isDirectory: true)
        try JobMaterializer.assertLayoutExists(jobDir: jobDir, fileManager: fm)

        // cancelFlagPath reserved under jobDir; file not created until cancel
        XCTAssertTrue(result.paths.cancelFlagPath.hasPrefix(jobDir.path))
        XCTAssertFalse(
            fm.fileExists(atPath: result.paths.cancelFlagPath),
            "cancel.flag must not exist pre-cancel (would trip CancelFlag.exists)"
        )
        XCTAssertEqual(
            (result.paths.cancelFlagPath as NSString).lastPathComponent,
            "cancel.flag"
        )

        // job.json round-trip
        let jobJSON = try Data(contentsOf: JobPathsFactory.jobJSONURL(paths: result.paths))
        let decodedSpec = try JSONDecoder().decode(JobSpec.self, from: jobJSON)
        XCTAssertEqual(decodedSpec.id, jobId)
        XCTAssertEqual(decodedSpec.baseModelSourceKey, "buildaimaker/tiny-qwen-mlx-fixture")

        // paths.json round-trip
        let pathsJSON = try Data(
            contentsOf: jobDir.appendingPathComponent("paths.json")
        )
        let decodedPaths = try JSONDecoder().decode(JobPaths.self, from: pathsJSON)
        XCTAssertEqual(decodedPaths.datasetPath, result.paths.datasetPath)
        XCTAssertEqual(decodedPaths.baseModelPath, result.paths.baseModelPath)

        // Normalized JSONL is OpenAI messages
        let trainText = try String(contentsOf: result.normalizedJSONLURL, encoding: .utf8)
        XCTAssertTrue(trainText.contains("\"messages\""))
        XCTAssertTrue(trainText.contains("\"role\""))

        // Templated JSONL has text field with ChatML markers
        let templatedText = try String(contentsOf: result.templatedJSONLURL, encoding: .utf8)
        XCTAssertTrue(templatedText.contains("\"text\""))
        XCTAssertTrue(templatedText.contains("<|im_start|>"))
    }

    func testMaterializeRejectsInvalidDataset() throws {
        let bad = libraryRoot.appendingPathComponent("bad.jsonl")
        try Data("not-json\n".utf8).write(to: bad)
        let modelDir = try writeFixtureModel()

        let request = LLMMaterializeRequest(
            libraryRoot: libraryRoot,
            sourceJSONLURL: bad,
            baseModelPath: modelDir,
            baseModelId: DomainFixtures.baseModelId,
            baseModelSourceKey: "buildaimaker/tiny-qwen-mlx-fixture",
            datasetVersionId: DomainFixtures.datasetVersionId
        )

        XCTAssertThrowsError(try JobMaterializer().materialize(request)) { error in
            let bam = error as? BAMError
            XCTAssertEqual(bam?.code, .datasetInvalid)
        }
    }

    func testMaterializeRejectsMissingModel() throws {
        let source = try writeFixtureJSONL()
        let missing = libraryRoot.appendingPathComponent("models/base/nope", isDirectory: true)

        let request = LLMMaterializeRequest(
            libraryRoot: libraryRoot,
            sourceJSONLURL: source,
            baseModelPath: missing,
            baseModelId: DomainFixtures.baseModelId,
            baseModelSourceKey: "missing",
            datasetVersionId: DomainFixtures.datasetVersionId
        )

        XCTAssertThrowsError(try JobMaterializer().materialize(request)) { error in
            let bam = error as? BAMError
            XCTAssertEqual(bam?.code, .modelNotFound)
        }
    }

    func testJobLocalPathsUnderLibraryRoot() throws {
        let source = try writeFixtureJSONL()
        let modelDir = try writeFixtureModel()
        let result = try JobMaterializer().materialize(
            LLMMaterializeRequest(
                libraryRoot: libraryRoot,
                sourceJSONLURL: source,
                baseModelPath: modelDir,
                baseModelId: "m1",
                baseModelSourceKey: "k",
                datasetVersionId: "v1"
            )
        )

        let jobDir = result.paths.jobDir
        XCTAssertTrue(result.paths.outputPath.hasPrefix(jobDir))
        XCTAssertTrue(result.paths.checkpointPath.hasPrefix(jobDir))
        XCTAssertTrue(result.paths.logPath.hasPrefix(jobDir))
        XCTAssertTrue(result.paths.cancelFlagPath.hasPrefix(jobDir))
        XCTAssertTrue(result.paths.datasetPath?.hasPrefix(jobDir) == true)
        XCTAssertTrue(result.normalizedJSONLURL.path.contains("/data/train.jsonl"))
        XCTAssertTrue(result.templatedJSONLURL.path.contains("/data/templated.jsonl"))
    }

    func testChatTemplateRegistryChatML() {
        let example = ChatExampleLike(
            messages: [
                ChatMessageLike(role: "system", content: "You are helpful."),
                ChatMessageLike(role: "user", content: "Hi"),
                ChatMessageLike(role: "assistant", content: "Hello"),
            ]
        )
        let text = ChatTemplateRegistry.apply(
            templateId: ChatTemplateRegistry.qwen25Instruct,
            example: example
        )
        XCTAssertTrue(text.contains("<|im_start|>system"))
        XCTAssertTrue(text.contains("<|im_start|>user"))
        XCTAssertTrue(text.contains("<|im_start|>assistant"))
        XCTAssertTrue(ChatTemplateRegistry.isKnown(ChatTemplateRegistry.chatMLGeneric))
    }

    // MARK: - Fixtures

    private func writeFixtureJSONL() throws -> URL {
        let url = libraryRoot.appendingPathComponent("source.jsonl")
        let body = """
            {"messages":[{"role":"system","content":"sys"},{"role":"user","content":"hello"},{"role":"assistant","content":"world"}]}
            {"messages":[{"role":"user","content":"ping"},{"role":"assistant","content":"pong"}]}
            """
        try Data(body.utf8).write(to: url)
        return url
    }

    private func writeFixtureModel() throws -> URL {
        let dir = libraryRoot
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent("base", isDirectory: true)
            .appendingPathComponent("tiny-qwen-mlx-fixture", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{\"model_type\":\"qwen2\"}".utf8)
            .write(to: dir.appendingPathComponent("config.json"))
        try Data("stub".utf8)
            .write(to: dir.appendingPathComponent("tokenizer.json"))
        try Data("stub".utf8)
            .write(to: dir.appendingPathComponent("tokenizer_config.json"))
        try Data("weights not included".utf8)
            .write(to: dir.appendingPathComponent("WEIGHTS_NOT_INCLUDED.txt"))
        return dir
    }
}
