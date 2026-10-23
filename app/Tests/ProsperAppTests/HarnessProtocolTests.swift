import OSLog
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

    /// A canary error line logged under com.prosper.app; `errorLogs(since:)` cuts its window at
    /// the canary's own store date. #488: on the CI runner entry dates ran over 0.25 s behind
    /// `Date()` in some runs, so a `Date()` cut hid every line logged right after it.
    struct LogMark {
        let canary = "errorLogs-mark-\(UUID().uuidString)"
        let date = Date()
    }

    static func logMark() -> LogMark {
        let mark = LogMark()
        Logger(subsystem: "com.prosper.app", category: "test").error("\(mark.canary, privacy: .public)")
        return mark
    }

    /// Error-level messages this process logged under com.prosper.app after `mark`. A closing
    /// canary logged here proves the store has caught up; until it reads back, the read is
    /// retried (failure path only), and a store that never returns it skips the test.
    static func errorLogs(since mark: LogMark, timeout: TimeInterval = 10) throws -> [String] {
        let end = logMark()
        return try poll(timeout: timeout) {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            // ponytail: 30 s of slack for the wall-vs-store clock skew; the canary does the exact cut.
            let entries = try store.getEntries(at: store.position(date: mark.date.addingTimeInterval(-30)),
                                               matching: errorLogsPredicate())
                .compactMap { $0 as? OSLogEntryLog }
                .map { (level: $0.level, date: $0.date, message: $0.composedMessage) }
            return selectErrorMessages(entries, after: mark.canary, through: end.canary)
        }
    }

    /// Calls `read` until it returns non-nil; past `timeout` the test is skipped, not failed or
    /// passed blind: the host's log store can't read back a line this process just logged.
    static func poll<T>(timeout: TimeInterval, _ read: () throws -> T?) throws -> T {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let value = try read() { return value }
            guard Date() < deadline else {
                throw XCTSkip("OSLogStore did not return a canary this process logged within \(timeout) s: log read-back can't be checked on this host (#488)")
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    /// Messages after the `start` canary (by its store date), canaries dropped; nil until both
    /// canaries are in `entries`.
    static func selectErrorMessages(_ entries: [(level: OSLogEntryLog.Level, date: Date, message: String)],
                                    after start: String, through end: String) -> [String]? {
        guard let from = entries.first(where: { $0.message == start })?.date,
              entries.contains(where: { $0.message == end }) else { return nil }
        return selectErrorMessages(entries.filter { $0.message != start && $0.message != end }, from: from)
    }

    static func errorLogsPredicate() -> NSPredicate {
        NSPredicate(format: "subsystem == %@", "com.prosper.app")
    }

    /// #338: error level, dated at or after `from`, deduped on (date, message): OSLogStore has been
    /// seen to return a line twice (suspected: an entry present in both the in-memory and the
    /// persisted store; not reproduced). A genuine repeat logged in the same microsecond collapses
    /// too; no caller counts those.
    static func selectErrorMessages(_ entries: [(level: OSLogEntryLog.Level, date: Date, message: String)],
                                    from: Date) -> [String] {
        var seen = Set<String>()
        return entries.compactMap { e in
            guard e.level == .error, e.date >= from,
                  seen.insert("\(e.date.timeIntervalSinceReferenceDate)|\(e.message)").inserted else { return nil }
            return e.message
        }
    }

    func testErrorLogsPredicatePinsSubsystem() {
        XCTAssertEqual(Self.errorLogsPredicate().predicateFormat, #"subsystem == "com.prosper.app""#)
    }

    func testErrorLogsReturnsALineLoggedHere() throws {
        let since = Self.logMark()
        let marker = "errorLogs-probe-\(UUID().uuidString)"
        Logger(subsystem: "com.prosper.app", category: "test").error("\(marker, privacy: .public)")
        let logs = try Self.errorLogs(since: since)
        XCTAssertEqual(logs.filter { $0 == marker }.count, 1, "\(logs)")
    }

    func testSelectErrorMessagesDedupesDoubledEntries() {
        let t = Date()
        let e = [(level: OSLogEntryLog.Level.error, date: t, message: "a"), (level: .error, date: t, message: "a"),
                 (level: .error, date: t + 1, message: "b"), (level: .error, date: t + 1, message: "b")]
        XCTAssertEqual(Self.selectErrorMessages(e, from: t), ["a", "b"])
    }

    func testSelectErrorMessagesDropsNonErrorLevel() {
        let t = Date()
        XCTAssertEqual(Self.selectErrorMessages([(level: .info, date: t, message: "i"),
                                                 (level: .error, date: t, message: "e")], from: t), ["e"])
    }

    func testSelectErrorMessagesDropsEntriesBeforeFrom() {
        let t = Date()
        XCTAssertEqual(Self.selectErrorMessages([(level: .error, date: t - 1, message: "early"),
                                                 (level: .error, date: t, message: "on")], from: t), ["on"])
    }

    func testSelectErrorMessagesKeepsSameMessageAtDifferentDates() {
        let t = Date()
        XCTAssertEqual(Self.selectErrorMessages([(level: .error, date: t, message: "a"),
                                                 (level: .error, date: t + 1, message: "a")], from: t), ["a", "a"])
    }

    func testSelectErrorMessagesKeepsDistinctMessagesAtSameDate() {
        let t = Date()
        XCTAssertEqual(Self.selectErrorMessages([(level: .error, date: t, message: "x"),
                                                 (level: .error, date: t, message: "y")], from: t), ["x", "y"])
    }

    /// #488: the cut is the start canary's store date, however far behind the wall clock it runs.
    func testCanaryWindowCutsAtTheStartCanarysDate() {
        let t = Date() - 0.5   // store clock 0.5 s behind: a Date()-0.25 cut would drop "mid"
        XCTAssertEqual(Self.selectErrorMessages([(level: .error, date: t - 0.1, message: "before"),
                                                 (level: .error, date: t, message: "S"),
                                                 (level: .error, date: t + 0.01, message: "mid"),
                                                 (level: .error, date: t + 0.02, message: "E")],
                                                after: "S", through: "E"), ["mid"])
    }

    func testCanaryWindowIsNilUntilBothCanariesReadBack() {
        let t = Date()
        XCTAssertTrue(Self.selectErrorMessages([(level: .error, date: t, message: "E")], after: "S", through: "E") == nil)
        XCTAssertTrue(Self.selectErrorMessages([(level: .error, date: t, message: "S")], after: "S", through: "E") == nil)
    }

    func testPollRetriesUntilARead() throws {
        var reads = 0
        XCTAssertEqual(try Self.poll(timeout: 3) { () -> Int? in reads += 1; return reads == 3 ? 7 : nil }, 7)
        XCTAssertEqual(reads, 3)
    }

    func testPollSkipsWhenNothingReadsBack() {
        XCTAssertThrowsError(try Self.poll(timeout: 0.2) { () -> Int? in nil }) { XCTAssertTrue($0 is XCTSkip, "\($0)") }
    }

    /// #174: a stdout line that isn't a JSON object is logged (cut to 256 bytes) and skipped.
    func testFramerLogsNonObjectLines() throws {
        let since = Self.logMark()
        var framer = JSONLineFramer()
        let long = "not json " + String(repeating: "x", count: 1000)
        let objs = framer.append(Data((long + "\n[1,2]\n" + #"{"ok":true}"# + "\n").utf8))
        XCTAssertEqual(objs.count, 1)
        let logs = try Self.errorLogs(since: since)
        XCTAssertTrue(logs.contains {
            $0.contains("not a JSON object: not json xxx") && $0.hasSuffix("… (1009 bytes)") && $0.count < 400
        }, "\(logs)")
        XCTAssertTrue(logs.contains { $0.hasSuffix("not a JSON object: [1,2]") }, "\(logs)")
    }

    /// #174: a line over `maxLineBytes` is dropped with an error log, whether it arrives in one
    /// read or streams in; streaming, it is dropped (and the buffer freed) before its newline.
    func testFramerDropsOverCapLineAndKeepsReading() throws {
        let since = Self.logMark()
        let huge = Data((#"{"a":""# + String(repeating: "x", count: JSONLineFramer.maxLineBytes + (1 << 20)) + #""}"#).utf8)
        let next = Data(("\n" + #"{"ok":true}"# + "\n").utf8)
        let dropped = { try Self.errorLogs(since: since).filter { $0.contains("over \(JSONLineFramer.maxLineBytes) bytes") }.count }

        var framer = JSONLineFramer()
        var objs: [[String: Any]] = []
        for start in stride(from: 0, to: huge.count, by: 1 << 20) {
            objs += framer.append(huge.subdata(in: start..<min(start + (1 << 20), huge.count)))
        }
        let droppedStreaming = try dropped()   // outside XCTAssert: its XCTSkip must skip, not fail
        XCTAssertEqual(droppedStreaming, 1, "dropped once over the cap, before its newline arrives")
        objs += framer.append(next)
        XCTAssertEqual(objs.count, 1)
        XCTAssertEqual(objs.first?["ok"] as? Bool, true)

        framer = JSONLineFramer()
        objs = framer.append(huge + next)
        XCTAssertEqual(objs.count, 1)
        XCTAssertEqual(objs.first?["ok"] as? Bool, true)
        let droppedBoth = try dropped()
        XCTAssertEqual(droppedBoth, 2, "the streamed line once, the one-read line once")
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

    func testRequestEncodesIDAndIncrements() throws {
        var rpc = JSONRPC()
        let (id1, line1) = try rpc.request(method: "initialize", params: [:])
        let (id2, _) = try rpc.request(method: "turn/start", params: ["threadId": "t"])
        XCTAssertEqual(id1, 1)
        XCTAssertEqual(id2, 2)
        let obj = (try? JSONSerialization.jsonObject(with: line1)) as? [String: Any]
        XCTAssertEqual(obj?["method"] as? String, "initialize")
        XCTAssertEqual(obj?["id"] as? Int, 1)
        XCTAssertEqual(obj?["jsonrpc"] as? String, "2.0")
        XCTAssertEqual(line1.last, UInt8(ascii: "\n"))
    }

    /// #174: a value JSON can't carry throws a named error instead of crashing (NSJSONSerialization
    /// raises an uncatchable ObjC exception on NaN) or sending a blank line.
    func testUnencodableParamsThrow() {
        var rpc = JSONRPC()
        for params: [String: Any] in [["v": Double.nan], ["v": [Double.infinity]], ["when": Date()]] {
            XCTAssertThrowsError(try rpc.request(method: "turn/start", params: params)) {
                guard case HarnessError.protocolError(let m) = $0 else { return XCTFail("\($0)") }
                XCTAssertTrue(m.contains("turn/start"), m)
            }
        }
        XCTAssertThrowsError(try JSONRPC.response(id: "r", result: ["v": Double.nan]))
    }

    /// #174: every request is bounded; turn requests get the longer wait.
    func testDefaultReplyTimeouts() {
        XCTAssertEqual(CodexHarness.defaultReplyTimeout(for: "initialize"), 60)
        XCTAssertEqual(CodexHarness.defaultReplyTimeout(for: "thread/resume"), 60)
        XCTAssertEqual(CodexHarness.defaultReplyTimeout(for: "turn/start"), 120)
        XCTAssertEqual(CodexHarness.defaultReplyTimeout(for: "turn/steer"), 120)
    }

    func testResponseFrame() throws {
        let line = try JSONRPC.response(id: "req-1", result: ["decision": "approved"])
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

    func testMapTurnStartedReadsTurnObjectID() {
        // TurnStartedNotification = { threadId, turn: Turn } in codex 0.139 and 0.162.
        let e = CodexHarness.mapNotification(
            method: "turn/started",
            params: ["threadId": "th1", "turn": ["id": "t1", "items": [], "status": "inProgress"]])
        guard case .turnStarted(let turn) = e.first else { return XCTFail("got \(e)") }
        XCTAssertEqual(turn.raw, "t1")
        // A turn/started without a turn id must not emit an empty id that would
        // overwrite the controller's current turn.
        XCTAssertTrue(CodexHarness.mapNotification(method: "turn/started", params: ["turnId": "t1"]).isEmpty)
    }

    func testImageInputEncodesAsLocalImage() {
        // codex 0.161 UserInput: local files are {"type":"localImage","path"}; `image` needs url.
        let j = CodexHarness.inputJSON(.image(path: "/tmp/a.png"))
        XCTAssertEqual(j["type"] as? String, "localImage")
        XCTAssertEqual(j["path"] as? String, "/tmp/a.png")
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
