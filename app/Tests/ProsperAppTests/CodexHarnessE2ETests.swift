import XCTest
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

    /// The mock app-server: reads JSONL requests on stdin, replies on stdout, and
    /// emits the notification sequence Codex would for a one-message turn, in the
    /// shapes of the codex 0.139/0.162 schemas (`{turn: Turn}` results and
    /// notifications). On a turn whose prompt contains "APPROVE", it first issues a
    /// server→client command-approval request and waits for the client's reply before
    /// finishing. On "HANG" it starts a shell command and leaves the turn running
    /// until a well-formed `turn/interrupt` request ends it; "WEDGE" does the same but
    /// never answers the interrupt (a hung codex). Every inbound line is
    /// appended to `received.jsonl` beside the script so tests can check what was sent.
    /// Thread and turn params are checked against the codex 0.139/0.161/0.162 schemas
    /// (`ThreadStartParams.sandbox: SandboxMode`, no `sandboxPolicy` there;
    /// `TurnStartParams.sandboxPolicy: SandboxPolicy`); a mismatch is a JSON-RPC error.
    private static let mockServer = #"""
    import sys, json, os

    LOG = os.path.join(os.path.dirname(os.path.abspath(__file__)), "received.jsonl")
    current_turn = None
    wedged = False

    def send(obj):
        sys.stdout.write(json.dumps(obj) + "\n")
        sys.stdout.flush()

    def turn(status):
        return {"id": current_turn, "items": [], "status": status}

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
            continue
        method = msg.get("method")
        mid = msg.get("id")
        params = msg.get("params", {})
        # A client reply to our approval server-request (has result, no method).
        if method is None and "result" in msg:
            continue
        if method == "initialize":
            send({"jsonrpc": "2.0", "id": mid, "result": {"capabilities": {}}})
        elif method == "initialized":
            pass
        elif method in ("thread/start", "thread/resume", "thread/fork"):
            problem = thread_params_error(method, params)
            if problem:
                error(mid, problem)
                continue
            tid = {"thread/start": "thread-1", "thread/fork": "thread-2"}.get(method, params.get("threadId"))
            send({"jsonrpc": "2.0", "id": mid, "result": {"thread": {"id": tid}}})
        elif method == "turn/start":
            problem = turn_params_error(params)
            if problem:
                error(mid, problem)
                continue
            current_turn = "turn-1"
            send({"jsonrpc": "2.0", "id": mid, "result": {"turn": turn("inProgress")}})
            prompt = json.dumps(params.get("input"))
            want_approval = "APPROVE" in prompt
            send({"jsonrpc": "2.0", "method": "turn/started",
                  "params": {"threadId": "thread-1", "turn": turn("inProgress")}})
            wedged = "WEDGE" in prompt
            if "HANG" in prompt or wedged:
                send({"jsonrpc": "2.0", "method": "item/started",
                      "params": {"threadId": "thread-1", "turnId": current_turn,
                                 "item": {"id": "cmd-1", "type": "commandExecution",
                                          "command": "sleep 600", "status": "inProgress"}}})
                continue
            if want_approval:
                # Server→client request; client must reply before we proceed.
                send({"jsonrpc": "2.0", "id": "appr-1",
                      "method": "item/commandExecution/requestApproval",
                      "params": {"threadId": "thread-1", "command": ["rm", "-rf", "build"], "cwd": "/tmp"}})
            send({"jsonrpc": "2.0", "method": "item/agentMessage/delta",
                  "params": {"turnId": "turn-1", "itemId": "m1", "delta": "Hello from mock"}})
            send({"jsonrpc": "2.0", "method": "thread/tokenUsage/updated",
                  "params": {"turnId": "turn-1", "tokenUsage": {"total": {"inputTokens": 12, "outputTokens": 3}}}})
            send({"jsonrpc": "2.0", "method": "turn/completed",
                  "params": {"threadId": "thread-1", "turn": turn("completed")}})
            current_turn = None
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
        let wrapper = "#!/bin/sh\nexec \"\(python)\" \"\(pyFile.path)\" \"$@\"\n"
        try wrapper.write(to: exe, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)

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

        let started = Date()
        do {
            try await harness.abort(session: session, turn: turn, timeout: 0.5)
            XCTFail("abort should time out when codex never answers")
        } catch HarnessError.timeout {
            // expected
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "bounded wait did not fire")
        await harness.shutdown()

        let interrupts = try Self.received("turn/interrupt", exe: exe)
        XCTAssertEqual(interrupts.count, 1, "the interrupt must be sent once, not retried")
        XCTAssertNotNil(interrupts.first?["id"])
    }

    /// Steer is a request whose turn id travels as `expectedTurnId`; the mock answers
    /// with an error (thrown here) if the field is missing or wrong.
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
