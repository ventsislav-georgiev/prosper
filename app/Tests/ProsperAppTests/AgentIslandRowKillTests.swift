import XCTest
@testable import ProsperApp

/// #1328 (R991-q1): a Kill on a row reaps while that row's own Stop is still out; the Stop's later
/// non-zero exit reads "Killed", never "Stop failed". Fake launch and signal closures only: no dch, no process.
final class AgentIslandRowKillTests: XCTestCase {
    private final class Fake: @unchecked Sendable {
        let open = DispatchSemaphore(value: 0)
        func runner() -> DchActionRunner {
            DchActionRunner(launch: { _, args, _, _, onPid, _ in
                onPid(4243)
                if args.first == "-k" { return (0, Data("killed: a\n".utf8)) }
                self.open.wait()
                return (1, Data("dch: master gone\n".utf8))
            }, signal: { _ in })
        }
    }

    func testARowKilledDuringItsOwnStopReadsKilled() {
        let f = Fake(), runner = f.runner(), key = AgentSessionKey(dir: "/d", name: "a")
        let stopped = DispatchSemaphore(value: 0), killed = DispatchSemaphore(value: 0)
        let box = Box()
        XCTAssertTrue(runner.start(key, path: "/fake/dch", args: ["--stop", "a", "--json"], yields: true, env: { [:] }) { r in
            box.set(r); stopped.signal()
        })
        XCTAssertTrue(runner.start(key, path: "/fake/dch", args: ["-k", "a"], kill: true, env: { [:] }) { _ in killed.signal() })
        XCTAssertEqual(killed.wait(timeout: .now() + 10), .success, "the Kill reaped first")
        f.open.signal()
        XCTAssertEqual(stopped.wait(timeout: .now() + 10), .success)
        let r = box.get()
        XCTAssertEqual(r?.status, 1)
        XCTAssertEqual(r.map { AgentIsland.rowText($0, name: "a", .stop) }, AgentIsland.killedText)
    }

    /// #1380 (R1368-i1): once the launch reports the exit, a cancel signals nothing; before it, exactly once.
    /// Fake launch and signal recorder only.
    func testCancelAfterTheExitIsReportedSignalsNothing() {
        final class Rec: @unchecked Sendable {
            let lock = NSLock(), exited = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
            var signals: [pid_t] = []
        }
        for reportExit in [true, false] {
            let rec = Rec(), key = AgentSessionKey(dir: "/d", name: "a"), finished = DispatchSemaphore(value: 0)
            let runner = DchActionRunner(launchExit: { _, _, _, _, onPid, _, onExit in
                onPid(4244)
                if reportExit { onExit() }
                rec.exited.signal()
                rec.release.wait()
                return (0, Data())
            }, signal: { pid in rec.lock.withLock { rec.signals.append(pid) } })
            XCTAssertTrue(runner.start(key, path: "/fake/dch", args: ["x"], env: { [:] }) { _ in finished.signal() })
            XCTAssertEqual(rec.exited.wait(timeout: .now() + 10), .success)
            runner.cancel(key)
            runner.cancel(key)
            XCTAssertEqual(rec.lock.withLock { rec.signals }, reportExit ? [] : [4244],
                           reportExit ? "exit reported: the pid may be reused, no signal" : "still running: exactly one SIGTERM")
            rec.release.signal()
            XCTAssertEqual(finished.wait(timeout: .now() + 10), .success)
        }
    }

    /// R1380-s2: the product's default launch (no launch seam) reports the exit: /bin/sh exits at once while its own
    /// /bin/sleep (left to finish by itself, 6 s) holds the merged pipe, so a cancel 2.5 s later (sh exits in milliseconds; the margin covers a loaded run) reaches a reaped pid
    /// and signals nothing. Red when the default launch passes `onExit: {}`: the recorder gets sh's pid. Takes ~6 s.
    func testCancelWhileAGrandchildHoldsThePipeAfterTheExitSignalsNothing() {
        final class Rec: @unchecked Sendable { let lock = NSLock(); var signals: [pid_t] = [] }
        let rec = Rec(), key = AgentSessionKey(dir: "/d", name: "a"), finished = DispatchSemaphore(value: 0)
        let runner = DchActionRunner(signal: { pid in rec.lock.withLock { rec.signals.append(pid) } })
        XCTAssertTrue(runner.start(key, path: "/bin/sh", args: ["-c", "(/bin/sleep 6) & exit 0"], env: { [:] }) { _ in finished.signal() })
        Thread.sleep(forTimeInterval: 2.5)
        runner.cancel(key)
        XCTAssertTrue(rec.lock.withLock { rec.signals }.isEmpty, "sh was reaped: its pid may be reused, no signal")
        XCTAssertEqual(finished.wait(timeout: .now() + 10), .success)
    }

    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var r: DchActionResult?
        func set(_ x: DchActionResult) { lock.withLock { r = x } }
        func get() -> DchActionResult? { lock.withLock { r } }
    }
}
