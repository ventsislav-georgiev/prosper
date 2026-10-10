import XCTest
import CryptoKit
@testable import ProsperApp

/// End-to-end test of `CodexHarness` against a *real* subprocess speaking the
/// Codex `app-server` JSON-RPC dialect — a small Python mock written to a temp
/// file at runtime. Exercises the parts that unit tests can't: process spawn,
/// stdio framing over a live pipe, the initialize handshake, a thread/turn
/// round-trip, server→client approval, and the notification→event stream.
///
/// No MLX model and no real `codex` binary are involved; the mock stands in for
/// the binary so the Swift harness wiring is verified deterministically.
final class CodexHarnessE2ETests: XCTestCase {

    /// The codex download is process-wide: a test ending mid-download must not hand
    /// its fake URL to the next test's controller.
    override func setUp() async throws {
        await MainActor.run { AgentController.resetCodexDownloadForTesting() }
    }

    /// The mock app-server: reads JSONL requests on stdin, replies on stdout, and
    /// emits the notification sequence Codex would for a one-message turn, in the
    /// shapes of the codex 0.139/0.162 schemas (`{turn: Turn}` results and
    /// notifications). On a turn whose prompt contains "APPROVE", it first issues a
    /// server→client command-approval request and waits for the client's reply before
    /// finishing. On "HANG" it starts a shell command and leaves the turn running
    /// until a well-formed `turn/interrupt` request ends it; "WEDGE" does the same but
    /// never answers the interrupt (a hung codex); "EXIT0" starts the turn and then
    /// exits cleanly (code 0) without finishing it; "SLOWSTART" holds the turn/start
    /// reply for 1 s (a Stop can land before the turn id is known). Turn ids count up
    /// per process (`turn-1`, `turn-2`, …); a turn/start after a WEDGE turn announces the
    /// new turn and then the wedged turn's late `turn/completed{interrupted}`. Every inbound line is appended to
    /// `received.jsonl` beside the script, and the pid is written to `pid`, so tests can
    /// check what was sent and kill the process. EXITON: a file `exit-on` beside the script
    /// naming a method makes the mock delete the file and exit cleanly (code 0) on that
    /// request, before replying (`thread/resume`: codex dies during a resume). ERRORON: a
    /// file `error-on` naming a method makes the mock delete it and answer that request with
    /// a JSON-RPC error, staying alive (`thread/resume`: the thread is gone). LATEON: a file
    /// `late-on` naming a method makes the mock delete it and sleep 1 s before handling that
    /// request (a reply that lands after the client's timeout). "JUNK" makes turn/start first
    /// print malformed stdout (a long non-JSON line, a JSON array, an object with neither id
    /// nor method, an `id: null` parse error, a response for unknown id 9999, and `{"result": -1e400}`,
    /// which parses to -inf: the harness must not re-serialize it for its log line, QA #93). "FAST" writes
    /// the whole turn (turn/started, turn/completed) and then the turn/start reply in one
    /// stdout write, so the turn has completed before `sendPrompt` returns its id; with
    /// "FAIL" too, the turn completes `failed` ("mock turn failed").
    /// PERMS / PATCH / LEGACY / AMEND / ELICIT issue one 0.162-schema server request (permissions
    /// approval; a `fileChange` item/started then its file-change approval; a legacy
    /// `applyPatchApproval` with a newline inside one path; a command
    /// approval proposing an execpolicy amendment; an MCP elicitation, which the client
    /// doesn't serve) with id "srv-1" and hold the turn until the client replies: a reply
    /// in the method's response shape (exact keys, `reply_error`) finishes the turn, any
    /// other fails it with "bad reply: …".
    /// Thread and turn params are checked against the codex 0.139/0.161/0.162 schemas
    /// (`ThreadStartParams.sandbox: SandboxMode`, no `sandboxPolicy` there;
    /// `TurnStartParams.sandboxPolicy: SandboxPolicy`); a mismatch is a JSON-RPC error.
    /// SPAWNCHILD: a file `spawn-child` beside the script makes the mock start a child that
    /// ignores SIGTERM (an MCP server stand-in), which writes its pid to `child-pid` once
    /// the ignore is in place. It sends no frame.
    private static let mockServer = #"""
    import sys, json, os, time, subprocess

    LOG = os.path.join(os.path.dirname(os.path.abspath(__file__)), "received.jsonl")
    WIRE = os.path.join(os.path.dirname(LOG), "wire.jsonl")
    EXIT_ON = os.path.join(os.path.dirname(LOG), "exit-on")
    ERROR_ON = os.path.join(os.path.dirname(LOG), "error-on")
    LATE_ON = os.path.join(os.path.dirname(LOG), "late-on")
    with open(os.path.join(os.path.dirname(LOG), "pid"), "w") as f:
        f.write(str(os.getpid()))
    if os.path.exists(os.path.join(os.path.dirname(LOG), "spawn-child")):
        CHILD_PID = os.path.join(os.path.dirname(LOG), "child-pid")
        subprocess.Popen([sys.executable, "-c",
            "import os, signal, sys, time; signal.signal(signal.SIGTERM, signal.SIG_IGN); "
            "open(sys.argv[1] + '.tmp', 'w').write(str(os.getpid())); os.rename(sys.argv[1] + '.tmp', sys.argv[1]); "
            "time.sleep(600)", CHILD_PID],
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    current_turn = None
    wedged = False
    turn_seq = 0

    def log(direction, frame):
        with open(WIRE, "a") as f:
            f.write(json.dumps({"dir": direction, "frame": frame}) + "\n")

    def send(*objs):   # one stdout write; junk lines bypass this (they aren't codex frames)
        for obj in objs:
            log("in", obj)
        sys.stdout.write("".join(json.dumps(obj) + "\n" for obj in objs))
        sys.stdout.flush()

    # Replies and payloads in recorded real-codex shapes (Fixtures/codex/<ver>/plain-turn.jsonl).
    with open(os.path.join(sys.argv[1], "plain-turn.jsonl")) as f:
        RECORDED = [json.loads(l)["frame"] for l in f]

    def recorded(method):
        """codex's result for the first `method` request, or the first `method` notification's params."""
        rid = next((m.get("id") for m in RECORDED if m.get("method") == method and "id" in m), None)
        for m in RECORDED:
            if rid is None and m.get("method") == method:
                return json.loads(json.dumps(m["params"]))
            if rid is not None and "method" not in m and m.get("id") == rid and "result" in m:
                return json.loads(json.dumps(m["result"]))

    TURN = recorded("turn/start")["turn"]

    def turn(status):
        return dict(TURN, id=current_turn, rootTurnId=current_turn, items=[], status=status)

    def finish_turn(problem=None):
        global current_turn
        send({"jsonrpc": "2.0", "method": "item/agentMessage/delta",
              "params": {"threadId": "thread-1", "turnId": current_turn, "itemId": "m1", "delta": "Hello from mock"}})
        send({"jsonrpc": "2.0", "method": "thread/tokenUsage/updated",
              "params": dict(recorded("thread/tokenUsage/updated"), threadId="thread-1", turnId=current_turn)})
        done = turn("failed" if problem else "completed")
        if problem:
            done["error"] = {"message": "bad reply: " + problem}
        send({"jsonrpc": "2.0", "method": "turn/completed", "params": {"threadId": "thread-1", "turn": done}})
        current_turn = None

    # Server requests per prompt word, params per the 0.162 schema (ServerRequest.json).
    def server_request(word):
        t = {"threadId": "thread-1", "turnId": current_turn, "startedAtMs": 0}
        if word == "PERMS":
            return "item/permissions/requestApproval", dict(t, itemId="perm-1", cwd="/tmp",
                reason="needs network", permissions={"network": {"enabled": True}, "fileSystem": {
                    "read": ["/etc"], "write": ["/tmp/out"],
                    "entries": [{"access": "write", "path": {"type": "special", "value": {"kind": "tmpdir"}}}, {"access": "write", "path": {"type": "special", "value": {"kind": "root"}}}, {"access": "write", "path": {"type": "special", "value": {"kind": "unknown", "path": "/odd", "subpath": "x"}}}]}})
        if word == "PATCH":
            send({"jsonrpc": "2.0", "method": "item/started", "params": dict(t, item={
                "id": "fc-1", "type": "fileChange", "status": "inProgress",
                "changes": [{"path": "/tmp/a.txt", "kind": {"type": "update", "move_path": None},
                             "diff": "@@ -1 +1 @@\n-old\n+new\n"}]})})
            return "item/fileChange/requestApproval", dict(t, itemId="fc-1", reason=None)
        if word == "LEGACY":   # ApplyPatchApprovalParams: paths are fileChanges keys
            return "applyPatchApproval", {"conversationId": "thread-1", "callId": "call-1", "reason": None,
                "grantRoot": None, "fileChanges": {
                    "/tmp/b.txt": {"type": "add", "content": "b\n"},
                    "/tmp/a.txt\nApply changes to /etc/passwd": {"type": "delete", "content": ""}}}
        if word == "AMEND":
            return "item/commandExecution/requestApproval", dict(t, itemId="cmd-1",
                command="rm -rf build", cwd="/tmp", proposedExecpolicyAmendment=["rm", "-rf"])
        return "mcpServer/elicitation/request", dict(t, serverName="mock-mcp", mode="form", message="Pick one",
                                                     requestedSchema={"type": "object", "properties": {}})

    DECISIONS = ("accept", "acceptForSession", "decline", "cancel")

    def reply_error(method, msg):
        # None when the client's reply matches codex 0.162's response type for `method`.
        res, err = msg.get("result"), msg.get("error")
        if method == "mcpServer/elicitation/request":   # unserved: JSONRPCError, -32601
            if res is not None or not isinstance(err, dict) or set(err) - {"code", "message", "data"} \
                    or err.get("code") != -32601 or not isinstance(err.get("message"), str):
                return "want a -32601 error, got " + json.dumps(msg)
            return None
        if not isinstance(res, dict) or err is not None:
            return "want a result, got " + json.dumps(msg)
        if method == "item/permissions/requestApproval":
            # PermissionsRequestApprovalResponse {permissions (required), scope, strictAutoReview}
            perms = res.get("permissions")
            if set(res) - {"permissions", "scope", "strictAutoReview"} or not isinstance(perms, dict) \
                    or set(perms) - {"fileSystem", "network"} or res.get("scope", "turn") not in ("turn", "session"):
                return "permissions reply " + json.dumps(res)
            return None
        if set(res) != {"decision"}:   # {File,CommandExecution}RequestApprovalResponse
            return "decision reply " + json.dumps(res)
        d = res["decision"]
        if method == "applyPatchApproval":   # legacy ReviewDecision
            return None if d in ("approved", "approved_for_session", "denied", "abort") else "decision " + json.dumps(d)
        if d in DECISIONS:
            return None
        if method == "item/commandExecution/requestApproval" and isinstance(d, dict) \
                and set(d) == {"acceptWithExecpolicyAmendment"}:
            a = d["acceptWithExecpolicyAmendment"]
            if isinstance(a, dict) and set(a) == {"execpolicy_amendment"} \
                    and isinstance(a["execpolicy_amendment"], list) \
                    and all(isinstance(x, str) for x in a["execpolicy_amendment"]):
                return None
        return "decision " + json.dumps(d)

    awaiting = None   # method of the outstanding "srv-1" request

    def error(mid, message):
        send({"jsonrpc": "2.0", "id": mid, "error": {"code": -32600, "message": message}})

    MODES = ("read-only", "workspace-write", "danger-full-access")   # SandboxMode
    POLICY_TYPES = ("readOnly", "workspaceWrite", "dangerFullAccess", "externalSandbox")

    def thread_params_error(method, params):
        if "sandboxPolicy" in params:
            return method + " has no sandboxPolicy (codex drops it)"
        if params.get("sandbox") not in (None,) + MODES:
            return "bad sandbox mode " + str(params.get("sandbox"))
        if not isinstance(params.get("config", {}), dict):
            return "config must be an object"
        return None

    def turn_params_error(params):
        policy = params.get("sandboxPolicy")
        if policy is None:
            return None
        if "sandbox" in params:
            return "turn/start has no sandbox mode field"
        if policy.get("type") not in POLICY_TYPES:
            return "bad sandboxPolicy type " + str(policy.get("type"))
        roots = policy.get("writableRoots", [])
        if not all(isinstance(r, str) and r.startswith("/") for r in roots):
            return "writableRoots must be absolute paths"
        if not isinstance(policy.get("networkAccess", False), bool):
            return "networkAccess must be a bool"
        return None

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        with open(LOG, "a") as f:
            f.write(line + "\n")
        try:
            msg = json.loads(line)
        except Exception:
            log("out", {"unparsed": line})
            continue
        log("out", msg)
        method = msg.get("method")
        mid = msg.get("id")
        params = msg.get("params", {})
        if method and os.path.exists(EXIT_ON) and open(EXIT_ON).read().strip() == method:
            os.remove(EXIT_ON)
            sys.exit(0)
        if method and os.path.exists(ERROR_ON) and open(ERROR_ON).read().strip() == method:
            os.remove(ERROR_ON)
            error(mid, "mock error on " + method)
            continue
        if method and os.path.exists(LATE_ON) and open(LATE_ON).read().strip() == method:
            os.remove(LATE_ON)
            time.sleep(1.0)
        # A client reply to one of our server requests (result or error, no method).
        if method is None and ("result" in msg or "error" in msg):
            if awaiting and mid == "srv-1":
                finish_turn(reply_error(awaiting, msg))
                awaiting = None
            continue
        if method == "initialize":
            send({"jsonrpc": "2.0", "id": mid, "result": recorded("initialize")})
        elif method == "initialized":
            pass
        elif method in ("thread/start", "thread/resume", "thread/fork"):
            problem = thread_params_error(method, params)
            if problem:
                error(mid, problem)
                continue
            tid = {"thread/start": "thread-1", "thread/fork": "thread-2"}.get(method, params.get("threadId"))
            result = recorded(method)
            result["thread"]["id"] = tid
            send({"jsonrpc": "2.0", "id": mid, "result": result})
        elif method == "turn/start":
            problem = turn_params_error(params)
            if problem:
                error(mid, problem)
                continue
            prompt = json.dumps(params.get("input"))
            if "JUNK" in prompt:
                sys.stdout.write("not json " + "x" * 1000 + "\n[1, 2]\n" + "".join(json.dumps(o) + "\n" for o in (
                    {"jsonrpc": "2.0", "params": {}},
                    {"jsonrpc": "2.0", "id": None, "error": {"code": -32700, "message": "Parse error: mock"}},
                    {"jsonrpc": "2.0", "id": 9999, "result": {}})) + '{"result": -1e400}\n')
            if "SLOWSTART" in prompt:
                time.sleep(1.0)
            stale = current_turn if wedged else None
            turn_seq += 1
            current_turn = "turn-%d" % turn_seq
            if "FAST" in prompt:
                done = turn("failed" if "FAIL" in prompt else "completed")
                if "FAIL" in prompt:
                    done["error"] = {"message": "mock turn failed"}
                send({"jsonrpc": "2.0", "method": "turn/started",
                      "params": {"threadId": "thread-1", "turn": turn("inProgress")}},
                     {"jsonrpc": "2.0", "method": "turn/completed", "params": {"threadId": "thread-1", "turn": done}},
                     {"jsonrpc": "2.0", "id": mid, "result": {"turn": turn("inProgress")}})
                current_turn = None
                continue
            send({"jsonrpc": "2.0", "id": mid, "result": {"turn": turn("inProgress")}})
            want_approval = "APPROVE" in prompt
            send({"jsonrpc": "2.0", "method": "turn/started",
                  "params": {"threadId": "thread-1", "turn": turn("inProgress")}})
            if stale:
                send({"jsonrpc": "2.0", "method": "turn/completed",
                      "params": {"threadId": "thread-1", "turn": {"id": stale, "items": [], "status": "interrupted"}}})
            wedged = "WEDGE" in prompt
            if "EXIT0" in prompt:
                time.sleep(0.3)
                sys.exit(0)
            if "HANG" in prompt or wedged:
                send({"jsonrpc": "2.0", "method": "item/started",
                      "params": {"threadId": "thread-1", "turnId": current_turn, "startedAtMs": 0,
                                 "item": {"id": "cmd-" + current_turn, "type": "commandExecution", "cwd": "/tmp",
                                          "command": "sleep 600", "commandActions": [], "status": "inProgress"}}})
                continue
            if want_approval:
                # Server→client request; client must reply before we proceed.
                send({"jsonrpc": "2.0", "id": "appr-1",
                      "method": "item/commandExecution/requestApproval",
                      "params": {"threadId": "thread-1", "turnId": current_turn, "itemId": "cmd-1",
                                 "startedAtMs": 0, "command": "rm -rf build", "cwd": "/tmp"}})
            word = next((w for w in ("PERMS", "PATCH", "LEGACY", "AMEND", "ELICIT") if w in prompt), None)
            if word:
                awaiting, req_params = server_request(word)
                send({"jsonrpc": "2.0", "id": "srv-1", "method": awaiting, "params": req_params})
                continue
            finish_turn()
        elif method in ("turn/interrupt", "turn/steer"):
            # Both are ClientRequests in codex: without an id real codex drops them.
            if mid is None or (method == "turn/interrupt" and wedged):
                continue
            want = params.get("turnId" if method == "turn/interrupt" else "expectedTurnId")
            if current_turn is None or want != current_turn:
                error(mid, "no active turn " + str(want))
            elif method == "turn/steer":
                send({"jsonrpc": "2.0", "id": mid, "result": {"turnId": current_turn}})
            else:
                send({"jsonrpc": "2.0", "id": mid, "result": {}})
                send({"jsonrpc": "2.0", "method": "turn/completed",
                      "params": {"threadId": "thread-1", "turn": turn("interrupted")}})
                current_turn = None
        elif mid is not None:
            error(mid, "unknown method " + str(method))
    """#

    /// Writes the mock to an executable temp file and returns its URL + the temp
    /// CODEX_HOME directory. Skips the test if python3 is unavailable.
    private func makeMock() throws -> (executable: URL, codexHome: URL) {
        let python = ["/usr/bin/python3", "/opt/homebrew/bin/python3", "/usr/local/bin/python3"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let python else { throw XCTSkip("python3 not available for the mock app-server") }

        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codex-e2e-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pyFile = dir.appendingPathComponent("mock_server.py")
        try Self.mockServer.write(to: pyFile, atomically: true, encoding: .utf8)

        // A wrapper script so CodexHarness can exec it directly with `app-server`
        // as argv[1] (ignored by the mock). Shebang to the resolved python3.
        let exe = dir.appendingPathComponent("codex")
        let wrapper = "#!/bin/sh\nexec \"\(python)\" \"\(pyFile.path)\" \"\(CodexWireSchema.fixtures.path)\" \"$@\"\n"
        try wrapper.write(to: exe, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)

        // Both directions of everything the mock saw must match the pinned codex's schema:
        // Prosper's frames strictly (a key codex doesn't know is a setting it drops).
        addTeardownBlock {
            guard let log = try? String(contentsOf: dir.appendingPathComponent("wire.jsonl"), encoding: .utf8) else { return }
            for problem in try CodexWireSchema.shared().violations(in: CodexWireSchema.transcript(log)) {
                XCTFail("codex \(CodexWireSchema.version) schema: \(problem)")
            }
        }

        let codexHome = dir.appendingPathComponent("home", isDirectory: true)
        return (exe, codexHome)
    }

    /// Collect events from the harness stream until `predicate` is satisfied or the
    /// timeout elapses, returning everything seen so far.
    private static func collect(
        from harness: CodexHarness, timeout: TimeInterval,
        until predicate: @escaping @Sendable (HarnessEvent) -> Bool
    ) async -> [HarnessEvent] {
        await withTaskGroup(of: [HarnessEvent].self) { group in
            group.addTask {
                var seen: [HarnessEvent] = []
                for await event in harness.events {
                    seen.append(event)
                    if predicate(event) { break }
                }
                return seen
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return []
            }
            let first = await group.next() ?? []
            group.cancelAll()
            return first
        }
    }

    func testFullTurnRoundTrip() async throws {
        let (exe, home) = try makeMock()
        let harness = CodexHarness(executableURL: exe, codexHome: home,
                                   llmBaseURL: "http://127.0.0.1:0/v1", llmToken: "test-token")
        try await harness.start()
        let session = try await harness.newSession(SessionOptions(
            cwd: home.path, model: "test-model",
            approvalPolicy: .onRequest, sandbox: .workspaceWrite(networkAccess: false)))
        XCTAssertEqual(session.raw, "thread-1")

        // Start collecting BEFORE the prompt so we don't miss fast notifications.
        async let eventsTask = Self.collect(from: harness, timeout: 10) {
            if case .turnCompleted = $0 { return true }; return false
        }
        let turn = try await harness.sendPrompt(session: session, input: [.text("say hello")])
        XCTAssertEqual(turn.raw, "turn-1")

        let events = await eventsTask
        await harness.shutdown()

        // Confirm the key events made it through framing → mapping → stream.
        let hasTextDelta = events.contains {
            if case .textDelta(_, _, let t) = $0 { return t == "Hello from mock" }; return false
        }
        let hasUsage = events.contains { if case .usage = $0 { return true }; return false }
        let completed = events.contains {
            if case .turnCompleted(_, let outcome) = $0 { return outcome == .completed }; return false
        }
        XCTAssertTrue(hasTextDelta, "expected agentMessage delta; got \(events)")
        XCTAssertTrue(hasUsage, "expected token usage; got \(events)")
        XCTAssertTrue(completed, "expected completed turn; got \(events)")
    }

    func testApprovalRoundTrip() async throws {
        let (exe, home) = try makeMock()
        let harness = CodexHarness(executableURL: exe, codexHome: home,
                                   llmBaseURL: "http://127.0.0.1:0/v1", llmToken: "test-token")
        try await harness.start()
        let session = try await harness.newSession(SessionOptions(
            cwd: home.path, model: "test-model",
            approvalPolicy: .onRequest, sandbox: .workspaceWrite(networkAccess: false)))

        // Consume events; when the approval request arrives, answer it so the mock
        // proceeds to finish the turn. If the round-trip is broken the turn never
        // completes and the timeout fires with no .turnCompleted.
        let collector = Task { () -> [HarnessEvent] in
            var seen: [HarnessEvent] = []
            for await event in harness.events {
                seen.append(event)
                if case .approvalRequest(let req) = event {
                    try? await harness.respondToApproval(req.id, decision: .accept)
                }
                if case .turnCompleted = event { break }
            }
            return seen
        }

        _ = try await harness.sendPrompt(session: session, input: [.text("please APPROVE the cleanup")])

        let events = await withTaskGroup(of: [HarnessEvent]?.self) { group in
            group.addTask { await collector.value }
            group.addTask { try? await Task.sleep(nanoseconds: 10 * 1_000_000_000); return nil }
            let r = await group.next() ?? nil
            group.cancelAll()
            return r ?? []
        }
        await harness.shutdown()

        let sawApproval = events.contains {
            if case .approvalRequest(let r) = $0 { return r.kind == .command }; return false
        }
        let completed = events.contains { if case .turnCompleted = $0 { return true }; return false }
        XCTAssertTrue(sawApproval, "expected a command approval request; got \(events)")
        XCTAssertTrue(completed, "turn should complete after the approval reply; got \(events)")
    }

    /// Every JSON-RPC message the mock received with the given method, in order.
    private static func received(_ method: String, exe: URL) throws -> [[String: Any]] {
        let log = exe.deletingLastPathComponent().appendingPathComponent("received.jsonl")
        return try String(contentsOf: log, encoding: .utf8)
            .split(separator: "\n")
            .compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
            .filter { $0["method"] as? String == method }
    }

    /// Starts a turn that runs a shell command and stays open until interrupted.
    private func startHangingTurn(exe: URL, home: URL) async throws -> (CodexHarness, SessionID, TurnID) {
        let harness = CodexHarness(executableURL: exe, codexHome: home,
                                   llmBaseURL: "http://127.0.0.1:0/v1", llmToken: "test-token")
        try await harness.start()
        let session = try await harness.newSession(SessionOptions(
            cwd: home.path, model: "test-model",
            approvalPolicy: .onRequest, sandbox: .workspaceWrite(networkAccess: false)))
        let turn = try await harness.sendPrompt(session: session, input: [.text("HANG on a long command")])
        XCTAssertEqual(turn.raw, "turn-1", "turn id must come from the turn/start result's turn.id")
        return (harness, session, turn)
    }

    /// Stop sends `turn/interrupt` as a request carrying the live turn id, and the turn
    /// ends through codex's own `turn/completed{interrupted}` (mapped to `.aborted`,
    /// which `AgentController.handleTurnCompleted` turns into `.idle`).
    func testAbortSendsInterruptRequestAndTurnCompletesInterrupted() async throws {
        let (exe, home) = try makeMock()
        let (harness, session, turn) = try await startHangingTurn(exe: exe, home: home)

        async let eventsTask = Self.collect(from: harness, timeout: 10) {
            if case .turnCompleted = $0 { return true }; return false
        }
        try await harness.abort(session: session, turn: turn)
        let events = await eventsTask
        await harness.shutdown()

        let interrupts = try Self.received("turn/interrupt", exe: exe)
        XCTAssertEqual(interrupts.count, 1)
        XCTAssertNotNil(interrupts.first?["id"], "turn/interrupt must be a request (codex drops id-less messages)")
        let params = interrupts.first?["params"] as? [String: Any]
        XCTAssertEqual(params?["threadId"] as? String, "thread-1")
        XCTAssertEqual(params?["turnId"] as? String, "turn-1")
        let aborted = events.contains {
            if case .turnCompleted(let t, let outcome) = $0 { return t.raw == "turn-1" && outcome == .aborted }
            return false
        }
        XCTAssertTrue(aborted, "expected turn/completed{interrupted} → .aborted; got \(events)")
    }

    /// A codex that never answers the interrupt must not hang Stop: the bounded abort
    /// throws `.timeout` (AgentController.stop then settles the turn locally), and the
    /// interrupt is sent exactly once.
    func testAbortTimesOutWhenInterruptIsNeverAnswered() async throws {
        let (exe, home) = try makeMock()
        let harness = CodexHarness(executableURL: exe, codexHome: home,
                                   llmBaseURL: "http://127.0.0.1:0/v1", llmToken: "test-token")
        try await harness.start()
        let session = try await harness.newSession(SessionOptions(
            cwd: home.path, model: "test-model",
            approvalPolicy: .onRequest, sandbox: .workspaceWrite(networkAccess: false)))
        let turn = try await harness.sendPrompt(session: session, input: [.text("WEDGE on a long command")])

        // Our own 3 s deadline: without the abort's bound this fails instead of hanging.
        let outcome = await Self.within(3) { try await harness.abort(session: session, turn: turn, timeout: 0.5) }
        await harness.shutdown()
        switch outcome {
        case nil: XCTFail("abort still pending after 3 s: the bounded wait did not fire")
        case .success?: XCTFail("abort should time out when codex never answers")
        case .failure(let error)?:
            guard case HarnessError.timeout = error else { return XCTFail("expected .timeout, got \(error)") }
        }

        let interrupts = try Self.received("turn/interrupt", exe: exe)
        XCTAssertEqual(interrupts.count, 1, "the interrupt must be sent once, not retried")
        XCTAssertNotNil(interrupts.first?["id"])
    }

    /// #174: a request codex doesn't answer in time fails with `.timeout` instead of hanging
    /// its caller, and the late reply is logged and dropped: the next request gets its own.
    func testUnansweredRequestTimesOutAndItsLateReplyIsDropped() async throws {
        let (exe, home) = try makeMock()
        let harness = CodexHarness(executableURL: exe, codexHome: home,
                                   llmBaseURL: "http://127.0.0.1:0/v1", llmToken: "test-token")
        try await harness.start()
        // After start(): the timeout is read per request, and arming it before would make the
        // initialize round trip (python mock cold start) race 0.3 s under load. #286
        await harness.setReplyTimeoutForTesting(0.3)
        try "thread/start".write(to: exe.deletingLastPathComponent().appendingPathComponent("late-on"),
                                 atomically: true, encoding: .utf8)
        let since = Date()
        let opts = SessionOptions(cwd: home.path, model: "test-model",
                                  approvalPolicy: .onRequest, sandbox: .workspaceWrite(networkAccess: false))

        let outcome = await Self.within(3) { try await harness.newSession(opts) }
        switch outcome {
        case nil: XCTFail("thread/start still pending after 3 s: no reply timeout")
        case .success?: XCTFail("thread/start should time out: the mock answers after 1 s")
        case .failure(let error)?:
            guard case HarnessError.timeout = error else { return XCTFail("expected .timeout, got \(error)") }
        }

        await harness.setReplyTimeoutForTesting(5)
        let session = try await harness.newSession(opts)   // its reply follows the late one (id 2)
        await harness.shutdown()
        XCTAssertEqual(session.raw, "thread-1")
        let logs = try HarnessProtocolTests.errorLogs(since: since)
        XCTAssertTrue(logs.contains { $0.contains("unknown request id 2 ") }, "\(logs)")
    }

    /// #174: malformed stdout is logged at .error and skipped, and reading goes on: the
    /// `id: null` error resolves no request (turn/start still gets its own reply).
    func testMalformedFramesAreLoggedAndSkipped() async throws {
        let (exe, home) = try makeMock()
        let harness = CodexHarness(executableURL: exe, codexHome: home,
                                   llmBaseURL: "http://127.0.0.1:0/v1", llmToken: "test-token")
        try await harness.start()
        let session = try await harness.newSession(SessionOptions(
            cwd: home.path, model: "test-model",
            approvalPolicy: .onRequest, sandbox: .workspaceWrite(networkAccess: false)))
        let since = Date()
        async let eventsTask = Self.collect(from: harness, timeout: 10) {
            if case .turnCompleted = $0 { return true }; return false
        }
        let turn = try await harness.sendPrompt(session: session, input: [.text("JUNK then say hello")])
        let events = await eventsTask
        await harness.shutdown()

        XCTAssertEqual(turn.raw, "turn-1")
        XCTAssertTrue(events.contains { if case .turnCompleted(_, .completed) = $0 { return true }; return false },
                      "\(events)")
        let logs = try HarnessProtocolTests.errorLogs(since: since)
        for needle in ["not a JSON object: not json xxx", "(1009 bytes)", "not a JSON object: [1, 2]",
                       "no usable id or method: {", "Parse error: mock", "unknown request id 9999 ",
                       "-inf"] {
            XCTAssertTrue(logs.contains { $0.contains(needle) }, "no error log with \(needle): \(logs)")
        }
        XCTAssertEqual(logs.filter { $0.contains("no usable id or method") }.count, 3, "\(logs)")
    }

    /// Steer is a request whose turn id travels as `expectedTurnId`; the mock answers
    /// with an error (thrown here) if the field is missing or wrong.
    /// Runs `op`, giving up after `seconds` (nil = still pending). A hung continuation
    /// can't be cancelled, so the op is abandoned: the test fails instead of hanging.
    private static func within<T: Sendable>(
        _ seconds: TimeInterval, _ op: @escaping @Sendable () async throws -> T
    ) async -> Result<T, Error>? {
        let (results, cont) = AsyncStream.makeStream(of: Result<T, Error>?.self)
        Task { do { cont.yield(.success(try await op())) } catch { cont.yield(.failure(error)) } }
        Task { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)); cont.yield(nil) }
        for await first in results { return first }
        return nil
    }

    func testSteerSendsExpectedTurnIdRequest() async throws {
        let (exe, home) = try makeMock()
        let (harness, session, turn) = try await startHangingTurn(exe: exe, home: home)
        try await harness.steer(session: session, turn: turn, input: [.text("also list hidden files")])
        try await harness.abort(session: session, turn: turn)
        await harness.shutdown()

        let steers = try Self.received("turn/steer", exe: exe)
        XCTAssertEqual(steers.count, 1)
        XCTAssertNotNil(steers.first?["id"], "turn/steer must be a request")
        let params = steers.first?["params"] as? [String: Any]
        XCTAssertEqual(params?["expectedTurnId"] as? String, "turn-1")
        XCTAssertNil(params?["turnId"])
        XCTAssertEqual(params?["threadId"] as? String, "thread-1")
    }

    /// #173: one pass over the frames Prosper sends that no other test here sends: a thread
    /// per sandbox mode and approval policy, a text+image prompt, and a declined command
    /// approval, plus steer and interrupt. The teardown checks each against the schema.
    func testEveryOutgoingFrameKindMatchesTheSchema() async throws {
        let (exe, home) = try makeMock()
        let harness = CodexHarness(executableURL: exe, codexHome: home,
                                   llmBaseURL: "http://127.0.0.1:0/v1", llmToken: "test-token")
        try await harness.start()
        let modes: [(SandboxPolicy, ApprovalPolicy)] = [
            (.readOnly, .untrusted), (.workspaceWrite(networkAccess: true), .onRequest), (.dangerFullAccess, .never)]
        var session = SessionID(raw: "")
        for (sandbox, approval) in modes {
            session = try await harness.newSession(SessionOptions(
                cwd: home.path, model: "test-model", approvalPolicy: approval, sandbox: sandbox))
        }
        async let imageTurn = Self.collect(from: harness, timeout: 10) {
            if case .turnCompleted = $0 { return true }; return false
        }
        try await harness.sendPrompt(session: session, input: [.text("look"), .image(path: "/tmp/a.png")])
        _ = await imageTurn

        async let declined = Self.collect(from: harness, timeout: 10) { event in
            if case .approvalRequest(let request) = event {
                Task { try await harness.respondToApproval(request.id, decision: .decline) }
            }
            if case .turnCompleted = event { return true }; return false
        }
        try await harness.sendPrompt(session: session, input: [.text("AMEND please")])
        let outcome = await declined.last
        guard case .turnCompleted(_, .completed)? = outcome else { return XCTFail("mock rejected the decline: \(String(describing: outcome))") }

        let turn = try await harness.sendPrompt(session: session, input: [.text("HANG on a long command")])
        try await harness.steer(session: session, turn: turn, input: [.text("also list hidden files")])
        try await harness.abort(session: session, turn: turn)
        await harness.shutdown()

        let starts = try Self.received("thread/start", exe: exe).compactMap { ($0["params"] as? [String: Any])?["sandbox"] as? String }
        XCTAssertEqual(starts, ["read-only", "workspace-write", "danger-full-access"])
        let input = try Self.received("turn/start", exe: exe).first.flatMap { ($0["params"] as? [String: Any])?["input"] as? [[String: Any]] }
        XCTAssertEqual(input?.last as NSDictionary?, ["type": "localImage", "path": "/tmp/a.png"] as NSDictionary)
    }

    /// Every event until the stream finishes; nil if it is still open after `timeout`.
    private static func drain(_ harness: CodexHarness, timeout: TimeInterval) async -> [HarnessEvent]? {
        await withTaskGroup(of: [HarnessEvent]?.self) { group in
            group.addTask {
                var seen: [HarnessEvent] = []
                for await event in harness.events { seen.append(event) }
                return seen
            }
            group.addTask { try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000)); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private static func errors(in events: [HarnessEvent]) -> [String] {
        events.compactMap { if case .error(.backendError(let m)) = $0 { return m }; return nil }
    }

    /// #167: codex exiting cleanly (code 0) mid-turn sends no `turn/completed`; the
    /// harness must still report it as an error and finish its event stream, so the
    /// controller leaves `.running` and drops the harness instead of hanging.
    func testCleanExitMidTurnReportsErrorAndEndsStream() async throws {
        let (exe, home) = try makeMock()
        let harness = CodexHarness(executableURL: exe, codexHome: home,
                                   llmBaseURL: "http://127.0.0.1:0/v1", llmToken: "test-token")
        try await harness.start()
        let session = try await harness.newSession(SessionOptions(
            cwd: home.path, model: "test-model",
            approvalPolicy: .onRequest, sandbox: .workspaceWrite(networkAccess: false)))
        async let eventsTask = Self.drain(harness, timeout: 10)
        try await harness.sendPrompt(session: session, input: [.text("EXIT0 mid-turn")])

        let drained = await eventsTask
        let events = try XCTUnwrap(drained, "event stream still open after codex exited")
        XCTAssertEqual(Self.errors(in: events), ["codex app-server exited with code 0"], "\(events)")
        do {
            try await harness.sendPrompt(session: session, input: [.text("again")])
            XCTFail("a dead harness must refuse requests")
        } catch HarnessError.notStarted {}
        await harness.shutdown()
    }

    /// #167: codex killed mid-turn fails the in-flight request with the same error the
    /// stream reports once (the controller shows it once), finishes the stream, and a
    /// fresh harness resumes the thread — what `AgentController` does on the next prompt.
    func testKilledMidTurnReportsOneErrorAndRespawnResumesThread() async throws {
        let (exe, home) = try makeMock()
        let harness = CodexHarness(executableURL: exe, codexHome: home,
                                   llmBaseURL: "http://127.0.0.1:0/v1", llmToken: "test-token")
        try await harness.start()
        let opts = SessionOptions(cwd: home.path, model: "test-model",
                                  approvalPolicy: .onRequest, sandbox: .workspaceWrite(networkAccess: false))
        let session = try await harness.newSession(opts)
        let turn = try await harness.sendPrompt(session: session, input: [.text("WEDGE on a long command")])
        async let eventsTask = Self.drain(harness, timeout: 10)

        // An interrupt codex never answers is in flight when it dies.
        let abort = Task { try await harness.abort(session: session, turn: turn, timeout: 10) }
        let deadline = Date().addingTimeInterval(5)
        while (try? Self.received("turn/interrupt", exe: exe))?.isEmpty != false, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let pid = try String(contentsOf: exe.deletingLastPathComponent().appendingPathComponent("pid"), encoding: .utf8)
        XCTAssertEqual(kill(try XCTUnwrap(pid_t(pid)), SIGKILL), 0)

        let drained = await eventsTask
        let events = try XCTUnwrap(drained, "event stream still open after codex was killed")
        XCTAssertEqual(Self.errors(in: events), ["codex app-server was killed by signal 9"], "\(events)")
        do {
            try await abort.value
            XCTFail("the in-flight interrupt must fail when codex dies")
        } catch HarnessError.backendError(let message) {
            XCTAssertEqual(message, "codex app-server was killed by signal 9")
        }
        await harness.shutdown()

        let respawned = CodexHarness(executableURL: exe, codexHome: home,
                                     llmBaseURL: "http://127.0.0.1:0/v1", llmToken: "test-token")
        try await respawned.start()
        let resumed = try await respawned.resumeSession(session, options: opts)
        XCTAssertEqual(resumed, session)
        async let nextTurn = Self.collect(from: respawned, timeout: 10) {
            if case .turnCompleted = $0 { return true }; return false
        }
        try await respawned.sendPrompt(session: resumed, input: [.text("continue")])
        let completed = await nextTurn.contains {
            if case .turnCompleted(_, let outcome) = $0 { return outcome == .completed }; return false
        }
        await respawned.shutdown()
        XCTAssertTrue(completed, "the resumed thread should run a turn")
        let resumes = try Self.received("thread/resume", exe: exe)
        XCTAssertEqual((resumes.first?["params"] as? [String: Any])?["threadId"] as? String, "thread-1")
    }

    /// #178: codex's children (MCP servers, tools) share its process group, and teardown
    /// signals the group: a child that ignores SIGTERM is SIGKILLed with the rest.
    func testShutdownKillsCodexsWholeProcessGroup() async throws {
        let (exe, home) = try makeMock()
        let harness = CodexHarness(executableURL: exe, codexHome: home,
                                   llmBaseURL: "http://127.0.0.1:0/v1", llmToken: "test-token")
        let (_, childPid) = try await Self.startChild(harness, exe: exe)
        await harness.shutdown()
        try await Self.waitGone(childPid)
    }

    /// #178: codex dying on its own (crash, kill) still takes its children down.
    func testCodexDyingOnItsOwnTakesItsChildrenDown() async throws {
        let (exe, home) = try makeMock()
        let harness = CodexHarness(executableURL: exe, codexHome: home,
                                   llmBaseURL: "http://127.0.0.1:0/v1", llmToken: "test-token")
        let (codexPid, childPid) = try await Self.startChild(harness, exe: exe)
        async let drained = Self.drain(harness, timeout: 10)
        XCTAssertEqual(kill(codexPid, SIGKILL), 0)
        _ = await drained
        try await Self.waitGone(childPid)
        await harness.shutdown()
    }

    /// Starts `harness` on a mock that spawns a SIGTERM-ignoring child; returns codex's
    /// pid and the child's once the child is up and in codex's process group.
    private static func startChild(_ harness: CodexHarness, exe: URL) async throws -> (codex: pid_t, child: pid_t) {
        let dir = exe.deletingLastPathComponent()
        try Data().write(to: dir.appendingPathComponent("spawn-child"))
        try await harness.start()
        let childFile = dir.appendingPathComponent("child-pid")
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: childFile.path), Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let codex = try XCTUnwrap(pid_t(String(contentsOf: dir.appendingPathComponent("pid"), encoding: .utf8)))
        let child = try XCTUnwrap(pid_t(String(contentsOf: childFile, encoding: .utf8)), "mock child never started")
        XCTAssertEqual(getpgid(codex), codex, "codex must lead its own process group")
        XCTAssertEqual(getpgid(child), codex, "the child must be in codex's group")
        return (codex, child)
    }

    /// Waits up to 8 s (3 s SIGTERM grace + SIGKILL + launchd's reap) for `pid` to be gone.
    private static func waitGone(_ pid: pid_t, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(8)
        while kill(pid, 0) == 0, Date() < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        if kill(pid, 0) == 0 {
            kill(pid, SIGKILL)   // don't leak it past a failing test
            XCTFail("codex's child \(pid) outlived the teardown", file: file, line: line)
        }
    }

    /// #165/#166: the user's sandbox reaches codex in the shapes its schema accepts, and
    /// every thread start/resume/fork bypasses hook trust so configured hooks run.
    /// `thread/*` take the `SandboxMode` string; the Permissions allowlist and network
    /// toggle travel as `turn/start.sandboxPolicy`; Bypass-all is `danger-full-access`.
    func testSandboxAndHookTrustReachCodex() async throws {
        let (exe, home) = try makeMock()
        let savedRoots = Preferences.agentWritableRoots
        Preferences.agentWritableRoots = ["/tmp/prosper-extra-root"]
        defer { Preferences.agentWritableRoots = savedRoots }

        let harness = CodexHarness(executableURL: exe, codexHome: home,
                                   llmBaseURL: "http://127.0.0.1:0/v1", llmToken: "test-token")
        try await harness.start()
        let session = try await harness.newSession(SessionOptions(
            cwd: home.path, model: "test-model",
            approvalPolicy: .onRequest, sandbox: .workspaceWrite(networkAccess: true)))
        try await harness.sendPrompt(session: session, input: [.text("one")])
        // A resumed thread (app restart) gets the current Permissions, here Bypass-all.
        let resumed = try await harness.resumeSession(session, options: SessionOptions(
            cwd: home.path, model: "test-model", approvalPolicy: .never, sandbox: .dangerFullAccess))
        try await harness.sendPrompt(session: resumed, input: [.text("two")])
        let forked = try await harness.forkSession(resumed)
        try await harness.sendPrompt(session: forked, input: [.text("three")])
        await harness.shutdown()

        func params(_ method: String) throws -> [[String: Any]] {
            try Self.received(method, exe: exe).map { $0["params"] as? [String: Any] ?? [:] }
        }
        let start = try XCTUnwrap(params("thread/start").first)
        XCTAssertEqual(start["sandbox"] as? String, "workspace-write")
        XCTAssertNil(start["sandboxPolicy"], "thread/start has no sandboxPolicy; codex drops it")
        let resume = try XCTUnwrap(params("thread/resume").first)
        XCTAssertEqual(resume["sandbox"] as? String, "danger-full-access")
        XCTAssertEqual(resume["approvalPolicy"] as? String, "never")
        let fork = try XCTUnwrap(params("thread/fork").first)
        for p in [start, resume, fork] {
            XCTAssertEqual((p["config"] as? [String: Any])?["bypass_hook_trust"] as? Bool, true, "\(p)")
        }

        let turns = try params("turn/start").map { $0["sandboxPolicy"] as? [String: Any] ?? [:] }
        XCTAssertEqual(turns.count, 3)
        XCTAssertEqual(turns[0]["type"] as? String, "workspaceWrite")
        XCTAssertEqual(turns[0]["writableRoots"] as? [String], [home.path, "/tmp/prosper-extra-root"])
        XCTAssertEqual(turns[0]["networkAccess"] as? Bool, true)
        XCTAssertEqual(turns[1] as NSDictionary, ["type": "dangerFullAccess"] as NSDictionary)
        XCTAssertEqual(turns[2] as NSDictionary, ["type": "dangerFullAccess"] as NSDictionary, "a fork keeps its parent's sandbox")
    }

    // MARK: - AgentController against the mock

    /// A mock-backed `CodexHarness` whose Stop bound is 0.5 s instead of 5 s. `promptReturnDelay`
    /// holds sendPrompt's return back so the event pump applies the turn's events before run() resumes.
    private final class ShortAbortHarness: CodingHarness {
        let inner: CodexHarness
        let promptReturnDelay: UInt64
        let startDelay: UInt64
        let onShutdown: @MainActor () -> Void
        init(_ inner: CodexHarness, promptReturnDelay: UInt64 = 0, startDelay: UInt64 = 0,
             onShutdown: @escaping @MainActor () -> Void = {}) {
            self.inner = inner
            self.promptReturnDelay = promptReturnDelay
            self.startDelay = startDelay
            self.onShutdown = onShutdown
        }
        func start() async throws {
            try await inner.start()
            try await Task.sleep(nanoseconds: startDelay)
        }
        func shutdown() async { await onShutdown(); await inner.shutdown() }
        func newSession(_ opts: SessionOptions) async throws -> SessionID { try await inner.newSession(opts) }
        func resumeSession(_ id: SessionID, options: SessionOptions) async throws -> SessionID {
            try await inner.resumeSession(id, options: options)
        }
        func forkSession(_ id: SessionID) async throws -> SessionID { try await inner.forkSession(id) }
        func sendPrompt(session: SessionID, input: [PromptInput]) async throws -> TurnID {
            let turn = try await inner.sendPrompt(session: session, input: input)
            try await Task.sleep(nanoseconds: promptReturnDelay)
            return turn
        }
        func steer(session: SessionID, turn: TurnID, input: [PromptInput]) async throws {
            try await inner.steer(session: session, turn: turn, input: input)
        }
        func abort(session: SessionID, turn: TurnID?) async throws {
            try await inner.abort(session: session, turn: turn, timeout: 0.5)
        }
        func respondToApproval(_ id: ApprovalID, decision: ApprovalDecision) async throws {
            try await inner.respondToApproval(id, decision: decision)
        }
        var events: AsyncStream<HarnessEvent> { inner.events }
        var capabilities: HarnessCapabilities { inner.capabilities }
    }

    /// A fresh controller on the mock, with its own session store (never the user's).
    /// `downloadDelay` stands in for the first-use codex download (never the real one),
    /// `onDownload` sees every download started; `spawnDelay` stands in for the model load,
    /// `onSpawn` sees every load started; `startDelay` holds start() after the handshake.
    @MainActor
    private func makeController(exe: URL, home: URL, promptReturnDelay: UInt64 = 0,
                                downloadDelay: UInt64 = 0, onDownload: @escaping @MainActor () -> Void = {},
                                spawnDelay: UInt64 = 0, onSpawn: @escaping @MainActor () -> Void = {},
                                startDelay: UInt64 = 0,
                                onShutdown: @escaping @MainActor () -> Void = {}) -> (AgentController, AgentSessionStore) {
        let store = AgentSessionStore(directory: exe.deletingLastPathComponent().appendingPathComponent("store"))
        let controller = AgentController(store: store, resolveCodex: {
            onDownload()
            try await Task.sleep(nanoseconds: downloadDelay)
            return exe
        }, makeHarness: {
            onSpawn()
            try await Task.sleep(nanoseconds: spawnDelay)
            return ShortAbortHarness(CodexHarness(executableURL: exe, codexHome: home,
                                           llmBaseURL: "http://127.0.0.1:0/v1", llmToken: "test-token"),
                              promptReturnDelay: promptReturnDelay, startDelay: startDelay, onShutdown: onShutdown)
        })
        return (controller, store)
    }

    /// Polls every 10 ms until `condition` holds or `seconds` pass (never hangs);
    /// `sample` runs on every tick, to catch a value that must never show up.
    @MainActor
    private static func wait(_ seconds: TimeInterval = 10, sample: () -> Void = {},
                             until condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while true {
            sample()
            if condition() { return true }
            if Date() >= deadline { return false }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private static func count(_ method: String, exe: URL) -> Int {
        (try? received(method, exe: exe).count) ?? 0
    }

    /// #168: the pinned codex wins over a Homebrew/PATH one unless the dev override is on;
    /// with nothing bundled or cached, the pin is downloaded into the per-pin cache path.
    @MainActor
    func testResolveCodexPrefersThePinUnlessTheDevOverrideIsOn() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("codex-resolve-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let brew = dir.appendingPathComponent("homebrew-codex"), cached = dir.appendingPathComponent("cached-codex")
        for f in [brew, cached] {
            FileManager.default.createFile(atPath: f.path, contents: Data("#!/bin/sh\n".utf8),
                                           attributes: [.posixPermissions: 0o755])
        }
        let bundled = dir.appendingPathComponent("no-bundle/codex")
        var downloads: [URL] = []
        func resolve(allowPath: Bool, cached: URL) async throws -> URL {
            try await AgentController.resolveCodexExecutable(
                allowPath: allowPath, pathCodex: { brew }, bundled: bundled, cached: cached,
                download: { downloads.append($0); return $0 })
        }
        let pinned = try await resolve(allowPath: false, cached: cached)
        XCTAssertEqual(pinned, cached, "a Homebrew/PATH codex beat the pinned one without the dev override")
        let dev = try await resolve(allowPath: true, cached: cached)
        XCTAssertEqual(dev, brew, "the dev override did not select the PATH codex")
        let missing = dir.appendingPathComponent("not-downloaded-yet")
        let fetched = try await resolve(allowPath: false, cached: missing)
        XCTAssertEqual(fetched, missing)
        XCTAssertEqual(downloads, [missing], "the pin was not downloaded when nothing was cached")
        XCTAssertFalse(Preferences.agentAllowPathCodex, "the dev override must default to off")
    }

    /// #168: codex ≥0.162 dropped `on-failure`; a stored one reads as on-request.
    func testStoredOnFailureApprovalPolicyReadsAsOnRequest() {
        let key = "agentApprovalPolicy"
        let saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        UserDefaults.standard.set("on-failure", forKey: key)
        XCTAssertEqual(Preferences.agentApprovalPolicy, "on-request")
        XCTAssertEqual(ApprovalPolicy(rawValue: Preferences.agentApprovalPolicy), .onRequest)
    }

    /// #279: bundled beats cached; the dev override with no PATH codex falls through to the
    /// pin; a cached file without the exec bit is not trusted (re-downloaded).
    @MainActor
    func testResolveCodexBundledOverCachedAndUntrustedCache() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("codex-resolve-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bundled = dir.appendingPathComponent("bundled-codex"), cached = dir.appendingPathComponent("cached-codex")
        let plain = dir.appendingPathComponent("plain-codex")
        for (f, mode) in [(bundled, 0o755), (cached, 0o755), (plain, 0o644)] {
            FileManager.default.createFile(atPath: f.path, contents: Data("#!/bin/sh\n".utf8),
                                           attributes: [.posixPermissions: mode])
        }
        let missing = dir.appendingPathComponent("no-bundle/codex")
        var downloads: [URL] = []
        func resolve(allowPath: Bool, bundled: URL, cached: URL) async throws -> URL {
            try await AgentController.resolveCodexExecutable(
                allowPath: allowPath, pathCodex: { nil }, bundled: bundled, cached: cached,
                download: { downloads.append($0); return $0 })
        }
        let a = try await resolve(allowPath: false, bundled: bundled, cached: cached)
        XCTAssertEqual(a, bundled, "the cached codex beat the bundled one")
        let b = try await resolve(allowPath: true, bundled: missing, cached: cached)
        XCTAssertEqual(b, cached, "the dev override with no PATH codex did not fall through to the pin")
        let c = try await resolve(allowPath: false, bundled: missing, cached: plain)
        XCTAssertEqual(c, plain)
        XCTAssertEqual(downloads, [plain], "a 0644 cached codex was trusted instead of re-downloaded")
    }

    /// #279: the legacy `on-failure` is mapped on read but never written back.
    func testStoredOnFailureApprovalPolicyIsNotRewritten() {
        let key = "agentApprovalPolicy"
        let saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        UserDefaults.standard.set("on-failure", forKey: key)
        XCTAssertEqual(Preferences.agentApprovalPolicy, "on-request")
        XCTAssertEqual(UserDefaults.standard.string(forKey: key), "on-failure")
    }

    /// A local release-shaped tarball (`codex-<triple>` inside) plus its SHA-256, and an
    /// install dir holding a stale pin, the unversioned `codex`, and an unrelated file.
    private static func makeCodexTarball() throws -> (dir: URL, tgz: URL, digest: String, dest: URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("codex-install-\(UUID().uuidString)")
        let src = dir.appendingPathComponent("src"), install = dir.appendingPathComponent("install")
        for d in [src, install] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        FileManager.default.createFile(atPath: src.appendingPathComponent("codex-aarch64-apple-darwin").path,
                                       contents: Data("#!/bin/sh\necho new\n".utf8),
                                       attributes: [.posixPermissions: 0o755])
        let tgz = dir.appendingPathComponent("codex.tar.gz")
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-czf", tgz.path, "-C", src.path, "codex-aarch64-apple-darwin"]
        try tar.run(); tar.waitUntilExit()
        XCTAssertEqual(tar.terminationStatus, 0)
        for name in ["codex", "codex-rust-v0.139.0", "other"] {
            FileManager.default.createFile(atPath: install.appendingPathComponent(name).path, contents: Data("old".utf8))
        }
        let digest = SHA256.hash(data: try Data(contentsOf: tgz)).map { String(format: "%02x", $0) }.joined()
        return (dir, tgz, digest, install.appendingPathComponent("codex-rust-v0.162.1"))
    }

    /// #279: a good digest installs the binary signed in the temp dir, prunes stale pins and
    /// deletes the tarball.
    func testInstallCodexGoodDigestInstallsPrunesAndDeletesTarball() throws {
        let (dir, tgz, digest, dest) = try Self.makeCodexTarball()
        defer { try? FileManager.default.removeItem(at: dir) }
        var signed: [URL] = []
        let out = try AgentController.installCodex(tgz: tgz, sha256: digest, dest: dest,
                                                   sign: { signed.append($0); return 0 })
        XCTAssertEqual(out, dest)
        XCTAssertEqual(try String(contentsOf: dest, encoding: .utf8), "#!/bin/sh\necho new\n")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: dest.path))
        XCTAssertEqual(signed.count, 1)
        XCTAssertNotEqual(signed.first?.deletingLastPathComponent(), dest.deletingLastPathComponent(),
                          "signed at the pinned path instead of the temp dir")
        let left = try FileManager.default.contentsOfDirectory(atPath: dest.deletingLastPathComponent().path).sorted()
        XCTAssertEqual(left, ["codex-rust-v0.162.1", "other"], "stale codex pins were not pruned")
        XCTAssertFalse(FileManager.default.fileExists(atPath: tgz.path), "the tarball was left behind")
    }

    /// #279: a bad digest or a failed sign fails closed and leaves the install dir untouched.
    func testInstallCodexFailsClosedOnBadDigestOrFailedSign() throws {
        for (label, badDigest, rc) in [("bad digest", true, Int32(0)), ("failed sign", false, Int32(1))] {
            let (dir, tgz, digest, dest) = try Self.makeCodexTarball()
            defer { try? FileManager.default.removeItem(at: dir) }
            let install = dest.deletingLastPathComponent()
            let before = try FileManager.default.contentsOfDirectory(atPath: install.path).sorted()
            XCTAssertThrowsError(try AgentController.installCodex(
                tgz: tgz, sha256: badDigest ? String(repeating: "0", count: 64) : digest, dest: dest,
                sign: { _ in rc }), "\(label) did not fail closed")
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: install.path).sorted(), before,
                           "\(label) touched the install dir")
            XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path), "\(label) left a binary at the pin")
        }
    }

    /// #250: Stop during the first-use codex download abandons the run once the download
    /// lands: no model load, no codex, and the phase stays idle (QA #74 M7: without the
    /// download guard, run()'s stopped-guard settle is what idles the phase).
    @MainActor
    func testControllerStopDuringCodexDownloadStartsNoCodex() async throws {
        let (exe, home) = try makeMock()
        let (controller, _) = makeController(exe: exe, home: home, downloadDelay: 300_000_000)
        controller.submit(goal: "hello")
        let downloading = await Self.wait { if case .loadingModel = controller.phase { return true } else { return false } }
        XCTAssertTrue(downloading, "the run never reached the codex download")

        controller.stop()
        let settled = await Self.wait { controller.phase == .idle }
        XCTAssertTrue(settled, "Stop did not settle the phase")
        var leaked: [AgentController.Phase] = []
        let watch = { if controller.phase != .idle, leaked.last != controller.phase { leaked.append(controller.phase) } }
        _ = await Self.wait(1, sample: watch) { false }   // the download lands at 300 ms
        XCTAssertEqual(leaked, [], "the stopped run moved the phase after the download")
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertEqual(Self.count("initialize", exe: exe), 0, "codex was started for a stopped run")
    }

    /// #250: a prompt re-submitted during the stopped run's download keeps its phase when
    /// the stopped run's download lands and abandons it.
    @MainActor
    func testControllerAbandonedDownloadSparesTheNextRun() async throws {
        let (exe, home) = try makeMock()
        let (controller, _) = makeController(exe: exe, home: home, downloadDelay: 300_000_000)
        controller.submit(goal: "hello")
        let downloading = await Self.wait { if case .loadingModel = controller.phase { return true } else { return false } }
        XCTAssertTrue(downloading, "the run never reached the codex download")
        controller.stop()
        let settled = await Self.wait { controller.phase == .idle }
        XCTAssertTrue(settled, "Stop did not settle the phase")

        controller.submit(goal: "hello")
        var idled = false
        let loading = await Self.wait(sample: { if controller.phase == .idle { idled = true } }) {
            if case .loadingModel(_, let status) = controller.phase { return status.hasPrefix("Loading") } else { return false }
        }
        XCTAssertTrue(loading, "the re-submitted run never got past its download")
        XCTAssertFalse(idled, "the stopped run's abandoned download idled the next run")
    }

    /// #261: prompts re-submitted during stopped runs' download await that same download
    /// (single-flight, one install into the cached path), and only the last run boots
    /// codex: an older stopped run (`stoppedRun` holds only the latest Stop) abandons it.
    @MainActor
    func testControllerResubmitDuringDownloadSharesTheDownload() async throws {
        let (exe, home) = try makeMock()
        var downloads = 0
        let (controller, _) = makeController(exe: exe, home: home, downloadDelay: 300_000_000,
                                             onDownload: { downloads += 1 })
        for _ in 0..<2 {
            controller.submit(goal: "hello")
            let downloading = await Self.wait { if case .loadingModel = controller.phase { return true } else { return false } }
            XCTAssertTrue(downloading, "the run never reached the codex download")
            controller.stop()
            let settled = await Self.wait { controller.phase == .idle }
            XCTAssertTrue(settled, "Stop did not settle the phase")
        }

        controller.submit(goal: "hello")
        let started = await Self.wait { Self.count("initialize", exe: exe) == 1 }
        XCTAssertTrue(started, "the re-submitted run never started codex")
        _ = await Self.wait(0.5) { false }   // a stopped run that went on would spawn by now
        XCTAssertEqual(downloads, 1, "the re-submitted runs started more than one codex download/install")
        XCTAssertEqual(Self.count("initialize", exe: exe), 1, "a stopped run started its own codex")
    }

    /// #261: Stop during the model load / codex spawn (the harness not stored yet) leaves
    /// no codex behind: the fresh harness is never started and the phase ends idle.
    @MainActor
    func testControllerStopDuringSpawnStartsNoCodex() async throws {
        let (exe, home) = try makeMock()
        let (controller, _) = makeController(exe: exe, home: home, spawnDelay: 300_000_000)
        controller.submit(goal: "hello")
        let spawning = await Self.wait {
            if case .loadingModel(_, let status) = controller.phase { return status.hasPrefix("Loading") } else { return false }
        }
        XCTAssertTrue(spawning, "the run never reached the model load")

        controller.stop()
        let settled = await Self.wait { controller.phase == .idle }
        XCTAssertTrue(settled, "Stop did not settle the phase")
        _ = await Self.wait(1) { false }   // the spawn lands at 300 ms
        XCTAssertEqual(Self.count("initialize", exe: exe), 0, "codex was started for a stopped run")
        XCTAssertEqual(controller.phase, .idle)
    }

    /// QA #83: a stopped run whose download lands after a re-submit never sets the
    /// "Loading" phase nor starts its own model load; only the re-submitted run does.
    @MainActor
    func testControllerStoppedRunsDownloadLoadsNoModel() async throws {
        let (exe, home) = try makeMock()
        var spawns = 0
        let (controller, _) = makeController(exe: exe, home: home, downloadDelay: 300_000_000,
                                             onSpawn: { spawns += 1 })
        controller.submit(goal: "hello")
        let downloading = await Self.wait { if case .loadingModel = controller.phase { return true } else { return false } }
        XCTAssertTrue(downloading, "the run never reached the codex download")
        controller.stop()
        let settled = await Self.wait { controller.phase == .idle }
        XCTAssertTrue(settled, "Stop did not settle the phase")

        controller.submit(goal: "hello")
        let started = await Self.wait { Self.count("initialize", exe: exe) == 1 }
        XCTAssertTrue(started, "the re-submitted run never started codex")
        _ = await Self.wait(0.5) { false }
        XCTAssertEqual(spawns, 1, "the stopped run went on to load the model")
    }

    /// QA #83: Stop landing while harness.start() is in flight (the harness not stored
    /// yet) shuts the started codex down instead of leaving it running unowned.
    @MainActor
    func testControllerStopDuringStartShutsTheHarnessDown() async throws {
        let (exe, home) = try makeMock()
        var shutdowns = 0
        let (controller, _) = makeController(exe: exe, home: home, startDelay: 300_000_000,
                                             onShutdown: { shutdowns += 1 })
        controller.submit(goal: "hello")
        let handshaken = await Self.wait { Self.count("initialize", exe: exe) == 1 }
        XCTAssertTrue(handshaken, "the run never started codex")

        controller.stop()
        let shut = await Self.wait(2) { shutdowns == 1 }
        XCTAssertTrue(shut, "the harness started for a stopped run was never shut down")
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertEqual(Self.count("thread/start", exe: exe), 0, "the stopped run opened a session")
    }

    /// QA #15: Stop while turn/start is still unanswered settles at once, interrupts the
    /// turn as soon as its id arrives, and the phase never goes back to running.
    @MainActor
    func testControllerStopBeforeTurnStartReturnsInterruptsTheTurn() async throws {
        let (exe, home) = try makeMock()
        let (controller, _) = makeController(exe: exe, home: home)
        controller.submit(goal: "SLOWSTART HANG on a long command")
        let sent = await Self.wait { Self.count("turn/start", exe: exe) == 1 }
        XCTAssertTrue(sent, "turn/start never reached the mock")

        controller.stop()   // the mock holds the turn/start reply for 1 s: no turn id yet
        XCTAssertEqual(controller.phase, .idle)
        var leaked: [AgentController.Phase] = []
        let watch = { if controller.phase != .idle, leaked.last != controller.phase { leaked.append(controller.phase) } }
        let interrupted = await Self.wait(sample: watch) { Self.count("turn/interrupt", exe: exe) == 1 }
        XCTAssertTrue(interrupted, "the turn was not interrupted once turn/start returned its id")
        let params = try Self.received("turn/interrupt", exe: exe).first?["params"] as? [String: Any]
        XCTAssertEqual(params?["turnId"] as? String, "turn-1")
        _ = await Self.wait(0.5, sample: watch) { false }   // let turn/completed{interrupted} land
        XCTAssertEqual(leaked, [], "Stop did not stick")
        XCTAssertEqual(controller.phase, .idle)
        await controller.end()
    }

    /// An interrupt codex never answers settles Stop locally after the bound, and that
    /// turn's late `turn/completed` must not settle the next turn.
    @MainActor
    func testControllerStopTimeoutSettlesAndIgnoresTheLateCompletion() async throws {
        let (exe, home) = try makeMock()
        let (controller, _) = makeController(exe: exe, home: home)
        controller.submit(goal: "WEDGE on a long command")
        let started = await Self.wait { controller.items.contains { $0.id == "cmd-turn-1" } }
        XCTAssertTrue(started, "turn-1 never started")

        controller.stop()
        XCTAssertEqual(controller.phase, .running, "Stop waits for codex to acknowledge the interrupt")
        let settled = await Self.wait(5) { controller.phase == .idle }
        XCTAssertTrue(settled, "an unanswered interrupt must settle Stop after the bound")
        XCTAssertEqual(Self.count("turn/interrupt", exe: exe), 1)
        // Every settle stamps a "Finished in" note; the turn's own duplicate .turnStarted
        // would re-raise .running after a wrong settle, so the notes are the witness.
        let settles = { controller.items.filter { if case .note = $0 { return true }; return false }.count }
        XCTAssertEqual(settles(), 1)

        // The mock starts turn-2, then delivers wedged turn-1's late turn/completed.
        controller.submit(goal: "HANG next")
        let second = await Self.wait { controller.items.contains { $0.id == "cmd-turn-2" } }
        XCTAssertTrue(second, "turn-2 never started")
        XCTAssertEqual(settles(), 1, "turn-1's late completion settled turn-2")
        XCTAssertEqual(controller.phase, .running)

        controller.stop()
        let stopped = await Self.wait(5) { controller.phase == .idle }
        XCTAssertTrue(stopped)
        let last = try Self.received("turn/interrupt", exe: exe).last?["params"] as? [String: Any]
        XCTAssertEqual(last?["turnId"] as? String, "turn-2")
        await controller.end()
    }

    /// QA on #165 M4: after codex dies, the next prompt resumes the same thread with the
    /// user's current Permissions (thread/resume mode + policy, turn/start sandboxPolicy).
    @MainActor
    func testControllerResumesTheThreadWithTheUsersSettings() async throws {
        let (exe, home) = try makeMock()
        let saved = (Preferences.agentBypassAll, Preferences.agentApprovalPolicy, Preferences.agentNetworkAccess)
        defer {
            Preferences.agentBypassAll = saved.0
            Preferences.agentApprovalPolicy = saved.1
            Preferences.agentNetworkAccess = saved.2
        }
        Preferences.agentBypassAll = false
        Preferences.agentApprovalPolicy = "untrusted"
        Preferences.agentNetworkAccess = true

        let (controller, store) = makeController(exe: exe, home: home)
        controller.submit(goal: "EXIT0 mid-turn")
        // `harnessEnded` saves the transcript right after dropping the dead harness.
        var resumable = false
        let deadline = Date().addingTimeInterval(10)
        while !resumable, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
            resumable = !(await store.loadTranscript(id: "thread-1")).isEmpty
        }
        XCTAssertTrue(resumable, "codex exit was not handled")
        guard case .error = controller.phase else { return XCTFail("expected an error, got \(controller.phase)") }

        controller.submit(goal: "say hello")
        let done = await Self.wait { Self.count("thread/resume", exe: exe) == 1 && controller.phase == .idle }
        XCTAssertTrue(done, "the follow-up did not resume and finish (phase \(controller.phase), items \(controller.items))")
        await controller.end()

        XCTAssertEqual(Self.count("thread/start", exe: exe), 1, "the follow-up opened a fresh thread")
        let resume = try XCTUnwrap(Self.received("thread/resume", exe: exe).first?["params"] as? [String: Any])
        XCTAssertEqual(resume["threadId"] as? String, "thread-1")
        XCTAssertEqual(resume["approvalPolicy"] as? String, "untrusted")
        XCTAssertEqual(resume["sandbox"] as? String, "workspace-write")
        let turn = try XCTUnwrap(Self.received("turn/start", exe: exe).last?["params"] as? [String: Any])
        let policy = try XCTUnwrap(turn["sandboxPolicy"] as? [String: Any])
        XCTAssertEqual(policy["type"] as? String, "workspaceWrite")
        XCTAssertEqual(policy["networkAccess"] as? Bool, true)
        XCTAssertEqual((policy["writableRoots"] as? [String])?.first, controller.workingDirectory)
    }

    /// Arms the mock's EXITON mode: it exits (code 0) on the next `method` request, unanswered.
    private static func exitOn(_ method: String, exe: URL) throws {
        try method.write(to: exe.deletingLastPathComponent().appendingPathComponent("exit-on"),
                         atomically: true, encoding: .utf8)
    }

    @MainActor
    private static func errorRows(_ controller: AgentController) -> [String] {
        controller.items.compactMap { if case .error(_, let m) = $0 { return m }; return nil }
    }

    /// `harnessEnded` ran: it saves the transcript right after dropping the dead harness.
    private static func harnessEnded(_ store: AgentSessionStore) async -> Bool {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if !(await store.loadTranscript(id: "thread-1")).isEmpty { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return false
    }

    private static let died = "Agent error: codex app-server exited with code 0"

    /// A turn ran to completion ("Finished in" note).
    @MainActor
    private static func finishedTurn(_ controller: AgentController) -> Bool {
        controller.items.contains { if case .note = $0 { return true }; return false }
    }

    /// QA A/B on #167: codex dying while it handles thread/resume shows one error row (not
    /// a second "not running" one) and keeps the thread armed: the next prompt resumes
    /// thread-1 instead of opening a fresh thread.
    @MainActor
    func testControllerCodexDeathDuringResumeKeepsTheThread() async throws {
        let (exe, home) = try makeMock()
        let (controller, store) = makeController(exe: exe, home: home)
        controller.submit(goal: "EXIT0 mid-turn")
        let ended = await Self.harnessEnded(store)
        XCTAssertTrue(ended, "codex exit was not handled")
        XCTAssertEqual(Self.errorRows(controller), [Self.died])

        try Self.exitOn("thread/resume", exe: exe)
        controller.submit(goal: "say hello")
        let failed = await Self.wait { Self.count("thread/resume", exe: exe) == 1 && controller.phase == .error(Self.died) }
        XCTAssertTrue(failed, "the death during thread/resume was not surfaced (phase \(controller.phase))")
        _ = await Self.wait(0.5) { false }   // let the failed request's error land too
        XCTAssertEqual(Self.errorRows(controller), [Self.died, Self.died], "one row per death")

        controller.submit(goal: "say hello again")
        let done = await Self.wait { Self.finishedTurn(controller) }
        XCTAssertTrue(done, "the follow-up did not finish (phase \(controller.phase), items \(controller.items))")
        await controller.end()
        XCTAssertEqual(Self.count("thread/start", exe: exe), 1, "the thread was lost: the follow-up opened a fresh one")
        let resumed = try Self.received("thread/resume", exe: exe).map { ($0["params"] as? [String: Any])?["threadId"] as? String }
        XCTAssertEqual(resumed, ["thread-1", "thread-1"])
        XCTAssertEqual(Self.errorRows(controller), [Self.died, Self.died])
    }

    /// QA M3 on #167: when codex exits on its own, `harnessEnded` drops the dead harness,
    /// so the next prompt spawns a fresh codex instead of failing on the dead one.
    @MainActor
    func testHarnessEndedDropsTheHarness() async throws {
        let (exe, home) = try makeMock()
        let (controller, store) = makeController(exe: exe, home: home)
        controller.submit(goal: "EXIT0 mid-turn")
        let ended = await Self.harnessEnded(store)
        XCTAssertTrue(ended, "codex exit was not handled")
        XCTAssertEqual(Self.count("initialize", exe: exe), 1)

        controller.submit(goal: "say hello")
        let done = await Self.wait { Self.finishedTurn(controller) }
        XCTAssertTrue(done, "the follow-up did not run (phase \(controller.phase), items \(controller.items))")
        await controller.end()
        XCTAssertEqual(Self.count("initialize", exe: exe), 2, "the follow-up did not spawn a fresh codex")
        XCTAssertEqual(Self.errorRows(controller), [Self.died])
    }

    /// QA M4 on #167: codex dying with turn/start in flight reaches the controller twice,
    /// as the `.error` event and as the request's error, with the same text: one row.
    @MainActor
    func testSurfaceErrorDedupes() async throws {
        let (exe, home) = try makeMock()
        let (controller, _) = makeController(exe: exe, home: home)
        try Self.exitOn("turn/start", exe: exe)
        controller.submit(goal: "say hello")
        let failed = await Self.wait { controller.phase == .error(Self.died) }
        XCTAssertTrue(failed, "the death during turn/start was not surfaced (phase \(controller.phase))")
        _ = await Self.wait(0.5) { false }   // both reports of the death have landed
        XCTAssertEqual(Self.errorRows(controller), [Self.died])
        await controller.end()
    }

    /// QA on cc8e35e: a thread codex no longer has (thread/resume errors, codex alive) falls
    /// back to a fresh thread and disarms the resume, so once that session ends the next
    /// prompt opens a fresh thread instead of trying the gone one again.
    @MainActor
    func testControllerResumeFallbackDisarmsTheResume() async throws {
        let (exe, home) = try makeMock()
        let (controller, store) = makeController(exe: exe, home: home)
        controller.submit(goal: "EXIT0 mid-turn")   // codex dies: the next prompt resumes thread-1
        let ended = await Self.harnessEnded(store)
        XCTAssertTrue(ended, "codex exit was not handled")

        try "thread/resume".write(to: exe.deletingLastPathComponent().appendingPathComponent("error-on"),
                                  atomically: true, encoding: .utf8)
        controller.submit(goal: "FAST hello")
        let done = await Self.wait { Self.notes(controller) == 1 && controller.phase == .idle }
        XCTAssertTrue(done, "the follow-up did not finish (phase \(controller.phase), items \(controller.items))")
        XCTAssertEqual(Self.count("thread/resume", exe: exe), 1)
        XCTAssertEqual(Self.count("thread/start", exe: exe), 2, "the failed resume did not fall back to a fresh thread")

        await controller.end()
        XCTAssertNil(controller.currentSessionID, "the fallback left the resume armed")
        controller.submit(goal: "FAST again")
        let again = await Self.wait { Self.notes(controller) == 2 && controller.phase == .idle }
        XCTAssertTrue(again, "the next prompt did not finish (phase \(controller.phase))")
        XCTAssertEqual(Self.count("thread/resume", exe: exe), 1, "the next prompt tried the gone thread again")
        XCTAssertEqual(Self.count("thread/start", exe: exe), 3)
        await controller.end()
    }

    @MainActor
    private static func notes(_ controller: AgentController) -> Int {
        controller.items.filter { if case .note = $0 { return true }; return false }.count
    }

    /// QA on #222 (1): a turn that completes before turn/start returns its id stays settled.
    /// CodexHarness's own late `.turnStarted` must not put the chat back on Working, and
    /// run() must not revive the finished turn's id: the next Stop that races turn/start
    /// settles at once instead of interrupting the dead turn.
    @MainActor
    func testControllerFastTurnStaysSettled() async throws {
        let (exe, home) = try makeMock()
        // turn/start's reply reaches run() only after the pump settled the turn (100 ms).
        let (controller, _) = makeController(exe: exe, home: home, promptReturnDelay: 100_000_000)
        controller.submit(goal: "FAST hello")
        let finished = await Self.wait { Self.finishedTurn(controller) }
        XCTAssertTrue(finished, "the fast turn never completed")
        var leaked: [AgentController.Phase] = []
        let watch = { if controller.phase != .idle, leaked.last != controller.phase { leaked.append(controller.phase) } }
        _ = await Self.wait(0.3, sample: watch) { false }
        XCTAssertEqual(leaked, [], "the finished turn's late .turnStarted re-raised the phase")
        XCTAssertEqual(controller.phase, .idle)

        controller.submit(goal: "SLOWSTART HANG on a long command")
        let sent = await Self.wait { Self.count("turn/start", exe: exe) == 2 }
        XCTAssertTrue(sent, "the second turn/start never reached the mock")
        controller.stop()
        XCTAssertEqual(controller.phase, .idle, "Stop took the finished turn-1 for the live one")
        let interrupted = await Self.wait { Self.count("turn/interrupt", exe: exe) >= 1 }
        XCTAssertTrue(interrupted)
        let ids = try Self.received("turn/interrupt", exe: exe).map { ($0["params"] as? [String: Any])?["turnId"] as? String }
        XCTAssertEqual(ids, ["turn-2"])
        await controller.end()
    }

    /// CHANGELOG on #222: a Stop does not hide an error the backend already reported (a
    /// Stop click landing just after the turn failed keeps the failure on screen).
    @MainActor
    func testControllerStopKeepsTheBackendsError() async throws {
        let (exe, home) = try makeMock()
        let (controller, _) = makeController(exe: exe, home: home)
        controller.submit(goal: "FAST FAIL")
        let failed = await Self.wait { controller.phase == .error("mock turn failed") }
        XCTAssertTrue(failed, "the failed turn was not surfaced (phase \(controller.phase))")
        _ = await Self.wait(0.3) { false }   // run() is past turn/start

        controller.stop()
        XCTAssertEqual(controller.phase, .error("mock turn failed"), "Stop hid the error")
        _ = await Self.wait(0.3) { false }
        XCTAssertEqual(controller.phase, .error("mock turn failed"))
        await controller.end()
    }

    /// run()'s raced `settledTurns.insert`: a turn whose turn/start a Stop raced keeps its
    /// late completion away from the run the user starts next.
    @MainActor
    func testControllerStoppedTurnsLateCompletionSparesTheNextRun() async throws {
        let (exe, home) = try makeMock()
        let (controller, _) = makeController(exe: exe, home: home)
        controller.submit(goal: "SLOWSTART WEDGE on a long command")
        let sent = await Self.wait { Self.count("turn/start", exe: exe) == 1 }
        XCTAssertTrue(sent, "turn/start never reached the mock")
        controller.stop()   // no turn id yet: settles now
        XCTAssertEqual(controller.phase, .idle)
        // run() interrupts turn-1 once its id arrives; the wedged mock never answers.
        let interrupted = await Self.wait { Self.count("turn/interrupt", exe: exe) == 1 }
        XCTAssertTrue(interrupted, "turn-1 was not interrupted once turn/start returned")
        XCTAssertEqual(Self.notes(controller), 1)

        // The mock starts turn-2, then delivers turn-1's late turn/completed{interrupted}.
        controller.submit(goal: "HANG next")
        let second = await Self.wait { controller.items.contains { $0.id == "cmd-turn-2" } }
        XCTAssertTrue(second, "turn-2 never started")
        _ = await Self.wait(0.2) { false }
        XCTAssertEqual(Self.notes(controller), 1, "turn-1's late completion settled turn-2")
        XCTAssertEqual(controller.phase, .running)

        controller.stop()
        let stopped = await Self.wait(5) { controller.phase == .idle }
        XCTAssertTrue(stopped)
        await controller.end()
    }

    /// The mock numbers turns per process like a fresh codex would restart them: end() and
    /// a config respawn forget the settled ids, so the next codex's turn-1 still settles.
    @MainActor
    func testControllerForgetsSettledTurnsOnEndAndRespawn() async throws {
        let (exe, home) = try makeMock()
        let (controller, _) = makeController(exe: exe, home: home)
        controller.submit(goal: "FAST one")
        let first = await Self.wait { Self.notes(controller) == 1 && controller.phase == .idle }
        XCTAssertTrue(first, "turn one did not finish (phase \(controller.phase))")

        await controller.end()
        controller.submit(goal: "FAST two")
        let second = await Self.wait(5) { Self.notes(controller) == 2 && controller.phase == .idle }
        XCTAssertTrue(second, "after end() the new codex's turn-1 was taken for the old one (phase \(controller.phase))")
        XCTAssertEqual(Self.count("initialize", exe: exe), 2)

        controller.applyAgentConfigChange()   // idle: respawns on a Task
        _ = await Self.wait(0.3) { false }
        controller.submit(goal: "FAST three")
        let third = await Self.wait(5) { Self.notes(controller) == 3 && controller.phase == .idle }
        XCTAssertTrue(third, "after a respawn the new codex's turn-1 was taken for the old one (phase \(controller.phase))")
        XCTAssertEqual(Self.count("initialize", exe: exe), 3)
        await controller.end()
    }

    // MARK: - Approval reply shapes (codex 0.162 schema; the mock fails the turn on a bad reply)

    /// The client's reply to the mock's "srv-1" server request, as codex received it.
    private static func reply(exe: URL) throws -> [String: Any]? {
        let log = exe.deletingLastPathComponent().appendingPathComponent("received.jsonl")
        return try String(contentsOf: log, encoding: .utf8)
            .split(separator: "\n")
            .compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
            .first { $0["method"] == nil && $0["id"] as? String == "srv-1" }
    }

    /// Submits `goal`, answers the approval the controller shows with `decision` (nil:
    /// expects none), and returns that approval plus the reply codex got. The turn must
    /// finish cleanly: the mock fails it when the reply isn't in the method's shape.
    @MainActor
    private func answer(_ goal: String, with decision: ApprovalDecision?) async throws
        -> (approval: ApprovalRequest?, reply: [String: Any]?) {
        let (exe, home) = try makeMock()
        let (controller, _) = makeController(exe: exe, home: home)
        controller.submit(goal: goal)
        var approval: ApprovalRequest?
        if let decision {
            let asked = await Self.wait { !controller.pendingApprovals.isEmpty }
            XCTAssertTrue(asked, "no approval reached the controller (phase \(controller.phase))")
            approval = controller.pendingApprovals.first
            if let approval { controller.respond(to: approval, decision: decision) }
        }
        let failed = { if case .error = controller.phase { return true }; return false }
        let ended = await Self.wait { Self.finishedTurn(controller) || failed() }
        XCTAssertTrue(ended, "the turn never finished (phase \(controller.phase))")
        XCTAssertEqual(controller.phase, .idle, "codex rejected the reply")
        XCTAssertTrue(controller.pendingApprovals.isEmpty)
        let reply = try Self.reply(exe: exe)
        await controller.end()
        return (approval, reply)
    }

    /// W7: `PermissionsRequestApprovalResponse {permissions, scope}` — no `decision`; a
    /// grant echoes the requested profile, "Always" is the session scope, Deny grants nothing.
    /// #266: the card shows that profile (roots, network) before "Always" is tapped.
    @MainActor
    func testControllerPermissionsReplyIsPermissionsAndScope() async throws {
        let requested: [String: Any] = ["network": ["enabled": true], "fileSystem": [
            "read": ["/etc"], "write": ["/tmp/out"],
            "entries": [["access": "write", "path": ["type": "special", "value": ["kind": "tmpdir"]]],
                        ["access": "write", "path": ["type": "special", "value": ["kind": "root"]]],
                        ["access": "write", "path": ["type": "special", "value": ["kind": "unknown", "path": "/odd", "subpath": "x"]]]]]]
        let granted = try await answer("PERMS please", with: .acceptForSession)
        XCTAssertEqual(granted.approval?.kind, .permission)
        XCTAssertEqual(granted.approval?.summary, "needs network")
        XCTAssertEqual(granted.approval?.detail, "Read: /etc\nWrite: /tmp/out, the temp dir, the whole disk, /odd/x\nNetwork: enabled\nIn: /tmp")
        XCTAssertEqual(granted.reply?["result"] as? NSDictionary,
                       ["permissions": requested, "scope": "session"] as NSDictionary)
        let once = try await answer("PERMS please", with: .accept)
        XCTAssertEqual(once.reply?["result"] as? NSDictionary,
                       ["permissions": requested, "scope": "turn"] as NSDictionary)
        let denied = try await answer("PERMS please", with: .decline)
        XCTAssertEqual(denied.reply?["result"] as? NSDictionary,
                       ["permissions": [String: Any](), "scope": "turn"] as NSDictionary)
    }

    /// W10: file-change approval params carry only `itemId`; the card's paths and diff come
    /// from the `fileChange` item announced in `item/started`.
    @MainActor
    func testControllerFileChangeApprovalShowsTheItemsDiff() async throws {
        let (approval, reply) = try await answer("PATCH please", with: .accept)
        XCTAssertEqual(approval?.kind, .fileChange)
        XCTAssertEqual(approval?.summary, "Apply changes to /tmp/a.txt")
        XCTAssertEqual(approval?.detail, "/tmp/a.txt\n@@ -1 +1 @@\n-old\n+new\n")
        XCTAssertEqual(reply?["result"] as? NSDictionary, ["decision": "accept"] as NSDictionary)
    }

    /// #266: legacy `applyPatchApproval` lists its `fileChanges` keys, sorted, each on one
    /// line (an embedded newline must not forge a summary line), and gets a `ReviewDecision`.
    @MainActor
    func testControllerLegacyPatchApprovalShowsOneLinePaths() async throws {
        let (approval, reply) = try await answer("LEGACY please", with: .accept)
        XCTAssertEqual(approval?.kind, .fileChange)
        XCTAssertEqual(approval?.summary, "Apply changes to /tmp/a.txt\\nApply changes to /etc/passwd, /tmp/b.txt")
        XCTAssertEqual(approval?.detail, "/tmp/a.txt\\nApply changes to /etc/passwd\n\n/tmp/b.txt\n")
        XCTAssertEqual(reply?["result"] as? NSDictionary, ["decision": "approved"] as NSDictionary)
    }

    /// W12: the amendment is `CommandExecutionApprovalDecision`'s object variant, not "accept".
    @MainActor
    func testControllerAmendmentReplyIsTheExecpolicyObject() async throws {
        let (approval, reply) = try await answer("AMEND please", with: .acceptWithAmendment(["rm", "-rf"]))
        XCTAssertEqual(approval?.kind, .command)
        XCTAssertEqual(reply?["result"] as? NSDictionary,
                       ["decision": ["acceptWithExecpolicyAmendment": ["execpolicy_amendment": ["rm", "-rf"]]]]
                       as NSDictionary)
    }

    /// An empty amendment prefix must fall through to a plain accept, never an empty amendment.
    @MainActor
    func testControllerEmptyAmendmentIsPlainAccept() async throws {
        let (_, reply) = try await answer("AMEND please", with: .acceptWithAmendment([]))
        XCTAssertEqual(reply?["result"] as? NSDictionary, ["decision": "accept"] as NSDictionary)
    }

    /// W8: a server request the client doesn't serve (MCP elicitation) gets a JSON-RPC
    /// "method not found" error, not a made-up `{decision}` result; no approval is shown.
    @MainActor
    func testControllerUnservedServerRequestGetsMethodNotFound() async throws {
        let (_, reply) = try await answer("ELICIT please", with: nil)
        XCTAssertNil(reply?["result"])
        let error = reply?["error"] as? [String: Any]
        XCTAssertEqual(error?["code"] as? Int, -32601)
        XCTAssertEqual(Set(error?.keys.map { $0 } ?? []), ["code", "message"])
    }

    /// Fake Responses endpoint for the real-codex test, plus a stand-in for the Bun plugin
    /// host's unix socket. First model call answers with one shell tool call (whichever
    /// shell tool codex offered), the follow-up with a final message. The socket writes
    /// `bridge.marker` with the hook event it received and replies an empty decision,
    /// like `plugin-host.js`. argv: <dir> <shell command>; writes <dir>/port once listening.
    private static let fakeResponsesServer = #"""
    import json, os, socket, sys, threading
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

    DIR = sys.argv[1]
    CMD = sys.argv[2]

    def bridge():
        path = os.path.join(DIR, "b.sock")
        srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        srv.bind(path)
        srv.listen(8)
        while True:
            conn, _ = srv.accept()
            data = b""
            while True:
                chunk = conn.recv(65536)
                if not chunk:
                    break
                data += chunk
                try:
                    evt = json.loads(data)
                    break
                except Exception:
                    continue
            with open(os.path.join(DIR, "bridge.marker"), "a") as f:
                f.write(data.decode("utf-8", "replace") + "\n")
            conn.sendall(b"{}\n")
            conn.close()

    def sse(kind, body):
        body["type"] = kind
        return ("event: %s\ndata: %s\n\n" % (kind, json.dumps(body))).encode()

    class H(BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def do_GET(self):
            out = json.dumps({"object": "list", "data": [], "models": []}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(out)))
            self.end_headers()
            self.wfile.write(out)

        def do_POST(self):
            req = json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))) or b"{}")
            with open(os.path.join(DIR, "requests.jsonl"), "a") as f:
                f.write(json.dumps({"path": self.path, "tools": [t.get("name") for t in req.get("tools", [])]}) + "\n")
            done = any(i.get("type") == "function_call_output" for i in req.get("input", []))
            names = [t.get("name") for t in req.get("tools", [])]
            if done:
                item = {"type": "message", "id": "msg_2", "role": "assistant", "status": "completed",
                        "content": [{"type": "output_text", "text": "done", "annotations": []}]}
            else:
                if "exec_command" in names:
                    name, args = "exec_command", {"cmd": CMD}
                elif "shell_command" in names:
                    name, args = "shell_command", {"command": CMD}
                else:
                    name, args = "shell", {"command": ["/bin/sh", "-c", CMD]}
                item = {"type": "function_call", "id": "fc_1", "call_id": "call_1", "name": name,
                        "arguments": json.dumps(args), "status": "completed"}
            rid = "resp_2" if done else "resp_1"
            usage = {"input_tokens": 10, "output_tokens": 5, "total_tokens": 15}
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.end_headers()
            self.wfile.write(sse("response.created", {"response": {"id": rid, "status": "in_progress", "output": []}}))
            self.wfile.write(sse("response.output_item.added", {"output_index": 0, "item": item}))
            self.wfile.write(sse("response.output_item.done", {"output_index": 0, "item": item}))
            self.wfile.write(sse("response.completed", {"response": {"id": rid, "status": "completed",
                                                                    "output": [item], "usage": usage}}))
            self.wfile.flush()
            self.close_connection = True

    threading.Thread(target=bridge, daemon=True).start()
    httpd = ThreadingHTTPServer(("127.0.0.1", 0), H)
    with open(os.path.join(DIR, "port.tmp"), "w") as f:
        f.write(str(httpd.server_address[1]))
    os.rename(os.path.join(DIR, "port.tmp"), os.path.join(DIR, "port"))
    httpd.serve_forever()
    """#

    /// Opt-in (#165/#166): the real codex app-server runs a Prosper-configured `PreToolUse`
    /// hook and a bridge-shaped hook (`exec nc -U <socket>`, what `BunHarness.bridgeCommand`
    /// renders) on a tool call, and the sandboxed command may write to a Permissions
    /// allowlist root outside the working directory (a root outside the temp dirs, which
    /// codex's workspace-write sandbox allows anyway). Skipped unless
    /// `PROSPER_REAL_CODEX_BIN` names a codex binary. No network: inference is a local
    /// fake Responses endpoint.
    func testRealCodexRunsPreToolUseHooks() async throws {
        guard let bin = ProcessInfo.processInfo.environment["PROSPER_REAL_CODEX_BIN"], !bin.isEmpty else {
            throw XCTSkip("set PROSPER_REAL_CODEX_BIN to a codex binary to run against real codex")
        }
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("prc-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = dir.appendingPathComponent("fake_responses.py")
        try Self.fakeResponsesServer.write(to: script, atomically: true, encoding: .utf8)
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        let extraRoot = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask,
                                                    appropriateFor: nil, create: true)
            .appendingPathComponent("prosper-sandbox-test-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: extraRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: extraRoot) }
        let written = extraRoot.appendingPathComponent("sandbox.marker")
        server.arguments = [script.path, dir.path, "touch \(MCPServer.q(written.path))"]
        try server.run()
        defer { server.terminate() }
        let portFile = dir.appendingPathComponent("port")
        let deadline = Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(atPath: portFile.path), Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let port = try String(contentsOf: portFile, encoding: .utf8)

        let marker = dir.appendingPathComponent("hook.marker")
        let savedHooks = Preferences.hooks
        Preferences.hooks = [
            HookRule(event: .preToolUse, command: "touch \(MCPServer.q(marker.path))"),
            HookRule(event: .preToolUse, command: "exec nc -U \(MCPServer.q(dir.appendingPathComponent("b.sock").path))"),
        ]
        defer { Preferences.hooks = savedHooks }
        let savedRoots = Preferences.agentWritableRoots
        Preferences.agentWritableRoots = [extraRoot.path]
        defer { Preferences.agentWritableRoots = savedRoots }

        let work = dir.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let harness = CodexHarness(executableURL: URL(fileURLWithPath: bin),
                                   codexHome: dir.appendingPathComponent("home", isDirectory: true),
                                   llmBaseURL: "http://127.0.0.1:\(port)/v1", llmToken: "test-token")
        try await harness.start()
        let session = try await harness.newSession(SessionOptions(
            cwd: work.path, model: "test-model",
            approvalPolicy: .never, sandbox: .workspaceWrite(networkAccess: false)))
        async let eventsTask = Self.collect(from: harness, timeout: 60) {
            if case .turnCompleted = $0 { return true }; return false
        }
        try await harness.sendPrompt(session: session, input: [.text("run echo")])
        let events = await eventsTask
        await harness.shutdown()

        let ranTool = events.contains { if case .toolCallStarted = $0 { return true }; return false }
        XCTAssertTrue(ranTool, "codex never called the tool; events: \(events)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path),
                      "PreToolUse hook did not run (hook trust?); events: \(events)")
        let bridged = (try? String(contentsOf: dir.appendingPathComponent("bridge.marker"), encoding: .utf8)) ?? ""
        XCTAssertTrue(bridged.contains("PreToolUse"), "bridge hook did not reach the socket: \(bridged)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: written.path),
                      "sandbox blocked a write to the allowlisted root; events: \(events)")
    }

    /// The local provider fails a dropped/stalled stream fast instead of codex's
    /// default 5 reconnects and 300 s idle wait.
    func testConfigWritesProviderStreamKnobs() async throws {
        let (exe, home) = try makeMock()
        let harness = CodexHarness(executableURL: exe, codexHome: home,
                                   llmBaseURL: "http://127.0.0.1:0/v1", llmToken: "test-token")
        try await harness.start()
        await harness.shutdown()

        let toml = try String(contentsOf: home.appendingPathComponent("config.toml"), encoding: .utf8)
        guard let start = toml.range(of: "[model_providers.prosper]") else {
            return XCTFail("no [model_providers.prosper] table in:\n\(toml)")
        }
        // The provider table runs until the next table header.
        let rest = toml[start.upperBound...]
        let table = rest[..<(rest.range(of: "\n[")?.lowerBound ?? rest.endIndex)]
        let lines = table.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        XCTAssertTrue(lines.contains("stream_max_retries = 0"), "\(table)")
        XCTAssertTrue(lines.contains("request_max_retries = 1"), "\(table)")
        XCTAssertTrue(lines.contains("stream_idle_timeout_ms = 120000"), "\(table)")
    }
}
