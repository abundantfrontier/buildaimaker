import XCTest
@testable import BAMControlPlane

final class ControlPlaneTests: XCTestCase {
    func testPingAndListActions() async {
        let plane = ControlPlane()
        await plane.installBuiltins()

        let ping = await plane.invoke(AppPingHandler.id, context: .test())
        XCTAssertTrue(ping.ok)
        XCTAssertEqual(ping.data?["pong"]?.boolValue, true)

        let list = await plane.invoke(AppListActionsHandler.id, context: .test())
        XCTAssertTrue(list.ok)
        let count = list.data?["count"]?.intValue ?? 0
        XCTAssertGreaterThanOrEqual(count, 4)

        let mcpList = await plane.invoke(
            AppListActionsHandler.id,
            params: .object(["mcpOnly": .bool(true)]),
            context: .test()
        )
        XCTAssertTrue(mcpList.ok)
        if case .array(let actions) = mcpList.data?["actions"] {
            let ids = actions.compactMap { $0["id"]?.stringValue }
            XCTAssertTrue(ids.contains("selection.set"))
            XCTAssertTrue(ids.contains("app.getState"))
            XCTAssertTrue(ids.contains("nav.go"))
        } else {
            XCTFail("expected actions array")
        }
    }

    func testGetStateAndNav() async {
        let plane = ControlPlane()
        await plane.installBuiltins()
        await plane.bootstrapSession(route: "home", flags: ["controlPlane": true])

        let before = await plane.invoke(AppGetStateHandler.id, context: .test())
        XCTAssertTrue(before.ok)
        XCTAssertEqual(before.data?["route"]?.stringValue, "home")
        XCTAssertEqual(before.data?["flags"]?["controlPlane"]?.boolValue, true)

        let nav = await plane.invoke(
            NavGoHandler.id,
            params: .object(["route": .string("characters")]),
            context: .test()
        )
        XCTAssertTrue(nav.ok)
        XCTAssertNotNil(nav.stateRevision)

        let after = await plane.invoke(AppGetStateHandler.id, context: .test())
        XCTAssertEqual(after.data?["route"]?.stringValue, "characters")
        XCTAssertEqual(after.stateRevision, nav.stateRevision)
    }

    func testUnknownAction() async {
        let plane = ControlPlane()
        await plane.installBuiltins()
        let out = await plane.invoke(ActionID("no.such.action"), context: .test())
        XCTAssertFalse(out.ok)
        XCTAssertEqual(out.error?.code, ActionErrorCode.unknownAction.rawValue)
    }

    func testSelectionSetAndPathsFilter() async {
        let plane = ControlPlane()
        await plane.installBuiltins()

        let set = await plane.invoke(
            SelectionSetHandler.id,
            params: .object(["characterId": .string("abc-123")]),
            context: .ui()
        )
        XCTAssertTrue(set.ok)

        let partial = await plane.invoke(
            AppGetStateHandler.id,
            params: .object(["paths": .array([.string("selection"), .string("revision")])]),
            context: .test()
        )
        XCTAssertTrue(partial.ok)
        XCTAssertEqual(partial.data?["selection"]?["characterId"]?.stringValue, "abc-123")
        XCTAssertNil(partial.data?["route"]) // filtered out
    }

    func testClientMutationIdDedupe() async {
        let plane = ControlPlane()
        await plane.installBuiltins()
        let ctx = ActionContext(
            source: .test,
            clientId: "agent-1",
            clientMutationId: "mut-1"
        )
        let first = await plane.invoke(
            NavGoHandler.id,
            params: .object(["route": .string("train")]),
            context: ctx
        )
        XCTAssertTrue(first.ok)
        let second = await plane.invoke(
            NavGoHandler.id,
            params: .object(["route": .string("jobs")]), // would change route if re-run
            context: ctx
        )
        XCTAssertTrue(second.ok)
        // Cached first outcome
        XCTAssertEqual(second.data?["route"]?.stringValue, "train")

        let state = await plane.invoke(AppGetStateHandler.id, context: .test())
        XCTAssertEqual(state.data?["route"]?.stringValue, "train")
    }

    func testTruncatedStateWhenBudgetTiny() async {
        let store = StateStore()
        await store.apply { s in
            s.route = "home"
            // inflate counts map
            for i in 0..<500 {
                s.counts["k\(i)"] = i
            }
        }
        let plane = ControlPlane(stateStore: store)
        await plane.registry.register(AppGetStateHandler(stateStore: store, budgetBytes: 200))
        let out = await plane.invoke(AppGetStateHandler.id, context: .test())
        XCTAssertFalse(out.ok)
        XCTAssertEqual(out.error?.code, ActionErrorCode.truncated.rawValue)
    }

    func testEventBusReceivesInvoke() async {
        let plane = ControlPlane()
        await plane.installBuiltins()
        let stream = plane.eventBus.subscribe()
        var kinds: [BusEventKind] = []
        let task = Task {
            for await ev in stream {
                kinds.append(ev.kind)
                if kinds.count >= 2 { break }
            }
        }
        _ = await plane.invoke(AppPingHandler.id, context: .test())
        await task.value
        XCTAssertTrue(kinds.contains(.actionInvoked))
        XCTAssertTrue(kinds.contains(.actionCompleted))
    }

    func testJSONValueRoundTrip() throws {
        let v: JSONValue = .object([
            "a": .string("x"),
            "b": .number(2),
            "c": .bool(true),
            "d": .null,
            "e": .array([.string("y")]),
        ])
        let data = try v.jsonData()
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        XCTAssertEqual(decoded, v)
    }

    func testNavGoClearsStaleGuideWhenRouteChanges() async {
        let plane = ControlPlane()
        await plane.installBuiltins()
        _ = await plane.invoke(
            NavGoHandler.id,
            params: .object([
                "route": .string("characters"),
                "guideTitle": .string("Opened Rocky"),
                "guideSteps": .array([.string("Click Rocky")]),
            ]),
            context: .test()
        )
        let mid = await plane.invoke(AppGetStateHandler.id, context: .test())
        XCTAssertEqual(mid.data?["ui"]?["guideTitle"]?.stringValue, "Opened Rocky")

        _ = await plane.invoke(
            NavGoHandler.id,
            params: .object(["route": .string("home")]),
            context: .test()
        )
        let after = await plane.invoke(AppGetStateHandler.id, context: .test())
        XCTAssertEqual(after.data?["route"]?.stringValue, "home")
        XCTAssertNil(after.data?["ui"]?["guideTitle"]?.stringValue)
    }

    func testNavGoMergesSelectionAndUI() async {
        let plane = ControlPlane()
        await plane.installBuiltins()
        let nav = await plane.invoke(
            NavGoHandler.id,
            params: .object([
                "route": .string("characters"),
                "characterId": .string("rocky-1"),
                "highlight": .string("characters.row"),
                "guideTitle": .string("Created Rocky"),
                "guideSteps": .array([.string("Open Characters"), .string("Click Rocky")]),
            ]),
            context: .test()
        )
        XCTAssertTrue(nav.ok)
        let state = await plane.invoke(AppGetStateHandler.id, context: .test())
        XCTAssertEqual(state.data?["route"]?.stringValue, "characters")
        XCTAssertEqual(state.data?["selection"]?["characterId"]?.stringValue, "rocky-1")
        XCTAssertEqual(state.data?["ui"]?["highlight"]?.stringValue, "characters.row")
        XCTAssertEqual(state.data?["ui"]?["guideTitle"]?.stringValue, "Created Rocky")
    }

    func testMcpToolNameMapping() {
        let def = ActionDefinition(
            id: "character.importMind",
            title: "Import",
            description: "d",
            risk: .write
        )
        XCTAssertEqual(def.mcpToolName, "character_import_mind")
        XCTAssertEqual(ActionDefinition.mcpToolName(for: "app.getState"), "app_get_state")
    }
}
