import AppKit
import XCTest
@testable import ProsperApp

/// #847 P1d (#1369): the controller's sayFirst, a new session's first message typed with `--say`. No test runs dch:
/// the io is a fake recording every read and say, the pause a recorder that moves an injected clock (no real wait),
/// and no panel is built or shown.
final class AgentIslandSayFirstTests: XCTestCase {
    private let notched = AgentIslandGeometry.make(
        frame: CGRect(x: 0, y: 0, width: 1512, height: 982), visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 950),
        topLeft: CGRect(x: 0, y: 950, width: 663.5, height: 32), topRight: CGRect(x: 848.5, y: 950, width: 663.5, height: 32),
        safeTop: 32)
    private let key = AgentSessionKey(dir: "/tmp/dch-test", name: "api")
    /// A screen with no prompt (refusal nil), one with a plan prompt below any composer (refusal promptShown).
    private static let idle = "Example screen"
    private static let prompt = "  Claude has written up a plan"

    private static func reply(_ result: String, _ reason: String? = nil) -> String {
        reason.map { "{\"result\":\"\(result)\",\"reason\":\"\($0)\"}" } ?? "{\"result\":\"\(result)\"}"
    }

    /// The fake dch: each read takes the next screen and each say the next reply (the last one repeats); the pause
    /// moves the clock by what it was asked.
    private final class FirstIO: @unchecked Sendable {
        let lock = NSLock()
        var screens: [String]
        var replies: [String]
        var noMirror = false
        var reads = 0
        var says: [String] = []
        var pauses: [TimeInterval] = []
        var t: TimeInterval = 0
        /// #1384: hooks run off main, outside the lock (@Sendable, so they never inherit the test's main actor); the
        /// gate parks the first say until released (bounded), as a say that takes a while.
        var onSay: (@Sendable () -> Void)?
        var onPause: (@Sendable () -> Void)?
        var gate: DispatchSemaphore?
        var held: [Bool] = []
        var started: [Bool] = []
        var saysAt = -1, readsAt = -1
        /// The thread of each say and each pause: one run is one thread (firstRun is synchronous), so they tell runs apart.
        var sayers: [UInt32] = [], pausers: [UInt32] = []
        init(screens: [String] = [AgentIslandSayFirstTests.idle], replies: [String]) {
            self.screens = screens
            self.replies = replies
        }
        private static func next(_ a: inout [String]) -> String { a.count > 1 ? a.removeFirst() : a.first ?? "" }
        var io: AgentPromptIO {
            AgentPromptIO(read: { _ in self.lock.withLock { self.reads += 1; return Self.next(&self.screens) } },
                          status: { _ in self.lock.withLock { XCTFail("sayFirst never asks the status"); return "" } },
                          send: { _, _ in XCTFail("sayFirst never uses --send") },
                          say: { _, text in
                              let (r, g, hook) = self.lock.withLock { () -> (String, DispatchSemaphore?, (@Sendable () -> Void)?) in
                                  self.says.append(text)
                                  return (Self.next(&self.replies), self.says.count == 1 ? self.gate : nil, self.onSay)
                              }
                              hook?()
                              _ = g?.wait(timeout: .now() + 10)
                              return r
                          },
                          noMirror: { _ in self.lock.withLock { self.noMirror } })
        }
        var counts: (reads: Int, says: Int, pauses: Int) { lock.withLock { (reads, says.count, pauses.count) } }
    }

    @MainActor
    private func controller(_ f: FirstIO) -> AgentIslandController {
        let c = AgentIslandController()
        c.showsPanel = false
        c.monitorClicks = { _ in nil }
        c.controlDch = { nil }
        c.io = f.io
        c.store = AgentIslandStore(geometry: notched)
        c.firstPause = { d in
            f.lock.withLock { f.pauses.append(d); f.t += d }
            f.onPause?()
        }
        c.firstClock = { f.lock.withLock { Date(timeIntervalSinceReferenceDate: f.t) } }
        return c
    }

    /// From a hook (off main): the controller's answer on main. The test thread is in wait(for:), serving main.
    private nonisolated static func onMain(_ b: @MainActor () -> Bool) -> Bool {
        DispatchQueue.main.sync { MainActor.assumeIsolated(b) }
    }

    /// A runner whose job on `key` runs until `park` is signalled (bounded); no process, no signal.
    private static func parkedRunner(_ park: DispatchSemaphore?) -> DchActionRunner {
        DchActionRunner(bound: 60, launch: { _, _, _, _, _, _ in
            _ = park?.wait(timeout: .now() + 10)
            return (0, Data())
        }, signal: { _ in })
    }

    /// Runs sayFirst to its end; `then` must run exactly once (an over-fulfilled expectation fails the test).
    /// #1877: returns what `then` got (nil: sent, else the reason).
    @MainActor @discardableResult
    private func sayFirst(_ c: AgentIslandController, _ text: String) -> String? {
        let done = expectation(description: "then")
        var got: String?
        c.sayFirst(key, text) { got = $0; done.fulfill() }
        wait(for: [done], timeout: 10)
        return got
    }

    /// T12: skipped not_claude, no_screen and prompt typed nothing, so each waits one step; ok on the fourth call.
    /// The line is cleared, nothing is kept, the text went out as the composer sends it (control characters dropped,
    /// trimmed).
    @MainActor
    func testSkipRoundsWaitThenOkClearsTheLine() {
        let f = FirstIO(replies: [Self.reply("skipped", "not_claude"), Self.reply("skipped", "no_screen"),
                                  Self.reply("skipped", "prompt"), Self.reply("ok")])
        let c = controller(f)
        let sent = sayFirst(c, "  Example task\r\n")
        XCTAssertTrue(sent == nil, "#1877: sent: `then` gets nil")
        XCTAssertEqual(f.lock.withLock { f.says }, Array(repeating: "Example task", count: 4))
        XCTAssertEqual(f.lock.withLock { f.pauses }, [2, 2, 2])
        XCTAssertTrue(c.store?.actions[key] == nil, "ok clears the line")
        XCTAssertTrue(c.unsentFirst[key] == nil)
    }

    /// T13: a prompt on the read (and an empty read from a dch with a mirror: unconfirmed) refuses that round: no
    /// say call, one step; the say goes only after a clean read.
    @MainActor
    func testAPromptOnTheReadMeansNoSayThatRound() {
        let f = FirstIO(screens: [Self.prompt, "", Self.idle], replies: [Self.reply("ok")])
        let c = controller(f)
        sayFirst(c, "Example task")
        let n = f.counts
        XCTAssertEqual(n.reads, 3)
        XCTAssertEqual(n.says, 1, "no say over the prompt or the empty read")
        XCTAssertEqual(f.lock.withLock { f.pauses }, [2, 2])
        XCTAssertTrue(c.store?.actions[key] == nil)
    }

    /// T14: a failed draft (draft_left, not_submitted, withdrawn) or no reply at all: exactly one say call, NO retry
    /// (the text may sit in the composer or have gone out), the line names the mapped reason, the text is kept for
    /// the window, `then` still runs.
    @MainActor
    func testAFailedSayIsNeverRetriedAndTheTextIsKept() {
        let cases: [(String, String)] = [(Self.reply("failed", "draft_left"), AgentWindowText.draftLeft),
                                         (Self.reply("failed", "not_submitted"), AgentWindowText.notSubmitted),
                                         (Self.reply("failed", "withdrawn"), AgentWindowText.notSent),
                                         ("", AgentWindowText.unconfirmed)]
        for (reply, why) in cases {
            let f = FirstIO(replies: [reply, Self.reply("ok")])
            let c = controller(f)
            let got = sayFirst(c, "Example task")
            XCTAssertEqual(got, why, "#1877: `then` gets the mapped reason: \(reply)")
            XCTAssertEqual(f.counts.says, 1, "no retry: \(reply)")
            XCTAssertEqual(f.counts.pauses, 0, reply)
            XCTAssertEqual(c.store?.actions[key], AgentWindowText.firstNotSent(why), reply)
            XCTAssertEqual(c.unsentFirst[key], "Example task", reply)
        }
    }

    /// #1963: a failed first message starting with "!" says the shell line (dch takes it back out); a plain one keeps notSubmitted.
    @MainActor
    func testAFailedBangFirstMessageSaysShellNotRun() {
        for (text, why) in [("!ls", AgentWindowText.shellNotRun), ("ls", AgentWindowText.notSubmitted)] {
            let f = FirstIO(replies: [Self.reply("failed", "not_submitted")])
            let c = controller(f)
            XCTAssertEqual(sayFirst(c, text), why, text)
            XCTAssertEqual(f.counts.says, 1, text)
        }
    }

    /// T15: skipped draft (someone typed into the composer): one call, then it fails, never typing over it. dch-lite
    /// (an empty read and no mirror): no say call at all, it fails at once.
    @MainActor
    func testASkippedDraftFailsAndLiteFailsAtOnce() {
        let f = FirstIO(replies: [Self.reply("skipped", "draft"), Self.reply("ok")])
        let c = controller(f)
        let draft = sayFirst(c, "Example task")
        XCTAssertEqual(draft, AgentWindowText.draft, "#1877: the draft reason, not another failure's")
        XCTAssertEqual(f.counts.says, 1)
        XCTAssertEqual(c.store?.actions[key], AgentWindowText.firstNotSent(AgentWindowText.draft))

        let lite = FirstIO(screens: [""], replies: [Self.reply("ok")])
        lite.noMirror = true
        let d = controller(lite)
        let lit = sayFirst(d, "Example task")
        XCTAssertEqual(lit, AgentWindowText.noScreen, "#1877")
        let n = lite.counts
        XCTAssertEqual(n.says, 0, "dch-lite: nothing is typed")
        XCTAssertEqual(n.reads, 1)
        XCTAssertEqual(n.pauses, 0, "at once")
        XCTAssertEqual(d.store?.actions[key], AgentWindowText.firstNotSent(AgentWindowText.noScreen))
        XCTAssertEqual(d.unsentFirst[key], "Example task")
    }

    /// T16: 90 s of skips: 46 rounds 2 s apart (0 to 90 s on the injected clock), then it fails with the last
    /// reason. The fake answers ok after 200 skips, so a missing cap ends as a wrong count, never a hang. While it
    /// runs the row's line is a running text, so the window's composer locks.
    @MainActor
    func testNinetySecondsOfSkipsFailWithTheLastReason() {
        let f = FirstIO(replies: Array(repeating: Self.reply("skipped", "not_claude"), count: 199)
                            + [Self.reply("skipped", "prompt"), Self.reply("ok")])
        f.replies[44] = Self.reply("skipped", "no_screen")
        f.replies[45] = Self.reply("skipped", "prompt")
        let c = controller(f)
        let done = expectation(description: "then")
        c.sayFirst(key, "Example task") { _ in done.fulfill() }
        XCTAssertEqual(c.store?.actions[key], AgentIsland.firstSendingText)
        XCTAssertTrue(AgentIsland.runningTexts.contains(AgentIsland.firstSendingText), "the composer locks on it")
        wait(for: [done], timeout: 10)
        let n = f.counts
        XCTAssertEqual(n.says, 46)
        XCTAssertEqual(n.pauses, 45)
        XCTAssertEqual(f.lock.withLock { f.t }, 90)
        XCTAssertEqual(c.store?.actions[key], AgentWindowText.firstNotSent(AgentWindowText.blocked), "the last reason")
        XCTAssertEqual(c.unsentFirst[key], "Example task")
    }

    /// T17 (#1384, was testInFlightHoldsTheKeyOnlyDuringTheRun): the key is in flight around each say (Always allow and
    /// the window's clicks stand down for it), never across the wait between rounds, and not after the run.
    @MainActor
    func testInFlightHoldsTheKeyOnlyAroundEachSay() {
        let f = FirstIO(replies: [Self.reply("skipped", "no_screen"), Self.reply("ok")])
        let c = controller(f)
        let key = key
        f.onSay = { let h = Self.onMain { c.heldByAutoAllow(key) }; f.lock.withLock { f.started.append(h) } }
        f.onPause = { let h = Self.onMain { c.heldByAutoAllow(key) }; f.lock.withLock { f.held.append(h) } }
        let done = expectation(description: "then")
        var heldInThen: Bool?
        c.sayFirst(key, "Example task") { _ in
            heldInThen = c.heldByAutoAllow(key)
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
        XCTAssertEqual(f.lock.withLock { f.started }, [true, true], "held during each say")
        XCTAssertEqual(f.lock.withLock { f.held }, [false], "not held between rounds")
        XCTAssertEqual(heldInThen, false, "released before then runs")
        XCTAssertFalse(c.heldByAutoAllow(key))
        XCTAssertEqual(f.counts.says, 2)
    }

    /// T19 (#1384, R1369-s1): a prompt on the read for 3 rounds. Between the rounds nothing holds the key, so the
    /// answer buttons show and a job on the session starts (the runner's start refuses a held key); then it says once.
    @MainActor
    func testAPromptForThreeRoundsDoesNotHoldTheKeyBetweenRounds() {
        let f = FirstIO(screens: [Self.prompt, Self.prompt, Self.prompt, Self.idle], replies: [Self.reply("ok")])
        let c = controller(f)
        c.runner = Self.parkedRunner(nil)
        let key = key
        f.onPause = {
            let h = Self.onMain { c.heldByAutoAllow(key) }
            let first = f.lock.withLock { f.held.append(h); return f.started.isEmpty }
            guard first else { return }
            let done = DispatchSemaphore(value: 0)
            let ok = Self.onMain { c.runner.start(key, path: "/usr/bin/example-dch", args: ["--restart", "api"], env: { [:] }, done: { _ in done.signal() }) }
            if ok { _ = done.wait(timeout: .now() + 10) }   // reaped (the key is free again) before the next round
            f.lock.withLock { f.started.append(ok) }
        }
        sayFirst(c, "Example task")
        XCTAssertEqual(f.lock.withLock { f.held }, [false, false, false], "no hold between rounds")
        XCTAssertEqual(f.lock.withLock { f.started }, [true], "a restart-like job starts between rounds")
        XCTAssertEqual(f.counts.says, 1)
        XCTAssertTrue(c.store?.actions[key] == nil)
    }

    /// T20 (#1384, R1369-s1): the key held by another say (the window's or an island click's would hold it the same
    /// way): the other run waits, no read and no say, until it is released, then says once. Ordered by events, never
    /// by timing: the waiter's 1st pause (its claim was refused, so the holder has the key) waits for the holder's say,
    /// which is parked; at the waiter's 2nd pause (refused again, the say still parked) the counts are taken, the say is
    /// released and the pause waits for the holder's `then` (its key released), so the waiter's next round says.
    @MainActor
    func testAKeyHeldElsewhereMeansNoSayUntilItIsReleased() {
        let f = FirstIO(replies: [Self.reply("ok"), Self.reply("ok")])
        let gate = DispatchSemaphore(value: 0), holderSaid = DispatchSemaphore(value: 0), holderDone = DispatchSemaphore(value: 0)
        f.gate = gate
        let c = controller(f)
        let key = key
        f.onSay = {
            f.lock.withLock { f.sayers.append(pthread_mach_thread_np(pthread_self())) }
            holderSaid.signal()
        }
        f.onPause = {
            let n = f.lock.withLock { f.pausers.append(pthread_mach_thread_np(pthread_self())); return f.pauses.count }
            if n == 1 { _ = holderSaid.wait(timeout: .now() + 10) }
            guard n == 2 else { return }
            let h = Self.onMain { c.heldByAutoAllow(key) }
            f.lock.withLock { f.saysAt = f.says.count; f.readsAt = f.reads; f.held.append(h) }
            gate.signal()
            _ = holderDone.wait(timeout: .now() + 10)
        }
        let done = expectation(description: "then")
        done.expectedFulfillmentCount = 2
        // The first `then` is the holder's: the waiter cannot end before the key is released.
        c.sayFirst(key, "Example task") { _ in holderDone.signal(); done.fulfill() }
        c.sayFirst(key, "Example task") { _ in holderDone.signal(); done.fulfill() }
        wait(for: [done], timeout: 10)
        XCTAssertEqual(f.lock.withLock { f.held }, [true], "the key is held at the waiter's 2nd pause")
        XCTAssertEqual(f.lock.withLock { f.saysAt }, 1, "only the holder's say while it holds the key")
        XCTAssertEqual(f.lock.withLock { f.readsAt }, 1, "and no read by the waiter")
        let (sayers, pausers) = f.lock.withLock { (f.sayers, f.pausers) }
        XCTAssertEqual(pausers.count, 2, "the waiter waits two rounds, then its claim is free")
        XCTAssertEqual(Set(pausers).count, 1, "one run waits")
        XCTAssertEqual(sayers.count, 2, "then exactly one say by the waiter once released")
        XCTAssertFalse(pausers.contains(sayers.first ?? 0), "the holder never waits")
        XCTAssertEqual(sayers.last, pausers.first, "the 2nd say is the waiter's")
        XCTAssertEqual(f.counts.reads, 2)
        XCTAssertFalse(c.heldByAutoAllow(key))
    }

    /// T21 (#1384, R1369-s1): a runner job on the session (a Restart or Stop): no read and no say until it is reaped.
    @MainActor
    func testARunnerJobOnTheKeyMeansNoSayUntilItEnds() {
        let f = FirstIO(replies: [Self.reply("ok")])
        let park = DispatchSemaphore(value: 0), ended = DispatchSemaphore(value: 0)
        let c = controller(f)
        c.runner = Self.parkedRunner(park)
        XCTAssertTrue(c.runner.start(key, path: "/usr/bin/example-dch", args: ["--restart", "api"], env: { [:] }, done: { _ in ended.signal() }))
        f.onPause = {
            guard f.lock.withLock({ f.pauses.count == 2 }) else { return }
            f.lock.withLock { f.saysAt = f.says.count; f.readsAt = f.reads }
            park.signal()
            _ = ended.wait(timeout: .now() + 10)   // reaped: the runner is free before the next round
        }
        sayFirst(c, "Example task")
        XCTAssertEqual(f.lock.withLock { f.saysAt }, 0, "no say while the job runs")
        XCTAssertEqual(f.lock.withLock { f.readsAt }, 0, "and no read")
        XCTAssertEqual(f.counts.says, 1, "one say after it ended")
        XCTAssertTrue(c.store?.actions[key] == nil)
    }

    /// T22 (#1384, R1369-s2): a controller nobody gave an io runs dch-lite under tests: an empty read, no mirror,
    /// no reply, so no row can reach a real `dch --say`.
    @MainActor
    func testTheDefaultIoUnderTestsIsDchLite() {
        let io = AgentIslandController().io
        XCTAssertTrue(io.noMirror(key))
        XCTAssertEqual(io.read(key), "")
        XCTAssertTrue(AgentWindowDriver.sayReply(io.say(key, "Example task")) == nil)
    }

    /// T18: a blank or control-only text sends nothing (no read, no say, no line, no hold) and `then` still runs, at once.
    @MainActor
    func testABlankTextSendsNothingAndThenStillRuns() {
        for text in ["", " \n\t ", "\u{1B}\u{7F}\r\n\u{85}"] {
            let f = FirstIO(replies: [Self.reply("ok")])
            let c = controller(f)
            var ran = 0
            c.sayFirst(key, text) { _ in ran += 1 }
            XCTAssertEqual(ran, 1, "then ran at once: \(text.debugDescription)")
            XCTAssertFalse(c.heldByAutoAllow(key))
            XCTAssertTrue(c.store?.actions[key] == nil)
            let n = f.counts
            XCTAssertEqual(n.reads + n.says, 0, text.debugDescription)
            XCTAssertTrue(c.unsentFirst[key] == nil)
        }
    }
}
