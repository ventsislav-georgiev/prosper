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

    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var r: DchActionResult?
        func set(_ x: DchActionResult) { lock.withLock { r = x } }
        func get() -> DchActionResult? { lock.withLock { r } }
    }
}
