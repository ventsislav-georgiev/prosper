import os
import XCTest
@testable import ProsperApp

/// #1133 (QA #849 INFO-3): while both dch list forms fail, AgentIsland.list keeps a dir's rows from the last
/// list (#486). A kept row keeps its claudeSessionID (the Agents window's transcript mapping) but is not fresh,
/// and Always allow answers fresh rows only: a kept row is the human's (its card, Needs input) until a list
/// answers again. Every dch call is a fake recorder: no test reads a real screen, sends a real key or runs dch.
final class AgentIslandKeptRowsTests: XCTestCase {

    private static func dialog(_ body: String) -> String {
        [String(repeating: "─", count: 90), " Bash command", "", "   \(body)", "   Clean the build tree", "",
         " Do you want to proceed?", " ❯ 1. Yes", "   2. No, and tell Claude what to do differently (esc)"]
            .joined(separator: "\n")
    }
    private static let screen = dialog("rm -rf .build")
    private static let otherScreen = dialog("swift build")
    private static let sid = "0b7c2f3e-aaaa-bbbb-cccc-0123456789ab"
    private static let path = "/Users/example/.claude/projects/p/\(sid).jsonl"
    private static let dir = "/Users/example/.local/state/dch"
    private let key = AgentSessionKey(dir: AgentIslandKeptRowsTests.dir, name: "api")

    /// dch 1.60's --ls-json row naming one Claude Code in "api".
    private static func json(_ state: String = "blocked") -> Data {
        Data((#"[{"name":"api","alias":"","activity_epoch":1,"state":"\#(state)","version":"1.60.0","agents":0,"#
            + #""claude_session_id":"\#(sid)","transcript_path":"\#(path)"}]"#).utf8)
    }

    /// The row as a good list gives it; `fresh: false` as AgentIsland.list keeps it.
    private func row(fresh: Bool = true, activity: TimeInterval = 1) -> AgentSession {
        var s = AgentSession(key: key, alias: "", activity: activity, state: .blocked, agents: 0, version: "1.60.0",
                             claudeSessionID: Self.sid, transcriptPath: Self.path)
        s.fresh = fresh
        return s
    }

    // MARK: - The list (runs on the island's poll queue: nonisolated, called here from a real queue)

    private final class Box<T>: @unchecked Sendable { var value: T?; init() {} }

    /// Runs `body` on a real serial queue (never the main thread) and waits for it, with a ceiling.
    private func onQueue<T>(_ body: @escaping @Sendable () -> T) -> T? {
        let box = Box<T>(), done = expectation(description: "ran on the queue")
        DispatchQueue(label: "test.agentisland.kept").async {
            XCTAssertFalse(Thread.isMainThread)
            box.value = body()
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
        return box.value
    }

    /// Done-condition 1: both forms fail -> the dir's last rows, ids kept (the window's mapping), marked not fresh.
    func testBothFormsFailingKeepsTheRowsWithTheirIdsMarkedNotFresh() throws {
        let good = row(), other = AgentSession(key: AgentSessionKey(dir: "/Users/example/other", name: "web"),
                                               alias: "", activity: 1, state: .idle, agents: 0)
        let calls = OSAllocatedUnfairLock(initialState: [[String]]())
        let kept = try XCTUnwrap(onQueue {
            AgentIsland.list(dirs: [Self.dir], keeping: [good, other]) { args, _ in
                calls.withLock { $0.append(args) }
                return nil   // both forms timed out
            }
        })
        XCTAssertEqual(calls.withLock { $0 }, [["--ls-json"], ["-lj"]])
        XCTAssertEqual(kept.count, 1, "this dir's row only")
        let k = try XCTUnwrap(kept.first)
        XCTAssertFalse(k.fresh, "kept: not fresh")
        XCTAssertEqual(k.claudeSessionID, Self.sid, "the id stays")
        XCTAssertEqual(k.transcriptPath, Self.path)
        XCTAssertEqual(AgentSidebar.source(k), AgentSidebar.source(good), "the window's transcript mapping does not blank")
        var expected = good
        expected.fresh = false
        XCTAssertEqual(kept, [expected], "every other field as last listed")
        // Equatable: the first kept list differs from the last good one, also with only ages compared away
        // (#768's collapsed path), so it is applied once and checkAutoAllow runs on it.
        XCTAssertNotEqual(k, good)
        XCTAssertFalse(AgentIsland.onlyActivityMoved(kept, [good]))
        // Kept again while it keeps failing: still not fresh.
        let again = onQueue { AgentIsland.list(dirs: [Self.dir], keeping: kept) { _, _ in nil } }
        XCTAssertEqual(again, [expected])
    }

    /// A list where one form works is fresh, and clears the mark of a kept row; one that answers empty is not kept.
    func testAListWhereOneFormWorksIsFreshAndClearsTheMark() throws {
        let kept = [row(fresh: false)]
        let json = try XCTUnwrap(onQueue { AgentIsland.list(dirs: [Self.dir], keeping: kept) { _, _ in Self.json() } })
        XCTAssertEqual(json.count, 1)
        XCTAssertEqual(json.first?.fresh, true, "--ls-json answered")
        XCTAssertEqual(json.first?.claudeSessionID, Self.sid)
        let lj = try XCTUnwrap(onQueue {
            AgentIsland.list(dirs: [Self.dir], keeping: kept) { args, _ in args == ["-lj"] ? Data("api\t\t1\n".utf8) : nil }
        })
        XCTAssertEqual(lj.count, 1)
        XCTAssertEqual(lj.first?.fresh, true, "--ls-json timed out, -lj answered")
        XCTAssertTrue(lj.first?.claudeSessionID == nil, "an -lj row names no Claude Code")
        let empty = onQueue { AgentIsland.list(dirs: [Self.dir], keeping: kept) { _, _ in Data() } }
        XCTAssertEqual(empty, [], "dch answered with no rows: gone, not kept")
    }

    /// The poller on its own queue: the kept list goes out once (marked), not again while it keeps failing,
    /// and a list that answers again goes out fresh.
    func testThePollerPublishesTheMarkOnceAndClearsItOnAFreshList() throws {
        final class Dch: @unchecked Sendable {
            let lock = NSLock()
            var out: Data?, now: TimeInterval = 1_000_000
        }
        let dir = tempDir(), dch = Dch()
        FileManager.default.createFile(atPath: dir.appendingPathComponent("api.sock").path, contents: nil)
        let path = dir.path
        let json = Self.json()
        dch.out = json
        let p = AgentIslandPoller(now: { dch.lock.withLock { dch.now } }, dirs: { [path] }, list: {
            AgentIsland.list(dirs: $0, keeping: $1) { _, _ in dch.lock.withLock { dch.out } }
        })
        func tick(_ out: Data?) -> [AgentSession]? {
            dch.lock.withLock { dch.out = out; dch.now += AgentPollGate.backstop }
            return onQueue { p.tick() } ?? nil
        }
        let first = tick(json)
        XCTAssertEqual(first?.count, 1)
        XCTAssertEqual(first?.first?.fresh, true)
        let kept = tick(nil)
        XCTAssertEqual(kept?.count, 1, "both forms failed: the row is kept, published once")
        XCTAssertEqual(kept?.first?.fresh, false)
        XCTAssertEqual(kept?.first?.claudeSessionID, Self.sid)
        XCTAssertTrue(tick(nil) == nil, "still failing: no change")
        let back = tick(json)
        XCTAssertEqual(back?.count, 1, "a fresh list goes out")
        XCTAssertEqual(back?.first?.fresh, true)
    }

    /// The phone's copies (the Remote Terminal list frame, Live status) carry no new key for a kept row.
    func testThePhoneCopiesOfAKeptRowCarryNoNewKey() throws {
        var s = AgentSession(key: AgentSessionKey(dir: Self.dir, name: "api"), alias: "API", activity: 1, state: .blocked,
                             agents: 1, version: "1.60.0", claudeSessionID: Self.sid, transcriptPath: Self.path,
                             cwd: "/Users/example/api")
        s.fresh = false
        let cache = try XCTUnwrap(DchWatchHub.cache(island: [s], dirs: [Self.dir], remote: Self.dir))
        let frame = try XCTUnwrap(JSONSerialization.jsonObject(with: DchFrame.listPayload(cache.rows)) as? [[String: Any]])
        XCTAssertEqual(frame.count, 1)
        let frameKeys = try XCTUnwrap(frame.first).keys
        XCTAssertEqual(Set(frameKeys), ["name", "alias", "state", "agents", "cwd"])
        let wire = try JSONEncoder().encode(LiveStatusPublisher.wire([s]))
        let live = try XCTUnwrap(JSONSerialization.jsonObject(with: wire) as? [[String: Any]])
        XCTAssertEqual(live.count, 1)
        let liveKeys = try XCTUnwrap(live.first).keys
        XCTAssertEqual(Set(liveKeys), ["name", "alias", "state", "agents"])
    }

    // MARK: - The controller (main)

    /// The keystroke recorder: screens read, keys "sent" (recorded only).
    private final class FakeIO: @unchecked Sendable {
        let lock = NSLock()
        var screen: String
        var reads = 0, statuses = 0, sends: [String] = []
        /// The next read waits on this once (a check still on the queue); bounded, so a slip never hangs.
        var gate: DispatchSemaphore?
        init(_ screen: String) { self.screen = screen }
        var io: AgentPromptIO {
            AgentPromptIO(read: { _ in
                _ = self.lock.withLock { () -> DispatchSemaphore? in defer { self.gate = nil }; return self.gate }?
                    .wait(timeout: .now() + 10)
                return self.lock.withLock { self.reads += 1; return self.screen }
            }, status: { _ in self.lock.withLock { self.statuses += 1 }; return "blocked" },
               send: { _, d in self.lock.withLock { self.sends.append(d) } })
        }
        var sent: [String] { lock.withLock { sends } }
        var readCount: Int { lock.withLock { reads } }
        /// A check's send ask (answer() re-reads --status right before the key); no card read asks it.
        var statusCount: Int { lock.withLock { statuses } }
    }

    @MainActor private final class Rec {
        var lists: [[AgentSession]?] = []
        var timers: [@MainActor @Sendable () -> Void] = []
        var lastState: AgentState? { lists.last??.first { $0.name == "api" }?.state }
    }

    @MainActor private func controller(_ f: FakeIO) -> (AgentIslandController, Rec) {
        let c = AgentIslandController(), r = Rec()
        c.io = f.io
        c.showsPanel = false
        c.store = AgentIslandStore(geometry: AgentWindowD1Tests.geometry)
        c.store?.expanded = true
        c.autoAllowOn = { true }
        c.controlDch = { nil }   // no dch of its own answers: Prosper decides
        c.now = { Date(timeIntervalSince1970: 1_000_000) }
        c.after = { _, fire in r.timers.append(fire) }
        c.onSessions = { r.lists.append($0) }
        return (c, r)
    }

    /// One list change, as apply runs it (the check, then the cards); what goes to the phone.
    @MainActor @discardableResult
    private func tick(_ c: AgentIslandController, _ s: AgentSession) -> AgentState? {
        c.store?.sessions = [s]
        c.checkAutoAllow()
        c.refreshCards()
        return c.published(c.store?.sessions ?? []).first?.state
    }

    @MainActor private func drain(_ c: AgentIslandController) {
        for _ in 0..<2 {
            c.queue.sync {}
            let hopped = expectation(description: "main hops")
            DispatchQueue.main.async { hopped.fulfill() }
            wait(for: [hopped], timeout: 5)
        }
    }

    /// Done-condition 2: a kept row with the id is not checked: Needs input and its card at once, as with the
    /// setting off; a print of another prompt meanwhile only redraws the card (no check, no key).
    @MainActor func testAKeptRowIsNotCheckedAndKeepsItsCardAndNeedsInput() throws {
        let f = FakeIO(Self.screen), (c, r) = controller(f)
        XCTAssertEqual(tick(c, row(fresh: false)), .blocked, "Needs input goes out at once")
        XCTAssertFalse(c.heldByAutoAllow(key), "no hold")
        drain(c)
        XCTAssertEqual(f.sent, [], "no key")
        XCTAssertEqual(f.statusCount, 0, "no check")
        XCTAssertEqual(f.readCount, 1, "only the card's read")
        XCTAssertEqual(c.store?.cards[key], .prompt(try XCTUnwrap(AgentPrompt.parse(Self.screen))), "its card")
        XCTAssertTrue(c.store?.actions[key] == nil, "not \"Allowed automatically\"")
        XCTAssertTrue(r.timers.isEmpty)
        f.lock.withLock { f.screen = Self.otherScreen }
        XCTAssertEqual(tick(c, row(fresh: false, activity: 2)), .blocked)
        drain(c)
        XCTAssertEqual(f.statusCount, 0, "the print started no check")
        XCTAssertEqual(f.sent, [])
        XCTAssertFalse(c.heldByAutoAllow(key))
        XCTAssertEqual(c.store?.cards[key], .prompt(try XCTUnwrap(AgentPrompt.parse(Self.otherScreen))), "the new card")
    }

    /// A check already on the queue when the listing starts failing is refused at its send: left to the human.
    @MainActor func testACheckWaitingWhenTheListingFailsIsRefusedAtTheSend() throws {
        let f = FakeIO(Self.screen), (c, r) = controller(f)
        let gate = DispatchSemaphore(value: 0)
        f.lock.withLock { f.gate = gate }
        XCTAssertEqual(tick(c, row()), .working, "checking")
        tick(c, row(fresh: false, activity: 2))   // the next list: both forms failed
        gate.signal()
        drain(c)
        XCTAssertEqual(f.statusCount, 1, "the send was asked")
        XCTAssertEqual(f.sent, [], "and refused: the row is not fresh")
        XCTAssertEqual(r.lastState, .blocked, "Needs input")
        XCTAssertFalse(c.heldByAutoAllow(key))
        XCTAssertEqual(c.store?.cards[key], .prompt(try XCTUnwrap(AgentPrompt.parse(Self.screen))), "its card")
    }

    /// Done-condition 3: once a list answers again, the same row is answerable.
    @MainActor func testAFreshListAfterwardsMakesItAnswerableAgain() {
        let f = FakeIO(Self.screen), (c, _) = controller(f)
        XCTAssertEqual(tick(c, row(fresh: false)), .blocked)
        drain(c)
        XCTAssertEqual(f.sent, [])
        XCTAssertEqual(tick(c, row(activity: 2)), .working, "fresh: checked")
        drain(c)
        XCTAssertEqual(f.sent, ["1"])
        XCTAssertEqual(c.store?.actions[key], AgentIslandController.autoAllowedText)
    }

    /// Rider R1133-1 (QA #857 INFO-1): Way 3 (#755) — a check orphaned by an off-toggle and taken back by an
    /// on-toggle — comes back while the listing fails, and the #935 gate turns its re-run away. The row's
    /// inFlight is released: no hold, and a click (the window's action) is taken at once.
    @MainActor func testInFlightIsFreeAfterARefusedWay3() {
        let f = FakeIO(Self.screen), (c, r) = controller(f)
        let on = OSAllocatedUnfairLock(initialState: true)
        c.autoAllowOn = { on.withLock { $0 } }
        let gate = DispatchSemaphore(value: 0)
        f.lock.withLock { f.gate = gate }
        tick(c, row())
        on.withLock { $0 = false }
        c.autoAllowChanged()   // the check is orphaned
        on.withLock { $0 = true }
        c.autoAllowChanged()   // and taken back
        XCTAssertTrue(c.heldByAutoAllow(key), "held again")
        tick(c, row(fresh: false, activity: 2))
        gate.signal()
        drain(c)
        XCTAssertEqual(f.statusCount, 1, "the orphaned check's send ask only: refused, not run again")
        XCTAssertEqual(f.sent, [])
        XCTAssertEqual(r.lastState, .blocked, "Needs input")
        XCTAssertFalse(c.heldByAutoAllow(key), "inFlight released")
        let clicked = expectation(description: "the click ran")
        let taken = c.humanAction(row(fresh: false, activity: 2), prompt: nil, run: { _ in 1 }) { _ in clicked.fulfill() }
        XCTAssertTrue(taken, "the click is taken: nothing holds the row")
        if taken { wait(for: [clicked], timeout: 10) }
        XCTAssertEqual(f.sent, [])
    }
}
