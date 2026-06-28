import XCTest
@testable import ProsperApp

/// The "Restart" menu item spawns a detached `/bin/sh` waiter that polls until
/// this process exits, then re-opens the bundle. The earlier draft interpolated
/// the bundle path into a double-quoted shell string (injection / breakage on
/// odd paths) and used an unbounded `while` (immortal spinner if `terminate`
/// is cancelled). These guard the fixed contract.
///
/// Cold path — fires once on an explicit menu click, never in a render/event
/// loop. No per-frame budget applies; the builder is pure O(1) string assembly.
/// The perf check below is a sanity ceiling, not a hot-path gate.
final class RelaunchTests: XCTestCase {

    private func args(_ path: String, _ pid: Int32 = 4242) -> [String] {
        AppDelegate.relaunchShellArguments(bundlePath: path, pid: pid)
    }

    // MARK: argv shape

    func testFirstArgIsDashC() {
        XCTAssertEqual(args("/Applications/Prosper.app").first, "-c")
    }

    func testPathAndPidPassedAsPositionalArgs() {
        // Injection safety hinges on these being separate argv entries — $1/$2 —
        // not substrings of the script body.
        let a = args("/Applications/Prosper.app", 99)
        XCTAssertEqual(a.count, 5)
        XCTAssertEqual(a[2], "sh")   // $0
        XCTAssertEqual(a[3], "99")   // $1 = pid
        XCTAssertEqual(a[4], "/Applications/Prosper.app") // $2 = path
    }

    func testScriptReferencesPositionalsNotInterpolatedValues() {
        let a = args("/Applications/Prosper.app", 99)
        let script = a[1]
        XCTAssertTrue(script.contains("\"$1\""), "pid must be read via $1")
        XCTAssertTrue(script.contains("\"$2\""), "path must be read via $2")
        // The actual values must NOT appear inside the script body.
        XCTAssertFalse(script.contains("99"))
        XCTAssertFalse(script.contains("Prosper.app"))
    }

    // MARK: injection safety

    func testMaliciousPathStaysInArgvNeverInScript() {
        let evil = "/tmp/a\"; rm -rf $HOME; open \"/x.app"
        let a = args(evil)
        XCTAssertEqual(a.last, evil, "path passed verbatim as a single argv slot")
        XCTAssertFalse(a[1].contains("rm -rf"), "no injection into the script body")
    }

    func testPathWithSpacesAndDollarsIsVerbatim() {
        let p = "/Users/me/My $Apps/Prosper Beta.app"
        XCTAssertEqual(args(p).last, p)
    }

    // MARK: stability — bounded waiter + correct exec target

    func testWaiterLoopIsBounded() {
        // A cancelled NSApp.terminate must not leave an immortal poll loop.
        let script = args("/x.app")[1]
        XCTAssertTrue(script.contains("-lt 600"), "loop must cap iterations")
    }

    func testUsesAbsoluteOpenPath() {
        // Not bare `open` — a tampered PATH must not pick a different binary.
        XCTAssertTrue(args("/x.app")[1].contains("/usr/bin/open"))
    }

    func testWaitsForDeregGraceBeforeOpen() {
        // A grace `sleep` must sit between the wait loop and `open`, so `open`
        // doesn't race LaunchServices' dead-instance deregistration and merely
        // activate a corpse instead of relaunching.
        let script = args("/x.app")[1]
        guard let doneRange = script.range(of: "done"),
              let openRange = script.range(of: "/usr/bin/open") else {
            return XCTFail("script missing loop-end or open")
        }
        let between = script[doneRange.upperBound..<openRange.lowerBound]
        XCTAssertTrue(between.contains("sleep"), "grace sleep must precede open")
    }

    func testReopensSamePidThatWasPassed() {
        XCTAssertEqual(args("/x.app", 1234)[3], "1234")
    }

    // MARK: compute time (cold-path sanity ceiling, not a render budget)

    func testBuilderIsCheap() {
        let path = "/Applications/Prosper.app"
        let start = DispatchTime.now()
        for _ in 0..<10_000 { _ = args(path) }
        let ns = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
        let perCall = Double(ns) / 10_000.0
        // Pure string assembly; generous ceiling — flags accidental O(n) work.
        XCTAssertLessThan(perCall, 50_000, "relaunch arg build ~\(Int(perCall))ns/call")
    }
}
