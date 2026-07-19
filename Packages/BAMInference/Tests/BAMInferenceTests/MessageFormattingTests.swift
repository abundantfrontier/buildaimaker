import XCTest
@testable import BAMInference

final class MessageFormattingTests: XCTestCase {
    func testFormatChatML_withSystemUser_opensAssistant() {
        let messages: [InferenceChatMessage] = [
            .system("You are helpful."),
            .user("Hello"),
        ]
        let formatted = ChatPromptFormatter.formatChatML(messages)
        XCTAssertTrue(formatted.contains("<|im_start|>system\nYou are helpful.<|im_end|>"))
        XCTAssertTrue(formatted.contains("<|im_start|>user\nHello<|im_end|>"))
        XCTAssertTrue(formatted.hasSuffix("<|im_start|>assistant\n"))
    }

    func testFormatChatML_endsWithAssistant_noOpenTurn() {
        let messages: [InferenceChatMessage] = [
            .user("Hi"),
            .assistant("Hey"),
        ]
        let formatted = ChatPromptFormatter.formatChatML(messages)
        XCTAssertFalse(formatted.hasSuffix("<|im_start|>assistant\n"))
        XCTAssertTrue(formatted.contains("<|im_start|>assistant\nHey<|im_end|>"))
    }

    func testFormatPlain_rolesAndContent() {
        let messages: [InferenceChatMessage] = [
            .system("sys"),
            .user("q"),
            .assistant("a"),
        ]
        let plain = ChatPromptFormatter.formatPlain(messages)
        XCTAssertEqual(plain, "system: sys\nuser: q\nassistant: a")
    }

    func testFormat_templateDispatch() {
        let messages = [InferenceChatMessage.user("x")]
        let chatml = ChatPromptFormatter.format(templateId: "chatml", messages: messages)
        let qwen = ChatPromptFormatter.format(templateId: "qwen2.5-instruct", messages: messages)
        let plain = ChatPromptFormatter.format(templateId: "plain", messages: messages)
        XCTAssertEqual(chatml, qwen)
        XCTAssertTrue(chatml.contains("<|im_start|>user"))
        XCTAssertEqual(plain, "user: x")
    }

    func testSystemAndLastUserExtractors() {
        let messages: [InferenceChatMessage] = [
            .system("S"),
            .user("first"),
            .assistant("a"),
            .user("second"),
        ]
        XCTAssertEqual(ChatPromptFormatter.systemPrompt(from: messages), "S")
        XCTAssertEqual(ChatPromptFormatter.lastUserMessage(from: messages), "second")
    }

    func testMessagesForCompletion_systemOverrideReplacesPriorSystem() {
        let history: [InferenceChatMessage] = [
            .system("old"),
            .user("hi"),
        ]
        let result = ChatPromptFormatter.messagesForCompletion(
            history: history,
            systemOverride: "new system"
        )
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].role, "system")
        XCTAssertEqual(result[0].content, "new system")
        XCTAssertEqual(result[1].role, "user")
        XCTAssertEqual(result[1].content, "hi")
    }

    func testMessagesForCompletion_nilOverrideKeepsHistory() {
        let history: [InferenceChatMessage] = [
            .system("keep"),
            .user("hi"),
        ]
        let result = ChatPromptFormatter.messagesForCompletion(history: history, systemOverride: nil)
        XCTAssertEqual(result, history)
    }

    func testMessagesForCompletion_blankOverrideIgnored() {
        let history = [InferenceChatMessage.user("only")]
        let result = ChatPromptFormatter.messagesForCompletion(history: history, systemOverride: "  ")
        XCTAssertEqual(result, history)
    }
}
