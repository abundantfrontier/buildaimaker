import XCTest
import BAMCore
@testable import BAMInference

final class TalkPipelineTests: XCTestCase {
    func testFakeSTTReturnsFixedTranscript() async throws {
        let stt = FakeSTTBackend(fixedTranscript: "unit test utterance")
        let session = try await stt.startStreamingSession(language: "en")
        if let fake = session as? FakeSTTStreamingSession {
            await fake.emitNextPartial()
            let partial = await fake.currentPartial
            XCTAssertFalse(partial.isEmpty)
        }
        let result = try await session.finalize()
        XCTAssertEqual(result.text, "unit test utterance")
        XCTAssertEqual(result.backendId, FakeSTTBackend.id)
        XCTAssertTrue(result.isStub)
        XCTAssertFalse(result.partials.isEmpty)
    }

    func testFakeTTSWritesSilentWav() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bam-tts-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let tts = FakeTTSBackend(writeSilentWav: true, simulatedLatencyMs: 0, silentSampleCount: 800)
        final class ProgressBox: @unchecked Sendable {
            var values: [Double] = []
        }
        let box = ProgressBox()
        let result = try await tts.synthesize(
            TTSRequest(text: "Hello world", outputDirectory: dir)
        ) { p in
            box.values.append(p)
        }
        XCTAssertEqual(result.backendId, FakeTTSBackend.id)
        XCTAssertTrue(result.isStub)
        XCTAssertFalse(result.wasCancelled)
        XCTAssertNotNil(result.audioURL)
        if let url = result.audioURL {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
            let data = try Data(contentsOf: url)
            // RIFF header
            XCTAssertEqual(String(data: data.prefix(4), encoding: .ascii), "RIFF")
            XCTAssertGreaterThan(data.count, 44)
        }
        XCTAssertFalse(box.values.isEmpty)
    }

    func testFakeTTSNoOpMode() async throws {
        let tts = FakeTTSBackend(writeSilentWav: false)
        let result = try await tts.synthesize(TTSRequest(text: "hi"))
        XCTAssertNil(result.audioURL)
        XCTAssertEqual(result.detail, "noop")
    }

    func testFakeTTSStopBargeIn() async throws {
        let tts = FakeTTSBackend(writeSilentWav: true, simulatedLatencyMs: 200)
        let task = Task {
            try await tts.synthesize(TTSRequest(text: "long synthesis"))
        }
        // Yield then barge-in.
        try await Task.sleep(nanoseconds: 30_000_000)
        await tts.stop()
        let result = try await task.value
        XCTAssertTrue(result.wasCancelled)
        XCTAssertNil(result.audioURL)
    }

    func testMicPermissionDeniedSurfacesBAMError() async throws {
        let stack = TalkBackendFactory.makeFakeStack()
        let coordinator = TalkCoordinator(
            stt: stack.stt,
            llm: stack.llm,
            tts: stack.tts,
            mic: FakeMicPermission(current: .denied),
            config: TalkCoordinatorConfig(baseModelPath: "/models/base/x")
        )
        do {
            _ = try await coordinator.ensureMicrophonePermission()
            XCTFail("expected TCC denial")
        } catch let error as BAMError {
            XCTAssertEqual(error.code, .tccMicDenied)
            XCTAssertTrue(
                (error.message ?? "").contains("Microphone")
                    || (error.errorDescription ?? "").contains("Microphone")
            )
        }
        let phase = await coordinator.phase
        XCTAssertEqual(phase, .error)
    }

    func testTalkTurnSTTThenLLMThenTTS() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bam-talk-turn-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let stt = FakeSTTBackend(fixedTranscript: "What is two plus two?")
        let llm = EchoLLMBackend()
        let tts = FakeTTSBackend(writeSilentWav: true, simulatedLatencyMs: 0)
        let coordinator = TalkCoordinator(
            stt: stt,
            llm: llm,
            tts: tts,
            mic: FakeMicPermission(current: .authorized),
            config: TalkCoordinatorConfig(
                systemPrompt: "Be brief.",
                baseModelPath: "/models/base/tiny",
                ttsOutputDirectory: dir
            )
        )

        try await coordinator.pushToTalkBegan()
        var phase = await coordinator.phase
        XCTAssertEqual(phase, .listening)

        // Drive partials once.
        await coordinator.refreshPartial()
        let partial = await coordinator.partialTranscript
        XCTAssertFalse(partial.isEmpty)

        let turn = try await coordinator.pushToTalkEnded()
        XCTAssertEqual(turn.userText, "What is two plus two?")
        XCTAssertFalse(turn.assistantText.isEmpty)
        XCTAssertTrue(turn.assistantText.contains("user: What is two plus two?"))
        XCTAssertEqual(turn.stt?.backendId, FakeSTTBackend.id)
        XCTAssertEqual(turn.llm?.backendId, EchoLLMBackend.id)
        XCTAssertEqual(turn.tts?.backendId, FakeTTSBackend.id)
        XCTAssertNotNil(turn.tts?.audioURL)
        XCTAssertFalse(turn.bargedIn)
        XCTAssertNotNil(turn.timestamps.sttMs)
        XCTAssertNotNil(turn.timestamps.llmMs)
        XCTAssertNotNil(turn.timestamps.ttsMs)

        let messages = await coordinator.messages
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0].role, "user")
        XCTAssertEqual(messages[1].role, "assistant")

        phase = await coordinator.phase
        XCTAssertEqual(phase, .idle)
    }

    func testRunTurnSkipsLiveSTT() async throws {
        let stack = TalkBackendFactory.makeFakeStack(fixedTranscript: "ignored")
        let coordinator = TalkCoordinator(
            stt: stack.stt,
            llm: stack.llm,
            tts: stack.tts,
            mic: stack.mic,
            config: TalkCoordinatorConfig(baseModelPath: "/m/base")
        )
        let turn = try await coordinator.runTurn(userText: "  injected text  ")
        XCTAssertEqual(turn.userText, "injected text")
        XCTAssertTrue(turn.assistantText.contains("injected text"))
        XCTAssertEqual(turn.stt?.text, "injected text")
        XCTAssertNotNil(turn.llm)
        XCTAssertNotNil(turn.tts)
    }

    func testBargeInStopsTTSDuringTurn() async throws {
        let stt = FakeSTTBackend(fixedTranscript: "interrupt me")
        let llm = EchoLLMBackend()
        // Long enough TTS window for barge-in to land mid-synthesis.
        let tts = FakeTTSBackend(writeSilentWav: true, simulatedLatencyMs: 600)
        let coordinator = TalkCoordinator(
            stt: stt,
            llm: llm,
            tts: tts,
            mic: FakeMicPermission(),
            config: TalkCoordinatorConfig(baseModelPath: "/m/base")
        )

        try await coordinator.pushToTalkBegan()
        let endTask = Task {
            try await coordinator.pushToTalkEnded()
        }

        // Poll until TTS phase, then barge-in.
        var sawTTS = false
        for _ in 0..<100 {
            let p = await coordinator.phase
            if p == .synthesizingTTS {
                sawTTS = true
                break
            }
            if p == .idle || p == .error {
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(sawTTS, "expected to observe synthesizingTTS before barge-in")

        await coordinator.bargeIn()
        let turn = try await endTask.value
        XCTAssertTrue(turn.bargedIn, "turn should report barge-in after stop")
        XCTAssertEqual(turn.userText, "interrupt me")
        XCTAssertFalse(turn.assistantText.isEmpty)
        XCTAssertEqual(turn.tts?.wasCancelled, true)

        let phase = await coordinator.phase
        XCTAssertEqual(phase, .idle)
    }

    func testNewPTTBargesInViaPushToTalkBegan() async throws {
        let stt = FakeSTTBackend(fixedTranscript: "second utterance")
        let llm = EchoLLMBackend()
        let tts = FakeTTSBackend(writeSilentWav: true, simulatedLatencyMs: 500)
        let coordinator = TalkCoordinator(
            stt: stt,
            llm: llm,
            tts: tts,
            mic: FakeMicPermission(),
            config: TalkCoordinatorConfig(baseModelPath: "/m/base")
        )

        try await coordinator.pushToTalkBegan()
        let firstEnd = Task { try await coordinator.pushToTalkEnded() }

        for _ in 0..<100 {
            if await coordinator.phase == .synthesizingTTS { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        // New PTT must stop TTS (design: barge-in on new PTT).
        try await coordinator.pushToTalkBegan()
        let phase = await coordinator.phase
        XCTAssertEqual(phase, .listening)

        _ = try? await firstEnd.value
        let turn = try await coordinator.pushToTalkEnded()
        XCTAssertEqual(turn.userText, "second utterance")
        XCTAssertNotNil(turn.llm)
    }

    func testMicMessagingSettingsURL() {
        let url = MicPermissionMessaging.systemSettingsMicrophoneURL
        XCTAssertTrue(url.absoluteString.contains("systempreferences")
            || url.absoluteString.contains("Privacy"))
        let err = MicPermissionMessaging.error(for: .denied)
        XCTAssertEqual(err.code, .tccMicDenied)
    }
}
