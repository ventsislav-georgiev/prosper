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
    /// emits the notification sequence Codex would for a one-message turn. On a
    /// turn whose prompt contains "APPROVE", it first issues a server→client
    /// command-approval request and waits for the client's reply before finishing.
    private static let mockServer = #"""
    import sys, json

    def send(obj):
        sys.stdout.write(json.dumps(obj) + "\n")
        sys.stdout.flush()

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except Exception:
            continue
        method = msg.get("method")
        mid = msg.get("id")
        # A client reply to our approval server-request (has result, no method).
        if method is None and "result" in msg:
            continue
        if method == "initialize":
            send({"jsonrpc": "2.0", "id": mid, "result": {"capabilities": {}}})
        elif method == "initialized":
            pass
        elif method == "thread/start":
            send({"jsonrpc": "2.0", "id": mid, "result": {"threadId": "thread-1"}})
        elif method == "turn/start":
            send({"jsonrpc": "2.0", "id": mid, "result": {"turnId": "turn-1"}})
            want_approval = "APPROVE" in json.dumps(msg.get("params", {}))
            send({"jsonrpc": "2.0", "method": "turn/started", "params": {"turnId": "turn-1"}})
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
                  "params": {"threadId": "thread-1", "turn": {"id": "turn-1", "status": "completed"}}})
        elif method == "turn/interrupt":
            pass
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
}
