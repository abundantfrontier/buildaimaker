import XCTest
@testable import BAMControlPlane

private struct FakeExpensiveHandler: ActionHandler {
    var ran = false
    var definition: ActionDefinition {
        ActionDefinition(
            id: ActionID("finetune.start"),
            title: "Start fine-tune",
            description: "test",
            risk: .expensive
        )
    }

    func execute(params: JSONValue, context: ActionContext) async -> ActionOutcome {
        .success(
            data: .object([
                "ran": .bool(true),
                "characterId": params["characterId"] ?? .null,
            ]),
            context: context
        )
    }
}

private struct FakeDedupeHandler: ActionHandler {
    var definition: ActionDefinition {
        ActionDefinition(
            id: ActionID("minds.dedupe"),
            title: "Dedupe",
            description: "test",
            risk: .destructive
        )
    }

    func execute(params: JSONValue, context: ActionContext) async -> ActionOutcome {
        .success(
            data: .object(["dryRun": params["dryRun"] ?? .bool(true)]),
            context: context
        )
    }
}

final class ConfirmationTests: XCTestCase {
    func testMCPExpensiveIssuesChallenge() async {
        let plane = ControlPlane()
        await plane.registry.register(FakeExpensiveHandler())
        let out = await plane.invoke(
            ActionID("finetune.start"),
            params: .object([
                "characterId": .string("c1"),
                "recipe": .string("mlx_lora"),
            ]),
            context: ActionContext(source: .mcp, clientId: "grok")
        )
        XCTAssertFalse(out.ok)
        XCTAssertEqual(out.error?.code, ActionErrorCode.needsConfirmation.rawValue)
        XCTAssertNotNil(out.confirmation)
        XCTAssertTrue(out.confirmation?.token.hasPrefix("conf_") == true)
        XCTAssertTrue(out.confirmation?.summary.contains("c1") == true)
        let pending1 = await plane.confirmationGate.pendingCount
        XCTAssertEqual(pending1, 1)
    }

    func testUIExpensiveRunsWithoutChallenge() async {
        let plane = ControlPlane()
        await plane.registry.register(FakeExpensiveHandler())
        let out = await plane.invoke(
            ActionID("finetune.start"),
            params: .object(["characterId": .string("c1")]),
            context: .ui()
        )
        XCTAssertTrue(out.ok)
        XCTAssertEqual(out.data?["ran"]?.boolValue, true)
        XCTAssertNil(out.confirmation)
    }

    func testDedupeDryRunSkipsConfirm() async {
        let plane = ControlPlane()
        await plane.registry.register(FakeDedupeHandler())
        let out = await plane.invoke(
            ActionID("minds.dedupe"),
            params: .object(["dryRun": .bool(true)]),
            context: ActionContext(source: .mcp)
        )
        XCTAssertTrue(out.ok)
        XCTAssertEqual(out.data?["dryRun"]?.boolValue, true)
    }

    func testDedupeLiveNeedsConfirmThenAllow() async {
        let plane = ControlPlane()
        await plane.registry.register(FakeDedupeHandler())
        let first = await plane.invoke(
            ActionID("minds.dedupe"),
            params: .object(["dryRun": .bool(false)]),
            context: ActionContext(source: .mcp)
        )
        XCTAssertFalse(first.ok)
        XCTAssertEqual(first.error?.code, ActionErrorCode.needsConfirmation.rawValue)
        guard let token = first.confirmation?.token else {
            XCTFail("missing token")
            return
        }
        let allowed = await plane.allowConfirmation(token)
        XCTAssertTrue(allowed.ok)
        XCTAssertEqual(allowed.data?["dryRun"]?.boolValue, false)
        let pendingAfterAllow = await plane.confirmationGate.pendingCount
        XCTAssertEqual(pendingAfterAllow, 0)
    }

    func testDenyDoesNotRunHandler() async {
        let plane = ControlPlane()
        await plane.registry.register(FakeExpensiveHandler())
        let first = await plane.invoke(
            ActionID("finetune.start"),
            params: .object(["characterId": .string("c1")]),
            context: ActionContext(source: .mcp)
        )
        let token = first.confirmation!.token
        let denied = await plane.denyConfirmation(token)
        XCTAssertTrue(denied.ok)
        XCTAssertEqual(denied.data?["allowed"]?.boolValue, false)
        let pendingAfterDeny = await plane.confirmationGate.pendingCount
        XCTAssertEqual(pendingAfterDeny, 0)
    }

    func testMCPCannotSelfConfirm() async {
        let plane = ControlPlane()
        await plane.installBuiltins()
        await plane.registry.register(FakeExpensiveHandler())
        let first = await plane.invoke(
            ActionID("finetune.start"),
            params: .object(["characterId": .string("c1")]),
            context: ActionContext(source: .mcp)
        )
        let token = first.confirmation!.token
        let selfConfirm = await plane.invoke(
            AppConfirmHandler.id,
            params: .object(["token": .string(token), "allow": .bool(true)]),
            context: ActionContext(source: .mcp)
        )
        XCTAssertFalse(selfConfirm.ok)
        XCTAssertEqual(selfConfirm.error?.code, ActionErrorCode.denied.rawValue)
        let stillPending = await plane.confirmationGate.pendingCount
        XCTAssertEqual(stillPending, 1)
    }

    func testBadTokenDenied() async {
        let plane = ControlPlane()
        await plane.registry.register(FakeExpensiveHandler())
        let out = await plane.invoke(
            ActionID("finetune.start"),
            params: .object(["characterId": .string("c1")]),
            context: ActionContext(
                source: .mcp,
                confirmToken: "conf_nope"
            )
        )
        XCTAssertFalse(out.ok)
        XCTAssertEqual(out.error?.code, ActionErrorCode.denied.rawValue)
    }

    func testPolicyHelpers() {
        let expensive = ActionDefinition(
            id: "finetune.start",
            title: "t",
            description: "d",
            risk: .expensive
        )
        XCTAssertTrue(
            ConfirmationPolicy.requiresHumanConfirm(
                definition: expensive,
                params: .object([:]),
                source: .mcp
            )
        )
        XCTAssertFalse(
            ConfirmationPolicy.requiresHumanConfirm(
                definition: expensive,
                params: .object([:]),
                source: .ui
            )
        )
        let dedupe = ActionDefinition(
            id: "minds.dedupe",
            title: "t",
            description: "d",
            risk: .destructive
        )
        XCTAssertFalse(
            ConfirmationPolicy.requiresHumanConfirm(
                definition: dedupe,
                params: .object([:]),
                source: .mcp
            )
        )
        XCTAssertTrue(
            ConfirmationPolicy.requiresHumanConfirm(
                definition: dedupe,
                params: .object(["dryRun": .bool(false)]),
                source: .mcp
            )
        )
    }
}
