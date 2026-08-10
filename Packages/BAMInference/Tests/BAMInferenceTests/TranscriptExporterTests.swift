import XCTest
@testable import BAMInference

final class TranscriptExporterTests: XCTestCase {
    func testJSONLLineIsValidOpenAIMessagesShape() throws {
        let messages: [InferenceChatMessage] = [
            .system("You are helpful."),
            .user("What is 2+2?"),
            .assistant("4"),
        ]
        let line = try TranscriptExporter.jsonlLine(from: messages)
        let data = Data(line.utf8)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let msgs = obj?["messages"] as? [[String: String]]
        XCTAssertEqual(msgs?.count, 3)
        XCTAssertEqual(msgs?[0]["role"], "system")
        XCTAssertEqual(msgs?[0]["content"], "You are helpful.")
        XCTAssertEqual(msgs?[1]["role"], "user")
        XCTAssertEqual(msgs?[2]["role"], "assistant")
        // No id fields in dataset candidate.
        XCTAssertNil(msgs?[0]["id"])
    }

    func testExportConversationEndsWithNewline() throws {
        let body = try TranscriptExporter.exportConversationJSONL(messages: [
            .user("a"),
            .assistant("b"),
        ])
        XCTAssertTrue(body.hasSuffix("\n"))
        XCTAssertEqual(body.split(separator: "\n", omittingEmptySubsequences: false).count, 2)
    }

    func testExportPairedSplitsTurns() throws {
        let messages: [InferenceChatMessage] = [
            .system("S"),
            .user("u1"),
            .assistant("a1"),
            .user("u2"),
            .assistant("a2"),
        ]
        let body = try TranscriptExporter.exportPairedJSONL(messages: messages)
        let lines = body.split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, 2)

        for line in lines {
            let data = Data(line.utf8)
            let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let msgs = obj?["messages"] as? [[String: String]]
            XCTAssertEqual(msgs?.first?["role"], "system")
            XCTAssertEqual(msgs?.count, 3)
        }
    }

    func testWriteCreatesFile() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bam-transcript-\(UUID().uuidString)", isDirectory: true)
        let url = dir.appendingPathComponent("candidate.jsonl")
        defer { try? FileManager.default.removeItem(at: dir) }

        try TranscriptExporter.write(
            messages: [
                .user("hello"),
                .assistant("world"),
            ],
            to: url,
            paired: false
        )
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("\"role\":\"user\""))
        XCTAssertTrue(text.contains("hello"))
        XCTAssertTrue(text.contains("world"))
    }
}
