import Foundation
import XCTest
@testable import ProsperApp

/// #988 R988c-1: runCapturingBoth drains stderr while it drains stdout and keeps only stderr's first 4096 bytes.
/// Each row runs /bin/sh through runCapturingBoth (as AgentIslandTests' B14 row does) with a literal command whose
/// builtins (printf, [, exit) write bytes to its own stdout and stderr: no other program, no file, no network.
/// Where things run: the call and onOutput on one global-queue thread; the wait and the asserts on the test's
/// thread. The 20 s is a ceiling only: a green call returns at once. R988d-f: at the ceiling the row fails and
/// leaves the child alone (no row signals any process); the pipes close when xctest exits.
final class DchCaptureDrainTests: XCTestCase {
    private final class Call: @unchecked Sendable {
        let lock = NSLock()
        var result: (out: Data, err: String, status: Int32, chunks: [Data])?
    }

    private static let zeros4096 = String(repeating: "0", count: 4096)

    /// nil (and a failure) when the call did not return within the ceiling.
    private func run(_ script: String, merge: Bool = false, path: String = "/bin/sh")
        -> (out: Data, err: String, status: Int32, chunks: [Data])? {
        let call = Call(), done = XCTestExpectation(description: "runCapturingBoth returned")
        DispatchQueue.global().async {
            var chunks: [Data] = []
            let r = DchCommand.runCapturingBoth(args: ["-c", script], env: [:], path: path, merge: merge,
                                                onOutput: { chunks.append($0) })
            call.lock.withLock { call.result = (r.out, r.err, r.status, chunks) }
            done.fulfill()
        }
        guard XCTWaiter().wait(for: [done], timeout: 20) == .completed else {
            XCTFail("runCapturingBoth did not return within the 20 s ceiling")
            return nil
        }
        return call.lock.withLock { call.result }
    }

    /// #1380: the exit hook runs (from the termination handler) before the call returns, once, with a real /bin/sh.
    func testTheExitHookRunsBeforeTheCallReturns() {
        final class Hits: @unchecked Sendable { let lock = NSLock(); var n = 0 }
        let hits = Hits(), done = XCTestExpectation(description: "returned")
        let seen = Hits()
        DispatchQueue.global().async {
            let r = DchCommand.runCapturingBoth(args: ["-c", "exit 0"], env: [:], path: "/bin/sh",
                                                onExit: { hits.lock.withLock { hits.n += 1 } })
            seen.lock.withLock { seen.n = hits.lock.withLock { hits.n } + 10 * Int(r.status) }
            done.fulfill()
        }
        XCTAssertEqual(XCTWaiter().wait(for: [done], timeout: 20), .completed)
        XCTAssertEqual(seen.lock.withLock { seen.n }, 1, "hook ran once before the return; exit status 0")
    }

    /// The hang: 200000 bytes to stderr while stdout is still open, then "done", exit 3.
    func testAFloodOfStderrBeforeStdoutStillReturns() throws {
        let r = try XCTUnwrap(run("printf '%0200000d' 0 >&2; printf 'done\\n'; exit 3"))
        XCTAssertEqual(String(decoding: r.out, as: UTF8.self), "done\n")
        XCTAssertEqual(r.status, 3)
        XCTAssertEqual(r.err, Self.zeros4096)
    }

    /// stdout large, stderr one line: both whole; the chunks onOutput got, joined, are out.
    func testLargeStdoutAndSmallStderrAreBothWhole() throws {
        let r = try XCTUnwrap(run("printf '%0300000d' 0; printf 'one line\\n' >&2"))
        XCTAssertEqual(r.out, Data(repeating: 0x30, count: 300_000))
        XCTAssertEqual(r.err, "one line\n")
        XCTAssertEqual(r.status, 0)
        XCTAssertEqual(r.chunks.reduce(Data(), +), r.out)
    }

    /// Both large and interleaved (10 rounds of 30000 to stdout and 20000 to stderr): out whole, err the first 4096.
    func testBothLargeInterleavedReturnsWithStderrCut() throws {
        let r = try XCTUnwrap(run("i=0; while [ $i -lt 10 ]; do printf '%030000d' 0; printf '%020000d' 0 >&2; i=$((i+1)); done"))
        XCTAssertEqual(r.out, Data(repeating: 0x30, count: 300_000))
        XCTAssertEqual(r.err, Self.zeros4096)
        XCTAssertEqual(r.status, 0)
    }

    /// Exactly 4096 bytes is kept whole; 4097 is cut to 4096.
    func testTheCapIs4096Bytes() throws {
        XCTAssertEqual(try XCTUnwrap(run("printf '%04096d' 0 >&2")).err, Self.zeros4096)
        XCTAssertEqual(try XCTUnwrap(run("printf '%04097d' 0 >&2")).err, Self.zeros4096)
    }

    /// A cut inside a two-byte character (U+00E9 as \303\251): the 4095 digits stay, the lone first byte
    /// becomes U+FFFD; before, the whole text became "".
    func testACutInsideAUTF8SequenceKeepsTheValidText() throws {
        let r = try XCTUnwrap(run("printf '%04095d\\303\\251' 0 >&2"))
        XCTAssertEqual(r.err, String(repeating: "0", count: 4095) + "\u{FFFD}")
    }

    /// merge: stderr goes into out whole, as before; err is empty.
    func testMergeKeepsAllOfStderrInOut() throws {
        let r = try XCTUnwrap(run("printf '%0200000d' 0 >&2", merge: true))
        XCTAssertEqual(r.out, Data(repeating: 0x30, count: 200_000))
        XCTAssertEqual(r.err, "")
        XCTAssertEqual(r.status, 0)
    }

    /// A path that does not exist never starts: (empty, "", -1), and no pid is reported.
    func testAMissingPathStillAnswersMinusOne() throws {
        let r = try XCTUnwrap(run("exit 0", path: "/Users/example/no-such-program"))
        XCTAssertEqual(r.out, Data())
        XCTAssertEqual(r.err, "")
        XCTAssertEqual(r.status, -1)
        XCTAssertTrue(r.chunks.isEmpty)
    }
}
