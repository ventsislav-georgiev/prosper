import XCTest
@testable import ProsperApp

/// #1321 (QA r1244 INFO-1): a window action on a session while a Restart or Stop of it runs (the island's, or
/// the phone's straight on the runner). dch types its pause, /exit and resume into Claude's composer, so a
/// message or Esc (no prompt) waits; an answer to a prompt goes, as the pause waits on it and dch never types
/// over a prompt. Fake runner and launch only: no dch runs, no key reaches a session.
final class AgentIslandHumanDuringJobTests: XCTestCase {
    private final class Fake: @unchecked Sendable {
        let lock = NSLock(), launched = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0)
        var launches: [[String]] = []

        func runner() -> DchActionRunner {
            DchActionRunner(bound: 60, launch: { _, args, _, _, onPid, _ in
                self.lock.withLock { self.launches.append(args) }
                onPid(4242)
                self.launched.signal()
                self.release.wait()
                return (0, Data())
            }, signal: { _ in })
        }

        var args: [[String]] { lock.withLock { launches } }

        /// A job straight on the runner, as the phone starts one; true once it launched.
        func start(_ r: DchActionRunner, _ key: AgentSessionKey, _ args: [String]?, kill: Bool = false) -> Bool {
            guard let args, r.start(key, path: "/fake/dch", args: args, yields: !kill, kill: kill, env: { [:] },
                                    done: { _ in self.done.signal() }) else { return false }
            return launched.wait(timeout: .now() + 5) == .success
        }

        /// Ends `n` launched jobs and waits for their results.
        func finish(_ n: Int) {
            for _ in 0..<n { release.signal() }
            for _ in 0..<n { _ = done.wait(timeout: .now() + 5) }
        }
    }

    private func session(_ name: String, dir: String = "/d") -> AgentSession {
        AgentSession(key: AgentSessionKey(dir: dir, name: name), alias: "", activity: 0, state: .blocked, agents: 0,
                     version: "1.24.1")
    }

    @MainActor
    private func controller(_ f: Fake, _ sessions: [AgentSession]) -> AgentIslandController {
        let c = AgentIslandController()
        c.showsPanel = false
        c.monitorClicks = { _ in nil }
        c.controlDch = { nil }
        c.runner = f.runner()
        let store = AgentIslandStore(geometry: AgentIslandGeometry.make(
            frame: CGRect(x: 0, y: 0, width: 1512, height: 982), visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 950),
            topLeft: CGRect(x: 0, y: 950, width: 663.5, height: 32), topRight: CGRect(x: 848.5, y: 950, width: 663.5, height: 32),
            safeTop: 32))
        store.sessions = sessions
        c.store = store
        return c
    }

    /// The window's action on `s`: true when taken, and then waited on until it ran.
    @MainActor
    private func act(_ c: AgentIslandController, _ s: AgentSession, prompt: AgentPrompt? = nil) -> Bool {
        let over = XCTestExpectation(description: "the action ran")   // unregistered: a refusal never waits on it
        guard c.humanAction(s, prompt: prompt, run: { _ -> Int in 0 }, done: { _ in over.fulfill() }) else { return false }
        wait(for: [over], timeout: 5)
        return true
    }

    /// A Restart running on a session: the window's message or Esc there is refused and holds nothing; another
    /// row's runs; a Kill still cuts through (#744). Once the Restart ends, the action runs.
    @MainActor
    func testAMessageOrEscWaitsWhileTheSessionsRestartRuns() {
        let f = Fake(), a = session("a"), b = session("b")
        let c = controller(f, [a, b])
        XCTAssertTrue(f.start(c.runner, a.key, AgentIsland.restartArgs("a")))
        XCTAssertFalse(act(c, a), "the Restart types into this composer: refused")
        XCTAssertFalse(c.heldByAutoAllow(a.key), "a refusal holds nothing")
        XCTAssertTrue(act(c, b), "another row: unaffected")
        XCTAssertTrue(f.start(c.runner, a.key, AgentIsland.killArgs("a"), kill: true), "a Kill still cuts through")
        f.finish(2)
        XCTAssertTrue(act(c, a), "free once the jobs end")
        XCTAssertEqual(f.args.count, 2, "only the Restart and the Kill launched")
    }

    /// Stop all of a dir (the phone's Stop of several, one dir-wide job): every row of that dir refuses a
    /// message or Esc; a row of another dir runs.
    @MainActor
    func testAMessageOrEscWaitsOnEveryRowOfADirWhoseStopRuns() {
        let f = Fake(), a = session("a"), b = session("b"), e = session("a", dir: "/e")
        let c = controller(f, [a, b, e])
        XCTAssertTrue(f.start(c.runner, AgentSessionKey(dir: "/d", name: ""), AgentIsland.stopArgs(["a", "b"])))
        XCTAssertFalse(act(c, a))
        XCTAssertFalse(act(c, b))
        XCTAssertTrue(act(c, e), "another dir: unaffected")
        f.finish(1)
        XCTAssertTrue(act(c, b), "free once the Stop ends")
    }

    /// TYPE THROUGH for a prompt: the pause waits for the agent to go idle, which a prompt it raised blocks
    /// (dch v1.76.0 AG_WAIT); dch types nothing over a prompt, and every key of an answer re-reads the dialog.
    @MainActor
    func testAPromptAnswerStillGoesWhileTheSessionsRestartRuns() {
        let f = Fake(), a = session("a")
        let c = controller(f, [a])
        let p = AgentPrompt(question: "Proceed?", context: [], options: [AgentPromptOption(digit: 1, label: "Yes", hint: nil)])
        XCTAssertTrue(f.start(c.runner, a.key, AgentIsland.restartArgs("a")))
        XCTAssertTrue(act(c, a, prompt: p), "the answer the pause waits on goes")
        f.finish(1)
    }
}
