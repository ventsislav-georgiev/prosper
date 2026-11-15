import XCTest
@testable import ProsperApp

/// #1181 (R1181-g): a run that reuses a started harness opens its session under the model that harness was
/// started for, not under a second read of the setting. Driven through the makeHarness seam with a fake
/// harness: no codex, no model. The setting is a private defaults suite (scratchDefaults) with made-up ids.
/// Everything here runs on the main actor, as AgentController does.
final class AgentKeptHarnessModelTests: XCTestCase {
    @MainActor private final class Harness: CodingHarness {
        nonisolated let events: AsyncStream<HarnessEvent>
        private let sink: AsyncStream<HarnessEvent>.Continuation
        private(set) var sessionModels: [String] = []
        private(set) var turns = 0
        init() { (events, sink) = AsyncStream<HarnessEvent>.makeStream() }
        func finishTurn() { sink.yield(.turnCompleted(turn: TurnID(raw: "turn-\(turns)"), .completed)) }
        func start() async throws {}
        func shutdown() async { sink.finish() }
        func newSession(_ opts: SessionOptions) async throws -> SessionID {
            sessionModels.append(opts.model)
            return SessionID(raw: "thread-\(sessionModels.count)")
        }
        func resumeSession(_ id: SessionID, options: SessionOptions) async throws -> SessionID { id }
        func forkSession(_ id: SessionID) async throws -> SessionID { id }
        func sendPrompt(session: SessionID, input: [PromptInput]) async throws -> TurnID {
            turns += 1
            return TurnID(raw: "turn-\(turns)")
        }
        func steer(session: SessionID, turn: TurnID, input: [PromptInput]) async throws {}
        func abort(session: SessionID, turn: TurnID?) async throws {}
        func respondToApproval(_ id: ApprovalID, decision: ApprovalDecision) async throws {}
        nonisolated var capabilities: HarnessCapabilities {
            HarnessCapabilities(forking: false, liveApprovals: false, ptyExec: false, images: false)
        }
    }

    /// A budget of polls, not a deadline.
    @MainActor private func wait(_ what: String, _ ok: () -> Bool) async {
        for _ in 0..<1000 where !ok() { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(ok(), what)
    }

    /// Run 1 under model-a; the setting moves to model-b; run 2 reuses the harness in a fresh session
    /// (newSession detaches the session, keeps the harness): its session is opened under model-a.
    /// Before the fix run 2 read the setting again and said model-b while model-a was still served.
    @MainActor
    func testAKeptHarnessKeepsItsModelForTheNextSession() async {
        let suite = scratchDefaults("agent-kept-harness-1181")
        suite.set("example-model-a", forKey: "agentModel")
        let harness = Harness(), made = MadeCounter()
        let dir = tempDir("agent-kept-harness-1181")
        let store = AgentSessionStore(directory: dir)
        let controller = AgentController(store: store, resolveCodex: { dir }, makeHarness: {
            made.bump()
            return harness
        }, releaseModel: {}, agentModel: { suite.string(forKey: "agentModel") ?? "" })
        addTeardownBlock { @MainActor in
            await controller.end()
            _ = await store.recentSessions(limit: 1)
        }
        controller.submit(goal: "one")
        await wait("run 1 opened its session") { harness.sessionModels.count == 1 }
        await wait("run 1 is sent") { harness.turns == 1 }
        harness.finishTurn()
        await wait("run 1 finished") { !controller.isActive }
        suite.set("example-model-b", forKey: "agentModel")
        controller.newSession()
        controller.submit(goal: "two")
        await wait("run 2 opened its session") { harness.sessionModels.count == 2 }
        XCTAssertEqual(harness.sessionModels, ["example-model-a", "example-model-a"])
        XCTAssertEqual(made.value, 1, "the harness was kept, not made again")
    }
}

private final class MadeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func bump() { lock.withLock { n += 1 } }
    var value: Int { lock.withLock { n } }
}
