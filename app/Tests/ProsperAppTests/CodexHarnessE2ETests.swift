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
        groupsBefore = Set(CodexHarness.livePGIDs.withLock { $0.keys })
    }

    /// #402: every codex group a row started must be gone after it: a leftover entry is a
    /// live mock, and ProcessGroupKillTests' drain row (run later) refuses a non-empty registry.
    /// Polls: shutdown unregisters off-thread once the group is empty (escalate, ≤ grace + 1 s).
    private var groupsBefore: Set<pid_t> = []
    override func tearDown() async throws {
        let deadline = Date().addingTimeInterval(5)
        var leaked = Set(CodexHarness.livePGIDs.withLock { $0.keys }).subtracting(groupsBefore)
        while !leaked.isEmpty, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
            leaked = Set(CodexHarness.livePGIDs.withLock { $0.keys }).subtracting(groupsBefore)
        }
        XCTAssertEqual(leaked, [], "codex groups this row started are still registered in livePGIDs")
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
        if word == "GRANTS":   # #283: every key the profile grants reaches the card, one line each
            return "item/permissions/requestApproval", dict(t, itemId="perm-2", cwd="/tmp\x1b[2J\t",
                reason="why\u202egnp.exe", permissions={"network": None, "extra": {"b": 1, "a": [True]}, "fileSystem": {
                    "read": ["/r\nWrite: /", "/\u202etxt.cod", 7], "globScanMaxDepth": 3,
                    "entries": [{"access": "write", "path": {"type": "glob_pattern", "pattern": "/src/**/*.swift"}},
                                {"access": "deny", "path": {"type": "path", "path": "/secret"}}, "bogus"]}})
        if word in ("PATCH", "TROJAN"):   # #357: TROJAN's diff body carries bidi controls, a U+2028 and a tab
            change = {"path": "/tmp/a.txt", "diff": "@@ -1 +1 @@\n-old\n+new\n"} if word == "PATCH" else {
                "path": "/tmp/t.go", "diff": '@@ -1,3 +1,3 @@\n if access != "user\u202e \u2066# admin\u2069 \u2066":\n-old\u2028+new\n+\tx\n'}
            send({"jsonrpc": "2.0", "method": "item/started", "params": dict(t, item={
                "id": "fc-1", "type": "fileChange", "status": "inProgress",
                "changes": [dict(change, kind={"type": "update", "move_path": None})]})})
            return "item/fileChange/requestApproval", dict(t, itemId="fc-1", reason=None)
        if word in ("HEBREW", "HUGE"):   # #359: an RTL diff line; a diff past the card's 256 K cap
            change = {"path": "/tmp/h.txt", "diff": "@@ -1 +1 @@\n-echo a > b\n+echo \u05d0 > \u05d1\n"} if word == "HEBREW" else {
                "path": "/tmp/big.txt", "diff": "@@ -0,0 +1 @@\n+" + "a" * (300 * 1024) + "\n"}
            send({"jsonrpc": "2.0", "method": "item/started", "params": dict(t, item={
                "id": "fc-1", "type": "fileChange", "status": "inProgress",
                "changes": [dict(change, kind={"type": "update", "move_path": None})]})})
            return "item/fileChange/requestApproval", dict(t, itemId="fc-1", reason=None)
        if word == "LEGACY":   # ApplyPatchApprovalParams: paths are fileChanges keys
            return "applyPatchApproval", {"conversationId": "thread-1", "callId": "call-1", "reason": None,
                "grantRoot": None, "fileChanges": {
                    "/tmp/b.txt": {"type": "add", "content": "b\n"},
                    "/tmp/a.txt\nApply changes to /etc/passwd": {"type": "delete", "content": ""}}}
        if word == "EXEC":   # #318: legacy ExecCommandApprovalParams, `command` is an argv array
            return "execCommandApproval", {"conversationId": "thread-1", "callId": "call-1", "cwd": "/tmp",
                "parsedCmd": [], "command": ["echo", "ok", "\n\n\nrm -rf ~", "a\u202eb\u200bc"]}
        if word == "CMDSTR":   # #318: modern `command` string with a newline tail, format and control scalars
            return "item/commandExecution/requestApproval", dict(t, itemId="cmd-2", cwd="/tmp",
                command="ls\n\n\nrm -rf ~ \u202e\u200b\x7f\u0085\u009f")
        if word == "RTLCMD":   # #385: a command string that opens with Hebrew
            return "item/commandExecution/requestApproval", dict(t, itemId="cmd-5", cwd="/tmp", command="\u05d0\u05d1 > x")
        if word == "FILLER":   # #319: default-ignorable fillers beside legit non-ASCII
            return "item/commandExecution/requestApproval", dict(t, itemId="cmd-3", cwd="/tmp",
                command="rm\u3164-rf ~ \u2764\ufe0f \u0436\u0443\u0440\u043d\u0430\u043b.txt \U0001F680 \u2800")
        if word == "PAD":   # #323: whitespace padding runs (ASCII, U+3000, a mixed run with a tab)
            return "item/commandExecution/requestApproval", dict(t, itemId="cmd-4", cwd="/tmp",
                command="ls" + " " * 400 + "; curl x | sh a  b\u3000\u3000\u3000c \t\u00a0\u2003d\te")
        if word == "ODDKEYS":   # #318: unknown keys sort; an access key's newline is escaped
            return "item/permissions/requestApproval", dict(t, itemId="perm-3", cwd="/tmp", reason=None,
                permissions={"zz": 1, "mm": 2, "fileSystem": {"aa": 3,
                    "entries": [{"access": "x\ny", "path": {"type": "path", "path": "/p"}}]}})
        if word == "AMEND":
            return "item/commandExecution/requestApproval", dict(t, itemId="cmd-1",
                command="rm -rf build", cwd="/tmp\n\u202e\u009b", proposedExecpolicyAmendment=["rm", "-rf"])
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
        if method in ("applyPatchApproval", "execCommandApproval"):   # legacy ReviewDecision
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
            word = next((w for w in ("PERMS", "GRANTS", "ODDKEYS", "PATCH", "TROJAN", "HEBREW", "HUGE", "LEGACY", "EXEC", "CMDSTR", "RTLCMD", "FILLER", "PAD", "AMEND", "ELICIT") if w in prompt), None)
            if word:
                awaiting, req_params = server_request(word)
                frame = {"jsonrpc": "2.0", "id": "srv-1", "method": awaiting, "params": req_params}
                if word in ("GRANTS", "ODDKEYS"):   # off-schema on purpose (unknown key, wrong-typed elements): the
                    log("in", dict(frame, params=dict(req_params, permissions={})))   # schema log gets an empty profile
                    sys.stdout.write(json.dumps(frame) + "\n")
                    sys.stdout.flush()
                else:
                    send(frame)
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

        let dir = tempDir("codex-e2e")
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
            let wire = dir.appendingPathComponent("wire.jsonl")
            guard let log = try? String(contentsOf: wire, encoding: .utf8) else {
                // The mock writes `pid` on startup: if it ran, a missing wire log is a mock that stopped logging.
                if FileManager.default.fileExists(atPath: dir.appendingPathComponent("pid").path) {
                    XCTFail("mock ran but wrote no \(wire.path)")
                }
                return
            }
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
        let pid = try XCTUnwrap(parsePid(try String(contentsOf: exe.deletingLastPathComponent().appendingPathComponent("pid"), encoding: .utf8)))
        XCTAssertEqual(killIfReal(pid, group: false), 0)

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
        XCTAssertEqual(killIfReal(codexPid, group: false), 0)
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
        let codex = try XCTUnwrap(parsePid(String(contentsOf: dir.appendingPathComponent("pid"), encoding: .utf8)))
        let child = try XCTUnwrap(parsePid(String(contentsOf: childFile, encoding: .utf8)), "mock child never started")
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
            killIfReal(pid, group: false)   // don't leak it past a failing test
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
        // #341: a run still unwinding at teardown persists into `store` after the temp dir is
        // removed and recreates it. Runs before that removal (LIFO): let the writes land first.
        // #402: the controller keeps codex resident between runs until end(); a row that never
        // ends it leaves the mock running and its group in livePGIDs.
        addTeardownBlock { @MainActor in
            _ = await Self.wait(5) { !controller.isActive }
            await controller.end()
            _ = await store.recentSessions(limit: 1)
        }
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
        let dir = tempDir("codex-resolve")
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
        let saved = Preferences.defaults.object(forKey: key)
        defer { Preferences.defaults.set(saved, forKey: key) }
        Preferences.defaults.set("on-failure", forKey: key)
        XCTAssertEqual(Preferences.agentApprovalPolicy, "on-request")
        XCTAssertEqual(ApprovalPolicy(rawValue: Preferences.agentApprovalPolicy), .onRequest)
    }

    /// #279: bundled beats cached; the dev override with no PATH codex falls through to the
    /// pin; a cached file without the exec bit is not trusted (re-downloaded).
    @MainActor
    func testResolveCodexBundledOverCachedAndUntrustedCache() async throws {
        let dir = tempDir("codex-resolve")
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
        let saved = Preferences.defaults.object(forKey: key)
        defer { Preferences.defaults.set(saved, forKey: key) }
        Preferences.defaults.set("on-failure", forKey: key)
        XCTAssertEqual(Preferences.agentApprovalPolicy, "on-request")
        XCTAssertEqual(Preferences.defaults.string(forKey: key), "on-failure")
    }

    /// A local release-shaped tarball (`codex-<triple>` inside, 0644 so the installer's chmod
    /// is what makes it executable) plus its SHA-256, and an install dir holding a stale pin,
    /// the unversioned `codex`, and an unrelated file. Pass `dir` to build into an existing one.
    private func makeCodexTarball(body: String = "#!/bin/sh\necho new\n", in existing: URL? = nil)
        throws -> (dir: URL, tgz: URL, digest: String, dest: URL) {
        let dir = existing ?? tempDir("codex-install")
        let src = dir.appendingPathComponent("src-\(UUID().uuidString)"), install = dir.appendingPathComponent("install")
        for d in [src, install] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        FileManager.default.createFile(atPath: src.appendingPathComponent("codex-aarch64-apple-darwin").path,
                                       contents: Data(body.utf8),
                                       attributes: [.posixPermissions: 0o644])
        let tgz = dir.appendingPathComponent("codex-\(UUID().uuidString).tar.gz")
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-czf", tgz.path, "-C", src.path, "codex-aarch64-apple-darwin"]
        try tar.run(); tar.waitUntilExit()
        XCTAssertEqual(tar.terminationStatus, 0)
        for name in ["codex", "codex-rust-v0.139.0", "other"] where existing == nil {
            FileManager.default.createFile(atPath: install.appendingPathComponent(name).path, contents: Data("old".utf8))
        }
        let digest = SHA256.hash(data: try Data(contentsOf: tgz)).map { String(format: "%02x", $0) }.joined()
        return (dir, tgz, digest, install.appendingPathComponent("codex-rust-v0.162.1"))
    }

    /// #279: a good digest installs the binary signed in the temp dir, prunes stale pins and
    /// deletes the tarball.
    func testInstallCodexGoodDigestInstallsPrunesAndDeletesTarball() throws {
        let (dir, tgz, digest, dest) = try makeCodexTarball()
        defer { try? FileManager.default.removeItem(at: dir) }
        var signed: [URL] = []
        let out = try AgentController.installCodex(tgz: tgz, sha256: digest, dest: dest,
                                                   sign: { signed.append($0); return 0 })
        XCTAssertEqual(out, dest)
        XCTAssertEqual(try String(contentsOf: dest, encoding: .utf8), "#!/bin/sh\necho new\n")
        XCTAssertEqual(try Self.mode(dest), 0o755, "the 0644 tarball binary was not chmodded 0755")
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
            let (dir, tgz, digest, dest) = try makeCodexTarball()
            defer { try? FileManager.default.removeItem(at: dir) }
            let install = dest.deletingLastPathComponent()
            let before = try FileManager.default.contentsOfDirectory(atPath: install.path).sorted()
            XCTAssertThrowsError(try AgentController.installCodex(
                tgz: tgz, sha256: badDigest ? String(repeating: "0", count: 64) : digest, dest: dest,
                sign: { _ in rc }), "\(label) did not fail closed")
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: install.path).sorted(), before,
                           "\(label) touched the install dir")
            XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path), "\(label) left a binary at the pin")
            XCTAssertFalse(FileManager.default.fileExists(atPath: tgz.path), "\(label) left the tarball behind")
        }
    }

    /// #346: a failed rename (dest is a non-empty directory) throws, removes the staging file
    /// and still deletes the tarball.
    func testInstallCodexFailedRenameCleansStagingFile() throws {
        let (dir, tgz, digest, dest) = try makeCodexTarball()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: dest.appendingPathComponent("stray").path, contents: Data("x".utf8))
        // The fixture dir also holds other pins; whatever was there before is all that may remain.
        // readdir, not FileManager: contentsOfDirectory hides AppleDouble `._` names (QA #158).
        let before = Self.names(in: dest.deletingLastPathComponent())
        XCTAssertTrue(before.contains(dest.lastPathComponent))
        XCTAssertThrowsError(try AgentController.installCodex(tgz: tgz, sha256: digest, dest: dest, sign: { _ in 0 })) {
            guard case HarnessError.spawnFailed(let msg) = $0 else { return XCTFail("wrong error: \($0)") }
            XCTAssertTrue(msg.contains("codex install rename failed"), "wrong failure: \(msg)")
        }
        XCTAssertEqual(Self.names(in: dest.deletingLastPathComponent()), before, "install dir changed after a failed rename")
        XCTAssertFalse(FileManager.default.fileExists(atPath: tgz.path), "the tarball was left behind")
    }

    /// #308: installing over an existing pin (the 0644 re-download path) replaces its bytes,
    /// lands 0755, and prunes a staging file an earlier crash left behind. QA #157: the leftover
    /// is named by `stagingName`, so renaming the staging file can't outrun the prune filter.
    func testInstallCodexOverExistingDestReplacesIt() throws {
        let (dir, tgz, digest, dest) = try makeCodexTarball()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try AgentController.installCodex(tgz: tgz, sha256: digest, dest: dest, sign: { _ in 0 })
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: dest.path)
        // A staging file a crash between move and rename left behind.
        let crashed = AgentController.stagingName(for: dest)
        FileManager.default.createFile(atPath: dest.deletingLastPathComponent()
            .appendingPathComponent(crashed).path, contents: Data("partial".utf8))
        XCTAssertTrue(Self.names(in: dest.deletingLastPathComponent()).contains(crashed))
        let second = try makeCodexTarball(body: "#!/bin/sh\necho newer\n", in: dir)
        XCTAssertEqual(second.dest, dest)
        _ = try AgentController.installCodex(tgz: second.tgz, sha256: second.digest, dest: dest, sign: { _ in 0 })
        XCTAssertEqual(try String(contentsOf: dest, encoding: .utf8), "#!/bin/sh\necho newer\n")
        XCTAssertEqual(try Self.mode(dest), 0o755)
        XCTAssertEqual(Self.names(in: dest.deletingLastPathComponent()), ["codex-rust-v0.162.1", "other"],
                       "a staging file or stale pin was left behind")
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.tgz.path))
    }

    /// Every name in `dir` but `.`/`..`, sorted, via readdir: FileManager hides `._` names.
    private static func names(in dir: URL) -> [String] {
        guard let d = opendir(dir.path) else { return [] }
        defer { closedir(d) }
        var out: [String] = []
        while let e = readdir(d) {
            let name = withUnsafeBytes(of: e.pointee.d_name) { String(decoding: $0.prefix(Int(e.pointee.d_namlen)), as: UTF8.self) }
            if name != "." && name != ".." { out.append(name) }
        }
        return out.sorted()
    }

    private static func mode(_ url: URL) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? -1
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

    /// #283: the card shows every key the reply would grant — glob and deny entries, an
    /// unknown key and `globScanMaxDepth` as JSON, a wrong-typed element as "?" in place —
    /// with newlines, controls and bidi/format scalars escaped; `network: null` grants nothing.
    @MainActor
    func testControllerPermissionsCardShowsEveryGrantedKeyOnOneLineEach() async throws {
        let (approval, reply) = try await answer("GRANTS please", with: .decline)
        XCTAssertEqual(approval?.kind, .permission)
        XCTAssertEqual(approval?.summary, #"why\u{202E}gnp.exe"#)
        XCTAssertEqual(approval?.detail, [
            "?: <?>",
            "Deny: /secret",
            #"Read: /r\nWrite: /, /\u{202E}txt.cod, ?"#,
            "Write: /src/**/*.swift",
            #"extra: {"a":[true],"b":1}"#,
            "globScanMaxDepth: 3",
            #"In: /tmp\u{1B}[2J\u{9}"#,
        ].joined(separator: "\n"))
        XCTAssertEqual(reply?["result"] as? NSDictionary,
                       ["permissions": [String: Any](), "scope": "turn"] as NSDictionary)
    }

    /// QA #102: a non-string `command` (number, null, array, a non-JSON inf) renders instead
    /// of raising the uncatchable ObjC exception `JSONSerialization` throws on a top-level scalar.
    func testCommandItemWithNonStringCommandRenders() {
        for (command, want) in [(5, "5"), (NSNull(), "null"), ([1, "a"], #"[1,"a"]"#), ([Double.infinity], "[inf]")]
            as [(Any, String)] {
            let events = CodexHarness.mapNotification(method: "item/started", params: [
                "threadId": "thread-1", "turnId": "turn-1",
                "item": ["id": "cmd-1", "type": "commandExecution", "command": command]])
            guard case .toolCallStarted(let call)? = events.first else { return XCTFail("no start for \(want)") }
            XCTAssertEqual(call.argumentsJSON, want)
        }
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

    /// #357: the diff body is escaped per line, so a Trojan Source line shows its bidi controls
    /// as `\u{…}` text; a U+2028 can't split a line, real newlines and a tab indent stay raw.
    @MainActor
    func testControllerFileChangeApprovalEscapesTheDiffBody() async throws {
        let (approval, _) = try await answer("TROJAN please", with: .accept)
        XCTAssertEqual(approval?.kind, .fileChange)
        XCTAssertEqual(approval?.detail, "/tmp/t.go\n@@ -1,3 +1,3 @@\n"
            + #" if access != "user\u{202E} \u{2066}# admin\u{2069} \u{2066}":"# + "\n"
            + #"-old\u{2028}+new"# + "\n+\tx\n")
    }

    /// #359: the request arrives display-ready: an RTL diff line already carries its LRMs, so the
    /// card's view body does no text work per render.
    @MainActor
    func testControllerFileChangeApprovalDetailIsLtrAtConstruction() async throws {
        let (approval, _) = try await answer("HEBREW please", with: .accept)
        let detail = try XCTUnwrap(approval?.detail)
        XCTAssertEqual(detail, CardText.ltr("/tmp/h.txt\n@@ -1 +1 @@\n-echo a > b\n+echo א > ב\n"))
        XCTAssertTrue(detail.contains("א \u{200E}>\u{200E} \u{200E}ב"), detail)
    }

    /// #359: codex sends no diff cap; the card keeps the first 256 K Characters and counts the rest.
    @MainActor
    func testControllerFileChangeApprovalCapsAHugeDiff() async throws {
        let (approval, _) = try await answer("HUGE please", with: .accept)
        let raw = "/tmp/big.txt\n@@ -0,0 +1 @@\n+" + String(repeating: "a", count: 300 * 1024) + "\n"
        XCTAssertEqual(approval?.detail, String(raw.prefix(262_144)) + "\n… 45085 more characters not shown")
    }

    /// #357: a CRLF line end reads as a plain newline; a lone `\r` can overprint, so it shows escaped.
    func testDiffLinesNormalizesCRLFAndEscapesALoneCR() {
        XCTAssertEqual(WireText.multiLine("-a\r\n+b\r\n"), "-a\n+b\n")
        XCTAssertEqual(WireText.multiLine("+x\ry"), #"+x\u{D}y"#)
        // Split on scalars: the CRLF left after the replacement is one Character, never equal to "\n".
        XCTAssertEqual(WireText.multiLine("+a\r\r\n+b"), #"+a\u{D}"# + "\n+b")
    }

    // MARK: - #358 transcript cards escaped at ingress

    /// A harness that plays a fixed event script on every prompt, inside one completed turn.
    private final class ScriptedHarness: CodingHarness, @unchecked Sendable {
        let script: [HarnessEvent]
        let events: AsyncStream<HarnessEvent>
        let sink: AsyncStream<HarnessEvent>.Continuation
        init(_ script: [HarnessEvent]) {
            self.script = script
            (events, sink) = AsyncStream<HarnessEvent>.makeStream()
        }
        func start() async throws {}
        func shutdown() async { sink.finish() }
        func newSession(_ opts: SessionOptions) async throws -> SessionID { SessionID(raw: "scripted") }
        func resumeSession(_ id: SessionID, options: SessionOptions) async throws -> SessionID { id }
        func forkSession(_ id: SessionID) async throws -> SessionID { id }
        func sendPrompt(session: SessionID, input: [PromptInput]) async throws -> TurnID {
            let turn = TurnID(raw: "turn-1")
            sink.yield(.turnStarted(turn))
            script.forEach { sink.yield($0) }
            sink.yield(.turnCompleted(turn: turn, .completed))
            return turn
        }
        func steer(session: SessionID, turn: TurnID, input: [PromptInput]) async throws {}
        func abort(session: SessionID, turn: TurnID?) async throws {}
        func respondToApproval(_ id: ApprovalID, decision: ApprovalDecision) async throws {}
        var capabilities: HarnessCapabilities { HarnessCapabilities(forking: false, liveApprovals: false, ptyExec: false, images: false) }
    }

    /// The controller's transcript after one turn of `script`.
    @MainActor
    private func transcript(after script: [HarnessEvent]) async -> [AgentItem] {
        let dir = tempDir("scripted-harness")
        let store = AgentSessionStore(directory: dir)
        let controller = AgentController(store: store, resolveCodex: { dir }, makeHarness: { ScriptedHarness(script) })
        addTeardownBlock { _ = await store.recentSessions(limit: 1) }   // let the persist land before the dir goes
        controller.submit(goal: "go")
        let ended = await Self.wait { Self.finishedTurn(controller) }
        XCTAssertTrue(ended, "the scripted turn never finished (phase \(controller.phase))")
        let items = controller.items
        await controller.end()
        return items
    }

    /// #358: a file diff reaches the transcript escaped like the approval card: bidi controls and a
    /// U+2028 show as `\u{…}` text, real newlines stay; the path is one escaped line.
    @MainActor
    func testControllerTranscriptFileDiffIsEscaped() async {
        let items = await transcript(after: [.fileChange(turn: TurnID(raw: "turn-1"), FileDiff(
            path: "/tmp/t\u{202E}og.go\n", unifiedDiff: "@@ -1 +1 @@\n user\u{202E} \u{2066}# admin\n-old\u{2028}+new\n",
            change: .modify))])
        let diffs = items.compactMap { if case .fileDiff(_, let path, let diff, _) = $0 { return (path, diff) }; return nil }
        XCTAssertEqual(diffs.first?.0, #"/tmp/t\u{202E}og.go\n"#)
        XCTAssertEqual(diffs.first?.1, "@@ -1 +1 @@\n" + #" user\u{202E} \u{2066}# admin"# + "\n" + #"-old\u{2028}+new"# + "\n")
    }

    /// #358: tool args and streamed output are escaped per chunk; a CRLF split across two chunks
    /// keeps its `\r` as `\u{D}` (the completion's whole output replaces the deltas later).
    @MainActor
    func testControllerTranscriptToolCallIsEscapedPerChunk() async {
        let items = await transcript(after: [
            .toolCallStarted(ToolCall(id: "c1", name: "shell", argumentsJSON: "{\"cmd\":\"echo a\u{202E}b\"}")),
            .toolCallOutput(id: "c1", chunk: ToolOutputChunk(stream: .stdout, text: "\u{1B}[0;31mred\u{1B}[0m\r")),
            .toolCallOutput(id: "c1", chunk: ToolOutputChunk(stream: .stdout, text: "\nnext\u{2067}")),
        ])
        let calls = items.compactMap { if case .toolCall(_, _, let args, _, let out) = $0 { return (args, out) }; return nil }
        XCTAssertEqual(calls.first?.0, #"{"cmd":"echo a\u{202E}b"}"#)
        XCTAssertEqual(calls.first?.1, #"red\u{D}"# + "\n" + #"next\u{2067}"#)
    }

    /// #358 (QA #173): the completion's output replaces the streamed deltas on the card, escaped
    /// like them (`WireText.toolOutput`): a bidi override and a non-SGR ESC sequence show as text.
    @MainActor
    func testControllerTranscriptToolCallCompletedOutputIsEscaped() async {
        let items = await transcript(after: [
            .toolCallStarted(ToolCall(id: "c1", name: "shell", argumentsJSON: "{}")),
            .toolCallOutput(id: "c1", chunk: ToolOutputChunk(stream: .stdout, text: "partial")),
            .toolCallCompleted(ToolCall(id: "c1", name: "shell", argumentsJSON: "{}", status: .succeeded,
                                        output: "a\u{202E}b\u{1B}[2Jc")),
        ])
        let outs = items.compactMap { if case .toolCall(_, _, _, _, let out) = $0 { return out }; return nil }
        XCTAssertEqual(outs, [#"a\u{202E}b\u{1B}[2Jc"#])
    }

    /// #358: restoring already-escaped history must not escape it again. #378: oneLine is not
    /// idempotent over its own output (it doubles the backslash of its `\n`), so restore goes
    /// through restoredLine, which is.
    func testWireTextIsIdempotent() {
        let raw = "a\u{202E}b\u{2028}c\rd\r\ne\tf\u{200B}\u{1B}]0;t\u{7}  \t g\u{A0}\u{A0}\u{A0}h\n"
        for f in [WireText.multiLine, WireText.restoredLine, WireText.toolOutput] {
            XCTAssertEqual(f(f(raw)), f(raw))
        }
        XCTAssertEqual(WireText.restoredLine(WireText.oneLine(raw)), WireText.oneLine(raw))
        XCTAssertNotEqual(WireText.oneLine(WireText.oneLine(raw)), WireText.oneLine(raw),
                          "a second oneLine pass doubles backslashes: never re-escape stored text with it")
        XCTAssertEqual(WireText.oneLine("ls -la a\u{A0}\u{A0}\u{A0}b"), WireText.oneLine(WireText.oneLine("ls -la a\u{A0}\u{A0}\u{A0}b")),
                       "with no escape in its output, oneLine is still idempotent")
        // #363: tool args saved multiLine-escaped before #363 load through restoredLine.
        let legacy = WireText.multiLine(raw)
        XCTAssertEqual(WireText.restoredLine(WireText.restoredLine(legacy)), WireText.restoredLine(legacy))
    }

    /// #378 (OQ-31 c): a backslash before n, u, r or t doubles, so the two characters `\n` stay
    /// visibly different from a real LF and a typed `\u{202E}` from an escaped bidi override; any
    /// other backslash (a Windows path) is left alone.
    func testWireTextOneLineDoublesBackslashBeforeItsEscapeLetters() {
        XCTAssertEqual(WireText.oneLine("a\nb"), #"a\nb"#)
        XCTAssertEqual(WireText.oneLine(#"a\nb"#), #"a\\nb"#)
        XCTAssertNotEqual(WireText.oneLine(#"a\nb"#), WireText.oneLine("a\nb"))
        XCTAssertEqual(WireText.oneLine(#"x\u{202E}y"#), #"x\\u{202E}y"#)
        XCTAssertEqual(WireText.oneLine("x\u{202E}y"), #"x\u{202E}y"#)
        XCTAssertEqual(WireText.oneLine(#"\r\t"#), #"\\r\\t"#)
        XCTAssertEqual(WireText.oneLine(#"C:\Users\Bob\ a\\b \d+"#), #"C:\Users\Bob\ a\\b \d+"#)
        XCTAssertEqual(WireText.multiLine(#"a\nb"#), #"a\nb"#, "a diff keeps its backslashes verbatim")
        XCTAssertEqual(CodexHarness.commandSummary(["printf", #"a\nb"#]), #"printf 'a\\nb'"#)
    }

    /// #358: tool output drops well-formed SGR colour codes; any other ESC sequence (an OSC) escapes.
    func testWireTextToolOutputStripsSGROnly() {
        XCTAssertEqual(WireText.toolOutput("\u{1B}[0;31mred\u{1B}[0m"), "red")
        XCTAssertEqual(WireText.toolOutput("\u{1B}]0;title\u{7}"), #"\u{1B}]0;title\u{7}"#)
        XCTAssertEqual(WireText.multiLine("\u{1B}[0m"), #"\u{1B}[0m"#, "only tool output strips SGR")
        // #363: a CSI with a final byte other than `m` (erase, cursor move) is escaped whole, never stripped.
        XCTAssertEqual(WireText.toolOutput("\u{1B}[2J\u{1B}[1;31Hi"), #"\u{1B}[2J\u{1B}[1;31Hi"#)
    }

    /// #363: a plain string command with a raw LF is one escaped line on the tool card (drawn with
    /// `.lineLimit(1)`), not cut to its first line.
    @MainActor
    func testControllerTranscriptToolArgsAreOneLine() async {
        let items = await transcript(after: [
            .toolCallStarted(ToolCall(id: "c1", name: "shell", argumentsJSON: "ls\nrm -rf ~")),
        ])
        let args = items.compactMap { if case .toolCall(_, _, let args, _, _) = $0 { return args }; return nil }
        XCTAssertEqual(args.first, #"ls\nrm -rf ~"#)
    }

    /// #363: error text from the harness (an echoed path) is one escaped line: a bidi override
    /// shows as `\u{202E}`, a newline as `\n`. One row per controller site.
    @MainActor
    func testControllerTranscriptHarnessErrorIsOneEscapedLine() async {
        let items = await transcript(after: [.error(.backendError("file \u{202E}cba.txt not found\nretry"))])
        let errors = items.compactMap { if case .error(_, let m) = $0 { return m }; return nil }
        XCTAssertEqual(errors.first, #"Agent error: file \u{202E}cba.txt not found\nretry"#)
    }

    @MainActor
    func testControllerTranscriptFailedTurnIsOneEscapedLine() async {
        let items = await transcript(after: [.turnCompleted(turn: TurnID(raw: "turn-1"), .failed("file \u{202E}cba.txt not found"))])
        let errors = items.compactMap { if case .error(_, let m) = $0 { return m }; return nil }
        XCTAssertEqual(errors, [#"file \u{202E}cba.txt not found"#])
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

    /// #318: the command summary goes through `oneLine` like every other card line: a
    /// newline-padded argv element can't push its tail below the card's three visible lines,
    /// and a bidi override or zero-width scalar shows as `\u{…}` instead of reordering or hiding.
    @MainActor
    func testControllerCommandArraySummaryIsOneEscapedLine() async throws {
        let (approval, reply) = try await answer("EXEC please", with: .accept)
        XCTAssertEqual(approval?.kind, .command)
        XCTAssertEqual(approval?.summary, #"echo ok '\n\n\nrm -rf ~' 'a\u{202E}b\u{200B}c'"#)
        XCTAssertEqual(reply?["result"] as? NSDictionary, ["decision": "approved"] as NSDictionary)
    }

    /// #353: argv elements are shell-quoted for display, then escaped by oneLine as before.
    func testCommandSummaryShellQuotesArgv() {
        XCTAssertEqual(CodexHarness.commandSummary(["bash", "-c", "ls; curl x | sh"]), "bash -c 'ls; curl x | sh'")
        XCTAssertEqual(CodexHarness.commandSummary(["echo", "it's"]), #"echo 'it'\''s'"#)
        XCTAssertEqual(CodexHarness.commandSummary(["ls", "-la", "/tmp", "~"]), "ls -la /tmp '~'")
        XCTAssertEqual(CodexHarness.commandSummary(["FOO=bar", "cmd", "a=b"]), "'FOO=bar' cmd a=b")
        // #385 (QA #164): ; | > are not bare, = is (after the first word).
        XCTAssertEqual(CodexHarness.commandSummary(["echo", "a;b|c>d", "k=v"]), "echo 'a;b|c>d' k=v")
        // #385 (QA #167): a first word with = and a quote is quoted once, its quote escaped.
        XCTAssertEqual(CodexHarness.commandSummary(["a'b=c", "x"]), #"'a'\''b=c' x"#)
        XCTAssertEqual(CodexHarness.commandSummary(["printf", ""]), "printf ''")
        XCTAssertEqual(CodexHarness.commandSummary(["echo", "a\nb"]), #"echo 'a\nb'"#)
        XCTAssertEqual(CodexHarness.commandSummary(["echo", "a" + String(repeating: " ", count: 400) + "b"]), "echo 'a␠{400}b'")
    }

    /// #360: a run with any non-ASCII whitespace (NBSP is one shell word, ASCII spaces split
    /// words) gets its own `⍽{N}` marker; CRLF is one line break, a lone CR still one `\n`.
    func testCommandSummaryMarksNonASCIIWhitespaceRunsAndCRLF() {
        XCTAssertEqual(CodexHarness.commandSummary(["echo", "a   b"]), "echo 'a␠{3}b'")
        XCTAssertEqual(CodexHarness.commandSummary(["echo", "a\u{A0}\u{A0}\u{A0}b"]), "echo 'a⍽{3}b'")
        XCTAssertEqual(CodexHarness.commandSummary(["echo", "a \u{A0} b"]), "echo 'a⍽{3}b'")
        XCTAssertEqual(WireText.oneLine("a\t\t\tb"), "a⍽{3}b")   // #372: a tab-only run is not spaces
        XCTAssertEqual(CodexHarness.commandSummary(["kill", "-9   1"]), "kill '-9␠{3}1'")   // #372: closed marker
        XCTAssertEqual(WireText.oneLine("ls\r\nrm -rf ~"), #"ls\nrm -rf ~"#)
        XCTAssertEqual(WireText.oneLine("ls\rrm -rf ~"), #"ls\nrm -rf ~"#)
        XCTAssertEqual(WireText.oneLine("a\u{B}b"), #"a\nb"#)   // #379: VT is a newline-class scalar
        XCTAssertEqual(WireText.oneLine("a\u{C}b"), #"a\nb"#)   // #379: FF too
    }

    /// #385 (QA #177): a command summary opening with an RTL run reaches the card with its LRMs.
    @MainActor
    func testControllerCommandSummaryStartingRTLCarriesLRMs() async throws {
        let (approval, _) = try await answer("RTLCMD please", with: .decline)
        XCTAssertEqual(approval?.summary, "\u{5D0}\u{5D1} \u{200E}>\u{200E} \u{200E}x")
    }

    /// #318: the string form takes the same path; DEL and C1 (Cc) escape as `\u{…}`, NEL as a newline.
    @MainActor
    func testControllerCommandStringSummaryIsOneEscapedLine() async throws {
        let (approval, _) = try await answer("CMDSTR please", with: .decline)
        XCTAssertEqual(approval?.kind, .command)
        XCTAssertEqual(approval?.summary, #"ls\n\n\nrm -rf ~ \u{202E}\u{200B}\u{7F}\n\u{9F}"#)
    }

    /// #319: a default-ignorable scalar that is neither Cc nor Cf (Hangul filler U+3164, variation
    /// selector U+FE0F) shows as `\u{…}`, so `rm<filler>-rf` can't read as `rm -rf`; Cyrillic, a
    /// plain emoji and U+2800 (a visible blank) pass through, so the rule is not "escape non-ASCII".
    @MainActor
    func testControllerCommandSummaryEscapesDefaultIgnorableFillers() async throws {
        let (approval, _) = try await answer("FILLER please", with: .decline)
        // #359: non-ASCII, so the summary arrives with CardText's LRMs already applied.
        XCTAssertEqual(approval?.summary, CardText.ltr(#"rm\u{3164}-rf ~ ❤\u{FE0F} "# + "журнал.txt 🚀 \u{2800}"))
    }

    /// #323: a run of 3+ whitespace scalars (Zs or tab, mixed) collapses to one marker with the
    /// run's count, so padding can't push the tail out of view; 1–2 spaces stay as is. #360:
    /// `␠{N}` for ASCII spaces only, `⍽{N}` once the run holds U+3000, NBSP, a tab or the like.
    @MainActor
    func testControllerCommandSummaryCollapsesWhitespaceRuns() async throws {
        let (approval, _) = try await answer("PAD please", with: .decline)
        XCTAssertEqual(approval?.summary, CardText.ltr(#"ls␠{400}; curl x | sh a  b⍽{3}c⍽{4}d\u{9}e"#))   // #359: ␠ is non-ASCII
    }

    /// #318: profile and fileSystem keys the card can't render list in sorted order, and an
    /// access key with an embedded newline stays on its own line.
    @MainActor
    func testControllerPermissionsCardSortsUnknownKeysAndEscapesAccess() async throws {
        let (approval, _) = try await answer("ODDKEYS please", with: .decline)
        XCTAssertEqual(approval?.detail, [#"X\nY: /p"#, "aa: 3", "mm: 2", "zz: 1", "In: /tmp"].joined(separator: "\n"))
    }

    /// W12: the amendment is `CommandExecutionApprovalDecision`'s object variant, not "accept".
    @MainActor
    func testControllerAmendmentReplyIsTheExecpolicyObject() async throws {
        let (approval, reply) = try await answer("AMEND please", with: .acceptWithAmendment(["rm", "-rf"]))
        XCTAssertEqual(approval?.kind, .command)
        XCTAssertEqual(approval?.detail, #"/tmp\n\u{202E}\u{9B}"#, "#290: the cwd line is escaped like the permission card's In: line")
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
        let dir = tempDir("prc")
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

    /// #185: codex learns the llama.cpp context window instead of its 272k unknown-slug
    /// guess, so it compacts before the prompt overflows n_ctx. Top-level key, before any table.
    func testConfigWritesModelContextWindowForGGUFModel() async throws {
        let saved = Preferences.defaults.string(forKey: "agentModel")
        defer { Preferences.defaults.set(saved, forKey: "agentModel") }
        Preferences.agentModel = "unsloth/Qwen3.5-4B-GGUF" // a registry GGUF row, whatever this Mac's default
        let (exe, home) = try makeMock()
        let harness = CodexHarness(executableURL: exe, codexHome: home,
                                   llmBaseURL: "http://127.0.0.1:0/v1", llmToken: "test-token")
        try await harness.start()
        await harness.shutdown()

        let toml = try String(contentsOf: home.appendingPathComponent("config.toml"), encoding: .utf8)
        let topLevel = toml[..<(toml.range(of: "\n[")?.lowerBound ?? toml.endIndex)]
        let lines = topLevel.split(separator: "\n").map(String.init)
        let line = "model_context_window = \(LlamaAgentEngine.contextTokens)"
        XCTAssertTrue(lines.contains(line), "\(topLevel)")
    }

    /// #185 negative: an MLX agent model has no known ceiling, so codex keeps its default.
    /// The built-in MLX ladder retired in #248 (those ids canonicalize to GGUF rows), so the
    /// only MLX agent model is a custom HF import. Checks the whole file, tables included.
    func testConfigOmitsModelContextWindowForMLXModel() async throws {
        let saved = Preferences.defaults.string(forKey: "agentModel")
        let mlxId = "test-owner/Custom-MLX-185-zzz"
        let savedGB = AgentModelRegistry.physicalMemoryGB
        defer { AgentModelRegistry.physicalMemoryGB = savedGB }
        AgentModelRegistry.physicalMemoryGB = 64 // canonicalId heals non-fitting rows (#437): pin a Mac this row fits
        defer {
            Preferences.defaults.set(saved, forKey: "agentModel")
            CustomModelStore.remove(mlxId)
        }
        CustomModelStore.upsert(CustomAgentModel(id: mlxId, label: "MLX 185", sizeBytes: 0,
                                                 note: "", toolFormat: .qwenXML))
        Preferences.agentModel = mlxId
        XCTAssertEqual(Preferences.agentModel, mlxId) // a registry row, not healed away
        XCTAssertTrue(AgentModelRegistry.gguf(for: mlxId) == nil)
        let (exe, home) = try makeMock()
        let harness = CodexHarness(executableURL: exe, codexHome: home,
                                   llmBaseURL: "http://127.0.0.1:0/v1", llmToken: "test-token")
        try await harness.start()
        await harness.shutdown()

        let toml = try String(contentsOf: home.appendingPathComponent("config.toml"), encoding: .utf8)
        let lines = toml.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        XCTAssertFalse(lines.contains { $0.hasPrefix("model_context_window") }, toml)
    }

    // MARK: - #408 end() racing a resubmit

    /// An in-process harness for the end()/resubmit race, no subprocess. A parking one's first
    /// shutdown suspends on a continuation until `releaseShutdown()`. Once a shutdown began,
    /// every request fails with notStarted, as a dying codex's would. sendPrompt throws
    /// backendError when `failsPrompt` (run()'s generic catch, which calls end()); with
    /// `parksPrompt` (#410) it suspends until `releasePrompt()` and then throws notStarted, a
    /// request that outlived its codex; otherwise it opens a turn that stays open until
    /// `completeTurn()`. `die()` is codex exiting on its own, as CodexHarness.handleTermination
    /// reports it: an .error event, then the stream finishes (which is what reaches the
    /// controller's harnessEnded).
    @MainActor
    private final class ParkingHarness: CodingHarness {
        nonisolated let events: AsyncStream<HarnessEvent>
        private let sink: AsyncStream<HarnessEvent>.Continuation
        let name: String, parks: Bool, failsPrompt: Bool, parksPrompt: Bool
        private(set) var shutdowns = 0, prompts = 0, newSessions = 0, resumed: [String] = []
        private var gone = false
        private var parked: CheckedContinuation<Void, Never>?
        private var promptParked: CheckedContinuation<Void, Never>?
        var isParked: Bool { parked != nil }
        var isPromptParked: Bool { promptParked != nil }
        init(_ name: String, parks: Bool, failsPrompt: Bool, parksPrompt: Bool = false) {
            self.name = name; self.parks = parks; self.failsPrompt = failsPrompt; self.parksPrompt = parksPrompt
            (events, sink) = AsyncStream<HarnessEvent>.makeStream()
        }
        func releaseShutdown() { parked?.resume(); parked = nil }
        func releasePrompt() { promptParked?.resume(); promptParked = nil }
        func completeTurn() { sink.yield(.turnCompleted(turn: TurnID(raw: "\(name)-turn-\(prompts)"), .completed)) }
        func die() {
            gone = true
            sink.yield(.error(.backendError("codex app-server exited with code 1")))
            sink.finish()
        }
        func start() async throws {}
        func shutdown() async {
            shutdowns += 1
            gone = true
            if parks, shutdowns == 1 { await withCheckedContinuation { parked = $0 } }
            sink.finish()
        }
        func newSession(_ opts: SessionOptions) async throws -> SessionID {
            guard !gone else { throw HarnessError.notStarted }
            newSessions += 1
            return SessionID(raw: "thread-\(name)")
        }
        func resumeSession(_ id: SessionID, options: SessionOptions) async throws -> SessionID {
            guard !gone else { throw HarnessError.notStarted }
            resumed.append(id.raw)
            return id
        }
        func forkSession(_ id: SessionID) async throws -> SessionID { id }
        func sendPrompt(session: SessionID, input: [PromptInput]) async throws -> TurnID {
            guard !gone else { throw HarnessError.notStarted }
            if parksPrompt {
                await withCheckedContinuation { promptParked = $0 }
                throw HarnessError.notStarted
            }
            if failsPrompt { throw HarnessError.backendError("turn/start failed") }
            prompts += 1
            let turn = TurnID(raw: "\(name)-turn-\(prompts)")
            sink.yield(.turnStarted(turn))
            return turn
        }
        func steer(session: SessionID, turn: TurnID, input: [PromptInput]) async throws {}
        func abort(session: SessionID, turn: TurnID?) async throws {}
        func respondToApproval(_ id: ApprovalID, decision: ApprovalDecision) async throws {}
        nonisolated var capabilities: HarnessCapabilities {
            HarnessCapabilities(forking: false, liveApprovals: false, ptyExec: false, images: false)
        }
    }

    @MainActor private final class Spawned {
        var all: [ParkingHarness] = []
        /// #412: runs once inside the next makeHarness call, in the spawning run's own job.
        var onSpawn: (@MainActor () -> Void)?
    }

    /// #412: a main-actor gate standing in for a seam (end()'s releaseModel, makeHarness).
    /// `pass()` counts the call and, while `parks`, suspends until `open()`.
    @MainActor private final class Gate {
        var parks: Bool
        private(set) var calls = 0
        private var parked: CheckedContinuation<Void, Never>?
        var isParked: Bool { parked != nil }
        init(parks: Bool = false) { self.parks = parks }
        func pass() async {
            calls += 1
            if parks { await withCheckedContinuation { parked = $0 } }
        }
        func open() { parked?.resume(); parked = nil }
    }

    /// Raised from `RaiseOnDeinit.deinit`. Bound as a task-local around a submit, the token is
    /// copied into that run's Task (and the tasks it starts) and released when they end: the
    /// one signal that a run, and the end() it awaits, has returned without a timed wait.
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var raised = false
        var isRaised: Bool { lock.withLock { raised } }
        func raise() { lock.withLock { raised = true } }
    }
    private final class RaiseOnDeinit: Sendable {
        let flag: Flag
        init(_ flag: Flag) { self.flag = flag }
        deinit { flag.raise() }
    }
    private enum RunToken { @TaskLocal static var current: RaiseOnDeinit? }

    @MainActor
    private static func errorRows(_ controller: AgentController) -> Int {
        controller.items.filter { if case .error = $0 { return true }; return false }.count
    }

    /// #408: run A fails at turn/start, shows its error and parks in its harness's shutdown
    /// inside end(); run B is submitted then, and starts at once (an error phase is not active).
    /// Returns once B has opened its turn or has failed; `aEnded` is raised once A's run is over.
    /// `release` is end()'s releaseModel; a parking one (#412) moves A's park from its shutdown
    /// (which then returns) to the release.
    @MainActor
    private func parkFailedRunThenResubmit(release: Gate = Gate()) async -> (AgentController, Spawned, aEnded: Flag) {
        let dir = tempDir("end-race")
        let store = AgentSessionStore(directory: dir)
        let spawned = Spawned()
        let parksInRelease = release.parks
        let controller = AgentController(store: store, resolveCodex: { dir }, makeHarness: {
            let first = spawned.all.isEmpty
            let harness = ParkingHarness(first ? "A" : "B", parks: first && !parksInRelease, failsPrompt: first)
            spawned.all.append(harness)
            return harness
        }, releaseModel: { await release.pass() })
        addTeardownBlock { @MainActor in
            spawned.all.forEach { $0.releaseShutdown() }
            release.parks = false
            release.open()
            await controller.end()
            _ = await store.recentSessions(limit: 1)   // let the persists land before the dir goes
        }
        let aEnded = Flag()
        RunToken.$current.withValue(RaiseOnDeinit(aEnded)) { controller.submit(goal: "first") }
        let parked = await Self.wait(2) {
            parksInRelease ? release.isParked : spawned.all.first?.isParked == true
        }
        XCTAssertTrue(parked, "run A never parked in end() (phase \(controller.phase))")
        XCTAssertEqual(controller.phase, .error("Agent error: turn/start failed"))
        controller.submit(goal: "second")
        XCTAssertTrue(controller.queued.isEmpty, "run B queued instead of starting")
        _ = await Self.wait(2) {
            (spawned.all.count == 2 && spawned.all[1].prompts == 1) || Self.errorRows(controller) > 1
        }
        return (controller, spawned, aEnded)
    }

    /// #408 case a: a run submitted while the failed run's end() is still shutting its harness
    /// down gets a harness of its own and re-attaches the failed run's thread on it, instead of
    /// failing against the dying harness (a second error row and a second end()).
    @MainActor
    func testResubmitDuringFailedRunTeardownSpawnsItsOwnHarness() async {
        let (controller, spawned, _) = await parkFailedRunThenResubmit()
        XCTAssertEqual(spawned.all.count, 2, "the resubmitted run reused the harness end() is shutting down")
        XCTAssertEqual(Self.errorRows(controller), 1, "the resubmitted run failed: \(controller.items)")
        XCTAssertEqual(controller.phase, .running)
        XCTAssertEqual(spawned.all.last?.resumed, ["thread-A"],
                       "run B did not re-attach run A's thread on its own harness")
        XCTAssertEqual(spawned.all.last?.prompts, 1)
        XCTAssertEqual(spawned.all.first?.shutdowns, 1, "run A's harness was shut down again")
    }

    /// #408 case b: when the failed run's shutdown returns, its end() finds a newer run and stops:
    /// that run keeps its harness (never shut down), its session and its phase, and its next turn
    /// goes out on the same harness and thread. The model residency is not observable without
    /// loading a model; the release sits behind the same guard as the phase.
    @MainActor
    func testStaleEndLeavesTheResubmittedRunItsHarnessSessionAndPhase() async {
        let (controller, spawned, aEnded) = await parkFailedRunThenResubmit()
        guard spawned.all.count == 2 else { return XCTFail("run B never got a harness of its own") }
        let (a, b) = (spawned.all[0], spawned.all[1])
        XCTAssertEqual(controller.phase, .running)
        XCTAssertFalse(aEnded.isRaised, "run A returned while its shutdown was parked")
        a.releaseShutdown()
        let ended = await Self.wait(2) { aEnded.isRaised }
        XCTAssertTrue(ended, "run A never returned from end()")
        XCTAssertEqual(b.shutdowns, 0, "the stale end() shut the newer run's harness down")
        XCTAssertEqual(controller.phase, .running, "the stale end() settled the newer run's phase")
        XCTAssertEqual(controller.currentSessionID, "thread-A", "the stale end() dropped the newer run's session")

        b.completeTurn()
        let idle = await Self.wait(2) { controller.phase == .idle }
        XCTAssertTrue(idle, "run B's turn never completed (phase \(controller.phase))")
        controller.submit(goal: "third")
        let sent = await Self.wait(2) { b.prompts == 2 }
        XCTAssertTrue(sent, "run B's next turn never went out on its harness (phase \(controller.phase))")
        XCTAssertEqual(spawned.all.count, 2, "run B's next turn spawned another harness")
        XCTAssertEqual(b.resumed, ["thread-A"], "run B's next turn re-attached its thread again")
        XCTAssertEqual(b.newSessions, 0)
        b.completeTurn()
        _ = await Self.wait(2) { controller.phase == .idle }
    }

    // MARK: - #412 end()'s guards, observed through the releaseModel seam

    /// #412 B2: the stale end() resumed from its parked shutdown returns at the post-shutdown
    /// guard: it never releases the model the newer run owns, and leaves its harness and phase.
    @MainActor
    func testStaleEndReturnsBeforeReleasingTheModelUnderTheResubmittedRun() async {
        let release = Gate()
        let (controller, spawned, aEnded) = await parkFailedRunThenResubmit(release: release)
        guard spawned.all.count == 2, spawned.all[1].prompts == 1 else {
            return XCTFail("run B never opened its turn (phase \(controller.phase))")
        }
        let (a, b) = (spawned.all[0], spawned.all[1])
        XCTAssertEqual(release.calls, 0, "run A's end() released the model before its shutdown returned")
        a.releaseShutdown()
        let ended = await Self.wait(2) { aEnded.isRaised }
        XCTAssertTrue(ended, "run A never returned from end()")
        XCTAssertEqual(release.calls, 0, "the stale end() released the model under the newer run")
        XCTAssertEqual(controller.phase, .running, "the stale end() settled the newer run's phase")
        XCTAssertEqual(b.shutdowns, 0, "the stale end() shut the newer run's harness down")
    }

    /// #412 B7: A's end() gets past its shutdown and parks in the release; B is submitted and
    /// opens its turn; once the release returns, the post-release guard stops the stale end()
    /// before it settles B's phase.
    @MainActor
    func testStaleEndParkedInTheReleaseLeavesTheResubmittedRunsPhase() async {
        let release = Gate(parks: true)
        let (controller, spawned, aEnded) = await parkFailedRunThenResubmit(release: release)
        guard spawned.all.count == 2, spawned.all[1].prompts == 1 else {
            return XCTFail("run B never opened its turn (phase \(controller.phase))")
        }
        let (a, b) = (spawned.all[0], spawned.all[1])
        XCTAssertEqual(a.shutdowns, 1)
        XCTAssertFalse(aEnded.isRaised, "run A returned while its release was parked")
        release.open()
        let ended = await Self.wait(2) { aEnded.isRaised }
        XCTAssertTrue(ended, "run A never returned from end()")
        XCTAssertEqual(controller.phase, .running, "the stale end() settled the newer run's phase")
        XCTAssertEqual(b.shutdowns, 0, "the stale end() shut the newer run's harness down")
        XCTAssertEqual(controller.currentSessionID, "thread-A", "the stale end() dropped the newer run's session")
        XCTAssertEqual(release.calls, 1)
    }

    /// #412 R2: Stop with no harness and no session defers end() to a Task; that end() belongs to
    /// the stopped run, whatever runs before it. Stop lands while run A's makeHarness is in flight
    /// (`onSpawn`, in A's own main-actor job), so A throws at its post-spawn checkpoint and its catch
    /// idles the phase in that same job, ahead of the deferred end(). Part 1: nothing else runs in
    /// between, so that end() is in-generation: it releases the model. Part 2: a submit queued
    /// before the Stop is accepted between A's catch and the deferred end(), which must then
    /// return at entry. (Parking A on a continuation and calling stop() from the test does not
    /// order it: the resumed run was observed landing behind a Task the test created after the
    /// resume, so the test cannot place A's catch ahead of the deferred end() from outside.)
    @MainActor
    func testDeferredStopEndBelongsToTheStoppedRun() async {
        let dir = tempDir("stop-capture")
        let store = AgentSessionStore(directory: dir)
        let spawned = Spawned()
        let release = Gate()
        let controller = AgentController(store: store, resolveCodex: { dir }, makeHarness: {
            let hook = spawned.onSpawn
            spawned.onSpawn = nil
            hook?()
            let harness = ParkingHarness("H\(spawned.all.count + 1)", parks: false, failsPrompt: false)
            spawned.all.append(harness)
            return harness
        }, releaseModel: { await release.pass() })
        addTeardownBlock { @MainActor in
            await controller.end()
            _ = await store.recentSessions(limit: 1)   // let the persists land before the dir goes
        }

        // Part 1: Stop during A1's load; the deferred end() runs in A1's generation.
        let a1Ended = Flag(), end1Done = Flag()
        spawned.onSpawn = { RunToken.$current.withValue(RaiseOnDeinit(end1Done)) { controller.stop() } }
        RunToken.$current.withValue(RaiseOnDeinit(a1Ended)) { controller.submit(goal: "first") }
        let done1 = await Self.wait(2) { end1Done.isRaised && a1Ended.isRaised }
        XCTAssertTrue(done1, "run A1 or its deferred end() never returned")
        XCTAssertEqual(release.calls, 1, "Stop during the load did not release the model")
        XCTAssertEqual(controller.phase, .idle)

        // Part 2: Stop during A2's load with run B's submit already queued on the main actor.
        let end2Done = Flag()
        spawned.onSpawn = {
            Task { controller.submit(goal: "third") }   // runs after A2's catch, before the end()
            RunToken.$current.withValue(RaiseOnDeinit(end2Done)) { controller.stop() }
        }
        controller.submit(goal: "second")
        let opened = await Self.wait(2) { spawned.all.count == 3 && spawned.all[2].prompts == 1 }
        guard opened else {
            return XCTFail("run B never opened its turn (phase \(controller.phase), queued \(controller.queued))")
        }
        let b = spawned.all[2]
        XCTAssertTrue(end2Done.isRaised, "the deferred end() had not run when B opened its turn")
        XCTAssertTrue(controller.queued.isEmpty, "B was queued: A2's catch did not idle the phase first")
        XCTAssertEqual(release.calls, 1, "the stopped run's deferred end() released the model under run B")
        XCTAssertEqual(controller.phase, .running, "the stopped run's deferred end() settled run B's phase")
        XCTAssertEqual(b.shutdowns, 0, "the deferred end() shut run B's harness down")
        XCTAssertEqual(controller.currentSessionID, "thread-\(b.name)")
    }

    // MARK: - #413 Stop during the model load settles the phase at once

    /// #413: run A submitted and parked inside makeHarness on `load` (the model load: no harness,
    /// no session yet; a real cancelled load runs to its end). `load` stops parking then, so a
    /// later run's makeHarness returns at once; A stays parked until `load.open()`. Harnesses are
    /// named by the makeHarness call they came from. `release` is end()'s releaseModel, parking.
    /// `aEnded` is raised once run A has returned.
    @MainActor
    private func parkRunInLoad() async -> (AgentController, Spawned, load: Gate, release: Gate, aEnded: Flag) {
        let dir = tempDir("stop-load")
        let store = AgentSessionStore(directory: dir)
        let spawned = Spawned()
        let load = Gate(parks: true), release = Gate(parks: true)
        let controller = AgentController(store: store, resolveCodex: { dir }, makeHarness: {
            let name = load.calls == 0 ? "A" : "B"
            await load.pass()
            let harness = ParkingHarness(name, parks: false, failsPrompt: false)
            spawned.all.append(harness)
            return harness
        }, releaseModel: { await release.pass() })
        addTeardownBlock { @MainActor in
            load.open()
            release.parks = false
            release.open()
            await controller.end()
            _ = await store.recentSessions(limit: 1)   // let the persists land before the dir goes
        }
        let aEnded = Flag()
        RunToken.$current.withValue(RaiseOnDeinit(aEnded)) { controller.submit(goal: "first") }
        let parked = await Self.wait(2) { load.isParked }
        XCTAssertTrue(parked, "run A never reached makeHarness (phase \(controller.phase))")
        load.parks = false
        guard case .loadingModel = controller.phase else {
            XCTFail("run A parked in the load under \(controller.phase)")
            return (controller, spawned, load, release, aEnded)
        }
        return (controller, spawned, load, release, aEnded)
    }

    /// #413 part 1: Stop during A's load idles the phase in stop() itself, so B is accepted at
    /// once and opens its turn while A is still in its load. Ordering driven: the deferred end()
    /// runs at the test's first await, in A's generation (B not yet submitted), and parks in the
    /// release; B is submitted then, so once the release returns the post-release guard stops
    /// that end(): release.calls is exactly 1, and B keeps its phase, harness and session.
    @MainActor
    func testStopDuringTheLoadSettlesThePhaseAndAdmitsAResubmit() async {
        let (controller, spawned, load, release, aEnded) = await parkRunInLoad()
        let endDone = Flag()
        RunToken.$current.withValue(RaiseOnDeinit(endDone)) { controller.stop() }
        XCTAssertEqual(controller.phase, .idle, "Stop during the load left the phase pending")
        XCTAssertFalse(controller.isActive)

        let inRelease = await Self.wait(2) { release.isParked }
        XCTAssertTrue(inRelease, "the deferred end() never reached the release")
        controller.submit(goal: "second")
        XCTAssertTrue(controller.queued.isEmpty, "B was queued behind the stopped load")
        let opened = await Self.wait(2) { spawned.all.first?.name == "B" && spawned.all.first?.prompts == 1 }
        guard opened, let b = spawned.all.first else {
            return XCTFail("run B never opened its turn (phase \(controller.phase), queued \(controller.queued))")
        }
        XCTAssertTrue(load.isParked, "run A left its load before B opened its turn")
        XCTAssertEqual(controller.phase, .running)

        load.open()
        let aDone = await Self.wait(2) { aEnded.isRaised }
        XCTAssertTrue(aDone, "run A never returned from its post-spawn checkpoint")
        XCTAssertEqual(controller.phase, .running, "run A's catch settled run B's phase")
        release.open()
        let ended = await Self.wait(2) { endDone.isRaised }
        XCTAssertTrue(ended, "the deferred end() never returned")
        XCTAssertEqual(release.calls, 1, "the deferred end() did not release exactly once")
        XCTAssertEqual(controller.phase, .running, "the stopped run's deferred end() settled run B's phase")
        XCTAssertEqual(b.shutdowns, 0, "the stopped run's deferred end() shut run B's harness down")
        XCTAssertEqual(controller.currentSessionID, "thread-B", "the stopped run's deferred end() dropped B's session")
    }

    /// #413 part 2: Stop during the load with no resubmit: the phase is idle at once, A's
    /// checkpoint throws and leaves it so, and the deferred end() releases exactly once.
    @MainActor
    func testStopDuringTheLoadReleasesOnceAndStaysIdle() async {
        let (controller, spawned, load, release, aEnded) = await parkRunInLoad()
        let endDone = Flag()
        RunToken.$current.withValue(RaiseOnDeinit(endDone)) { controller.stop() }
        XCTAssertEqual(controller.phase, .idle, "Stop during the load left the phase pending")
        XCTAssertFalse(controller.isActive)

        load.open()
        let aDone = await Self.wait(2) { aEnded.isRaised }
        XCTAssertTrue(aDone, "run A never returned from its post-spawn checkpoint")
        XCTAssertEqual(controller.phase, .idle)
        let inRelease = await Self.wait(2) { release.isParked }
        XCTAssertTrue(inRelease, "the deferred end() never reached the release")
        release.open()
        let ended = await Self.wait(2) { endDone.isRaised }
        XCTAssertTrue(ended, "the deferred end() never returned")
        XCTAssertEqual(release.calls, 1)
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertEqual(load.calls, 1, "another run reached the load")
        XCTAssertEqual(spawned.all.map(\.shutdowns), [0], "run A's unkept harness was shut down")
    }

    /// #413 part 3: a goal queued during the load stays queued through Stop: the settle never
    /// drains (a drain would start a run inside stop() and hand the deferred end() its generation).
    /// Synchronously after stop(): idle, the goal still queued, no user bubble for it (submit and
    /// the drain both append one); afterwards no other run reached the load.
    @MainActor
    func testStopDuringTheLoadLeavesAQueuedGoalQueued() async {
        let (controller, spawned, load, release, aEnded) = await parkRunInLoad()
        controller.submit(goal: "second")
        XCTAssertEqual(controller.queued.map(\.text), ["second"])
        let started: () -> Bool = {
            controller.items.contains { if case .user(_, "second") = $0 { return true }; return false }
        }
        let endDone = Flag()
        RunToken.$current.withValue(RaiseOnDeinit(endDone)) { controller.stop() }
        XCTAssertEqual(controller.phase, .idle, "Stop during the load left the phase pending")
        XCTAssertEqual(controller.queued.map(\.text), ["second"], "Stop started the queued goal")
        XCTAssertFalse(started(), "Stop started the queued goal")
        XCTAssertEqual(load.calls, 1)

        load.open()
        let aDone = await Self.wait(2) { aEnded.isRaised }
        XCTAssertTrue(aDone, "run A never returned from its post-spawn checkpoint")
        let inRelease = await Self.wait(2) { release.isParked }
        XCTAssertTrue(inRelease, "the deferred end() never reached the release")
        release.open()
        let ended = await Self.wait(2) { endDone.isRaised }
        XCTAssertTrue(ended, "the deferred end() never returned")
        XCTAssertEqual(release.calls, 1)
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertEqual(controller.queued.map(\.text), ["second"], "the queued goal left the queue")
        XCTAssertFalse(started(), "the queued goal was started")
        XCTAssertEqual(load.calls, 1, "another run reached the load")
        XCTAssertEqual(spawned.all.count, 1)
    }

    // MARK: - #410 a dead run's late catch after a resubmit

    /// `wait` for a condition that needs an await (the session store is an actor).
    @MainActor
    private static func waitAsync(_ seconds: TimeInterval = 2, until condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !(await condition()) {
            if Date() >= deadline { return false }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return true
    }

    private static func errorCount(_ items: [AgentItem]) -> Int {
        items.filter { if case .error = $0 { return true }; return false }.count
    }

    /// #410: codex dies while run A's turn/start is in flight (.error, then the stream ends, so
    /// harnessEnded leaves .error and no harness), run B is submitted and opens its turn, and
    /// only then does A's request fail. A's late catch leaves B alone: no second error row, B's
    /// phase, harness and session intact, B's turn completes, and the store holds B's thread
    /// with A's death as its only error and no failed session.
    @MainActor
    func testDeadRunsLateCatchLeavesTheResubmittedRunAlone() async {
        let dir = tempDir("late-catch")
        let store = AgentSessionStore(directory: dir)
        let spawned = Spawned()
        let controller = AgentController(store: store, resolveCodex: { dir }, makeHarness: {
            let first = spawned.all.isEmpty
            let harness = ParkingHarness(first ? "A" : "B", parks: false, failsPrompt: false, parksPrompt: first)
            spawned.all.append(harness)
            return harness
        })
        addTeardownBlock { @MainActor in
            spawned.all.forEach { $0.releasePrompt() }
            await controller.end()
            _ = await store.recentSessions(limit: 1)   // let the persists land before the dir goes
        }
        let aEnded = Flag()
        RunToken.$current.withValue(RaiseOnDeinit(aEnded)) { controller.submit(goal: "first") }
        let inFlight = await Self.wait(2) { spawned.all.first?.isPromptParked == true }
        guard inFlight, let a = spawned.all.first else { return XCTFail("run A's turn/start never went out") }

        a.die()
        // harnessEnded persists the transcript before it drops the harness, in one synchronous
        // pass, and nothing earlier saved one: a saved transcript means the harness is gone.
        let dropped = await Self.waitAsync { await !store.loadTranscript(id: "thread-A").isEmpty }
        XCTAssertTrue(dropped, "the controller never dropped run A's dead harness")
        XCTAssertEqual(controller.phase, .error("Agent error: codex app-server exited with code 1"))

        controller.submit(goal: "second")
        let opened = await Self.wait(2) { spawned.all.count == 2 && spawned.all[1].prompts == 1 }
        guard opened else { return XCTFail("run B never opened its turn (phase \(controller.phase))") }
        let b = spawned.all[1]
        XCTAssertEqual(b.resumed, ["thread-A"], "run B did not re-attach the dead run's thread")
        XCTAssertFalse(aEnded.isRaised, "run A returned while its request was parked")

        a.releasePrompt()
        let late = await Self.wait(2) { aEnded.isRaised }
        XCTAssertTrue(late, "run A's late catch never returned")
        XCTAssertEqual(Self.errorRows(controller), 1, "run A's late catch surfaced over run B: \(controller.items)")
        XCTAssertEqual(controller.phase, .running, "run A's late catch settled run B's phase")
        XCTAssertEqual(b.shutdowns, 0, "run A's late catch shut run B's harness down")
        XCTAssertEqual(controller.currentSessionID, "thread-A", "run A's late catch dropped run B's session")

        b.completeTurn()
        let idle = await Self.wait(2) { controller.phase == .idle }
        XCTAssertTrue(idle, "run B's turn never completed (phase \(controller.phase))")
        let final = await Self.waitAsync {
            await store.loadTranscript(id: "thread-A").contains { if case .note = $0 { return true }; return false }
        }
        XCTAssertTrue(final, "run B's finished transcript never reached the store")
        let saved = await store.loadTranscript(id: "thread-A")
        XCTAssertEqual(Self.errorCount(saved), 1, "the store holds a failure for run B: \(saved)")
        let sessions = await store.recentSessions().map(\.id)
        XCTAssertEqual(sessions, ["thread-A"], "a failed session was minted")
    }
}
