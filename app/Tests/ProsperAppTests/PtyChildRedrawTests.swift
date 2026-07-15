import XCTest
@testable import ProsperApp

/// PtyChild.redraw() must force a repaint a Node/Ink TUI cannot ignore: a real
/// size jiggle (rows-1, then restore) — two genuine SIGWINCHes with CHANGED
/// sizes. A plain same-size SIGWINCH is dropped by Node's resize check, which
/// left Claude Code's question prompts as a black screen on attach.
final class PtyChildRedrawTests: XCTestCase {

    /// Inner script mirrors attach_tui.py in dch: report `R<rows>` on every
    /// SIGWINCH. redraw() must yield rows-1 then rows.
    func testRedrawJigglesRows() throws {
        let script = """
        trap 'stty size | awk '\\''{print "R"$1}'\\''' WINCH
        echo READY
        while :; do sleep 0.1; done
        """
        var lines: [String] = []
        let lock = NSLock()
        let gotReady = expectation(description: "inner script started")
        // Two rounds: the second proves the jiggling flag releases after the
        // restore instead of wedging every later redraw().
        let round1 = expectation(description: "first jiggle: rows-1 then rows")
        let round2 = expectation(description: "second jiggle: flag released")
        var readyDone = false, shrinks = 0, rounds = 0

        let child = try PtyChild(
            exe: "/bin/sh", args: ["-c", script], env: ["PATH": "/usr/bin:/bin"],
            cols: 80, rows: 24,
            onOutput: { bytes in
                lock.lock(); defer { lock.unlock() }
                for line in String(decoding: bytes, as: UTF8.self).split(separator: "\n") {
                    let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !t.isEmpty else { continue }
                    lines.append(t)
                    if t == "READY", !readyDone { readyDone = true; gotReady.fulfill() }
                    if t == "R23" { shrinks += 1 }
                    // Restore lands after its shrink: full round = 23 then 24.
                    if t == "R24", shrinks > rounds {
                        rounds += 1
                        if rounds == 1 { round1.fulfill() }
                        if rounds == 2 { round2.fulfill() }
                    }
                }
            },
            onExit: { _ in })
        child.run()
        defer { child.terminate() }

        wait(for: [gotReady], timeout: 5)
        child.redraw()
        wait(for: [round1], timeout: 5)
        child.redraw()
        wait(for: [round2], timeout: 5)

        lock.lock(); defer { lock.unlock() }
        XCTAssertEqual(shrinks, 2, "each redraw must shrink once: \(lines)")
        XCTAssertEqual(rounds, 2, "each redraw must restore once: \(lines)")
    }

    /// A resize that lands mid-jiggle must win: the restore step re-reads the
    /// latest size instead of resurrecting the pre-jiggle one.
    func testResizeDuringJiggleWins() throws {
        let script = """
        trap 'stty size | awk '\\''{print "R"$1"x"$2}'\\''' WINCH
        echo READY
        while :; do sleep 0.1; done
        """
        var lines: [String] = []
        let lock = NSLock()
        let gotReady = expectation(description: "inner script started")
        let gotNew = expectation(description: "new size reported after jiggle")
        var readyDone = false, newDone = false

        let child = try PtyChild(
            exe: "/bin/sh", args: ["-c", script], env: ["PATH": "/usr/bin:/bin"],
            cols: 80, rows: 24,
            onOutput: { bytes in
                lock.lock(); defer { lock.unlock() }
                for line in String(decoding: bytes, as: UTF8.self).split(separator: "\n") {
                    let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !t.isEmpty else { continue }
                    lines.append(t)
                    if t == "READY", !readyDone { readyDone = true; gotReady.fulfill() }
                    if t == "R30x100", !newDone { newDone = true; gotNew.fulfill() }
                }
            },
            onExit: { _ in })
        child.run()
        defer { child.terminate() }

        wait(for: [gotReady], timeout: 5)
        child.redraw()                      // shrink to 23 rows, restore in 120 ms
        child.resize(cols: 100, rows: 30)   // real resize lands mid-jiggle
        wait(for: [gotNew], timeout: 5)
        // Let the +120 ms restore land before judging what it restored to.
        Thread.sleep(forTimeInterval: 0.4)

        lock.lock(); defer { lock.unlock() }
        // The restore must NOT bring back 80x24.
        if let last = lines.last(where: { $0.hasPrefix("R") }) {
            XCTAssertEqual(last, "R30x100", "restore resurrected a stale size: \(lines)")
        } else {
            XCTFail("no size reports: \(lines)")
        }
    }
}
