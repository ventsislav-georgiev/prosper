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

    /// #1024: every signal CodexHarness.sendSignal sends (probes left out), with its pid and send time, forwarded so
    /// the fake is really signalled. No queue.sync in it: term's SIGTERM is sent on the connection queue.
    private final class Sent: @unchecked Sendable {
        private let lock = NSLock()
        private var log: [(pid: pid_t, sig: Int32, at: Date)] = []
        func add(_ pid: pid_t, _ sig: Int32) { lock.withLock { log.append((pid, sig, Date())) } }
        /// The ones to `pid` or its group.
        func of(_ pid: pid_t) -> [(pid: pid_t, sig: Int32, at: Date)] { lock.withLock { log.filter { $0.pid == pid || $0.pid == -pid } } }
        func terms(_ pid: pid_t) -> Int { of(pid).filter { $0.sig == SIGTERM }.count }
    }

    private func record() -> Sent {
        let sent = Sent(), saved = CodexHarness.sendSignal
        CodexHarness.sendSignal = { pid, sig in
            if sig != 0 { sent.add(pid, sig) }
            return Darwin.kill(pid, sig)
        }
        addTeardownBlock { CodexHarness.sendSignal = saved }
        return sent
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
        wait(20) {   // #1024: returns at the write; 20 s only bounds a red run
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
        throws -> (r: Rig, dir: URL, dch: pid_t, kid: pid_t, at: Date, sent: Sent) {
        let f = try fake()
        let r = rig(f.path, agentGrace: agentGrace)
        r.queue.sync { r.conn.ingest(DchFrame.encode(DchFrame.ctl, json: ["argv": verb])) }
        let dch = try XCTUnwrap(pid(f.dir, "pid")), kid = try XCTUnwrap(pid(f.dir, "kid"))
        XCTAssertTrue(wait(20) { output(r) })
        let sent = record()
        var at = Date()
        for (i, e) in edges.enumerated() {
            at = Date()
            apply(e, r)
            // #1024: term() sends on the connection queue inside apply's queue.sync, so the seam has it now, no wait.
            if i == 0 { XCTAssertEqual(sent.terms(dch), 1, "the first edge's SIGTERM, sent by the edge: \(edges)") }
            // The trap must have run before the next edge; 20 s bounds only a red run (5 s failed under load).
            if i == 0 { XCTAssertTrue(wait(20) { terms(f.dir) == 1 }, "the first edge's SIGTERM: \(edges)") }
        }
        return (r, f.dir, dch, kid, at, sent)
    }

    private static let say = ["--say", "alpha", "--json", "--", "hi"]

    /// Every pair of edges on an agent verb (660 s grace): exactly one SIGTERM.
    func testACutDchIsSIGTERMedOnce() throws {
        let pairs: [[Edge]] = [[.cancel, .stop], [.cancel, .close], [.cancel, .cancel], [.stop], [.close],
                               [.close, .stop], [.stop, .close], [.stop, .cancel], [.close, .cancel]]
        for edges in pairs {
            let s = try run(Self.say, edges)
            // #1024: counted at the send (every SIGTERM path of a close, 0x34 or stop sends inside its edge), so two
            // back to back that the trap would see as one still count two; no 0.5 s wait for the trap.
            XCTAssertEqual(s.sent.terms(s.dch), 1, "one SIGTERM sent after \(edges)")
            XCTAssertEqual(terms(s.dir), 1, "one SIGTERM after \(edges)")
        }
    }

    /// A --read (2 s grace) the same: a 0x34 then a stop, a 0x34 then a close.
    func testAShortGraceVerbIsSIGTERMedOnce() throws {
        for edges: [Edge] in [[.cancel, .stop], [.cancel, .close]] {
            let s = try run(["--read", "alpha"], edges)
            XCTAssertEqual(s.sent.terms(s.dch), 1, "one SIGTERM sent after \(edges)")   // #1024: as above
            XCTAssertEqual(terms(s.dir), 1, "one SIGTERM after \(edges)")
        }
    }

    /// A stop after a 0x34 on an agent verb: no new SIGTERM, and the group's SIGKILL comes about 2 s from
    /// the stop (serve's g_stop clamp), not at the 0x34's 660 s. A stop alone: one SIGTERM, the same 2 s.
    func testAStopAfterACancelBringsTheSIGKILLForward() throws {
        for edges: [Edge] in [[.cancel, .stop], [.stop]] {
            let s = try run(Self.say, edges)
            // #1024: the waits return at the death; their bounds only end a red run.
            XCTAssertTrue(wait(30) { Darwin.kill(s.dch, 0) != 0 }, "dch SIGKILLed: \(edges)")
            XCTAssertTrue(wait(15) { Darwin.kill(s.kid, 0) != 0 }, "its group too: \(edges)")
            // #1024: read off the seam at the send, not at the test's late poll: the stop's SIGKILL to the group.
            let sent = s.sent.of(s.dch)
            XCTAssertEqual(sent.map { $0.pid }, [s.dch, -s.dch], "\(edges)")
            XCTAssertEqual(sent.map { $0.sig }, [SIGTERM, SIGKILL], "one SIGTERM to dch, one SIGKILL to its group: \(edges)")
            if sent.count == 2, let kill = sent.last {
                XCTAssertGreaterThanOrEqual(kill.at.timeIntervalSince(s.at), 1.9, "not before the stop's 2 s: \(edges)")
                XCTAssertLessThan(kill.at.timeIntervalSince(s.at), 15, "about 2 s, not 660 s: \(edges)")
            }
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
            // #1024: 3 s, not 1: the timer must fire after the reap, and 1 s from the SIGTERM was not always enough under load.
            let grace: TimeInterval = 3
            let r = rig(f.path, agentGrace: grace)
            r.queue.sync { r.conn.ingest(DchFrame.encode(DchFrame.ctl, json: ["argv": Self.say])) }
            let dch = try XCTUnwrap(pid(f.dir, "pid")), kid = try XCTUnwrap(pid(f.dir, "kid"))
            XCTAssertTrue(wait(20) { output(r) })
            let sent = record(), cut = Date()
            apply(first, r)
            // A zombie still answers kill(pid, 0): gone means waitpid ran, and the termination handler clears the
            // job's pid right after it (#1024: no 0.2 s wait).
            XCTAssertTrue(wait(20) { Darwin.kill(dch, 0) != 0 }, "dch exits on the SIGTERM: \(first)")
            apply(.stop, r)
            // #1024: a negative no later event shows, so a wait derived from the timers it rules out: the cut's
            // grace and the stop's 2 s, plus 0.5 s.
            let until = max(cut + grace, Date() + DchCtl.cancelGrace) + 0.5
            usleep(useconds_t(max(0, until.timeIntervalSinceNow) * 1_000_000))
            XCTAssertEqual(Darwin.kill(kid, 0), 0, "the leftover kid was not SIGKILLed by a late timer: \(first)")
            XCTAssertEqual(sent.of(dch).map { $0.sig }, [SIGTERM], "the cut's SIGTERM and no SIGKILL sent: \(first)")
            XCTAssertEqual(terms(f.dir), 1, "\(first)")
        }
    }
}
