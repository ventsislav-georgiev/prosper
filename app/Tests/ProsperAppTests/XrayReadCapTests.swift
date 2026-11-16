import XCTest
@testable import ProsperApp

/// #1405 (QA R1389-i1): X-ray's dch reads stop at an output limit instead of capturing until EOF. Every child here is
/// a /bin/sh the row writes (builtins only: printf, exec of /bin/sleep); the kill is a recorder that ends only the pid
/// the call reported. No dch, no window. The 5 s sleep is the child that outlives the check; a green row ends it.
final class XrayReadCapTests: XCTestCase {
    private final class Rec: @unchecked Sendable {
        let lock = NSLock()
        var pids: [pid_t] = [], bytes = 0
    }

    /// 5000 zero bytes, then (still alive) a sleep that replaces the shell, so the pid is the one that is signalled.
    private static let flood = "printf '%05000d' 0; exec /bin/sleep 5"

    /// The limit is the largest parser cap and never below Chapters' own.
    func testTheLimitIsNotBelowAnyParserCap() {
        XCTAssertGreaterThanOrEqual(XrayPanels.maxReadBytes, XrayChapters.maxBytes)
    }

    /// Over the limit: exactly limit + 1 bytes are read, the one recorded pid is ended once, status XrayPanels.overCap, no data.
    /// Red at TIP (DchConnection.swift runCapturingBoth: no outputLimit parameter, the call does not compile; the old
    /// loop appended every chunk and returned them).
    func testPastTheLimitTheReadStopsAtLimitPlusOneAndTheChildIsEnded() {
        let rec = Rec(), killed = Rec()
        let r = DchCommand.runCapturingBoth(
            args: ["-c", Self.flood], env: [:], path: "/bin/sh",
            onPid: { pid in rec.lock.withLock { rec.pids.append(pid) } },
            onOutput: { chunk in rec.lock.withLock { rec.bytes += chunk.count } },
            outputLimit: (1000, { pid in killed.lock.withLock { killed.pids.append(pid) }; _ = Darwin.kill(pid, SIGKILL) }))
        XCTAssertEqual(rec.lock.withLock { rec.bytes }, 1001, "stopped at limit + 1")
        XCTAssertEqual(r.status, XrayPanels.overCap)
        XCTAssertTrue(r.out.isEmpty)
        XCTAssertEqual(rec.lock.withLock { rec.pids.count }, 1)
        XCTAssertEqual(killed.lock.withLock { killed.pids }, rec.lock.withLock { rec.pids }, "its own pid, once")
    }

    /// The same through X-ray's helper: overCap (#1407, not -1: the timeout's) and nothing for the caller, one end through the
    /// terminate seam. Red at TIP (XrayPanel.swift:120 returned -1 past the limit, as a timeout; XrayPanels.overCap did not exist).
    func testRunBoundedPastTheLimitIsAFailureWithNoData() {
        let killed = Rec()
        let r = XrayPanels.runBounded(XrayChild(), "/bin/sh", ["-c", Self.flood], [:], outputLimit: 1000,
                                      terminate: { pid in killed.lock.withLock { killed.pids.append(pid) }; _ = Darwin.kill(pid, SIGKILL) })
        XCTAssertEqual(r.status, XrayPanels.overCap)
        XCTAssertNotEqual(r.status, -1)
        XCTAssertTrue(r.out.isEmpty)
        XCTAssertEqual(killed.lock.withLock { killed.pids.count }, 1)
    }

    /// #1407: overCap is outside every dch exit (0...255) and is not the timeout's -1.
    func testOverCapSharesNoStatusWithAnExitOrTheTimeout() {
        XCTAssertFalse((0...255).contains(XrayPanels.overCap))
        XCTAssertNotEqual(XrayPanels.overCap, -1)
    }

    /// #1407: a timeout keeps -1 (a remote one is "host unreachable"). Pin; passes at TIP.
    func testATimeoutStaysMinusOne() {
        let r = XrayPanels.runBounded(XrayChild(), "/bin/sh", ["-c", "exec /bin/sleep 5"], [:], timeout: 1.0, outputLimit: 1000,
                                      terminate: { pid in _ = Darwin.kill(pid, SIGKILL) })
        XCTAssertEqual(r.status, -1)
        XCTAssertTrue(r.out.isEmpty)
    }

    /// Exactly at the limit and under it: the bytes as they are, the exit status, no kill.
    func testAtAndUnderTheLimitNothingChanges() {
        for n in [999, 1000] {
            let killed = Rec()
            let r = XrayPanels.runBounded(XrayChild(), "/bin/sh", ["-c", "printf '%0\(n)d' 0"], [:], outputLimit: 1000,
                                          terminate: { pid in killed.lock.withLock { killed.pids.append(pid) } })
            XCTAssertEqual(r.status, 0, "\(n) bytes")
            XCTAssertEqual(r.out, Data(String(repeating: "0", count: n).utf8))
            XCTAssertTrue(killed.lock.withLock { killed.pids }.isEmpty)
        }
    }
}
