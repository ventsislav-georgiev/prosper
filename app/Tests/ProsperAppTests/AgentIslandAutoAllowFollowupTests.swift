import os
import XCTest
@testable import ProsperApp

/// #927: follow-ups of #755 in the Always allow path. Every dch call is a fake (FakeIO, copied from
/// AgentIslandAutoAllowTests); no row reads a real screen, sends a real key, shows the panel or posts to the Worker.
final class AgentIslandAutoAllowFollowupTests: XCTestCase {

    // MARK: - Fixtures (from AgentIslandAutoAllowTests)

    private static func dialog(_ question: String, _ options: [String], title: String = "Bash command",
                               body: [String] = ["   rm -rf .build", "   Clean the build tree"]) -> String {
        var lines = [String(repeating: "─", count: 90), " \(title)", ""] + body + ["", " \(question)"]
        for (i, o) in options.enumerated() { lines.append((i == 0 ? " ❯ " : "   ") + "\(i + 1). \(o)") }
        return lines.joined(separator: "\n")
    }

    private static let proceed = "Do you want to proceed?"
    private static let noTell = "No, and tell Claude what to do differently (esc)"
    private static let bash3 = dialog(proceed, ["Yes", "Yes, and don't ask again for rm commands in /Users/example/proj", noTell])
    /// A plan approval: never answered, left to the human.
    private static let plan = dialog("Would you like to proceed?",
                                     ["Yes, and use auto mode", "Yes, manually approve edits", "No, keep planning"],
                                     title: "Ready to code?", body: [" Here is Claude's plan:", "   Add the parser."])
    /// The idle input box: no prompt on the screen.
    private static let idle = """
    ⏺ Which file should I open?

    ──────────────────────────────────────────────────────────────────────────────────────────
    ❯
    ──────────────────────────────────────────────────────────────────────────────────────────
      ? for shortcuts
    """

    /// Screens are read in order, the last one repeating; status and sends are recorded.
    private final class FakeIO: @unchecked Sendable {
        let lock = NSLock()
        var screens: [String]
        var status = "blocked"
        var reads = 0, sends: [String] = []
        /// The next read waits on this, once.
        var gate: DispatchSemaphore?
        init(_ screens: String...) { self.screens = screens }
        func set(_ screens: [String], status: String) {
            lock.withLock { self.screens = screens; self.status = status }
        }
        var io: AgentPromptIO {
            AgentPromptIO(read: { _ in
                self.lock.withLock { () -> DispatchSemaphore? in defer { self.gate = nil }; return self.gate }?.wait()
                return self.lock.withLock {
                    self.reads += 1
                    return self.screens.count > 1 ? self.screens.removeFirst() : self.screens[0]
                }
            }, status: { _ in self.lock.withLock { self.status } },
            send: { _, d in self.lock.withLock { self.sends.append(d) } })
        }
    }

    private let key = AgentSessionKey(dir: "/d", name: "s")
    private static let claude = "0b7c2f3e-aaaa-bbbb-cccc-0123456789ab"

    private static let geometry = AgentIslandGeometry.make(
        frame: CGRect(x: 0, y: 0, width: 1512, height: 982), visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 950),
        topLeft: CGRect(x: 0, y: 950, width: 663.5, height: 32), topRight: CGRect(x: 848.5, y: 950, width: 663.5, height: 32),
        safeTop: 32)

    /// What the controller published, its timers (the `after` seam: never a real timer) and its clock.
    @MainActor private final class Rec {
        var lists: [[AgentSession]?] = []
        var timers: [@MainActor @Sendable () -> Void] = []
        var now = Date(timeIntervalSince1970: 1_000_000)
        var lastState: AgentState? { lists.last??.first { $0.name == "s" }?.state }
    }

    /// The setting is a lock the rows flip (the seam; never the operator's defaults). showsPanel off: no panel is made.
    @MainActor private func controller(_ f: FakeIO, on: OSAllocatedUnfairLock<Bool>) -> (AgentIslandController, Rec) {
        let c = AgentIslandController(), r = Rec()
        c.io = f.io
        c.showsPanel = false
        c.store = AgentIslandStore(geometry: Self.geometry)
        c.autoAllowOn = { on.withLock { $0 } }   // runs on main and on c.queue: a lock read only
        c.now = { r.now }   // main
        c.after = { _, fire in r.timers.append(fire) }   // main: stored, fired by the row
        c.onSessions = { r.lists.append($0) }   // main
        return (c, r)
    }

    private func session(_ state: AgentState) -> AgentSession {
        AgentSession(key: key, alias: "", activity: 1, state: state, agents: 0, claudeSessionID: Self.claude)
    }

    /// One poll that changed the list, as apply runs it.
    @MainActor private func tick(_ c: AgentIslandController, _ state: AgentState?) {
        c.store?.sessions = state.map { [session($0)] } ?? []
        c.checkAutoAllow()
    }

    /// Runs the queued dch work, then the main hops it posted.
    @MainActor private func drain(_ c: AgentIslandController) {
        c.queue.sync {}
        let hopped = expectation(description: "main hops")
        DispatchQueue.main.async { hopped.fulfill() }
        wait(for: [hopped], timeout: 5)
    }

    /// Calls the armed timers without draining (a read may be gated).
    @MainActor private func ring(_ r: Rec) {
        let t = r.timers
        r.timers = []
        for f in t { f() }
    }

    /// Entries in one of the controller's private stores (Mirror: no product API for the row).
    @MainActor private func entries(_ c: AgentIslandController, _ name: String) -> Int? {
        Mirror(reflecting: c).children.first { $0.label == name }.map { Mirror(reflecting: $0.value).children.count }
    }

    /// Off, then on while the check is in flight: the check is taken back (#755 INFO-1).
    @MainActor private func takeBack(_ c: AgentIslandController, _ on: OSAllocatedUnfairLock<Bool>) {
        on.withLock { $0 = false }
        c.autoAllowChanged()
        on.withLock { $0 = true }
        c.autoAllowChanged()
    }

    // MARK: - INFO-1: the rows #755 left untested

    /// A taken-back check whose session left blocked meanwhile is not checked again: the `.checking` term.
    @MainActor func testATakenBackCheckOfARowNoLongerBlockedIsNotCheckedAgain() {
        let f = FakeIO(Self.plan), gate = DispatchSemaphore(value: 0), on = OSAllocatedUnfairLock(initialState: true)
        f.gate = gate
        let (c, _) = controller(f, on: on)
        tick(c, .blocked)
        takeBack(c, on)
        tick(c, .working)   // the hold drops
        gate.signal()
        drain(c)
        drain(c)
        XCTAssertEqual(f.lock.withLock { f.reads }, 1, "no second check for a row that is not blocked")
        XCTAssertEqual(f.lock.withLock { f.sends }, [])
        XCTAssertEqual(c.published(c.store?.sessions ?? []).first?.state, .working)
    }

    /// Turning the setting off lays the island out at once (#755 INFO-2's layout()), with nothing else calling it.
    @MainActor func testTurningTheSettingOffLaysTheIslandOutAtOnce() {
        let f = FakeIO(Self.plan), on = OSAllocatedUnfairLock(initialState: true)
        let (c, _) = controller(f, on: on)
        c.store?.sessions = [session(.blocked)]   // no apply ran: nothing laid out yet
        XCTAssertFalse(c.shown)
        on.withLock { $0 = false }
        c.autoAllowChanged()
        XCTAssertTrue(c.shown, "laid out by autoAllowChanged")
        XCTAssertEqual(f.lock.withLock { f.reads }, 0)
    }

    // MARK: - INFO-4: a card click during a check

    @MainActor func testAClickDuringACheckSaysSoAndSendsNothing() throws {
        let f = FakeIO(Self.plan), gate = DispatchSemaphore(value: 0), on = OSAllocatedUnfairLock(initialState: true)
        f.gate = gate
        let (c, _) = controller(f, on: on)
        tick(c, .blocked)   // the check holds the row, its read gated
        let p = try XCTUnwrap(AgentPrompt.parse(Self.plan))
        c.answer(session(.blocked), p, try XCTUnwrap(p.options.last))   // a card drawn before the check
        XCTAssertEqual(c.store?.actions[key], AgentIslandController.answerBusyText)
        gate.signal()
        drain(c)
        XCTAssertEqual(f.lock.withLock { f.sends }, [], "the click is not sent")
        XCTAssertEqual(f.lock.withLock { f.reads }, 1, "the check's read only")
    }

    /// The other way round stays as before: a click first, the check leaves it to the human, no refusal text.
    @MainActor func testAClickBeforeTheCheckIsSentWithNoRefusal() throws {
        let f = FakeIO(Self.bash3), on = OSAllocatedUnfairLock(initialState: true)
        let (c, _) = controller(f, on: on)
        c.store?.sessions = [session(.blocked)]
        let p = try XCTUnwrap(AgentPrompt.parse(Self.bash3))
        c.answer(session(.blocked), p, try XCTUnwrap(p.options.first))
        XCTAssertTrue(c.store?.actions[key] == nil)
        tick(c, .blocked)
        drain(c)
        XCTAssertEqual(f.lock.withLock { f.sends }, ["1"], "the click's answer only")
        XCTAssertTrue(c.store?.actions[key] == nil)
    }

    // MARK: - INFO-2: a taken-back verify

    /// Answered; the verify is taken back and refuses (the same prompt still up: the loop guard); its re-check
    /// finds the answer taken (no prompt, dch working): held, no Needs input; still listed blocked after the
    /// verify delay: the Needs input goes out, and nothing is read or sent again.
    @MainActor func testATakenBackVerifyWhoseAnswerTookPostsNoNeedsInput() {
        let f = FakeIO(Self.bash3), gate = DispatchSemaphore(value: 0), on = OSAllocatedUnfairLock(initialState: true)
        let (c, r) = controller(f, on: on)
        tick(c, .blocked)
        drain(c)
        XCTAssertEqual(f.lock.withLock { f.sends }, ["1"])
        f.set([Self.bash3, Self.idle], status: "working")
        f.lock.withLock { f.gate = gate }
        ring(r)   // the verify, its read gated
        takeBack(c, on)
        XCTAssertEqual(r.lastState, .working)
        gate.signal()
        drain(c)   // the verify: .human (loop guard), taken back: re-checked
        drain(c)   // the re-check: the answer took
        XCTAssertEqual(r.lastState, .working, "no Needs input for an answered prompt")
        XCTAssertEqual(c.published(c.store?.sessions ?? []).first?.state, .working)
        XCTAssertEqual(r.timers.count, 1)
        let reads = f.lock.withLock { f.reads }
        ring(r)
        drain(c)
        XCTAssertEqual(r.lastState, .blocked, "still listed blocked: its Needs input")
        XCTAssertEqual(f.lock.withLock { f.reads }, reads, "nothing read again")
        XCTAssertEqual(f.lock.withLock { f.sends }, ["1"])
        XCTAssertTrue(r.timers.isEmpty)
    }

    /// The same order with dch still saying blocked: a real Needs input, published at once.
    @MainActor func testATakenBackVerifyStillBlockedPostsNeedsInputAtOnce() {
        let f = FakeIO(Self.bash3), gate = DispatchSemaphore(value: 0), on = OSAllocatedUnfairLock(initialState: true)
        let (c, r) = controller(f, on: on)
        tick(c, .blocked)
        drain(c)
        f.set([Self.bash3, Self.idle], status: "blocked")
        f.lock.withLock { f.gate = gate }
        ring(r)
        takeBack(c, on)
        gate.signal()
        drain(c)
        drain(c)
        XCTAssertEqual(r.lastState, .blocked)
        XCTAssertEqual(c.published(c.store?.sessions ?? []).first?.state, .blocked)
        XCTAssertTrue(r.timers.isEmpty)
        XCTAssertEqual(f.lock.withLock { f.sends }, ["1"])
    }

    // MARK: - INFO-5: the per-session stores

    @MainActor func testTheStoresOfAGoneSessionArePruned() {
        let f = FakeIO(Self.bash3), on = OSAllocatedUnfairLock(initialState: true)
        let (c, r) = controller(f, on: on)
        tick(c, .blocked)
        drain(c)
        XCTAssertEqual(entries(c, "allowed"), 1)
        XCTAssertEqual(entries(c, "rereadGen"), 1)
        tick(c, nil)   // gone from the list
        XCTAssertEqual(entries(c, "rereadGen"), 0, "no hold, no generation")
        XCTAssertEqual(entries(c, "allowed"), 1, "the loop guard's window is still open")
        r.now += AgentIslandController.loopWindow
        tick(c, nil)
        XCTAssertEqual(entries(c, "allowed"), 0)
    }

    /// A row missing from one list and back inside the window keeps its loop guard.
    @MainActor func testTheLoopGuardOutlivesARowMissingFromAList() {
        let f = FakeIO(Self.bash3), on = OSAllocatedUnfairLock(initialState: true)
        let (c, r) = controller(f, on: on)
        tick(c, .blocked)
        drain(c)
        tick(c, nil)
        r.now += AgentIslandController.loopWindow - 1
        tick(c, nil)
        tick(c, .blocked)
        drain(c)
        XCTAssertEqual(f.lock.withLock { f.sends }, ["1"], "the same prompt back: not again")
        XCTAssertEqual(r.lastState, .blocked)
    }

    /// A verify timer armed before its session left the list is a no-op once the session is back and answered again.
    @MainActor func testAStaleTimerOfAPrunedSessionIsANoOp() {
        let f = FakeIO(Self.bash3), on = OSAllocatedUnfairLock(initialState: true)
        let (c, r) = controller(f, on: on)
        tick(c, .blocked)
        drain(c)
        let stale = r.timers
        r.timers = []
        tick(c, nil)
        r.now += AgentIslandController.loopWindow + 1
        tick(c, .blocked)
        drain(c)
        XCTAssertEqual(f.lock.withLock { f.sends }, ["1", "1"])
        let reads = f.lock.withLock { f.reads }
        for t in stale { t() }
        drain(c)
        XCTAssertEqual(f.lock.withLock { f.reads }, reads, "the old timer starts no re-read")
        XCTAssertEqual(r.timers.count, 1)
    }
}
