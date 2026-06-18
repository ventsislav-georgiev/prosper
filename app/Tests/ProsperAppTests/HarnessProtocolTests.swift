import XCTest
@testable import ProsperApp

final class HarnessProtocolTests: XCTestCase {

    // MARK: JSON line framing

    func testFramerSplitsCompleteLines() {
        var framer = JSONLineFramer()
        let objs = framer.append(Data((#"{"a":1}"# + "\n" + #"{"b":2}"# + "\n").utf8))
        XCTAssertEqual(objs.count, 2)
        XCTAssertEqual(objs[0]["a"] as? Int, 1)
        XCTAssertEqual(objs[1]["b"] as? Int, 2)
    }

    func testFramerBuffersPartialLine() {
        var framer = JSONLineFramer()
        XCTAssertTrue(framer.append(Data(#"{"a":"#.utf8)).isEmpty)        // no newline yet
        let objs = framer.append(Data("1}\n".utf8))
        XCTAssertEqual(objs.count, 1)
        XCTAssertEqual(objs[0]["a"] as? Int, 1)
    }

    func testFramerSkipsNonJSONLines() {
        var framer = JSONLineFramer()
        let objs = framer.append(Data(("not json\n" + #"{"ok":true}"# + "\n").utf8))
        XCTAssertEqual(objs.count, 1)
        XCTAssertEqual(objs[0]["ok"] as? Bool, true)
    }

    // MARK: Frame classification

    func testClassifyResponse() {
        guard case .response(let id, let result, let error)? = JSONRPCFrame(["jsonrpc": "2.0", "id": 7, "result": ["threadId": "t1"]]) else {
            return XCTFail("expected response")
        }
        XCTAssertEqual(id, 7)
        XCTAssertEqual(result?["threadId"] as? String, "t1")
        XCTAssertNil(error)
    }

    func testClassifyServerRequest() {
        let obj: [String: Any] = ["jsonrpc": "2.0", "id": "req-1", "method": "execCommandApproval", "params": ["command": ["ls"]]]
        guard case .serverRequest(let id, let method, let params)? = JSONRPCFrame(obj) else {
            return XCTFail("expected serverRequest")
        }
        XCTAssertEqual(id as? String, "req-1")
        XCTAssertEqual(method, "execCommandApproval")
        XCTAssertEqual(params["command"] as? [String], ["ls"])
    }

    func testClassifyNotification() {
        guard case .notification(let method, _)? = JSONRPCFrame(["jsonrpc": "2.0", "method": "turn/started", "params": [:]]) else {
            return XCTFail("expected notification")
        }
        XCTAssertEqual(method, "turn/started")
    }

    // MARK: Outgoing frames

    func testRequestEncodesIDAndIncrements() {
        var rpc = JSONRPC()
        let (id1, line1) = rpc.request(method: "initialize", params: [:])
        let (id2, _) = rpc.request(method: "turn/start", params: ["threadId": "t"])
        XCTAssertEqual(id1, 1)
        XCTAssertEqual(id2, 2)
        let obj = (try? JSONSerialization.jsonObject(with: line1)) as? [String: Any]
        XCTAssertEqual(obj?["method"] as? String, "initialize")
        XCTAssertEqual(obj?["id"] as? Int, 1)
        XCTAssertEqual(obj?["jsonrpc"] as? String, "2.0")
        XCTAssertEqual(line1.last, UInt8(ascii: "\n"))
    }

    func testResponseFrame() {
        let line = JSONRPC.response(id: "req-1", result: ["decision": "approved"])
        let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
        XCTAssertEqual(obj?["id"] as? String, "req-1")
        XCTAssertEqual((obj?["result"] as? [String: Any])?["decision"] as? String, "approved")
    }

    // MARK: Notification → event mapping

    func testMapAgentMessageDelta() {
        let e = CodexHarness.mapNotification(method: "item/agentMessage/delta",
                                             params: ["turnId": "t1", "itemId": "i1", "delta": "Hello"])
        guard case .textDelta(let turn, let itemID, let text) = e.first else { return XCTFail() }
        XCTAssertEqual(turn.raw, "t1")
        XCTAssertEqual(itemID, "i1")
        XCTAssertEqual(text, "Hello")
    }

    func testMapReasoningDelta() {
        let e = CodexHarness.mapNotification(method: "item/reasoning/textDelta",
                                             params: ["turnId": "t1", "itemId": "i1", "delta": "thinking"])
        guard case .reasoningDelta(_, _, let text) = e.first else { return XCTFail() }
        XCTAssertEqual(text, "thinking")
    }

    // Command execution arrives via the generic item lifecycle envelope, discriminated
    // by `item.type`, not per-type methods.
    func testMapCommandLifecycleViaItemEnvelope() {
        let started = CodexHarness.mapNotification(
            method: "item/started",
            params: ["turnId": "t1", "item": ["id": "c1", "type": "commandExecution", "command": "ls -la"]])
        guard case .toolCallStarted(let call) = started.first else { return XCTFail() }
        XCTAssertEqual(call.name, "shell")
        XCTAssertEqual(call.status, .running)

        let done = CodexHarness.mapNotification(
            method: "item/completed",
            params: ["item": ["id": "c1", "type": "commandExecution", "command": "ls -la",
                              "status": "completed", "exitCode": 0,
                              "aggregatedOutput": "a\nb\n", "durationMs": 1500]])
        guard case .toolCallCompleted(let okCall) = done.first else { return XCTFail() }
        XCTAssertEqual(okCall.status, .succeeded)
        // The combined output + an exit/duration footer must reach the UI (not be dropped).
        XCTAssertEqual(okCall.output, "a\nb\n— exit 0 · 1.5s")

        let failed = CodexHarness.mapNotification(
            method: "item/completed",
            params: ["item": ["id": "c1", "type": "commandExecution", "command": "false",
                              "status": "completed", "exitCode": 1,
                              "aggregatedOutput": "boom"]])
        guard case .toolCallCompleted(let failCall) = failed.first else { return XCTFail() }
        XCTAssertEqual(failCall.status, .failed)
        XCTAssertEqual(failCall.output, "boom\n— exit 1")

        // A blocked/never-started command (no exitCode, no output) still reports why.
        let blocked = CodexHarness.mapNotification(
            method: "item/completed",
            params: ["item": ["id": "c1", "type": "commandExecution", "command": "ls",
                              "status": "failed"]])
        guard case .toolCallCompleted(let blockedCall) = blocked.first else { return XCTFail() }
        XCTAssertEqual(blockedCall.status, .failed)
        XCTAssertEqual(blockedCall.output,
                       "— failed (no exit code — likely blocked or not started)")
    }

    // A single fileChange item fans out to one .fileChange per changed file.
    func testMapFileChangeItemFansOut() {
        let e = CodexHarness.mapNotification(
            method: "item/completed",
            params: ["turnId": "t1", "item": [
                "id": "f1", "type": "fileChange", "status": "completed",
                "changes": [
                    ["path": "a.swift", "diff": "@@ -1 +1 @@", "kind": ["type": "update"]],
                    ["path": "b.swift", "diff": "@@ -0 +1 @@", "kind": ["type": "add"]],
                ],
            ]])
        XCTAssertEqual(e.count, 2)
        guard case .fileChange(_, let d0) = e[0], case .fileChange(_, let d1) = e[1] else { return XCTFail() }
        XCTAssertEqual(d0.path, "a.swift"); XCTAssertEqual(d0.change, .modify)
        XCTAssertEqual(d1.path, "b.swift"); XCTAssertEqual(d1.change, .add)
    }

    func testMapPlanUpdated() {
        let e = CodexHarness.mapNotification(
            method: "turn/plan/updated",
            params: ["turnId": "t1", "plan": [
                ["step": "build", "status": "completed"],
                ["step": "test", "status": "inProgress"],
            ]])
        guard case .planUpdated(_, let steps) = e.first else { return XCTFail() }
        XCTAssertEqual(steps.count, 2)
        XCTAssertEqual(steps[0].state, .done); XCTAssertEqual(steps[1].state, .inProgress)
    }

    func testMapTokenUsage() {
        let e = CodexHarness.mapNotification(
            method: "thread/tokenUsage/updated",
            params: ["turnId": "t1", "tokenUsage": ["total": ["inputTokens": 120, "outputTokens": 45]]])
        guard case .usage(let usage) = e.first else { return XCTFail() }
        XCTAssertEqual(usage.inputTokens, 120)
        XCTAssertEqual(usage.outputTokens, 45)
    }

    func testMapTurnCompleted() {
        let e = CodexHarness.mapNotification(
            method: "turn/completed", params: ["turn": ["id": "t1", "status": "completed"]])
        guard case .turnCompleted(let turn, let outcome) = e.first else { return XCTFail() }
        XCTAssertEqual(turn.raw, "t1")
        XCTAssertEqual(outcome, .completed)
    }

    func testMapTurnFailedCarriesMessage() {
        let e = CodexHarness.mapNotification(
            method: "turn/completed",
            params: ["turn": ["id": "t1", "status": "failed", "error": ["message": "boom"]]])
        guard case .turnCompleted(_, let outcome) = e.first else { return XCTFail() }
        XCTAssertEqual(outcome, .failed("boom"))
    }

    func testMapInterruptedTurnIsAborted() {
        let e = CodexHarness.mapNotification(
            method: "turn/completed", params: ["turn": ["id": "t1", "status": "interrupted"]])
        guard case .turnCompleted(_, let outcome) = e.first else { return XCTFail() }
        XCTAssertEqual(outcome, .aborted)
    }

    func testMapUnknownNotificationIsIgnored() {
        XCTAssertTrue(CodexHarness.mapNotification(method: "some/futureEvent", params: [:]).isEmpty)
    }
}

extension TurnOutcome: Equatable {
    public static func == (lhs: TurnOutcome, rhs: TurnOutcome) -> Bool {
        switch (lhs, rhs) {
        case (.completed, .completed), (.aborted, .aborted): return true
        case (.failed(let a), .failed(let b)): return a == b
        default: return false
        }
    }
}
