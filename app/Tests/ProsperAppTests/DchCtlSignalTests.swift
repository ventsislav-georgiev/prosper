import Darwin
import Network
import os
import XCTest
@testable import ProsperApp

/// QA #729 F1: a ctl's dch gets one SIGTERM per request, whatever edge comes after the cut (a 0x34, a close,
/// a server stop), as dch serve (conn_end cuts only an uncut ctl, serve.c:1827-1828@v1.54.0; a stop only moves
/// the SIGKILL forward, :1502-1503). dch's ty_on_sig _exits on a second signal (dch.c:6256-6272@v1.54.0).
/// The "dch" is a /bin/sh fake in a tempDir() that logs each SIGTERM and keeps running, so a second one is
/// counted, not hidden by an exit. Fakes are SIGKILLed at teardown by their recorded pids, never by name.
final class DchCtlSignalTests: XCTestCase {
    private final class Frames: @unchecked Sendable {
        let lock = NSLock()
        var all: [Data] = []
    }

    private struct Rig {
        let conn: DchConnection
        let queue: DispatchQueue
        let frames: Frames
    }

    private func rig(_ script: String, agentGrace: TimeInterval? = nil) -> Rig {
        let queue = DispatchQueue(label: "test.dchconn.ctlsignal")
        let frames = Frames()
        let conn = DchConnection(conn: NWConnection(host: "127.0.0.1", port: 9, using: .tcp), queue: queue,
                                 log: Logger(subsystem: "test", category: "dch"), onClose: { @Sendable _ in })
        conn.sendOverride = { f in frames.lock.withLock { frames.all.append(f) } }
        let sock = tempDir("ctlsig-sock").path
        conn.ctl.path = { script }
        conn.ctl.env = { ["DCH_SOCKET_DIR": sock, "PATH": "/usr/bin:/bin"] }
        conn.ctl.after = { _, _ in }   // no timeout fires on its own
        if let agentGrace { conn.ctl.agentGrace = agentGrace }
        conn.clipboard.enabled = { false }
        conn.commands.enabled = { false }
        conn.listSessions = { [] }
        conn.kill = { _ in }
        conn.rename = { _, _ in nil }
        conn.spawn = { _, _, _, _, _, _ in throw PtyChild.PtyError.forkFailed }
        addTeardownBlock { queue.sync { conn.close() } }
        return Rig(conn: conn, queue: queue, frames: frames)
    }

    /// A fake dch: $D/pid, a kid in its group in $D/kid, one "term" line in $D/sig per SIGTERM. `onTerm`
    /// runs after the line (default: keep running).
    private func fake(onTerm: String = "") throws -> (path: String, dir: URL) {
        let dir = tempDir("ctlsig-fake")
        let path = dir.appendingPathComponent("dch").path
        try """
            #!/bin/sh
            D='\(dir.path)'
            echo $$ > "$D/pid"; /bin/sleep 30 & echo $! > "$D/kid"
            trap 'echo term >> "$D/sig"; \(onTerm)' TERM
            printf 'working\\n'; while :; do /bin/sleep 0.05; done

            """.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        addTeardownBlock {
            for f in ["pid", "kid"] {
                if let s = try? String(contentsOf: dir.appendingPathComponent(f), encoding: .utf8),
                   let pid = pid_t(s.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1, Darwin.kill(pid, 0) == 0 {
                    Darwin.kill(pid, SIGKILL)
                }
            }
        }
        return (path, dir)
    }

    @discardableResult
    private func wait(_ secs: TimeInterval, _ cond: () -> Bool) -> Bool {
        let end = Date() + secs
        while Date() < end { if cond() { return true }; usleep(20_000) }
        return cond()
    }

    private func pid(_ dir: URL, _ name: String) -> pid_t? {
        var p: pid_t?
        wait(5) {
            p = (try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8))
                .flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            return p != nil
        }
        return p
    }

    private func terms(_ dir: URL) -> Int {
        ((try? String(contentsOf: dir.appendingPathComponent("sig"), encoding: .utf8)) ?? "")
            .split(separator: "\n").filter { $0 == "term" }.count
    }

    private func output(_ r: Rig) -> Bool {
        r.frames.lock.withLock { r.frames.all.contains { $0.first == DchFrame.ctlStdout } }
    }

    enum Edge: String { case cancel, close, stop }

    private func apply(_ e: Edge, _ r: Rig) {
        switch e {
        case .cancel: r.queue.sync { r.conn.ingest(DchFrame.encode(DchFrame.ctlCancel, [])) }
        case .close: r.queue.sync { r.conn.close() }
        case .stop: r.queue.sync { r.conn.serverStop() }
        }
    }

    /// Starts `verb` on the fake, waits for its output, then runs `edges` in order, each after the trap logged
    /// the one before (a signal sent while the first is pending would coalesce and hide a second).
    private func run(_ verb: [String], _ edges: [Edge], agentGrace: TimeInterval? = nil)
        throws -> (r: Rig, dir: URL, dch: pid_t, kid: pid_t, at: Date) {
        let f = try fake()
        let r = rig(f.path, agentGrace: agentGrace)
        r.queue.sync { r.conn.ingest(DchFrame.encode(DchFrame.ctl, json: ["argv": verb])) }
        let dch = try XCTUnwrap(pid(f.dir, "pid")), kid = try XCTUnwrap(pid(f.dir, "kid"))
        XCTAssertTrue(wait(5) { output(r) })
        var at = Date()
        for (i, e) in edges.enumerated() {
            at = Date()
            apply(e, r)
            if i == 0 { XCTAssertTrue(wait(5) { terms(f.dir) == 1 }, "the first edge's SIGTERM: \(edges)") }
        }
        return (r, f.dir, dch, kid, at)
    }

    private static let say = ["--say", "alpha", "--json", "--", "hi"]

    /// Every pair of edges on an agent verb (660 s grace): exactly one SIGTERM.
    func testACutDchIsSIGTERMedOnce() throws {
        let pairs: [[Edge]] = [[.cancel, .stop], [.cancel, .close], [.cancel, .cancel], [.stop], [.close],
                               [.close, .stop], [.stop, .close], [.stop, .cancel], [.close, .cancel]]
        for edges in pairs {
            let s = try run(Self.say, edges)
            usleep(500_000)   // a second SIGTERM would be logged by now (the fake's loop sleeps 0.05 s)
            XCTAssertEqual(terms(s.dir), 1, "one SIGTERM after \(edges)")
        }
    }

    /// A --read (2 s grace) the same: a 0x34 then a stop, a 0x34 then a close.
    func testAShortGraceVerbIsSIGTERMedOnce() throws {
        for edges: [Edge] in [[.cancel, .stop], [.cancel, .close]] {
            let s = try run(["--read", "alpha"], edges)
            usleep(500_000)
            XCTAssertEqual(terms(s.dir), 1, "one SIGTERM after \(edges)")
        }
    }

    /// A stop after a 0x34 on an agent verb: no new SIGTERM, and the group's SIGKILL comes about 2 s from
    /// the stop (serve's g_stop clamp), not at the 0x34's 660 s. A stop alone: one SIGTERM, the same 2 s.
    func testAStopAfterACancelBringsTheSIGKILLForward() throws {
        for edges: [Edge] in [[.cancel, .stop], [.stop]] {
            let s = try run(Self.say, edges)
            XCTAssertTrue(wait(15) { Darwin.kill(s.dch, 0) != 0 }, "dch SIGKILLed: \(edges)")
            XCTAssertTrue(wait(5) { Darwin.kill(s.kid, 0) != 0 }, "its group too: \(edges)")
            XCTAssertLessThan(Date().timeIntervalSince(s.at), 15, "about 2 s, not 660 s: \(edges)")
            XCTAssertEqual(terms(s.dir), 1, "\(edges)")
        }
    }

    /// A cut's grace timer outlives a dch reaped inside it: when it fires, nothing is signalled (the pid
    /// guard: a closed connection keeps its job, so the timer reaches it), so a group left behind (or a
    /// recycled pid) is never SIGKILLed by it, and a stop after the reap arms nothing. Here dch exits on the
    /// SIGTERM and leaves its kid in the group.
    func testALateTimerSignalsNothingOnceDchIsReaped() throws {
        for first: Edge in [.close, .cancel] {
            let f = try fake(onTerm: "exit 0")
            let r = rig(f.path, agentGrace: 1)
            r.queue.sync { r.conn.ingest(DchFrame.encode(DchFrame.ctl, json: ["argv": Self.say])) }
            let dch = try XCTUnwrap(pid(f.dir, "pid")), kid = try XCTUnwrap(pid(f.dir, "kid"))
            XCTAssertTrue(wait(5) { output(r) })
            apply(first, r)
            XCTAssertTrue(wait(5) { Darwin.kill(dch, 0) != 0 }, "dch exits on the SIGTERM: \(first)")
            usleep(200_000)   // the reap clears the job's pid
            apply(.stop, r)
            usleep(3_000_000)   // past the 1 s grace and a stop's 2 s
            XCTAssertEqual(Darwin.kill(kid, 0), 0, "the leftover kid was not SIGKILLed by a late timer: \(first)")
            XCTAssertEqual(terms(f.dir), 1, "\(first)")
        }
    }
}
