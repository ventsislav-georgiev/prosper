import XCTest
@testable import ProsperApp

/// PtyChild.redraw() must force a repaint a Node/Ink TUI cannot ignore: a real
/// size jiggle (rows-1, then restore) — two genuine SIGWINCHes with CHANGED
/// sizes. A plain same-size SIGWINCH is dropped by Node's resize check, which
/// left Claude Code's question prompts as a black screen on attach.
final class PtyChildRedrawTests: XCTestCase {

    /// Hands a child back from the spawning thread (a `var` can't cross the closure).
    private final class Box: @unchecked Sendable { var result: Result<PtyChild, Error>? }

    /// Size reports from the inner program, tallied off the pump thread.
    private final class Lines: @unchecked Sendable {
        enum Event { case ready, round(Int), other }
        private let lock = NSLock()
        private(set) var all: [String] = []
        private(set) var shrinks = 0
        private(set) var rounds = 0

        func record(_ line: String) -> Event {
            lock.lock(); defer { lock.unlock() }
            all.append(line)
            if line == "READY" { return .ready }
            if line == "R23x80" { shrinks += 1 }
            // A restore only closes a round once its shrink has been seen.
            if line == "R24x80", shrinks > rounds {
                rounds += 1
                return .round(rounds)
            }
            return .other
        }
    }

    /// Inner program: print `R<rows>x<cols>` on every SIGWINCH. Reads the size in the
    /// handler itself — a `sh` trap running `stty | awk` forks twice, which under load
    /// takes longer than the jiggle's 120 ms restore and reports the size AFTER the
    /// restore, so the shrink it exists to observe goes missing.
    /// Report ORDER is not size order: the handler is re-entrant, so a handler
    /// that read the old size can be interrupted by a newer one and print after
    /// it. Any line on stdin answers `NOW<rows>x<cols>`, the size at that moment.
    private static let reporter = """
    import signal, fcntl, termios, struct, sys
    def size():
        r, c, _, _ = struct.unpack('HHHH', fcntl.ioctl(0, termios.TIOCGWINSZ, b'\\0' * 8))
        return '%dx%d' % (r, c)
    def on_winch(*_):
        sys.stdout.write('R' + size() + '\\n'); sys.stdout.flush()
    signal.signal(signal.SIGWINCH, on_winch)
    print('READY', flush=True)
    for _ in sys.stdin: print('NOW' + size(), flush=True)
    """

    private func spawnReporter(
        blockingWinch: Bool = false, onLine: @escaping (String) -> Void
    ) throws -> PtyChild {
        let make = {
            try PtyChild(
                exe: "/usr/bin/python3", args: ["-u", "-c", Self.reporter],
                env: ["PATH": "/usr/bin:/bin"], cols: 80, rows: 24,
                onOutput: { bytes in
                    // Scan for tokens rather than splitting lines: a re-entrant WINCH
                    // handler interleaves its write with the one it interrupted, so two
                    // reports can arrive without a separator between them.
                    let text = String(decoding: bytes, as: UTF8.self)
                    if text.contains("READY") { onLine("READY") }
                    for m in text.matches(of: /(?:R|NOW)[0-9]+x[0-9]+/) { onLine(String(m.output)) }
                },
                onExit: { _ in })
        }
        guard blockingWinch else { return try make() }

        // Fork from a thread that has SIGWINCH blocked — production forks from Swift
        // runtime threads, which do. Scoped to that thread so the mask dies with it
        // instead of leaking into the next test.
        let box = Box()
        let spawned = DispatchSemaphore(value: 0)
        Thread {
            var blocked = sigset_t()
            sigemptyset(&blocked)
            sigaddset(&blocked, SIGWINCH)
            pthread_sigmask(SIG_BLOCK, &blocked, nil)
            box.result = Result { try make() }
            spawned.signal()
        }.start()
        XCTAssertEqual(spawned.wait(timeout: .now() + 15), .success, "spawn thread stalled")
        return try XCTUnwrap(box.result).get()
    }

    /// redraw() must yield rows-1 then rows.
    func testRedrawJigglesRows() throws {
        let state = Lines()
        let gotReady = expectation(description: "inner program started")
        // Two rounds: the second proves the jiggling flag releases after the
        // restore instead of wedging every later redraw().
        let round1 = expectation(description: "first jiggle: rows-1 then rows")
        let round2 = expectation(description: "second jiggle: flag released")

        let child = try spawnReporter { line in
            switch state.record(line) {
            case .ready: gotReady.fulfill()
            case .round(1): round1.fulfill()
            case .round(2): round2.fulfill()
            default: break
            }
        }
        child.run()
        defer { child.terminate() }

        wait(for: [gotReady], timeout: 15)
        child.redraw()
        wait(for: [round1], timeout: 15)
        child.redraw()
        wait(for: [round2], timeout: 15)

        XCTAssertEqual(state.shrinks, 2, "each redraw must shrink once: \(state.all)")
        XCTAssertEqual(state.rounds, 2, "each redraw must restore once: \(state.all)")
    }

    /// A resize that lands mid-jiggle must win: the restore step re-reads the
    /// latest size instead of resurrecting the pre-jiggle one. Judged by the
    /// pty's actual size once the restore has run, not by the last SIGWINCH
    /// report: under load the shrink's handler can print its stale 23x80 after
    /// the resize's 30x100 (re-entrant handler), which failed this test with a
    /// correct restore.
    func testResizeDuringJiggleWins() throws {
        let state = Lines()
        let gotReady = expectation(description: "inner program started")
        let gotNew = expectation(description: "new size reported after jiggle")
        gotReady.assertForOverFulfill = false
        gotNew.assertForOverFulfill = false
        let gotNow = expectation(description: "current size answered")
        let now = Lines()

        let child = try spawnReporter { line in
            _ = state.record(line)
            if line == "READY" { gotReady.fulfill() }
            if line == "R30x100" { gotNew.fulfill() }
            if line.hasPrefix("NOW") { _ = now.record(line); gotNow.fulfill() }
        }
        child.run()
        defer { child.terminate() }

        wait(for: [gotReady], timeout: 15)
        child.redraw()                      // shrink to 23 rows, restore in 120 ms
        child.resize(cols: 100, rows: 30)   // real resize lands mid-jiggle
        wait(for: [gotNew], timeout: 15)
        // Wait for the delayed restore to have run, however late load makes it.
        let restored = expectation(for: NSPredicate { _, _ in !child.isJiggling }, evaluatedWith: nil)
        wait(for: [restored], timeout: 15)

        // The restore must NOT bring back 80x24.
        child.write(Array("?\n".utf8))
        wait(for: [gotNow], timeout: 15)
        XCTAssertEqual(now.all, ["NOW30x100"], "restore resurrected a stale size: \(state.all)")
    }

    /// A blocked signal mask survives fork AND exec. We fork from Swift runtime
    /// threads that have SIGWINCH blocked, so the child inherited a signal it could
    /// never receive: dch's client installed its handler and it never ran, and every
    /// resize was dropped — the phone rotated into landscape and the session stayed
    /// at the portrait width. The child must start with a clear mask.
    func testChildStartsWithAClearSignalMask() throws {
        let gotReady = expectation(description: "inner program started")
        let gotSize = expectation(description: "resize reached a child forked with SIGWINCH blocked")
        gotReady.assertForOverFulfill = false
        gotSize.assertForOverFulfill = false

        let child = try spawnReporter(blockingWinch: true) { line in
            if line == "READY" { gotReady.fulfill() }
            if line == "R30x100" { gotSize.fulfill() }
        }
        child.run()
        defer { child.terminate() }

        wait(for: [gotReady], timeout: 15)
        child.resize(cols: 100, rows: 30)
        wait(for: [gotSize], timeout: 15)
    }
}
