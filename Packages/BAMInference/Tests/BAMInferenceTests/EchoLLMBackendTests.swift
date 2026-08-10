import XCTest
@testable import BAMInference

final class EchoLLMBackendTests: XCTestCase {
    func testEchoIncludesSystemAndLastUser() async throws {
        let backend = EchoLLMBackend()
        let request = LLMCompletionRequest(
            messages: [
                .system("Be brief."),
                .user("What is 2+2?"),
            ],
            baseModelPath: "/tmp/models/base/tiny-qwen",
            adapterPath: nil,
            adapterEnabled: false
        )
        let result = try await backend.complete(request)
        XCTAssertEqual(result.backendId, "echo")
        XCTAssertTrue(result.isStub)
        XCTAssertEqual(result.assistantMessage.role, "assistant")
        XCTAssertTrue(result.assistantMessage.content.contains("system: Be brief."))
        XCTAssertTrue(result.assistantMessage.content.contains("user: What is 2+2?"))
        XCTAssertTrue(result.assistantMessage.content.contains("adapter=off"))
        XCTAssertTrue(result.assistantMessage.content.contains("base=tiny-qwen"))
    }

    func testEchoReflectsAdapterOnA_B() async throws {
        let backend = EchoLLMBackend()
        let withAdapter = LLMCompletionRequest(
            messages: [.user("hello")],
            baseModelPath: "/m/base",
            adapterPath: "/m/adapters/lora-1",
            adapterEnabled: true
        )
        let on = try await backend.complete(withAdapter)
        XCTAssertTrue(on.assistantMessage.content.contains("adapter=on (lora-1)"))

        let offRequest = LLMCompletionRequest(
            messages: [.user("hello")],
            baseModelPath: "/m/base",
            adapterPath: "/m/adapters/lora-1",
            adapterEnabled: false
        )
        let off = try await backend.complete(offRequest)
        XCTAssertTrue(off.assistantMessage.content.contains("adapter=off"))
    }

    func testFactoryForceEcho() {
        let backend = LLMBackendFactory.makeDefault(forceEcho: true)
        XCTAssertEqual(backend.backendId, "echo")
    }

    func testSessionSendAppendsTurns() async throws {
        var session = PlaygroundSession(
            systemPrompt: "sys",
            baseModelPath: "/models/base/x"
        )
        let backend = EchoLLMBackend()
        _ = try await session.send(userText: "  hi there  ", backend: backend)
        XCTAssertEqual(session.messages.count, 2)
        XCTAssertEqual(session.messages[0].role, "user")
        XCTAssertEqual(session.messages[0].content, "hi there")
        XCTAssertEqual(session.messages[1].role, "assistant")
        XCTAssertEqual(session.lastBackendId, "echo")
        XCTAssertEqual(session.lastWasStub, true)

        let exported = session.exportMessages()
        XCTAssertEqual(exported.first?.role, "system")
        XCTAssertEqual(exported.first?.content, "sys")
    }

    func testEffectiveAdapterPathHonorsToggle() {
        let on = LLMCompletionRequest(
            messages: [],
            adapterPath: "/a",
            adapterEnabled: true
        )
        XCTAssertEqual(on.effectiveAdapterPath, "/a")
        let off = LLMCompletionRequest(
            messages: [],
            adapterPath: "/a",
            adapterEnabled: false
        )
        XCTAssertNil(off.effectiveAdapterPath)
    }
}
