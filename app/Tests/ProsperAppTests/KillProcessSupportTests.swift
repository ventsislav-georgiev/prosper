// The guard seam behind BOTH kill paths — the killproc extension (via
// host.process) and the stats popups' ✕ button. Every case drives the real rules
// with a stubbed name resolver and a spy in place of kill(2), so no test ever
// signals a real process.

import XCTest
@testable import ProsperApp

final class KillProcessSupportTests: XCTestCase {
    /// Fake process table: everything else "does not exist".
    private let table: [pid_t: String] = [
        0: "kernel_task",
        1: "/sbin/launchd",
        501: "/Applications/Safari.app/Contents/MacOS/Safari",
        777: "/usr/sbin/WindowServer",
        778: "/System/Library/CoreServices/loginwindow.app/Contents/MacOS/loginwindow",
        900: "Prosperity",
        4242: "/Applications/Prosper.app/Contents/MacOS/Prosper",
        4243: "  ",
    ]
    private let own: pid_t = 4242

    private func refusal(_ pid: pid_t) -> String? {
        KillProcessSupport.refusal(pid: pid, name: { table[$0] }, own: own)
    }

    /// Kills `pid` and returns (refusal, signals actually sent).
    private func kill(_ pid: pid_t, force: Bool = false) -> (String?, [(pid_t, Int32)]) {
        var sent: [(pid_t, Int32)] = []
        let why = KillProcessSupport.kill(pid: pid, force: force, name: { table[$0] }, own: own,
                                          send: { p, s in sent.append((p, s)); return 0 })
        return (why, sent)
    }

    // MARK: refusals

    func testSystemPIDsRefused() {
        XCTAssertEqual(refusal(0), "system pid")
        XCTAssertEqual(refusal(1), "system pid")
        XCTAssertEqual(refusal(-1), "system pid")
    }

    func testOwnPIDRefused() {
        XCTAssertEqual(refusal(own), "that's Prosper")
        XCTAssertEqual(refusal(501), nil, "a neighbouring pid is still killable")
    }

    func testProtectedNamesRefusedBareAndByPath() {
        XCTAssertEqual(refusal(0), "system pid")            // kernel_task also caught by pid
        XCTAssertEqual(refusal(777), "protected: WindowServer")
        XCTAssertEqual(refusal(778), "protected: loginwindow")
        // The name is matched whole, never as a substring.
        XCTAssertEqual(refusal(900), nil, "Prosperity is not Prosper")
    }

    func testVanishedProcessRefused() {
        XCTAssertEqual(refusal(9001), "no such process", "unknown pid")
        XCTAssertEqual(refusal(4243), "no such process", "blank name")
    }

    func testEveryProtectedNameIsRefused() {
        for name in KillProcessSupport.protectedNames {
            XCTAssertEqual(KillProcessSupport.refusal(pid: 9001, name: { _ in name }, own: own),
                           "protected: \(name)")
            XCTAssertEqual(KillProcessSupport.refusal(pid: 9001,
                                                      name: { _ in "/usr/libexec/\(name)" },
                                                      own: own),
                           "protected: \(name)", "matched on the base name of a full path")
        }
    }

    // MARK: the kill call itself

    func testRefusedKillsNeverReachTheSyscall() {
        for pid in [pid_t(0), 1, own, 777, 778, 9001, 4243] {
            let (why, sent) = kill(pid)
            XCTAssertNotNil(why, "pid \(pid) must be refused")
            XCTAssertTrue(sent.isEmpty, "pid \(pid) must not be signalled")
        }
    }

    func testNormalProcessIsSignalled() {
        let (why, sent) = kill(501)
        XCTAssertNil(why)
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?.0, 501)
        XCTAssertEqual(sent.first?.1, SIGTERM, "default signal is a polite terminate")
    }

    func testForceSendsSIGKILL() {
        let (why, sent) = kill(501, force: true)
        XCTAssertNil(why)
        XCTAssertEqual(sent.first?.1, SIGKILL)
    }

    func testFailedSyscallIsReported() {
        let why = KillProcessSupport.kill(pid: 501, force: false, name: { table[$0] }, own: own,
                                          send: { _, _ in -1 })
        XCTAssertEqual(why, "kill failed")
    }

    /// Prosper's real pid is refused by the production defaults, not just by the
    /// injected `own` — the argument is a test seam, never a way around the rule.
    func testProductionDefaultsRefuseOurOwnProcess() {
        XCTAssertEqual(KillProcessSupport.refusal(pid: getpid()), "that's Prosper")
        var sent = 0
        let why = KillProcessSupport.kill(pid: getpid(), force: true, send: { _, _ in sent += 1; return 0 })
        XCTAssertEqual(why, "that's Prosper")
        XCTAssertEqual(sent, 0)
    }
}
