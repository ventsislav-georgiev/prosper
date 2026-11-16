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
        init(screens: [String] = [AgentIslandSayFirstTests.idle], replies: [String]) {
            self.screens = screens
            self.replies = replies
        }
        private static func next(_ a: inout [String]) -> String { a.count > 1 ? a.removeFirst() : a.first ?? "" }
        var io: AgentPromptIO {
            AgentPromptIO(read: { _ in self.lock.withLock { self.reads += 1; return Self.next(&self.screens) } },
                          status: { _ in self.lock.withLock { XCTFail("sayFirst never asks the status"); return "" } },
                          send: { _, _ in XCTFail("sayFirst never uses --send") },
                          say: { _, text in self.lock.withLock { self.says.append(text); return Self.next(&self.replies) } },
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
        c.firstPause = { d in f.lock.withLock { f.pauses.append(d); f.t += d } }
        c.firstClock = { f.lock.withLock { Date(timeIntervalSinceReferenceDate: f.t) } }
        return c
    }

    /// Runs sayFirst to its end; `then` must run exactly once (an over-fulfilled expectation fails the test).
    @MainActor
    private func sayFirst(_ c: AgentIslandController, _ text: String) {
        let done = expectation(description: "then")
        c.sayFirst(key, text) { done.fulfill() }
        wait(for: [done], timeout: 10)
    }

    /// T12: skipped not_claude, no_screen and prompt typed nothing, so each waits one step; ok on the fourth call.
    /// The line is cleared, nothing is kept, the text went out as the composer sends it (control characters dropped,
    /// trimmed).
    @MainActor
    func testSkipRoundsWaitThenOkClearsTheLine() {
        let f = FirstIO(replies: [Self.reply("skipped", "not_claude"), Self.reply("skipped", "no_screen"),
                                  Self.reply("skipped", "prompt"), Self.reply("ok")])
        let c = controller(f)
        sayFirst(c, "  Example task\r\n")
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
            sayFirst(c, "Example task")
            XCTAssertEqual(f.counts.says, 1, "no retry: \(reply)")
            XCTAssertEqual(f.counts.pauses, 0, reply)
            XCTAssertEqual(c.store?.actions[key], AgentWindowText.firstNotSent(why), reply)
            XCTAssertEqual(c.unsentFirst[key], "Example task", reply)
        }
    }

    /// T15: skipped draft (someone typed into the composer): one call, then it fails, never typing over it. dch-lite
    /// (an empty read and no mirror): no say call at all, it fails at once.
    @MainActor
    func testASkippedDraftFailsAndLiteFailsAtOnce() {
        let f = FirstIO(replies: [Self.reply("skipped", "draft"), Self.reply("ok")])
        let c = controller(f)
        sayFirst(c, "Example task")
        XCTAssertEqual(f.counts.says, 1)
        XCTAssertEqual(c.store?.actions[key], AgentWindowText.firstNotSent(AgentWindowText.draft))

        let lite = FirstIO(screens: [""], replies: [Self.reply("ok")])
        lite.noMirror = true
        let d = controller(lite)
        sayFirst(d, "Example task")
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
        c.sayFirst(key, "Example task") { done.fulfill() }
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

    /// T17: the key is in flight for the run (Always allow and the window's clicks stand down), and not after.
    @MainActor
    func testInFlightHoldsTheKeyOnlyDuringTheRun() {
        let f = FirstIO(replies: [Self.reply("skipped", "no_screen"), Self.reply("ok")])
        let c = controller(f)
        let done = expectation(description: "then")
        var heldInThen: Bool?
        c.sayFirst(key, "Example task") {
            heldInThen = c.heldByAutoAllow(self.key)
            done.fulfill()
        }
        XCTAssertTrue(c.heldByAutoAllow(key), "held from the call")
        wait(for: [done], timeout: 10)
        XCTAssertEqual(heldInThen, false, "released before then runs")
        XCTAssertFalse(c.heldByAutoAllow(key))
        XCTAssertEqual(f.counts.says, 2)
    }

    /// T18: a blank or control-only text sends nothing (no read, no say, no line, no hold) and `then` still runs, at once.
    @MainActor
    func testABlankTextSendsNothingAndThenStillRuns() {
        for text in ["", " \n\t ", "\u{1B}\u{7F}\r\n\u{85}"] {
            let f = FirstIO(replies: [Self.reply("ok")])
            let c = controller(f)
            var ran = 0
            c.sayFirst(key, text) { ran += 1 }
            XCTAssertEqual(ran, 1, "then ran at once: \(text.debugDescription)")
            XCTAssertFalse(c.heldByAutoAllow(key))
            XCTAssertTrue(c.store?.actions[key] == nil)
            let n = f.counts
            XCTAssertEqual(n.reads + n.says, 0, text.debugDescription)
            XCTAssertTrue(c.unsentFirst[key] == nil)
        }
    }
}
