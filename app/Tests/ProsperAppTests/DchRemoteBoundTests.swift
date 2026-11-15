import Foundation
import XCTest
@testable import ProsperApp

/// #988 (QA #511 follow-up): Remote Terminal's own dch calls for the phone (list, read, rename, kill) are bounded
/// at `DchCommand.remoteTimeout`. Each row sets `DchCommand.remoteStandIn` (the program, its arguments and the
/// kill) and shortens the timeout, both restored in a defer, so no row ever runs dch. The child is /bin/sleep 30
/// ("never answers in time") or /bin/sh with a literal printf ("answers"). The kill is always a recorder: no row
/// signals any process; a sleeping child is left to end by itself. The 20 s is a ceiling only.
final class DchRemoteBoundTests: XCTestCase {
    private final class Recorder: @unchecked Sendable {
        let lock = NSLock()
        var pids: [pid_t] = []
        var kill: @Sendable (pid_t) -> Void { { pid in self.lock.withLock { self.pids.append(pid) } } }
        var recorded: [pid_t] { lock.withLock { pids } }
    }

    private final class Box<T>: @unchecked Sendable { var value: T? }

    private static let sleeps = (path: "/bin/sleep", args: ["30"])
    /// Left in place after a row's ceiling, so a call still running never reaches dch for a second call.
    private static let answersNothing: (path: String, args: [String], terminate: @Sendable (pid_t) -> Void) =
        ("/bin/sh", ["-c", "printf ''"], { _ in })

    /// Runs `body` on a global queue with the stand-in set and the timeout at 2 s (#486: room for Process.run
    /// under load). nil and a failure when it did not return within the 20 s ceiling; the child is left alone.
    private func run<T>(_ child: (path: String, args: [String]), _ recorder: Recorder,
                        _ body: @escaping @Sendable () -> T) -> T? {
        let saved = (DchCommand.remoteTimeout, DchCommand.remoteStandIn)
        var late = false
        defer {
            DchCommand.remoteTimeout = saved.0
            DchCommand.remoteStandIn = late ? Self.answersNothing : saved.1
        }
        DchCommand.remoteTimeout = 2
        DchCommand.remoteStandIn = (child.path, child.args, recorder.kill)
        let box = Box<T>(), done = XCTestExpectation(description: "the call returned")
        DispatchQueue.global().async {
            box.value = body()
            done.fulfill()
        }
        guard XCTWaiter().wait(for: [done], timeout: 20) == .completed else {
            late = true
            XCTFail("the call did not return within the 20 s ceiling")
            return nil
        }
        return box.value
    }

    /// The parent pid and the command name of `pid` (sysctl, read only); nil when there is no such process.
    private static func parentAndName(_ pid: pid_t) -> (ppid: pid_t, name: String)? {
        var kp = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard pid > 0, sysctl(&mib, 4, &kp, &size, nil, 0) == 0, size > 0 else { return nil }
        let name = withUnsafeBytes(of: kp.kp_proc.p_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return (kp.kp_eproc.e_ppid, name)
    }

    /// The recorder got exactly one pid, and it is this process's own sleeping child.
    private func assertKilledTheChild(_ recorder: Recorder, file: StaticString = #filePath, line: UInt = #line) {
        let pids = recorder.recorded
        XCTAssertEqual(pids.count, 1, "one kill, by the recorded pid", file: file, line: line)
        guard let pid = pids.first, let p = Self.parentAndName(pid) else {
            return XCTFail("no live recorded child", file: file, line: line)
        }
        XCTAssertEqual(p.ppid, getpid(), "the call's own child", file: file, line: line)
        XCTAssertEqual(p.name, "sleep", file: file, line: line)
    }

    func testRemoteTimeoutIsTenSeconds() {
        XCTAssertEqual(DchCommand.remoteTimeout, 10)
    }

    // MARK: - Never answers in time: the failure answer, and the kill goes to the recorded child

    func testATimedOutListIsTheEmptyList() throws {
        let rec = Recorder()
        let rows = try XCTUnwrap(run(Self.sleeps, rec) { DchCommand.listSessions() })
        XCTAssertEqual(rows, [], "as a dch that printed nothing; no -lj second call")
        assertKilledTheChild(rec)
    }

    func testATimedOutReadIsNoScreen() throws {
        let rec = Recorder()
        let screen = try XCTUnwrap(run(Self.sleeps, rec) { DchCommand.readScreen("api") })
        XCTAssertEqual(screen, Data(), "an empty snapshot: the phone keeps what it has")
        assertKilledTheChild(rec)
    }

    func testATimedOutRenameIsOurSentence() throws {
        let rec = Recorder()
        let answer = try XCTUnwrap(run(Self.sleeps, rec) { DchCommand.setAlias("api", alias: "web") })
        XCTAssertEqual(answer, "Couldn't rename api: dch didn't answer in time")
        assertKilledTheChild(rec)
    }

    func testATimedOutKillReturns() throws {
        let rec = Recorder()
        try XCTUnwrap(run(Self.sleeps, rec) { DchCommand.kill("api") })
        assertKilledTheChild(rec)
    }

    func testTheTimeoutSentenceShowsTheNameCutAsEveryRenameAnswer() {
        let long = String(repeating: "a", count: 70)
        XCTAssertEqual(DchCommand.renameTimedOut(long),
                       "Couldn't rename \(String(repeating: "a", count: 64))\u{2026}: dch didn't answer in time")
    }

    // MARK: - Answers: today's result, unchanged, and nothing is killed

    func testAnAnsweringListIsParsedAsBefore() throws {
        let rec = Recorder()
        let json = #"[{"name":"api","alias":"","activity_epoch":1,"state":"idle","agents":0}]"#
        let rows = try XCTUnwrap(run(("/bin/sh", ["-c", "printf '%s' '\(json)'"]), rec) { DchCommand.listSessions() })
        XCTAssertEqual(rows, DchCommand.parseListJSON(Data(json.utf8)))
        XCTAssertEqual(rows.map(\.name), ["api"])
        XCTAssertEqual(rec.recorded, [])
    }

    func testAnAnsweringReadKeepsTheScreenAndTheCaret() throws {
        let rec = Recorder()
        let screen = try XCTUnwrap(run(("/bin/sh", ["-c", "printf 'screen'; printf 'cursor 2 3 1 0\\n' >&2"]), rec) {
            DchCommand.readScreen("api")
        })
        XCTAssertEqual(screen, Data("screen\u{1b}[2;3H".utf8))
        XCTAssertEqual(rec.recorded, [])
    }

    func testAnAnsweringRenameIsTakenOrRefusedAsBefore() throws {
        let rec = Recorder()
        let taken = try XCTUnwrap(run(("/bin/sh", ["-c", "printf ''"]), rec) { DchCommand.setAlias("api", alias: "web") })
        XCTAssertTrue(taken == nil, "exit 0: taken")
        let refused = try XCTUnwrap(run(("/bin/sh", ["-c", "printf 'no session: api\\n' >&2; exit 1"]), rec) {
            DchCommand.setAlias("api", alias: "web")
        })
        XCTAssertEqual(refused, "Couldn't rename api: no session: api")
        XCTAssertEqual(rec.recorded, [])
    }

    func testAnAnsweringKillReturnsAndKillsNothing() throws {
        let rec = Recorder()
        try XCTUnwrap(run(("/bin/sh", ["-c", "printf ''"]), rec) { DchCommand.kill("api") })
        XCTAssertEqual(rec.recorded, [])
    }

    // MARK: - R988e-b: a fallback call gets only what is left of its request's one bound

    /// As `run`, with `first` for the first call, `fallback` for the second (remoteFallbackStandIn) and the timeout at
    /// `bound`; all restored in a defer (after the ceiling both stand-ins answer nothing at once).
    private func runWithFallback<T>(_ first: (path: String, args: [String]), then fallback: (path: String, args: [String]),
                                    bound: TimeInterval, _ recorder: Recorder,
                                    _ body: @escaping @Sendable () -> T) -> T? {
        let saved = DchCommand.remoteFallbackStandIn
        var late = false
        defer { DchCommand.remoteFallbackStandIn = late ? (Self.answersNothing.path, Self.answersNothing.args) : saved }
        DchCommand.remoteFallbackStandIn = fallback
        let out = run(first, recorder) { () -> T in   // run sets 2 s and restores the timeout; the call reads `bound`
            DchCommand.remoteTimeout = bound
            return body()
        }
        late = out == nil
        return out
    }

    /// The first child answers empty after 8 s (/bin/sleep 8 prints nothing) and the fallback never answers. One 13 s
    /// bound for the request ends the call near 13 s, inside the 20 s ceiling; a fresh 13 s bound for the fallback
    /// would end it near 21 s, past the ceiling. The one kill goes to the fallback's child (the first was reaped).
    func testAListWhoseFallbackNeverAnswersEndsWithinOneBound() throws {
        let rec = Recorder()
        let rows = try XCTUnwrap(runWithFallback(("/bin/sleep", ["8"]), then: Self.sleeps, bound: 13, rec) {
            DchCommand.listSessions()
        })
        XCTAssertEqual(rows, [], "the failure answer it already had")
        assertKilledTheChild(rec)
    }

    func testAReadWhoseFallbackNeverAnswersEndsWithinOneBound() throws {
        let rec = Recorder()
        let screen = try XCTUnwrap(runWithFallback(("/bin/sleep", ["8"]), then: Self.sleeps, bound: 13, rec) {
            DchCommand.readScreen("api")
        })
        XCTAssertEqual(screen, Data(), "the failure answer it already had")
        assertKilledTheChild(rec)
    }

    /// A first call that answers empty at once and a fallback that answers: today's answers, nothing killed.
    func testAnAnsweringFallbackIsTakenAsBefore() throws {
        let rec = Recorder(), empty = (path: "/bin/sh", args: ["-c", "printf ''"])
        let rows = try XCTUnwrap(runWithFallback(empty, then: ("/bin/sh", ["-c", "printf 'api\\tweb\\t1\\n'"]), bound: 2, rec) {
            DchCommand.listSessions()
        })
        XCTAssertEqual(rows, DchCommand.parseListTSV("api\tweb\t1\n"))
        XCTAssertEqual(rows.map(\.alias), ["web"])
        let screen = try XCTUnwrap(runWithFallback(empty, then: ("/bin/sh", ["-c", "printf 'screen'"]), bound: 2, rec) {
            DchCommand.readScreen("api")
        })
        XCTAssertEqual(screen, Data("screen".utf8))
        XCTAssertEqual(rec.recorded, [])
    }

    /// Nothing left of the bound: no time for a fallback, so it is never started.
    func testNothingLeftOfTheBoundStartsNoFallback() {
        let now = ProcessInfo.processInfo.systemUptime
        XCTAssertTrue(DchCommand.remoteLeft(until: now - 1) == nil, "past the deadline")
        XCTAssertTrue(DchCommand.remoteLeft(until: now) == nil, "at the deadline")
        let left = DchCommand.remoteLeft(until: now + 100) ?? 0
        XCTAssertTrue(left > 0 && left <= 100, "\(left)")
    }
}
