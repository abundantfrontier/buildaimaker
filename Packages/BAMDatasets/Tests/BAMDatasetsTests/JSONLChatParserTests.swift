import XCTest
import BAMCore
import BAMDatasets

final class JSONLChatParserTests: XCTestCase {
    func testValidOpenAIMessagesFixture() throws {
        let url = try fixtureURL("valid_openai_messages.jsonl")
        let result = try JSONLChatParser.validate(fileURL: url)
        XCTAssertTrue(result.isValid, "issues: \(result.issues)")
        XCTAssertEqual(result.format, .openaiMessages)
        XCTAssertEqual(result.rowCount, 2)
        XCTAssertTrue(result.issues.isEmpty)
    }

    func testValidShareGPTFixture() throws {
        let url = try fixtureURL("valid_sharegpt.jsonl")
        let result = try JSONLChatParser.validate(fileURL: url)
        XCTAssertTrue(result.isValid, "issues: \(result.issues)")
        XCTAssertEqual(result.format, .shareGPT)
        XCTAssertEqual(result.rowCount, 2)
    }

    func testInvalidNotJSON() throws {
        let url = try fixtureURL("invalid_not_json.jsonl")
        let result = try JSONLChatParser.validate(fileURL: url)
        XCTAssertFalse(result.isValid)
        XCTAssertFalse(result.issues.isEmpty)
        XCTAssertEqual(result.issues[0].code, .datasetInvalid)
        XCTAssertEqual(result.issues[0].line, 1)
        XCTAssertTrue(result.issues[0].message.contains("Invalid JSON"))
    }

    func testInvalidMissingMessages() throws {
        let url = try fixtureURL("invalid_missing_messages.jsonl")
        let result = try JSONLChatParser.validate(fileURL: url)
        XCTAssertFalse(result.isValid)
        XCTAssertEqual(result.issues[0].line, 1)
        XCTAssertTrue(
            result.issues[0].message.contains("Unrecognized")
                || result.issues[0].message.contains("messages")
        )
    }

    func testInvalidEmptyMessages() throws {
        let url = try fixtureURL("invalid_empty_messages.jsonl")
        let result = try JSONLChatParser.validate(fileURL: url)
        XCTAssertFalse(result.isValid)
        XCTAssertTrue(result.issues.contains { $0.message.contains("empty") })
    }

    func testInvalidBadRole() throws {
        let url = try fixtureURL("invalid_bad_role.jsonl")
        let result = try JSONLChatParser.validate(fileURL: url)
        XCTAssertFalse(result.isValid)
        XCTAssertTrue(result.issues[0].message.contains("unknown role"))
        XCTAssertEqual(result.issues[0].code, .datasetInvalid)
    }

    func testEmptyContents() {
        let result = JSONLChatParser.validate(contents: "\n\n  \n")
        XCTAssertFalse(result.isValid)
        XCTAssertTrue(result.issues[0].message.lowercased().contains("empty"))
    }

    func testPreviewOpenAI() throws {
        let url = try fixtureURL("valid_openai_messages.jsonl")
        let examples = try JSONLChatParser.preview(fileURL: url, maxExamples: 1)
        XCTAssertEqual(examples.count, 1)
        XCTAssertEqual(examples[0].messages.count, 3)
        XCTAssertEqual(examples[0].messages[0].role, "system")
        XCTAssertEqual(examples[0].messages[1].role, "user")
        XCTAssertEqual(examples[0].messages[2].role, "assistant")
    }

    func testPreviewShareGPTMapsSpeakers() throws {
        let url = try fixtureURL("valid_sharegpt.jsonl")
        let examples = try JSONLChatParser.preview(fileURL: url, maxExamples: 2)
        XCTAssertEqual(examples.count, 2)
        XCTAssertEqual(examples[0].messages[0].role, "user")
        XCTAssertEqual(examples[0].messages[1].role, "assistant")
        XCTAssertEqual(examples[1].messages[0].role, "system")
    }

    func testValidateContentsMatchesFile() throws {
        let url = try fixtureURL("valid_openai_messages.jsonl")
        let contents = try String(contentsOf: url, encoding: .utf8)
        let fromString = JSONLChatParser.validate(contents: contents)
        let fromFile = try JSONLChatParser.validate(fileURL: url)
        XCTAssertEqual(fromString.isValid, fromFile.isValid)
        XCTAssertEqual(fromString.rowCount, fromFile.rowCount)
        XCTAssertEqual(fromString.format, fromFile.format)
    }

    func testBAMErrorSurfaceFromIssue() {
        let issue = DatasetValidationIssue(line: 3, message: "bad row")
        let error = issue.asBAMError
        XCTAssertEqual(error.code, .datasetInvalid)
        XCTAssertEqual(error.message, "line 3: bad row")
    }

    // MARK: - Helpers

    private func fixtureURL(_ name: String) throws -> URL {
        let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")
            ?? Bundle.module.url(forResource: (name as NSString).deletingPathExtension,
                                 withExtension: (name as NSString).pathExtension,
                                 subdirectory: "Fixtures")
            ?? Bundle.module.url(forResource: (name as NSString).deletingPathExtension,
                                 withExtension: (name as NSString).pathExtension)
        guard let url else {
            XCTFail("Missing fixture \(name) in Bundle.module")
            throw BAMError(code: .datasetInvalid, message: "missing fixture \(name)")
        }
        return url
    }
}
