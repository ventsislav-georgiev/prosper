import os
import XCTest
@testable import ProsperApp

/// #927 round 2 (N927-a, N927-b): a click refused because the session is busy says so over "Allowed automatically",
/// and leaves an in-progress text alone. Text on a row only. Every dch call is a fake: the runner's launch never starts
/// a process (a semaphore wait), the prompt reads are a recording fake; no panel is made, no event is posted.
final class AgentIslandAutoAllowRefusalTests: XCTestCase {

    private let key = AgentSessionKey(dir: "/Users/example", name: "work")

    private static let geometry = AgentIslandGeometry.make(
        frame: CGRect(x: 0, y: 0, width: 1512, height: 982), visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 950),
        topLeft: CGRect(x: 0, y: 950, width: 663.5, height: 32), topRight: CGRect(x: 848.5, y: 950, width: 663.5, height: 32),
        safeTop: 32)

    private static let plan = [String(repeating: "─", count: 90), " Ready to code?", "", " Here is Claude's plan:", "   Add the parser.", "",
                               " Would you like to proceed?", " ❯ 1. Yes, and use auto mode", "   2. Yes, manually approve edits",
                               "   3. No, keep planning"].joined(separator: "\n")

    /// A launch that waits on `open`: a job on the runner stays running until the row's teardown opens it.
    private final class Hang: @unchecked Sendable {
        let open = DispatchSemaphore(value: 0)
        func runner() -> DchActionRunner {
            DchActionRunner(launch: { _, _, _, _, onPid, _ in
                onPid(4243)   // the runner's queue; a semaphore wait only
                self.open.wait()
                return (0, Data())
            }, signal: { _ in })
        }
    }

    /// The prompt reads: the screen is the plan, the first read may wait on `gate`; sends are recorded.
    private final class FakeIO: @unchecked Sendable {
        let lock = NSLock()
        var gate: DispatchSemaphore?
        var sends: [String] = []
        var io: AgentPromptIO {
            AgentPromptIO(read: { _ in
                self.lock.withLock { () -> DispatchSemaphore? in defer { self.gate = nil }; return self.gate }?.wait()
                return AgentIslandAutoAllowRefusalTests.plan
            }, status: { _ in "blocked" }, send: { _, d in self.lock.withLock { self.sends.append(d) } })
        }
    }

    private func session() -> AgentSession {
        AgentSession(key: key, alias: "", activity: 1, state: .blocked, agents: 0, version: "1.28.2",
                     claudeSessionID: "0b7c2f3e-aaaa-bbbb-cccc-0123456789ab")
    }

    /// A controller on the fake runner with one live session, a fake control binary (never run) and the island open.
    @MainActor private func controller(_ f: FakeIO = FakeIO(), on: Bool = false) -> (AgentIslandController, Hang) {
        let c = AgentIslandController(), h = Hang()
        c.showsPanel = false
        c.io = f.io
        c.runner = h.runner()
        c.autoAllowOn = { on }   // runs on main and on c.queue: a constant
        c.after = { _, _ in }   // main: the verify timers never fire
        let store = AgentIslandStore(geometry: Self.geometry)
        store.sessions = [session()]
        store.controlDch = DchCommand.Binary(path: "/fake/dch", version: [1, 28, 2])
        store.expanded = true
        c.store = store
        addTeardownBlock { for _ in 0..<4 { h.open.signal() } }
        return (c, h)
    }

    /// The session is busy: a job of the fake runner holds its key.
    @MainActor private func hold(_ c: AgentIslandController) {
        XCTAssertTrue(c.runner.start(key, path: "/fake/dch", args: ["--revive", "work"], env: { [:] }) { _ in })
    }

    // MARK: - Over "Allowed automatically"

    @MainActor func testARefusedRestartClickSaysSoOverAllowedAutomatically() {
        let (c, _) = controller()
        hold(c)
        c.store?.actions[key] = "Allowed automatically"
        XCTAssertFalse(c.restart(session(), sayBusy: true))
        XCTAssertEqual(c.store?.actions[key], "Restart not run: another job is running")
    }

    @MainActor func testARefusedStopClickSaysSoOverAllowedAutomatically() {
        let (c, _) = controller()
        hold(c)
        c.store?.actions[key] = "Allowed automatically"
        XCTAssertFalse(c.stop(session(), sayBusy: true))
        XCTAssertEqual(c.store?.actions[key], "Stop not run: another job is running")
    }

    @MainActor func testARefusedRenameSaysSoOverAllowedAutomatically() {
        let (c, _) = controller()
        hold(c)
        c.store?.actions[key] = "Allowed automatically"
        XCTAssertFalse(c.rename(session(), alias: "api"))
        XCTAssertEqual(c.store?.actions[key], "Rename not run: another job is running")
    }

    @MainActor func testARefusedMessageClickSaysSoOverAllowedAutomatically() {
        let (c, _) = controller()
        hold(c)
        c.store?.actions[key] = "Allowed automatically"
        c.askMessage(session())
        XCTAssertEqual(c.store?.actions[key], "Message not sent: another job is running")
    }

    @MainActor func testARefusedAnswerClickSaysSoOverAllowedAutomaticallyAndSendsNothing() throws {
        let f = FakeIO(), gate = DispatchSemaphore(value: 0)
        f.gate = gate
        let (c, _) = controller(f, on: true)
        c.store?.sessions = [session()]
        c.checkAutoAllow()   // the check holds the row, its read gated
        c.store?.actions[key] = "Allowed automatically"
        let p = try XCTUnwrap(AgentPrompt.parse(Self.plan))
        c.answer(session(), p, try XCTUnwrap(p.options.last))
        XCTAssertEqual(c.store?.actions[key], "Answer not sent: another job is running")
        gate.signal()
        c.queue.sync {}
        XCTAssertEqual(f.lock.withLock { f.sends }, [], "the click is not sent")
    }

    // MARK: - An in-progress text stays (unchanged against the parent)

    @MainActor func testARefusedRestartClickLeavesARunningText() {
        let (c, _) = controller()
        hold(c)
        c.store?.actions[key] = "Restarting…"
        XCTAssertFalse(c.restart(session(), sayBusy: true))
        XCTAssertEqual(c.store?.actions[key], "Restarting…")
    }

    @MainActor func testARefusedStopClickLeavesARunningText() {
        let (c, _) = controller()
        hold(c)
        c.store?.actions[key] = "Stopping…"
        XCTAssertFalse(c.stop(session(), sayBusy: true))
        XCTAssertEqual(c.store?.actions[key], "Stopping…")
    }

    @MainActor func testARefusedRenameLeavesARunningText() {
        let (c, _) = controller()
        hold(c)
        c.store?.actions[key] = "Restarting…"
        XCTAssertFalse(c.rename(session(), alias: "api"))
        XCTAssertEqual(c.store?.actions[key], "Restarting…")
    }

    @MainActor func testARefusedMessageClickLeavesARunningText() {
        let (c, _) = controller()
        hold(c)
        c.store?.actions[key] = "Sending…"
        c.askMessage(session())
        XCTAssertEqual(c.store?.actions[key], "Sending…")
    }

    @MainActor func testARefusedAnswerClickLeavesARunningText() throws {
        let f = FakeIO(), gate = DispatchSemaphore(value: 0)
        f.gate = gate
        let (c, _) = controller(f, on: true)
        c.store?.sessions = [session()]
        c.checkAutoAllow()
        c.store?.actions[key] = "Restarting…"
        let p = try XCTUnwrap(AgentPrompt.parse(Self.plan))
        c.answer(session(), p, try XCTUnwrap(p.options.last))
        XCTAssertEqual(c.store?.actions[key], "Restarting…")
        gate.signal()
        c.queue.sync {}
        XCTAssertEqual(f.lock.withLock { f.sends }, [])
    }

    // MARK: - The moved constant

    func testTheAutoAllowedTextIsWordedAsShown() {
        XCTAssertEqual(AgentIsland.autoAllowedText, "Allowed automatically")
    }
}
