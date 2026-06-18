import XCTest
@testable import ProsperApp

/// Round-trips a session through `AgentSessionStore` against its real on-device
/// SQLite file, then cleans up. Verifies the transcript JSON codec preserves every
/// `AgentItem` case and that resume metadata (cwd, title, ordering) survives.
final class AgentSessionStoreTests: XCTestCase {

    /// Each test gets its own throwaway database directory: the production store is a
    /// singleton over a persistent Application Support file, and sharing it across
    /// tests/runs leaks rows and WAL state between runs (and silently — the store
    /// swallows write errors with `try?`). Isolation keeps the suite deterministic.
    private var tempDir: URL!

    private func makeStore() -> AgentSessionStore {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agent-store-\(UUID().uuidString)", isDirectory: true)
        tempDir = dir
        return AgentSessionStore(directory: dir)
    }

    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    func testTranscriptRoundTripPreservesAllItemKinds() async throws {
        let store = makeStore()
        let id = "test-session-\(UUID().uuidString)"

        await store.upsertSession(id: id, cwd: "/tmp/work", model: "test-model", title: "fix the build")

        let items: [AgentItem] = [
            .user(id: "u1", text: "fix the build"),
            .assistant(id: "r1", text: "thinking…", reasoning: true),
            .assistant(id: "a1", text: "Done.", reasoning: false),
            .toolCall(id: "t1", name: "shell", args: "{\"cmd\":\"ls\"}", status: .succeeded, output: "a.txt"),
            .fileDiff(id: "f1", path: "x.swift", diff: "@@ -1 +1 @@", change: .modify),
            .plan(id: "plan", steps: [PlanStep(title: "step 1", state: .done),
                                      PlanStep(title: "step 2", state: .inProgress)]),
            .error(id: "e1", message: "boom"),
        ]
        await store.saveTranscript(id: id, items: items)

        let restored = await store.loadTranscript(id: id)
        XCTAssertEqual(restored.count, items.count, "all items must survive the round-trip")
        // Guard the count before indexing: a write/read failure must surface as a clean
        // test failure, not an out-of-range trap that crashes the whole xctest process.
        guard restored.count == items.count else { return }

        guard case .user(let uid, let utext) = restored[0] else { return XCTFail("item 0 not .user") }
        XCTAssertEqual(uid, "u1"); XCTAssertEqual(utext, "fix the build")

        guard case .assistant(_, let rtext, let reasoning) = restored[1] else { return XCTFail("item 1 not .assistant") }
        XCTAssertEqual(rtext, "thinking…"); XCTAssertTrue(reasoning)

        guard case .toolCall(_, let name, let args, let status, let output) = restored[3] else { return XCTFail("item 3 not .toolCall") }
        XCTAssertEqual(name, "shell"); XCTAssertEqual(args, "{\"cmd\":\"ls\"}")
        XCTAssertEqual(status, .succeeded); XCTAssertEqual(output, "a.txt")

        guard case .fileDiff(_, let path, _, let change) = restored[4] else { return XCTFail("item 4 not .fileDiff") }
        XCTAssertEqual(path, "x.swift"); XCTAssertEqual(change, .modify)

        guard case .plan(_, let steps) = restored[5] else { return XCTFail("item 5 not .plan") }
        XCTAssertEqual(steps.count, 2)
        XCTAssertEqual(steps[0].state, .done); XCTAssertEqual(steps[1].state, .inProgress)

        guard case .error(_, let message) = restored[6] else { return XCTFail("item 6 not .error") }
        XCTAssertEqual(message, "boom")
    }

    func testRecentSessionsListsAndDeletes() async throws {
        let store = makeStore()
        let id = "test-session-\(UUID().uuidString)"
        await store.upsertSession(id: id, cwd: "/tmp/work", model: "m", title: "a goal to find")

        let listed = await store.recentSessions()
        let mine = listed.first { $0.id == id }
        XCTAssertNotNil(mine, "freshly upserted session must appear in recentSessions")
        XCTAssertEqual(mine?.title, "a goal to find")
        XCTAssertEqual(mine?.cwd, "/tmp/work")

        await store.deleteSession(id: id)
        let after = await store.recentSessions().first { $0.id == id }
        XCTAssertNil(after, "deleted session must not appear")
    }
}

// AgentItem.Status / FileDiff.Change / PlanStep.State are Equatable via their raw
// shapes; XCTAssertEqual on them relies on synthesized conformance where present.
extension ToolCall.Status: Equatable {}
extension FileDiff.Change: Equatable {}
extension PlanStep.State: Equatable {}
