import AppKit
import Darwin
import Foundation
import Network
import os.log

/// Wire protocol between DchTerm and `DchSessionServer`. Length-prefixed binary
/// frames over a raw TCP connection (both ends are ours, so no HTTP/WebSocket
/// handshake is needed — ponytail).
///
///   [type: 1 byte][len: 4 bytes big-endian][payload: len bytes]
///
/// Control payloads are JSON; DATA payloads are raw pty bytes. One connection per
/// operation: LIST/KILL are request→response; ATTACH/CREATE turn the connection
/// into a bidirectional byte pipe for the session's lifetime.
enum DchFrame {
    // client → server
    static let attach: UInt8  = 0x01  // {name, cols, rows}
    static let create: UInt8  = 0x02  // {name?, command:[..], cols, rows}
    static let list: UInt8    = 0x03  // (empty)
    static let kill: UInt8    = 0x04  // {name}
    static let resize: UInt8  = 0x05  // {cols, rows}  (on an attached conn)
    static let rename: UInt8  = 0x06  // {name, alias}  (alias "" clears)
    static let redraw: UInt8  = 0x07  // (empty) force remote repaint (on an attached conn)
    static let machineInfo: UInt8 = 0x08 // (empty) → machineInfoResp; identity handshake
    static let snapshot: UInt8 = 0x09 // (empty) → snapshotResp; authoritative screen (on an attached conn)
    static let putClipboard: UInt8 = 0x0a // raw image bytes → this Mac's clipboard, then ok
    // both directions
    static let data: UInt8    = 0x10  // raw pty bytes
    // server → client
    static let listResp: UInt8 = 0x11 // [{name, alias?, state?}]
    static let exit: UInt8     = 0x12 // {code}
    static let error: UInt8    = 0x13 // {message}
    static let ok: UInt8       = 0x14 // (empty) ack for kill
    static let machineInfoResp: UInt8 = 0x18 // {device_id, hostname, wakeId?}
    static let snapshotResp: UInt8 = 0x19 // raw ANSI screen from dch's VT mirror (empty = unavailable)

    /// Encode one frame. DATA payloads can be large; control payloads are tiny.
    static func encode(_ type: UInt8, _ payload: [UInt8]) -> Data {
        var out = Data(capacity: 5 + payload.count)
        out.append(type)
        var len = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &len) { out.append(contentsOf: $0) }
        out.append(contentsOf: payload)
        return out
    }
    static func encode(_ type: UInt8, json obj: Any) -> Data {
        let data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
        return encode(type, [UInt8](data))
    }
}

/// One client connection. Parses frames off the socket and either answers a
/// control request or, once attached, bridges the pty.
final class DchConnection: @unchecked Sendable {
    private let conn: NWConnection
    private let queue: DispatchQueue
    private let log: Logger
    private let onClose: (ObjectIdentifier) -> Void
    /// Called once this connection owns a dch client for `name`, so the server can
    /// retire any earlier connection still holding a client for the SAME session.
    private let onAttach: (ObjectIdentifier, String) -> Void
    private var closed = false
    private var buffer = Data()
    private var pty: PtyChild?
    /// dch session name of the attached session — needed to ask dch for its mirror.
    private var sessionName: String?

    /// The session this connection attached to, once it has one.
    var attachedSession: String? { sessionName }

    init(conn: NWConnection, queue: DispatchQueue, log: Logger,
         onClose: @escaping (ObjectIdentifier) -> Void,
         onAttach: @escaping (ObjectIdentifier, String) -> Void = { _, _ in }) {
        self.conn = conn
        self.queue = queue
        self.log = log
        self.onClose = onClose
        self.onAttach = onAttach
    }

    func start() {
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.close()
            default: break
            }
        }
        conn.start(queue: queue)
        receive()
    }

    func close() {
        guard !closed else { return }
        closed = true
        pty?.terminate()       // kill the dch client → master daemon survives
        pty = nil
        conn.cancel()
        onClose(ObjectIdentifier(self))
    }

    private func receive() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty { self.buffer.append(data); self.drain() }
            if isComplete || error != nil { self.close(); return }
            if !self.closed { self.receive() }
        }
    }

    /// Pull complete frames out of `buffer` and dispatch them.
    private func drain() {
        while buffer.count >= 5 {
            let type = buffer[buffer.startIndex]
            let len = buffer.withUnsafeBytes { raw -> Int in
                let b = raw.baseAddress!.advanced(by: 1).assumingMemoryBound(to: UInt8.self)
                return (Int(b[0]) << 24) | (Int(b[1]) << 16) | (Int(b[2]) << 8) | Int(b[3])
            }
            guard buffer.count >= 5 + len else { return }   // wait for the rest
            let payload = buffer.subdata(in: buffer.index(buffer.startIndex, offsetBy: 5)..<buffer.index(buffer.startIndex, offsetBy: 5 + len))
            buffer.removeSubrange(buffer.startIndex..<buffer.index(buffer.startIndex, offsetBy: 5 + len))
            handle(type: type, payload: payload)
        }
    }

    private func send(_ frame: Data) {
        conn.send(content: frame, completion: .contentProcessed { _ in })
    }

    private func handle(type: UInt8, payload: Data) {
        switch type {
        case DchFrame.list:
            let rows = DchCommand.listSessions().map { row -> [String: Any] in
                var o: [String: Any] = ["name": row.name]
                if !row.alias.isEmpty { o["alias"] = row.alias }
                if !row.state.isEmpty { o["state"] = row.state }   // working|idle|blocked|done
                return o
            }
            send(DchFrame.encode(DchFrame.listResp, json: rows))
        case DchFrame.kill:
            if let o = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any],
               let n = o["name"] as? String {
                DchCommand.kill(n)
            }
            send(DchFrame.encode(DchFrame.ok, []))
        case DchFrame.rename:
            if let o = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any],
               let n = o["name"] as? String {
                DchCommand.setAlias(n, alias: o["alias"] as? String ?? "")
            }
            send(DchFrame.encode(DchFrame.ok, []))
        case DchFrame.attach, DchFrame.create:
            startSession(type: type, payload: payload)
        case DchFrame.data:
            pty?.write([UInt8](payload))
        case DchFrame.resize:
            if let o = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any] {
                let cols = (o["cols"] as? Int) ?? 80
                let rows = (o["rows"] as? Int) ?? 24
                pty?.resize(cols: cols, rows: rows)
            }
        case DchFrame.redraw:
            pty?.redraw()
        case DchFrame.snapshot:
            sendSnapshot()
        case DchFrame.putClipboard:
            setClipboardImage(payload)
            send(DchFrame.encode(DchFrame.ok, []))
        case DchFrame.machineInfo:
            // Identity-only handshake (read-only, no side effects). Lets the paired
            // app bind this connection to a stable machine + its wake id, so it can
            // wake the right Mac later regardless of which address was dialed. The
            // wake config itself (enabled/cadence) is fetched authenticated from the
            // server; only non-secret identity goes over the tailnet. wakeId is nil
            // until remote-wake was configured while signed in.
            var info: [String: Any] = [
                "device_id": SupporterStore.deviceID(),
                "hostname": SupporterStore.deviceName(),
            ]
            if let wakeId = LiveExtensionHostServices.currentWakeId { info["wakeId"] = wakeId }
            send(DchFrame.encode(DchFrame.machineInfoResp, json: info))
        default:
            break
        }
    }

    /// Put an image the phone copied onto THIS Mac's clipboard. Claude Code's image
    /// paste reads the clipboard of the machine it runs on, so a phone that only
    /// sends ctrl-V pastes whatever the Mac happens to hold — Universal Clipboard
    /// syncs phone images to the Mac unreliably, which is why the phone ships the
    /// bytes itself and then sends ctrl-V.
    ///
    /// Deliberately synchronous on the connection queue: the ctrl-V arrives as the
    /// very next frame, so the clipboard has to be set before this returns.
    private func setClipboardImage(_ data: Data) {
        guard !data.isEmpty, let image = NSImage(data: data) else { return }
        let png = data.starts(with: [0x89, 0x50, 0x4e, 0x47])
            ? data
            : image.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0) }?
                .representation(using: .png, properties: [:])
        let pb = NSPasteboard.general
        pb.clearContents()
        if let png { pb.setData(png, forType: .png) }
        if let tiff = image.tiffRepresentation { pb.setData(tiff, forType: .tiff) }
    }

    /// Answer a snapshot request with dch's own rendered screen (`--read --ansi`).
    /// The master keeps a full VT mirror of the session, so this is the authoritative
    /// picture of what the remote program has drawn — the client can repaint from it
    /// instead of waiting for the TUI to notice it should redraw. An empty payload
    /// means "no mirror" (a session whose master predates dch 1.2, or a lite build):
    /// the client then just keeps whatever it has.
    private func sendSnapshot() {
        guard let name = sessionName, !name.isEmpty else {
            send(DchFrame.encode(DchFrame.snapshotResp, []))
            return
        }
        // `--read` forks dch and round-trips the master socket; keep it off this
        // connection's queue so the pty byte pump never waits on it.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let screen = DchCommand.readScreen(name)
            guard let self else { return }
            self.queue.async {
                guard !self.closed else { return }
                self.send(DchFrame.encode(DchFrame.snapshotResp, [UInt8](screen)))
            }
        }
    }

    private func startSession(type: UInt8, payload: Data) {
        guard pty == nil else { return }  // one session per connection
        let o = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any] ?? [:]
        let name = o["name"] as? String
        sessionName = name
        let command = (o["command"] as? [String]) ?? []
        let cols = (o["cols"] as? Int) ?? 80
        let rows = (o["rows"] as? Int) ?? 24

        let args = DchCommand.spawnArgs(name: name, command: command, attach: type == DchFrame.attach)
        do {
            let child = try PtyChild(
                exe: DchCommand.dchPath, args: args, env: DchCommand.childEnv(),
                cols: cols, rows: rows,
                onOutput: { [weak self] bytes in
                    // Blocking send = real backpressure. This runs on PtyChild's pump
                    // thread, so waiting here stalls the pty read; the pty kernel buffer
                    // then fills and the inner app's write() throttles — no unbounded
                    // growth in NWConnection's send queue on a fast stream (Claude Code).
                    guard let self else { return }
                    let sem = DispatchSemaphore(value: 0)
                    self.conn.send(content: DchFrame.encode(DchFrame.data, bytes),
                                   completion: .contentProcessed { _ in sem.signal() })
                    // Bounded, not forever: a phone that vanished mid-stream never
                    // acknowledges, and an unbounded wait parks this pump thread for
                    // good. The pty then stops being drained, the dch client blocks in
                    // write() — where it ignores SIGHUP — and detaching it becomes
                    // impossible. That is how clients leaked and narrowed the session.
                    // Well past any real stall on a tailnet; TCP keepalive kills the
                    // link at ~70s anyway, so this only fires when it is truly gone.
                    if sem.wait(timeout: .now() + 20) == .timedOut {
                        self.log.error("dch client stalled 20s — dropping the connection")
                        self.queue.async { self.close() }
                    }
                },
                onExit: { [weak self] code in
                    guard let self else { return }
                    // Close only after the exit frame is handed to the stack, and mark
                    // it the final message so the FIN follows the data. cancel() right
                    // after send() could drop the unflushed frame — the client then
                    // saw a link drop, reattached, and resurrected the dead session.
                    self.conn.send(content: DchFrame.encode(DchFrame.exit, json: ["code": code]),
                                   contentContext: .finalMessage,
                                   completion: .contentProcessed { _ in self.close() })
                    // Failsafe: if the completion never fires (client stalled or gone
                    // mid-teardown), don't leak the connection. close() is idempotent.
                    self.queue.asyncAfter(deadline: .now() + 5) { self.close() }
                })
            pty = child
            child.run()
            // Our client is up and has already reported our window size, so retiring
            // the previous one can't leave the master on someone else's size. Order
            // matters: retire AFTER the spawn, never before — a failed spawn would
            // otherwise have killed a working client for nothing.
            if let name, !name.isEmpty { onAttach(ObjectIdentifier(self), name) }
        } catch {
            send(DchFrame.encode(DchFrame.error, json: ["message": "\(error)"]))
            close()
        }
    }
}

// MARK: - dch CLI

/// Resolves the `dch` binary and builds its argument vectors. Centralized so the
/// attach/create/list/kill call sites stay declarative.
enum DchCommand {
    /// Bundled copy first (the "user installs nothing" goal), then a brew install,
    /// then the dev clone, then PATH. ponytail: bundling into Resources is a
    /// build.sh step (TODO) — until then the dev clone path keeps it working.
    static var dchPath: String {
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("dch").path,
            "/opt/homebrew/bin/dch",
            "\(NSHomeDirectory())/personal/dch/dch",
            "/usr/local/bin/dch",
        ].compactMap { $0 }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? "dch"
    }

    /// `-E` disables dch's in-band detach escape (Ctrl-\) so it passes through to the
    /// inner app (Claude Code); the app detaches by closing the TCP connection.
    /// `-f` force-attaches so an app client can mirror a session already attached in
    /// a standalone terminal. dch's `-n name [cmd]` is attach-or-create.
    /// SIGHUP dch clients that outlived the Prosper that spawned them.
    ///
    /// A client killed by `-9`, a crash, or a force quit is reparented to launchd and
    /// keeps its pty — and its window size. dch keeps ONE size per session and the last
    /// client to report wins, so a leftover client at 49 columns silently narrows the
    /// session for the phone that is actually looking at it. SIGHUP is dch's own detach
    /// signal (`attach.c` installs `signal(SIGHUP, die)`): the client leaves, the master
    /// daemon and everything running inside it are untouched.
    static func sweepOrphanedClients() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-axo", "pid=,ppid=,tty=,command="]
        let pipe = Pipe()
        p.standardOutput = pipe
        do { try p.run() } catch { return }
        let out = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let pids = orphanedClientPIDs(ps: String(decoding: out, as: UTF8.self))
        // DchCommand.kill(_:) shadows the global, hence Darwin.kill.
        for pid in pids { Darwin.kill(pid, SIGHUP) }
        guard !pids.isEmpty else { return }
        // A client stuck writing to an undrained pty ignores SIGHUP (and SIGTERM) —
        // observed on 39 leaked clients that only died to SIGKILL. They are leaves: the
        // master daemon and the program inside the session don't notice.
        Thread.sleep(forTimeInterval: 0.3)
        for pid in pids where Darwin.kill(pid, 0) == 0 { Darwin.kill(pid, SIGKILL) }
    }

    /// Parse `ps -axo pid=,ppid=,tty=,command=` for our orphans. Three conditions, all
    /// needed: `ppid == 1` (its Prosper is gone — a live one still owns its children),
    /// a real tty (the `--master-of` daemons are ppid 1 too, but have none, and killing
    /// one would kill the session), and `-E` in the argv, which only Prosper passes.
    static func orphanedClientPIDs(ps: String) -> [pid_t] {
        ps.split(separator: "\n").compactMap { line in
            let f = line.split(separator: " ", omittingEmptySubsequences: true)
            guard f.count >= 4, let pid = pid_t(f[0]), f[1] == "1", f[2] != "??" else { return nil }
            let command = f[3...].joined(separator: " ")
            guard command.contains("dch"), !command.contains("--master-of"),
                  f[3...].contains("-E") else { return nil }
            return pid
        }
    }

    static func spawnArgs(name: String?, command: [String], attach: Bool) -> [String] {
        var args = ["-E"]
        if attach { args.append("-f") }
        if let name, !name.isEmpty { args += ["-n", name] }
        args += command
        return args
    }

    static func childEnv() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        // If Prosper was itself launched from inside a dch session, its env carries
        // DCH_SESSION and dch would refuse to spawn ("nesting disabled"). Strip it.
        env.removeValue(forKey: "DCH_SESSION")
        if Preferences.isolateRemoteSessions {
            // Private socket dir so app sessions don't intermix with standalone dch.
            env["DCH_SOCKET_DIR"] = "\(NSHomeDirectory())/.config/prosper/dch-isolated"
        }
        return env
    }

    /// Sessions with dch's own agent state (`working`/`idle`/`blocked`/`done`),
    /// which it resolves from the session's rendered screen — that's why we ask dch
    /// instead of guessing from output timestamps. `--ls-json` arrived in dch 1.4;
    /// against an older binary it prints nothing and we fall back to `-lj`'s
    /// `name\talias\tactivityEpoch` lines (state empty).
    static func listSessions() -> [(name: String, alias: String, activityEpoch: Int, state: String)] {
        let rows = parseListJSON(runCapturingData(args: ["--ls-json"]))
        if !rows.isEmpty { return rows }
        return parseListTSV(runCapturing(args: ["-lj"]))
    }

    /// `[{"name","alias","activity_epoch","state"}]` — dch 1.4+ `--ls-json`.
    static func parseListJSON(_ data: Data) -> [(name: String, alias: String, activityEpoch: Int, state: String)] {
        guard let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
        return rows.compactMap { o in
            guard let name = o["name"] as? String, !name.isEmpty else { return nil }
            return (name, o["alias"] as? String ?? "",
                    o["activity_epoch"] as? Int ?? 0, o["state"] as? String ?? "")
        }
    }

    /// `name\talias\tactivityEpoch` lines — every dch's `-lj`, state unknown.
    static func parseListTSV(_ text: String) -> [(name: String, alias: String, activityEpoch: Int, state: String)] {
        text
            .split(separator: "\n")
            .compactMap { line in
                let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
                guard let name = parts.first, !name.isEmpty else { return nil }
                let alias = parts.count > 1 ? String(parts[1]) : ""
                let epoch = parts.count > 2 ? Int(parts[2]) ?? 0 : 0
                return (String(name), alias, epoch, "")
            }
    }

    /// dch's rendered screen for `name`, colors included, with the caret appended as a
    /// CUP when dch can tell us where it is. Empty when the master has no VT mirror
    /// (dch < 1.2 / lite build — it exits 3 and prints nothing).
    ///
    /// The mirror is cell contents only, so a client painting it has to guess the
    /// caret — which drew the phone's input row a line off its box. `--read --cursor`
    /// (dch ≥ 1.5) reports `cursor <row> <col> <visible> <wrap>` on stderr; turning
    /// that into `ESC[row;colH` needs no protocol change, because it's just more
    /// screen bytes. Older dch rejects the flag and older masters report nothing —
    /// both fall back to the screen alone.
    static func readScreen(_ name: String) -> Data {
        let (screen, err) = runCapturingBoth(args: ["--read", name, "--ansi", "--cursor"])
        guard !screen.isEmpty else { return runCapturingData(args: ["--read", name, "--ansi"]) }
        guard let cup = cursorCUP(err) else { return screen }
        return screen + Data(cup.utf8)
    }

    /// `cursor 7 12 1 0` (1-based, on stderr) → `ESC[7;12H`.
    static func cursorCUP(_ stderrText: String) -> String? {
        for line in stderrText.split(separator: "\n") where line.hasPrefix("cursor ") {
            let f = line.split(separator: " ")
            guard f.count >= 3, let row = Int(f[1]), let col = Int(f[2]),
                  row > 0, col > 0 else { continue }
            return "\u{1b}[\(row);\(col)H"
        }
        return nil
    }

    /// The dch socket directory the spawned client/master use, resolved exactly as
    /// dch's `compute_sock_dir` does from the SAME env we hand it: `$DCH_SOCKET_DIR`,
    /// else `$XDG_RUNTIME_DIR/dch-$UID`, else `/tmp/dch-$UID`. Authoritative in every
    /// isolation mode (no guessing, no subprocess).
    static var socketDir: String {
        let env = childEnv()
        if let d = env["DCH_SOCKET_DIR"], !d.isEmpty { return d }
        if let x = env["XDG_RUNTIME_DIR"], !x.isEmpty { return "\(x)/dch-\(getuid())" }
        return "/tmp/dch-\(getuid())"
    }

    /// True while the transport a remote session needs is up: the default route is
    /// alive AND a Tailscale address is assigned. Nothing here is "remote" without
    /// both: on a network drop the local pty of a detached session keeps stamping
    /// activity and stale NWConnections linger for ~70s of TCP keepalive, so the
    /// keep-awake hold used to be renewed forever for a session no client could
    /// possibly reach — the Mac never slept. The address check alone is NOT enough:
    /// Tailscale's utun keeps its 100.x address when the physical network drops, so
    /// only the route check catches the actual "Mac lost network" case (the address
    /// check catches Tailscale being stopped). No transport → zero remote sessions,
    /// everywhere this is read.
    static var transportUp: Bool {
        SystemInfo.networkReachable() && DchSessionServer.tailscaleIPv4() != nil
    }

    /// True if any detached session produced pty output within `seconds`. Lets the
    /// keep-awake hold survive a client disconnect while a session is still working:
    /// the master stamps `<name>.sock.act`'s mtime on each output, so we just scan
    /// those sidecars directly — no `dch` fork on the (possibly hours-long) poll
    /// loop. A long-running command that prints nothing reads as idle — an accepted
    /// limitation (per the design).
    static func anySessionActive(within seconds: Int) -> Bool {
        guard transportUp else { return false }
        let dir = socketDir
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return false }
        let cutoff = Date().addingTimeInterval(-Double(seconds))
        for n in names where n.hasSuffix(".sock.act") {
            if let m = (try? fm.attributesOfItem(atPath: "\(dir)/\(n)"))?[.modificationDate] as? Date,
               m >= cutoff {
                return true
            }
        }
        return false
    }

    /// True if ANY detached session exists at all (its socket is present),
    /// regardless of activity. Drives the keep-awake watch mode: with no sessions
    /// there is nothing whose resumed output could re-acquire the hold, so the
    /// watcher tick can stop. Same no-fork sidecar-scan approach as
    /// `anySessionActive` (a `.sock.act` sidecar ends in ".act", so the suffix
    /// filter below sees only the live sockets).
    static func anySessionExists() -> Bool {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: socketDir)
        else { return false }
        return names.contains { $0.hasSuffix(".sock") }
    }

    /// Per-session keep-awake view for the OpenLid Status UI: every live session
    /// plus whether it stamped pty output within `seconds` — the exact per-session
    /// signal `anySessionActive` OR's into the keep-awake hold. (A session running a
    /// silent long command reads inactive, same documented limitation.)
    static func sessionsStatus(within seconds: Int) -> [(name: String, alias: String, active: Bool)] {
        let dir = socketDir
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-Double(seconds))
        let up = transportUp
        return listSessions().map { s in
            let m = (try? fm.attributesOfItem(atPath: "\(dir)/\(s.name).sock.act"))?[.modificationDate] as? Date
            return (s.name, s.alias, up && (m.map { $0 >= cutoff } ?? false))
        }
    }

    static func kill(_ name: String) {
        _ = runCapturing(args: ["-k", name])
    }

    /// Set (or clear, when empty) a session's display alias.
    static func setAlias(_ name: String, alias: String) {
        _ = runCapturing(args: ["-m", name, alias])
    }

    private static func runCapturing(args: [String]) -> String {
        String(data: runCapturingData(args: args), encoding: .utf8) ?? ""
    }

    /// Run dch for a short control command and capture stdout. Not used for attach
    /// (that needs a pty) — only for `--ls-json` / `-k` / `--read`, whose output is
    /// raw bytes (escape sequences), hence Data rather than String.
    private static func runCapturingData(args: [String]) -> Data {
        runCapturingBoth(args: args).out
    }

    /// Same as `runCapturingData`, plus stderr as text — `--read --cursor` reports the
    /// caret there so it can't corrupt the screen on stdout.
    private static func runCapturingBoth(args: [String]) -> (out: Data, err: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: dchPath)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "DCH_SESSION")
        if Preferences.isolateRemoteSessions {
            env["DCH_SOCKET_DIR"] = "\(NSHomeDirectory())/.config/prosper/dch-isolated"
        }
        p.environment = env
        let pipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = pipe
        p.standardError = errPipe
        do { try p.run() } catch { return (Data(), "") }
        // Screen first (it can be tens of KB), then stderr (one line at most, so it
        // fits the pipe buffer while we drain stdout — no deadlock).
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let err = errPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (data, String(data: err, encoding: .utf8) ?? "")
    }
}
