import XCTest
@testable import ProsperApp

/// #1181 leftovers. R1181-i: one rule for which formats drop a leading think block. R1181-h and R1181-l: the run
/// keeps the id the spawn loaded and the phase says so, driven through AgentController's spawnHarness seam with a
/// fake harness: no codex, no server, no model. Ids are made up ("example-model-a" is the pick, "example-model-b"
/// the model the fake says is resident): the rows need two distinct ids, never a catalog lookup. The setting is
/// read through the controller's agentModel seam (a constant), so no defaults are read or written.
/// Every closure here runs on the main actor (the rows, the fake harness and the seams are @MainActor).
final class AgentModelLeftoverTests: XCTestCase {

    // MARK: R1181-i

    /// Today's answer per format, as a literal list; the set check fails when a case is added without a row.
    func testLeadingThinkRuleOverEveryFormat() {
        let expected: [(ToolCallFormat, Bool)] = [
            (.qwenXML, true), (.hermesJSON, true), (.mistral, false), (.harmony, false),
            (.nemotron, false), (.glm, false), (.kimi, false), (.minimax, false),
        ]
        XCTAssertEqual(Set(expected.map(\.0)), Set(ToolCallFormat.allCases))
        XCTAssertEqual(expected.count, ToolCallFormat.allCases.count)
        for (format, drops) in expected {
            XCTAssertEqual(StreamSplitter.dropsLeadingThink(format), drops, "\(format)")
            // The splitter built from the format follows the same rule: a leading think block is dropped
            // only where the rule says so (the other formats send it, or stop at their think marker).
            var splitter = StreamSplitter(format: format)
            let out = splitter.ingest("<think>plan</think>Hi") + splitter.finish()
            XCTAssertEqual(out == "Hi", drops, "\(format): \(out)")
            XCTAssertEqual(StreamSplitter.endsInThink("<think>plan", format: format), drops, "\(format)")
        }
    }

    // MARK: R1181-h, R1181-l

    @MainActor private final class Harness: CodingHarness {
        nonisolated let events: AsyncStream<HarnessEvent>
        private let sink: AsyncStream<HarnessEvent>.Continuation
        private(set) var sessionModels: [String] = []
        private(set) var turns = 0
        /// Called when the controller starts the harness: the phase is read there, before .running replaces it.
        var onStart: (() -> Void)?
        init() { (events, sink) = AsyncStream<HarnessEvent>.makeStream() }
        func start() async throws { onStart?() }
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

    /// A budget of yields, not a deadline: no clock is read and nothing sleeps.
    @MainActor private func wait(_ what: String, _ ok: () -> Bool) async {
        for _ in 0..<200_000 where !ok() { await Task.yield() }
        XCTAssertTrue(ok(), what)
    }

    /// One run whose pick is example-model-a; the fake spawn answers `loaded` as the model it holds.
    /// Returns the picks the spawn was given, the session's models and the phase status seen at harness start.
    @MainActor private func runOnce(loaded: String) async -> (picks: [String], sessions: [String], status: String?) {
        let harness = Harness()
        var picks: [String] = []
        var status: String?
        let dir = tempDir("agent-model-leftover-1181")
        let store = AgentSessionStore(directory: dir)
        let controller = AgentController(store: store, resolveCodex: { dir }, spawnHarness: { _, pick in
            picks.append(pick)
            return (harness, loaded)
        }, releaseModel: {}, agentModel: { "example-model-a" })
        harness.onStart = {
            if case .loadingModel(_, let s) = controller.phase { status = s }
        }
        addTeardownBlock { @MainActor in
            await controller.end()
            _ = await store.recentSessions(limit: 1)
        }
        controller.submit(goal: "one")
        await wait("the run opened its session") { harness.sessionModels.count == 1 }
        await wait("the run is sent") { harness.turns == 1 }
        return (picks, harness.sessionModels, status)
    }

    /// R1181-h: the spawn says another model than the pick is loaded; the codex session names the loaded one
    /// (AgentController `model = spawned.loaded`). Before it the session named the pick.
    @MainActor
    func testRunNamesTheModelTheSpawnLoaded() async {
        let r = await runOnce(loaded: "example-model-b")
        XCTAssertEqual(r.picks, ["example-model-a"], "the load is asked for the pick, once")
        XCTAssertEqual(r.sessions, ["example-model-b"])
    }

    /// R1181-l: the phase names the resident model instead of "Loading <pick>" once the spawn answered it.
    @MainActor
    func testPhaseSaysUsingTheLoadedModelWhenAnotherIsResident() async {
        let r = await runOnce(loaded: "example-model-b")
        XCTAssertEqual(r.status, "Using example-model-b (already loaded)\u{2026}")
    }

    /// The spawn loaded the pick: the phase is today's "Loading <pick>" and the session names the pick.
    @MainActor
    func testPhaseKeepsLoadingWhenThePickIsLoaded() async {
        let r = await runOnce(loaded: "example-model-a")
        XCTAssertEqual(r.status, "Loading example-model-a\u{2026}")
        XCTAssertEqual(r.sessions, ["example-model-a"])
    }
}
