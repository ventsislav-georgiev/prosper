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
                if row.agents > 0 { o["agents"] = row.agents }     // live subagents; absent from older dch
                o.merge(row.metaWire) { $1 }                       // "meta"/"meta_epoch", dch 1.22+
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
        let pb = Pasteboard.general
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

// MARK: - Session list rows

/// One `dch --ls-json` (or `-lj`) row: the one decode Agent Island and Remote
/// Terminal share. `meta`/`metaEpoch` are dch 1.22+; older dch omits them (nil, 0).
struct DchListRow: Equatable, Sendable {
    let name: String
    let alias: String
    let activityEpoch: Int
    let state: String
    let agents: Int
    var meta: DchSessionMeta? = nil
    /// When the meta's content last changed (not liveness); 0 = unknown.
    var metaEpoch: Int = 0
    /// #578: the dch version of the master serving it; "" from a master too old to say.
    var version: String = ""

    /// The phone's `meta`/`meta_epoch` row keys, re-encoded from the decoded fields
    /// (never dch's raw JSON); empty when there is no meta or nothing survives the
    /// filter. The phone is a second untrusted-text consumer: only allowlisted PR URLs
    /// go out, repo/title truncated.
    var metaWire: [String: Any] {
        guard let meta else { return [:] }
        var m: [String: Any] = [:]
        if let t = meta.tasks {
            var o: [String: Any] = [:]
            if let v = t.done { o["done"] = v }
            if let v = t.total { o["total"] = v }
            if let v = t.inProgress { o["in_progress"] = v }
            if let v = t.queued { o["queued"] = v }
            if !o.isEmpty { m["tasks"] = o }
        }
        var prs: [String: Any] = [:]
        let open = meta.openPRs.compactMap { pr -> [String: Any]? in
            // repo/num come from the URL, not dch's fields, so the chip names what opens.
            guard let u = pr.pullURL else { return nil }
            let p = u.path.split(separator: "/")   // owner, repo, "pull", digits
            var o: [String: Any] = ["url": u.absoluteString, "repo": String("\(p[0])/\(p[1])".prefix(Self.maxRepoChars)),
                                    "title": String(String.UnicodeScalarView(pr.title.unicodeScalars.prefix(Self.maxTitleChars)))]
            if let n = Int(p[3]) { o["num"] = n }
            return o
        }
        // Nothing left after filtering: no meta key at all, as with no meta.
        guard m["tasks"] != nil || !open.isEmpty || meta.merged != nil else { return [:] }
        prs["open"] = open
        if let v = meta.merged { prs["merged"] = v }
        m["prs"] = prs
        var w: [String: Any] = ["meta": m]
        if metaEpoch > 0 { w["meta_epoch"] = metaEpoch }
        return w
    }

    static let maxRepoChars = 100
    /// Unicode scalars, not Characters: combining marks cannot grow a "200" title.
    static let maxTitleChars = 200
}

/// dch 1.22's per-session `meta`, written by `dch --meta` from ANY program in the
/// session, so untrusted: every key is optional and decoded on its own, a wrong
/// type drops that key only, counts clamp to >= 0, unknown keys are ignored.
struct DchSessionMeta: Equatable, Sendable {
    struct Tasks: Equatable, Sendable {
        var done: Int?, total: Int?, inProgress: Int?, queued: Int?
    }

    struct PR: Equatable, Sendable {
        let url: String
        let repo: String
        let num: Int?
        /// Plain text for a tooltip or accessibility label, never markup or a link.
        let title: String

        /// `url` only when it is exactly `https://github.com/<owner>/<repo>/pull/<digits>`:
        /// no userinfo, port, query or fragment, owner/repo in GitHub's name charset
        /// and within GitHub's lengths (owner 39, repo 100), so the forwarded url is bounded.
        /// Anything else is a label, never opened.
        var pullURL: URL? {
            guard let c = URLComponents(string: url), c.scheme == "https", c.host == "github.com",
                  c.user == nil, c.password == nil, c.port == nil, c.query == nil, c.fragment == nil
            else { return nil }
            let p = c.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false)
            func name(_ s: Substring) -> Bool {
                !s.isEmpty && s != "." && s != ".."
                    && s.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "-_.".unicodeScalars.contains($0)) }
            }
            guard p.count == 5, p[0].isEmpty, name(p[1]), name(p[2]), p[1].count <= 39, p[2].count <= 100, p[3] == "pull",
                  (1...9).contains(p[4].count), p[4].allSatisfy({ $0.isASCII && $0.isNumber })
            else { return nil }
            return c.url
        }

        /// "prosper#12": the repo's name part and the number. From the URL when it
        /// is clickable, so the label names what opens; else from `repo`/`num`.
        var label: String? {
            if let u = pullURL {
                let p = u.path.split(separator: "/")
                return "\(p[1])#\(p[3])"
            }
            guard let num, let repoName = repo.split(separator: "/").last else { return nil }
            return "\(repoName)#\(num)"
        }
    }

    var tasks: Tasks?
    var openPRs: [PR] = []
    var merged: Int?

    /// dch caps `prs.open` at 50; so does the decode, whatever the writer sent.
    static let maxOpenPRs = 50

    /// A JSON integer clamped to >= 0; nil for anything else (bools included:
    /// JSONSerialization hands them over as NSNumber, and `true as? Int` is 1).
    static func count(_ v: Any?) -> Int? {
        guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), let i = v as? Int else { return nil }
        return max(0, i)
    }

    /// nil when `json` is not an object (dch's null, a missing key).
    init?(json: Any?) {
        guard let o = json as? [String: Any] else { return nil }
        if let t = o["tasks"] as? [String: Any] {
            tasks = Tasks(done: Self.count(t["done"]), total: Self.count(t["total"]),
                          inProgress: Self.count(t["in_progress"]), queued: Self.count(t["queued"]))
        }
        if let p = o["prs"] as? [String: Any] {
            merged = Self.count(p["merged"])
            openPRs = ((p["open"] as? [Any]) ?? []).prefix(Self.maxOpenPRs).compactMap { e in
                guard let e = e as? [String: Any] else { return nil }
                return PR(url: e["url"] as? String ?? "", repo: e["repo"] as? String ?? "",
                          num: Self.count(e["num"]), title: e["title"] as? String ?? "")
            }
        }
    }

    init(tasks: Tasks? = nil, openPRs: [PR] = [], merged: Int? = nil) {
        (self.tasks, self.openPRs, self.merged) = (tasks, openPRs, merged)
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
        if let dchPathOverride { return dchPathOverride }
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("dch").path,
            "/opt/homebrew/bin/dch",
            "\(NSHomeDirectory())/personal/dch/dch",
            "/usr/local/bin/dch",
        ].compactMap { $0 }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? "dch"
    }

    /// Test seam (#486): the executable every dch call runs. Tests point it at
    /// /bin/sh or a sleeping script, never at dch.
    nonisolated(unsafe) static var dchPathOverride: String?

    // MARK: Control verbs (#578)

    /// The binaries a control verb (--history, --revive; later --restart, --spawn)
    /// may run with. Never ~/personal/dch/dch: that is dch's working tree, built
    /// from uncommitted code, so its version string proves nothing. Homebrew first,
    /// so it wins a version tie: --restart re-execs masters onto the calling
    /// binary's path, and a path inside Prosper.app goes away when the app moves.
    static var controlCandidates: [String] {
        ["/opt/homebrew/bin/dch", Bundle.main.resourceURL?.appendingPathComponent("dch").path,
         "/usr/local/bin/dch"].compactMap { $0 }
    }

    /// `dch --version` is exactly "dch X.Y.Z" (one trailing newline allowed).
    static func parseVersion(_ s: String) -> [Int]? {
        let t = s.hasSuffix("\n") ? String(s.dropLast()) : s
        guard t.hasPrefix("dch ") else { return nil }
        let parts = t.dropFirst(4).split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }) else { return nil }
        return parts.compactMap { Int($0) }
    }

    /// A master's `--ls-json` "version" ("1.23.0"; "" from a master too old to
    /// say, which is []). Each component's leading digits, so "1.24.0-rc1" is 1.24.0.
    static func masterVersion(_ s: String) -> [Int] {
        s.isEmpty ? [] : s.split(separator: ".", omittingEmptySubsequences: false).map { Int($0.prefix { $0.isASCII && $0.isNumber }) ?? 0 }
    }

    /// Numeric per component (1.10.0 > 1.9.0), never as strings; missing components are 0.
    static func isAtLeast(_ a: [Int], _ b: [Int]) -> Bool {
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return true
    }

    static func versionString(_ v: [Int]) -> String { v.map(String.init).joined(separator: ".") }

    struct Binary: Equatable, Sendable {
        let path: String
        let version: [Int]
    }

    /// The newest candidate that answers `--version`; on a tie the earlier one.
    static func newest(_ candidates: [String], version: (String) -> [Int]?) -> Binary? {
        var best: Binary?
        for path in candidates {
            guard let v = version(path) else { continue }
            if best.map({ !isAtLeast($0.version, v) }) ?? true { best = Binary(path: path, version: v) }
        }
        return best
    }

    /// The binary control verbs run with; probes are cached, so this forks only
    /// for a binary not seen at its current mtime. Off main: a probe is bounded
    /// at `islandTimeout`.
    static func controlDch() -> Binary? { newest(controlCandidates, version: probedVersion) }

    private final class VersionCache: @unchecked Sendable {
        let lock = NSLock()
        var map: [String: (mtime: TimeInterval, version: [Int]?)] = [:]
    }
    private static let versionCache = VersionCache()

    /// `path --version`, cached per resolved path and mtime (a brew upgrade
    /// retargets the symlink, a rebuild moves the mtime), never per call. A
    /// missing or non-executable path is nil; a timed-out probe is not cached.
    static func probedVersion(_ path: String) -> [Int]? {
        let real = (path as NSString).resolvingSymlinksInPath
        guard FileManager.default.isExecutableFile(atPath: real), let m = AgentDirScanner.mtime(real) else { return nil }
        if let hit = versionCache.lock.withLock({ versionCache.map[real] }), hit.mtime == m { return hit.version }
        guard let out = bounded(islandTimeout, { onPid in
            runCapturingBoth(args: ["--version"], env: AgentIsland.listEnv(dir: defaultSocketDir), path: real, onPid: onPid).out
        }) else { return nil }
        let v = parseVersion(String(decoding: out, as: UTF8.self))
        versionCache.lock.withLock { versionCache.map[real] = (m, v) }
        return v
    }

    /// Whether a control may run: the binary is at least the verb's minimum and
    /// every live master's version ("" = an old master, which passes), so it never
    /// downgrades a newer master. `.refused` carries the one-line reason.
    enum Gate: Equatable {
        case ok(String)
        case refused(String)

        var isOK: Bool { if case .ok = self { true } else { false } }
    }

    static func gate(_ dch: Binary?, masters: [String], minimum: [Int]) -> Gate {
        let need = masters.map(masterVersion).reduce(minimum) { isAtLeast($0, $1) ? $0 : $1 }
        guard let dch, isAtLeast(dch.version, need) else { return .refused("needs dch \(versionString(need))") }
        return .ok(dch.path)
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
            env["DCH_SOCKET_DIR"] = isolatedSocketDir
        }
        return env
    }

    /// Sessions with dch's own agent state (`working`/`idle`/`blocked`/`done`),
    /// which it resolves from the session's rendered screen — that's why we ask dch
    /// instead of guessing from output timestamps. `--ls-json` arrived in dch 1.4;
    /// against an older binary it prints nothing and we fall back to `-lj`'s
    /// `name\talias\tactivityEpoch` lines (state empty).
    static func listSessions() -> [DchListRow] {
        let rows = parseListJSON(runCapturingData(args: ["--ls-json"]))
        if !rows.isEmpty { return rows }
        return parseListTSV(runCapturing(args: ["-lj"]))
    }

    /// `[{"name","alias","harness","activity_epoch","state","agents"}]` — dch 1.4+
    /// `--ls-json`; `agents` (live subagent count) only from newer dch, else 0.
    ///
    /// `harness` is the Claude Code session name running inside the session (dch
    /// 1.9+). `dch -l` shows it whenever no explicit alias exists, so the phone
    /// does the same: an empty alias falls back to it, and the raw socket name is
    /// the last resort. Folding it into `alias` keeps the wire format unchanged.
    static func parseListJSON(_ data: Data) -> [DchListRow] {
        guard let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
        return rows.compactMap { o in
            guard let name = o["name"] as? String, !name.isEmpty else { return nil }
            var alias = o["alias"] as? String ?? ""
            if alias.isEmpty { alias = o["harness"] as? String ?? "" }
            return DchListRow(name: name, alias: alias,
                              activityEpoch: o["activity_epoch"] as? Int ?? 0, state: o["state"] as? String ?? "",
                              agents: o["agents"] as? Int ?? 0,
                              meta: DchSessionMeta(json: o["meta"]),
                              metaEpoch: DchSessionMeta.count(o["meta_epoch"]) ?? 0,
                              version: o["version"] as? String ?? "")
        }
    }

    /// `name\talias\tactivityEpoch` lines — every dch's `-lj`, state unknown.
    static func parseListTSV(_ text: String) -> [DchListRow] {
        text
            .split(separator: "\n")
            .compactMap { line in
                let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
                guard let name = parts.first, !name.isEmpty else { return nil }
                let alias = parts.count > 1 ? String(parts[1]) : ""
                let epoch = parts.count > 2 ? Int(parts[2]) ?? 0 : 0
                return DchListRow(name: String(name), alias: alias, activityEpoch: epoch, state: "", agents: 0)
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
    static var socketDir: String { socketDir(env: childEnv()) }

    /// #474: the dir a terminal-started `dch` uses — Prosper's own env, no isolation
    /// override. Agent Island lists it whatever Remote Terminal does.
    static var defaultSocketDir: String { socketDir(env: ProcessInfo.processInfo.environment) }

    /// Remote Terminal's private dir while `isolateRemoteSessions` is on.
    static var isolatedSocketDir: String { "\(NSHomeDirectory())/.config/prosper/dch-isolated" }

    static func socketDir(env: [String: String]) -> String {
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
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "DCH_SESSION")
        if Preferences.isolateRemoteSessions {
            env["DCH_SOCKET_DIR"] = isolatedSocketDir
        }
        let r = runCapturingBoth(args: args, env: env)
        return (r.out, r.err)
    }

    /// Run dch with exactly `env` — #474 lists each socket dir with its own
    /// DCH_SOCKET_DIR, whatever the isolation preference says.
    /// `path` defaults to dchPath read here; a bounded caller resolves it on its own
    /// thread instead (#486 r2), so a late-starting body never reads a reset override.
    /// #578: `merge` sends stderr into `out` (a control verb prints results on
    /// stdout and refusals on stderr; its last line is whichever came last), and
    /// `status` is the exit code (-1 when it never started).
    static func runCapturingBoth(args: [String], env: [String: String], path: String = dchPath, merge: Bool = false,
                                 onPid: (pid_t) -> Void = { _ in }) -> (out: Data, err: String, status: Int32) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.environment = env
        let pipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = pipe
        p.standardError = merge ? pipe : errPipe
        do { try p.run() } catch { return (Data(), "", -1) }
        onPid(p.processIdentifier)
        // Screen first (it can be tens of KB), then stderr (one line at most, so it
        // fits the pipe buffer while we drain stdout — no deadlock).
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let err = merge ? Data() : errPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (data, String(data: err, encoding: .utf8) ?? "", p.terminationStatus)
    }

    /// #477: every Agent Island dch call (--ls-json, -lj, --read, --status, --send)
    /// gives up after this, so a wedged dch never parks the island queue, which
    /// also carries the poll. Remote Terminal's calls stay unbounded. A var only
    /// so tests can shorten it (#486); a test pins the 4.
    nonisolated(unsafe) static var islandTimeout: TimeInterval = 4

    /// stdout of one island call; nil when it timed out (#486: list keeps the last sessions).
    /// #578: `path` is the control binary for --history.
    static func runIsland(args: [String], env: [String: String], path: String? = nil) -> Data? {
        let path = path ?? dchPath   // on the caller's thread, not the body's
        return bounded(islandTimeout) { onPid in runCapturingBoth(args: args, env: env, path: path, onPid: onPid).out }
    }

    private final class BoundedCall: @unchecked Sendable {
        let lock = NSLock(), done = DispatchSemaphore(value: 0)
        var pid: pid_t?, out: Data?
    }

    /// Runs `body` on its own thread and waits at most `timeout`. On expiry the
    /// child `body` reported through `onPid` is killed by that pid and nil
    /// comes back at once; a body that still never returns strands only its own
    /// thread, never the caller.
    static func bounded(_ timeout: TimeInterval,
                        terminate: @escaping @Sendable (pid_t) -> Void = { _ = Darwin.kill($0, SIGKILL) },
                        _ body: @escaping @Sendable (_ onPid: (pid_t) -> Void) -> Data) -> Data? {
        let call = BoundedCall()
        DispatchQueue.global(qos: .utility).async {
            let out = body { pid in call.lock.withLock { call.pid = pid } }
            call.lock.withLock { call.out = out }
            call.done.signal()
        }
        if call.done.wait(timeout: .now() + timeout) == .success { return call.lock.withLock { call.out ?? Data() } }
        // A body that has returned has reaped its child: never signal a pid that may be reused.
        if let pid = call.lock.withLock({ call.out == nil ? call.pid : nil }) { terminate(pid) }
        return nil
    }
}
