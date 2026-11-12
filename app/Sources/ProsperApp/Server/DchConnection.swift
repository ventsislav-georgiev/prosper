import AppKit
import CryptoKit
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
    // #591: the island's History and its controls (DchControlOps). Each gets exactly one reply.
    static let history: UInt8 = 0x0b  // (empty) → historyResp | error
    static let revive: UInt8  = 0x0c  // {name} | {all: true} → ok {names} | error
    static let restart: UInt8 = 0x0d  // {names: [..]} | {all: true} → ok {names} | error
    static let stop: UInt8    = 0x0e  // {names: [..]} → ok {names} | error
    // #616: the phone's read-only library sync (DchLibraryOps). One reply.
    static let library: UInt8 = 0x0f  // (empty) | {} | {etag} → libraryResp | error
    // #620: History's pin, X and Clear unpinned (DchControlOps). Each gets exactly one reply.
    static let pin: UInt8       = 0x24  // {name, pin: Bool} → ok {names} | error
    static let forget: UInt8    = 0x25  // {name} → ok {names} | error (a pinned record is refused)
    static let forgetAll: UInt8 = 0x26  // (empty) | {} → ok {cleared, skipped, failed} | error
    // #617: clipboard history both ways (DchClipboardOps), only while "clipboard" is in ops.
    static let clipboardList: UInt8 = 0x15        // {limit?, before?, since?} → clipboardResp | error
    static let clipboardItem: UInt8 = 0x16        // {id, offset?, max_side?} → clipboardItemResp, data…, ok | error
    static let putClipboardText: UInt8 = 0x17     // {text} → ok | error (the live pasteboard)
    static let addClipboardHistory: UInt8 = 0x22  // {items: [..]} → ok {added, skipped} | error (small text)
    static let clipboardUpload: UInt8 = 0x23      // {id, date, kind, size, sha256, …}, data… → ok {added}|{skipped} | error
    // #618: chat with this Mac's local agent model (DchChat), only while "chat" is in ops.
    static let models: UInt8 = 0x1e   // (empty) | {} → modelsResp | error
    static let chat: UInt8   = 0x1f   // {model?, messages: [{role, content}], max_tokens?} → chatDelta…, chatDone | error
    // #619: allowlisted palette commands (DchCommandOps), only while "commands" is in ops. One reply.
    static let commands: UInt8   = 0x28  // (empty) | {} → commandsResp | error
    static let runCommand: UInt8 = 0x29  // {id, argument?} → commandResult | error
    // #731: the phone's own snippets, shown here read-only (DchLibraryOps.put). One reply.
    static let putPhoneSnippets: UInt8 = 0x2c  // {device_id, device_name?, hash, snippets} → ok {count, hash} | error
    // #760: the one sidekick pattern of the Mac and the phone (DchSidekickOps). One reply.
    static let sidekickSync: UInt8 = 0x2d  // {pattern, updated} → ok {pattern, updated} (the winner) | error
    // #765: the phone's push stream instead of its list poll (5-30 s live, 15-120 s in battery saver;
    // DchWatchHub), only while "watch" is in ops.
    static let watch: UInt8 = 0x2e  // {} → listResp, ok {sidekick}, then listResp | ok {sidekick} | ok {} … | error
    // #838: dch's control verbs run by this Mac's dch (DchCtl), only while "ctl" is in ops (always).
    static let ctl: UInt8 = 0x30  // {argv: [verb, name, …]} → ctlStdout…/ctlStderr…, then ctlExit | error
    // both directions
    static let data: UInt8    = 0x10  // raw pty bytes
    // server → client
    static let listResp: UInt8 = 0x11 // [{name, alias?, state?, agents?, cwd?, meta?, meta_epoch?}]
    static let exit: UInt8     = 0x12 // {code}
    static let error: UInt8    = 0x13 // {message}
    static let ok: UInt8       = 0x14 // (empty) ack for kill, rename, putClipboard; {names} for #591's verbs
    static let machineInfoResp: UInt8 = 0x18 // {device_id, hostname, wakeId?, ops, server, os, name, proto}
    static let snapshotResp: UInt8 = 0x19 // raw ANSI screen from dch's VT mirror (empty = unavailable)
    static let historyResp: UInt8 = 0x1b // [{name, alias?, end, last_seen, started, runtime, cwd?, command?, takes, pinned?}]
    static let libraryResp: UInt8 = 0x1c // {etag, unchanged: true} | {etag, snippets, quicklinks, errors?}
    static let clipboardItemResp: UInt8 = 0x1a // {id, date, kind, source, size, sha256, name?, mime?}, then data
    static let clipboardResp: UInt8 = 0x1d     // [{id, date, kind, source, size, text?, thumb?, name?}]
    static let chatDelta: UInt8 = 0x20  // {text} one streamed chunk of a chat's reply
    static let chatDone: UInt8 = 0x21   // {stop: "stop"} a chat's final reply after its deltas
    static let modelsResp: UInt8 = 0x27 // [{id, name, loaded}] (empty: no local model on disk)
    static let commandsResp: UInt8 = 0x2a  // [{id, title, subtitle?, ext, argument?, icon?}]
    static let commandResult: UInt8 = 0x2b // {text, detail?}
    static let ctlStdout: UInt8 = 0x31  // raw bytes: a chunk of the ctl's dch stdout
    static let ctlStderr: UInt8 = 0x32  // raw bytes: a chunk of its stderr
    static let ctlExit: UInt8 = 0x33    // {exit, why?: "cap"|"timeout"|"cancel"}: always a ran ctl's last frame
    static let ctlCancel: UInt8 = 0x34  // (empty) C→S: cut the running ctl (SIGTERM, SIGKILL 2 s or 660 s later); "ctl-cancel" in ops

    /// QA #606 F1: the requests that change the list. After one, the list frame forks until
    /// the island has caught up (DchWatchHub.changed).
    static let listChanging: Set<UInt8> = [kill, rename, create, revive, restart, stop]

    /// #617: the phone's ProsperTransport.maxFrame: what the Mac sends stays within it
    /// (list paging, item checks). The Mac's receive side is bounded by maxRequestFrame.
    static let maxFrame = 8 << 20
    /// #617 fix round 1: a garbage guard on every received frame, not a protocol limit. The
    /// shipped phone sends a pasted photo as one 0x0a putClipboard (17 MB for a 4032 px PNG)
    /// and a big paste as one 0x10 frame; a larger length prefix closes the connection.
    static let maxRequestFrame = 256 << 20

    /// #591: the requests beyond the original set this Mac answers, in machineInfoResp's
    /// "ops" (an older phone ignores the key; a newer one hides what an older Mac lacks).
    /// #800: "create" (0x02) and "paste_image" (0x0a) too, always: this Mac serves both
    /// unconditionally (0x0a sets the pasteboard whatever clipboard sync says), and a client
    /// gates them on these names for a server that may not (dch serve).
    /// #838: "ctl" (0x30) too, always, and "ctl-cancel" (0x34).
    static let ops = ["history", "revive", "restart", "stop", "library", "pin", "forget", "snippets_put", "sidekick",
                      "create", "paste_image", "ctl", "ctl-cancel"]

    /// The identity handshake's payload. Read-only, no secret: the wake config itself
    /// comes authenticated from the server. wakeId is nil until remote wake was set
    /// up while signed in. #617: "clipboard" joins ops only while clipboard sync is on, and
    /// #707's "clipboard_max_side" (clipboardItem's max_side) only beside it.
    /// #618: "chat" only while the agent model is on disk. #619: "commands" only while
    /// "Run commands from iPhone" is on. #669: "revive_no_message" only while the control
    /// dch passes 1.27.0 (historyResp is a bare array, so the capability lives here).
    /// #765: "watch" only while Agent Island lists Remote Terminal's dir (DchWatchHub.available).
    static func machineInfo(deviceID: String, hostname: String, wakeId: String?, clipboard: Bool = false,
                            chat: Bool = false, commands: Bool = false, reviveNoMessage: Bool = false,
                            watch: Bool = false, create: Bool = true, xray: Bool = false) -> [String: Any] {
        // #838: `create` is DchConnection.createAllowed, a seam (this Mac always allows create);
        // "xray" only while the dch ctl runs has --xray (DchCtlOps.xray).
        var all = ops.filter { create || $0 != "create" } + (reviveNoMessage ? ["revive_no_message"] : []) + (clipboard ? ["clipboard", "clipboard_max_side"] : [])
        all += (chat ? ["chat"] : []) + (commands ? ["commands"] : []) + (watch ? ["watch"] : []) + (xray ? ["xray"] : [])
        // #776: server, os, name and proto (docs/protocol/remote-frames.md). Added keys only, so an
        // older phone reads the same. `hostname` already carries the computer name, so `name` is it.
        var info: [String: Any] = ["device_id": deviceID, "hostname": hostname, "ops": all,
                                   "server": "prosper", "os": osName, "name": hostname, "proto": proto]
        if let wakeId { info["wakeId"] = wakeId }
        return info
    }

    /// #776: the remote-frames.md version this Mac speaks. A client refuses a newer major, so it stays 1.x.
    static let proto = "1.1"   // #838: 1.1 adds "ctl"

    /// #776: machineInfoResp's "os": "macOS 27.0", the patch only when it is not 0.
    static let osName = osLabel(ProcessInfo.processInfo.operatingSystemVersion)
    static func osLabel(_ v: OperatingSystemVersion) -> String {
        "macOS \(v.majorVersion).\(v.minorVersion)" + (v.patchVersion > 0 ? ".\(v.patchVersion)" : "")
    }

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

    /// listResp's payload, from dch's rows (a fork) or the island's (#765). Keys sorted, so the
    /// same rows are the same bytes and the watch stream can compare payloads.
    static func listPayload(_ rows: [DchListRow]) -> Data {
        let o = rows.map { row -> [String: Any] in
            var o: [String: Any] = ["name": row.name]
            if !row.alias.isEmpty { o["alias"] = row.alias }
            if !row.state.isEmpty { o["state"] = row.state }   // working|idle|blocked|done
            if row.agents > 0 { o["agents"] = row.agents }     // live subagents; absent from older dch
            if let cwd = row.wireCwd { o["cwd"] = cwd }        // #877: dch 1.52+, absent when unknown
            o.merge(row.metaWire) { $1 }                       // "meta"/"meta_epoch", dch 1.22+
            return o
        }
        return (try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])) ?? Data("[]".utf8)
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
    /// #591: the history and control verbs' dch, server-wide (DchControlOps.live).
    var ops = DchControlOps.live
    /// #616: the library request's files (DchLibraryOps.dir).
    var library = DchLibraryOps()
    /// #760: sidekickSync's merge; its adopt runs on main.
    var sidekick = DchSidekickOps()
    /// #617: the clipboard requests' store, folders and gate.
    var clipboard = DchClipboardOps()
    /// #617: this connection's clipboardUpload, which its data frames feed. On `queue`.
    private var upload: DchClipboardUpload?
    /// #617 fix round 1: this connection ever started a clipboardUpload. Sticky: after an
    /// early reply the phone's leftover data frames would otherwise reach a later pty.
    private var uploaded = false
    /// #618: the phone's chats with the local model, server-wide (DchChat.shared).
    var chat = DchChat.shared
    /// #618: this connection's models or chat request; closing cancels it. On `queue`.
    private var chatTask: Task<Void, Never>?
    /// #618: this connection ever started a chat. Sticky, as `uploaded`.
    private var chatted = false
    /// #619: the phone's allowlisted palette commands and their gate.
    var commands = DchCommandOps()
    /// #619: this connection's commands or runCommand request; closing cancels it. On `queue`.
    private var commandTask: Task<Void, Never>?
    /// #627: the kill frame's `dch -k <name>`; tests set a recorder so no real dch runs.
    var kill: (String) -> Void = { DchCommand.kill($0) }
    /// QA #606 F1: the rename frame's `dch -m <name> <alias>`; tests set a recorder.
    /// #811: nil when dch took it, else the 0x13 message.
    var rename: (String, String) -> String? = { DchCommand.setAlias($0, alias: $1) }
    /// #765: the island's list cache and the watch streams, server-wide; nil = always fork.
    var watch: DchWatchHub?
    /// QA #625 F1: attach/create's pty (exe, args, cols, rows, onOutput, onExit); tests make it
    /// throw as a failed forkpty does.
    var spawn: (String, [String], Int, Int, @escaping ([UInt8]) -> Void, @escaping (Int32) -> Void) throws -> PtyChild = {
        try PtyChild(exe: $0, args: $1, env: DchCommand.childEnv(), cols: $2, rows: $3, onOutput: $4, onExit: $5)
    }
    /// #765 J16: the list frame's dch fork when the island has no list; tests count it.
    var listSessions: () -> [DchListRow] = { DchCommand.listSessions() }
    /// #838: the ctl request's dch, its timeout and cap; tests point it at a fake.
    var ctl = DchCtlOps()
    /// #838: the one gate 0x02 create and ctl's --spawn and --revive share, and "create" in ops. This Mac always
    /// allows create (no setting); a seam so tests can serve as a dch serve without --allow-create does.
    var createAllowed: @Sendable () -> Bool = { true }
    /// #838: this connection's running ctl; closing kills its child. On `queue`.
    private var ctlJob: DchCtlJob?
    /// #841: a ctl ran on this connection (running or warm): it takes only ctl frames from then on. On `queue`.
    private var ctlConnection = false
    /// #838 amendment 4: a connection that ran a 0x30 closes after `ctlIdle` with no frame from the
    /// client and no ctl running (#841: it never attaches or watches). `clock` is a seam for tests. On `queue`.
    var ctlIdle: TimeInterval = 300
    var clock: @Sendable () -> Date = { Date() }
    private var lastActive = Date.distantPast
    private var idleArmed = false
    /// #765: this connection is a watch stream (not a keep-awake client). On `queue`.
    private(set) var watching = false
    /// QA #462 M3: a history/control request of this connection awaits its reply. On `queue`.
    private(set) var inFlight = false
    /// Test seam (#591): frames go here instead of the socket.
    var sendOverride: (@Sendable (Data) -> Void)?

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

    /// #776: `last`, a frame that must reach the client before the FIN (the receive guard's
    /// error, QA #625 F1 a failed spawn's): sent as the final message, and the cancel waits for its completion (5 s at
    /// most), as startSession's exit frame. Once closed nothing is read, handled or sent.
    func close(after last: Data? = nil) {
        guard !closed else { return }
        closed = true
        buffer.removeAll()
        pty?.terminate()       // kill the dch client → master daemon survives
        pty = nil
        upload?.cancel()       // #617: a dropped upload discards its partial item
        chatTask?.cancel()     // #618: a dropped chat stops its generation
        commandTask?.cancel()  // #619: its reply is dropped (a handler already running finishes)
        ctlJob?.cancel()       // #838: kills its dch's process group (a --follow ends here)
        watch?.remove(ObjectIdentifier(self))   // #765: its timers go with it
        if let last, sendOverride == nil {
            // A failed send completes too; the failsafe covers one that never does. cancel() is idempotent.
            let conn = conn
            conn.send(content: last, contentContext: .finalMessage, completion: .contentProcessed { _ in conn.cancel() })
            queue.asyncAfter(deadline: .now() + 5) { conn.cancel() }
        } else {
            if let last { sendOverride?(last) }
            conn.cancel()
        }
        onClose(ObjectIdentifier(self))
    }

    /// #852: DchSessionServer.stop's close: a running ctl gets the short grace (DchCtlJob.serverStop).
    func serverStop() {
        ctlJob?.serverStop()
        close()
    }

    private func receive() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty { self.ingest(data) }
            if isComplete || error != nil { self.close(); return }
            guard !self.closed else { return }
            // #617: an upload's unwritten backlog pauses reading until its disk catches up.
            guard let upload = self.upload else { return self.receive() }
            upload.whenDrained { [weak self] in
                guard let self else { return }
                self.queue.async { [weak self] in if self?.closed == false { self?.receive() } }
            }
        }
    }

    /// Raw socket bytes, on `queue`; a test seam too (#617 fix round 1).
    func ingest(_ data: Data) {
        guard !closed else { return }   // #776: nothing is read past a close (the receive guard's included)
        buffer.append(data)
        drain()
    }

    /// Pull complete frames out of `buffer` and dispatch them.
    private func drain() {
        while buffer.count >= 5 {
            let type = buffer[buffer.startIndex]
            let len = buffer.withUnsafeBytes { raw -> Int in
                let b = raw.baseAddress!.advanced(by: 1).assumingMemoryBound(to: UInt8.self)
                return (Int(b[0]) << 24) | (Int(b[1]) << 16) | (Int(b[2]) << 8) | Int(b[3])
            }
            // #617: a length past maxRequestFrame is garbage, whatever the frame type.
            // #776: its error goes before the FIN (an immediate cancel dropped it on the wire).
            guard len <= DchFrame.maxRequestFrame else {
                return close(after: DchControlOps.error("frame too large"))
            }
            guard buffer.count >= 5 + len else { return }   // wait for the rest
            let payload = buffer.subdata(in: buffer.index(buffer.startIndex, offsetBy: 5)..<buffer.index(buffer.startIndex, offsetBy: 5 + len))
            buffer.removeSubrange(buffer.startIndex..<buffer.index(buffer.startIndex, offsetBy: 5 + len))
            lastActive = clock()
            handle(type: type, payload: payload)
        }
    }

    private func armIdle(after delay: TimeInterval) {
        guard !idleArmed, !closed else { return }
        idleArmed = true
        queue.asyncAfter(deadline: .now() + max(delay, 1)) { [weak self] in self?.idleTick() }
    }

    /// The warm ctl connection's idle check (amendment 4). On `queue`; re-arms itself until it closes.
    func idleTick() {
        idleArmed = false
        guard !closed else { return }
        let quiet = clock().timeIntervalSince(lastActive)
        if !inFlight, quiet >= ctlIdle { return close() }
        armIdle(after: inFlight ? ctlIdle : ctlIdle - quiet)
    }

    private func send(_ frame: Data) {
        if let sendOverride { return sendOverride(frame) }
        conn.send(content: frame, completion: .contentProcessed { _ in })
    }

    /// A request's one final reply, from any thread: back on `queue`, dropped once closed.
    /// It ends an upload too: data frames after it (the phone's, sent before it read an
    /// early reply) find no upload and no pty, and are dropped.
    /// QA #606 F1: `listChanged`, the reply of a verb that changes the list.
    private func finalReply(_ frame: Data, listChanged: Bool = false) {
        queue.async {
            if listChanged { self.watch?.changed() }
            self.inFlight = false
            self.upload = nil
            self.chatTask = nil
            self.commandTask = nil
            self.ctlJob = nil
            self.lastActive = self.clock()   // a warm connection's idle time starts at its reply
            if !self.closed { self.send(frame) }
        }
    }

    private final class SendResult: @unchecked Sendable { var failed = false }

    /// #617: a stream's non-final frame, from the stream's own thread (never `queue`):
    /// handed to the socket and waited on, as the pty pump does, so a big item never
    /// piles up in NWConnection's send queue. False once the connection is gone.
    private func sendStreamed(_ frame: Data) -> Bool {
        guard !queue.sync(execute: { closed }) else { return false }
        if let sendOverride { sendOverride(frame); return true }
        let sem = DispatchSemaphore(value: 0), result = SendResult()
        conn.send(content: frame, completion: .contentProcessed { e in
            result.failed = e != nil
            sem.signal()
        })
        guard sem.wait(timeout: .now() + 60) == .success else {
            queue.async { self.close() }
            return false
        }
        return !result.failed
    }

    func handle(type: UInt8, payload: Data) {
        // #841, dch 1.42 serve.c on_frame: a ctl connection (running or warm) stays one. Its frames are
        // read while the ctl runs, so an attach, watch or request there would mix into the ctl's stream.
        if ctlConnection, ![DchFrame.machineInfo, DchFrame.list, DchFrame.ctl, DchFrame.ctlCancel].contains(type) {
            // QA #688 INFO-1: serve refuses only the frames it reads whole (rframe.c rf_control: 0x01-0x09,
            // 0x2e); the rest (0x10, 0x0a, any type it does not serve, Prosper's Mac-only requests too) it
            // drops unread, with no frame and no close.
            guard (0x01...0x09).contains(type) || type == DchFrame.watch else { return }
            return close(after: DchControlOps.error(DchCtl.ctlOnly))
        }
        // QA #606 F1: once a list-changing request ran (for #591's verbs: was sent off, then
        // again on the reply), the list frame forks until the island has the change.
        defer { if DchFrame.listChanging.contains(type) { watch?.changed() } }
        switch type {
        case DchFrame.list:
            // #765 J16: the island's list when it has one for this dir and no change is pending, else one dch fork.
            send(DchFrame.encode(DchFrame.listResp, [UInt8](watch?.listReply() ?? DchFrame.listPayload(listSessions()))))
        case DchFrame.watch:
            startWatch(payload)
        case DchFrame.kill:
            if let o = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any],
               let n = o["name"] as? String {
                // #627: dch's -k takes no name starting with '-'; it would re-parse "--all" as a flag.
                guard AgentIsland.passable(n) else { return send(DchControlOps.error(DchControlOps.dashNameRefusal)) }
                kill(n)
            }
            send(DchFrame.encode(DchFrame.ok, []))
        case DchFrame.rename:
            let o = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any]
            // #850: dch serve.c:1159 refuses an id-shaped alias before running dch, whatever the name.
            // #863: serve.c:1154-1158@v1.46.1 checks a name starting with "-" first, so such a pair gets
            // DASH_MSG. Prosper still runs dch -m for a dash name with any other alias (remote-frames.md).
            if let a = o?["alias"] as? String, DchControlOps.idShaped(a) {
                let dash = (o?["name"] as? String)?.utf8.first == 0x2d   // QA #727 INFO-4: the byte, as serve
                return send(DchControlOps.error(dash ? DchControlOps.dashNameRefusal : DchControlOps.idShapedRefusal))
            }
            if let o, let n = o["name"] as? String,
               let message = rename(n, o["alias"] as? String ?? "") {
                // #811 (QA #636 INFO-1): dch refused it (a just-exited session exits 1); a malformed request stays 0x14 (spec).
                return send(DchControlOps.error(message))
            }
            send(DchFrame.encode(DchFrame.ok, []))
        case DchFrame.attach, DchFrame.create:
            startSession(type: type, payload: payload)
        case DchFrame.data:
            if let upload { upload.feed(payload) } else { pty?.write([UInt8](payload)) }
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
            Self.setPasteboardImage(payload)
            send(DchFrame.encode(DchFrame.ok, []))
        case DchFrame.putClipboardText:
            send(clipboard.putText(payload))
        case DchFrame.clipboardUpload:
            // #617: one upload per connection; its data frames follow and feed it.
            guard !closed else { return }
            guard !inFlight, upload == nil else { return send(DchControlOps.error("busy with an earlier request")) }
            // Data frames are this connection's keystrokes once attached.
            guard pty == nil else { return send(DchControlOps.error("clipboardUpload needs its own connection")) }
            inFlight = true
            uploaded = true
            let up = DchClipboardUpload(ops: clipboard, reply: { self.finalReply($0) },
                                        closeConnection: { [weak self] in
                                            guard let self else { return }
                                            self.queue.async { [weak self] in self?.close() }
                                        })
            upload = up
            up.start(payload)
        case DchFrame.machineInfo:
            // Identity-only handshake (read-only, no side effects). Lets the paired
            // app bind this connection to a stable machine + its wake id, so it can
            // wake the right Mac later regardless of which address was dialed. The
            // wake config itself (enabled/cadence) is fetched authenticated from the
            // server; only non-secret identity goes over the tailnet.
            // #671: the revive_no_message bit probes `dch --version` (4 s per hung candidate),
            // so it runs off this queue as #591's verbs do; the rest is read here, as before.
            // The phone sends 0x08 alone on its own connection, so the reply may trail others.
            let deviceID = SupporterStore.deviceID(), hostname = SupporterStore.deviceName()
            let wakeId = LiveExtensionHostServices.currentWakeId, clip = clipboard.enabled()
            clipboard.log(.default, "machineInfo: clipboard \(clip ? "advertised" : "not advertised")")   // #701
            let chat = chat.available, commands = commands.enabled(), ops = ops, watch = watch?.available() ?? false
            let create = createAllowed(), ctl = ctl
            // #704: the phone gives up after 2 s and a cold probe can take 4 s per hung
            // candidate, so the reply waits at most 0.25 s for it (a cached probe is a stat
            // per candidate). Past that it goes without the bit; the probe runs on and fills
            // probedVersion's cache, timeouts included, for the next handshake.
            let answered = OSAllocatedUnfairLock(initialState: false)
            let answer: @Sendable (Bool, Bool) -> Void = { revive, xray in
                guard answered.withLock({ done in defer { done = true }; return !done }) else { return }
                let frame = DchFrame.encode(DchFrame.machineInfoResp, json: DchFrame.machineInfo(
                    deviceID: deviceID, hostname: hostname, wakeId: wakeId, clipboard: clip, chat: chat,
                    commands: commands, reviveNoMessage: revive, watch: watch, create: create, xray: xray))
                self.queue.async { if !self.closed { self.send(frame) } }
            }
            DispatchQueue.global(qos: .userInitiated).async {
                answer(DchCommand.gate(ops.binary(), masters: [], minimum: AgentIsland.reviveNoMessageMinimum).isOK, ctl.xray())
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.25) { answer(false, false) }
        case DchFrame.models, DchFrame.chat:
            // #618: one request per connection, as clipboardUpload; a chat's deltas come
            // back in order on `queue`, then the one final reply.
            guard !closed else { return }
            guard !inFlight else { return send(DchControlOps.error("busy with an earlier request")) }
            if type == DchFrame.chat {
                // Never on an attached connection, and a chat's connection never attaches.
                guard pty == nil else { return send(DchControlOps.error("chat needs its own connection")) }
                chatted = true
            }
            inFlight = true
            let chat = chat
            let reply: DchControlOps.Reply = { self.finalReply($0) }
            let send: DchControlOps.Reply = { f in self.queue.async { if !self.closed { self.send(f) } } }
            chatTask = Task {
                if type == DchFrame.models { return await chat.models(payload, reply: reply) }
                await chat.chat(payload, send: send, reply: reply)
            }
        case DchFrame.commands, DchFrame.runCommand:
            // #619: one request per connection, as chat. A single reply and no data frames,
            // so an attached connection may run one too and nothing sticky is needed.
            guard !closed else { return }
            guard !inFlight else { return send(DchControlOps.error("busy with an earlier request")) }
            inFlight = true
            let commands = commands
            let reply: DchControlOps.Reply = { self.finalReply($0) }
            commandTask = Task { await commands.handle(type, payload, reply: reply) }
        case DchFrame.ctl:
            startCtl(payload)
        case DchFrame.ctlCancel:
            ctlJob?.cancelRequest()   // a 0x34 with no ctl running, or after its 0x33: ignored, no frame
        case DchFrame.history, DchFrame.revive, DchFrame.restart, DchFrame.stop, DchFrame.library,
             DchFrame.putPhoneSnippets, DchFrame.sidekickSync, DchFrame.pin, DchFrame.forget, DchFrame.forgetAll,
             DchFrame.clipboardList, DchFrame.clipboardItem, DchFrame.addClipboardHistory:
            // #591: off this queue, unlike kill: the reads fork dch and a restart can
            // take minutes, while every connection (and each attached pty's send
            // completions) runs on this one queue. The one reply comes back here.
            // QA #462 M3: a closed connection forks nothing, and one request is in
            // flight per connection; another meanwhile is refused at once. A verb
            // already started is not cancelled when the connection closes: a restart
            // the phone started finishes, and its reply is dropped by !closed below.
            guard !closed else { return }
            // #841 (QA #680 INFO-8): revive and restart start processes, so they follow the create gate
            // as 0x02 and ctl's --spawn and --revive do (dch serve: CTL_CREATE, and no attach that would start one).
            if [DchFrame.revive, DchFrame.restart].contains(type), !createAllowed() {
                return send(DchControlOps.error(DchCtl.createOff))
            }
            guard !inFlight else { return send(DchControlOps.error("busy with an earlier request")) }
            inFlight = true
            let ops = ops, library = library, clipboard = clipboard, sidekick = sidekick
            let changes = DchFrame.listChanging.contains(type)
            DispatchQueue.global(qos: .userInitiated).async {
                let reply: DchControlOps.Reply = { self.finalReply($0, listChanged: changes) }
                switch type {
                case DchFrame.library: library.handle(payload, reply: reply)
                case DchFrame.putPhoneSnippets: library.put(payload, reply: reply)
                case DchFrame.sidekickSync: sidekick.handle(payload, reply: reply)
                case DchFrame.clipboardList, DchFrame.clipboardItem, DchFrame.addClipboardHistory:
                    clipboard.handle(type, payload, send: { self.sendStreamed($0) }, reply: reply)
                default: ops.handle(type, payload, reply: reply)
                }
            }
        default:
            break
        }
    }

    /// #838: 0x30 → its dch's 0x31/0x32 chunks, then 0x33; or one 0x13 and nothing runs. Checked
    /// here, run off this queue. Ungated by any setting, as attach input, kill and rename.
    /// #841, as dch 1.42 serve: one ctl at a time per connection, another meanwhile gets DchCtl.busy and
    /// nothing closes; any other refusal is the last frame, 0x13 then the FIN (a warm connection too).
    private func startCtl(_ payload: Data) {
        guard !closed else { return }
        guard pty == nil, !watching, ctlJob != nil || !inFlight else { return send(DchControlOps.error(DchCtl.ownConnection)) }
        guard ctlJob == nil else { return send(DchCtl.busy) }
        let o = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any]
        guard let argv = o?["argv"] as? [String] else {
            return close(after: DchControlOps.error("malformed ctl request: send {\"argv\": [verb, name, ...]}"))
        }
        let ctl = ctl, create = createAllowed(), cwd = o?["cwd"] as? String
        let cwdWhy = DchCtl.cwdRefusal(o?["cwd"], verb: argv.first ?? "")
        // (dch path, refusal). serve refuses --xray before any shape (rframe.c ctl_check): its probe
        // may take seconds, so an --xray is vetted off this queue, every other 0x30 here.
        let vet: @Sendable () -> (String?, String?) = {
            if argv.first == "--xray", !ctl.xray() { return (nil, DchCtl.xrayOff) }
            if let why = DchCtl.refusal(argv, create: create) ?? cwdWhy { return (nil, why) }
            return ctl.path().map { ($0, nil) } ?? (nil, "dch is not available on this Mac")
        }
        let vetted = argv.first == "--xray" ? nil : vet()
        if let why = vetted?.1 { return close(after: DchControlOps.error(why)) }
        ctlConnection = true
        inFlight = true
        armIdle(after: ctlIdle)
        let job = DchCtlJob()
        ctlJob = job
        DispatchQueue.global(qos: .userInitiated).async {
            let (path, why) = vetted ?? vet()
            guard let path else { return self.ctlFinal(DchControlOps.error(why ?? "")) }
            job.run(path: path, argv: argv, env: ctl.env(), cwd: cwd, follow: DchCtl.follows(argv), cap: ctl.cap,
                    timeout: ctl.timeout(of: argv[0]), grace: ctl.grace(of: argv[0]), after: ctl.after,
                    send: { self.sendStreamed($0) }, reply: { self.ctlFinal($0) })
        }
    }

    /// #841: a ctl's final frame. A 0x33 leaves the connection warm; a 0x13 (dch could not run, an
    /// --xray refused) is a refusal, so the FIN follows it, as dch serve.
    private func ctlFinal(_ frame: Data) {
        guard frame.first == DchFrame.error else { return finalReply(frame) }
        queue.async {
            self.inFlight = false
            self.ctlJob = nil
            self.close(after: frame)
        }
    }

    /// #765: 0x2e on a connection of its own: {} (or {"device_id"}) → the stream DchWatchHub
    /// runs until this connection closes. Refused while the island has no list for this dir:
    /// the phone keeps polling then.
    private func startWatch(_ payload: Data) {
        guard !closed, !watching else { return }
        guard pty == nil, !inFlight, !uploaded, !chatted else { return send(DchControlOps.error("watch needs its own connection")) }
        let o = payload.isEmpty ? [:] : (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any]
        guard let o else { return send(DchControlOps.error("malformed watch request: send {}")) }
        // The phone sends {"device_id"} (Q8); a {} client's tailnet address stands for its device_id.
        var device = o["device_id"] as? String ?? ""
        if device.isEmpty, case let .hostPort(host, _) = conn.endpoint { device = "\(host)" }
        watching = true
        let ok = watch?.open(ObjectIdentifier(self), device: device,
                             send: { [weak self] frame, done in self?.streamSend(frame, done) ?? done() },
                             close: { [weak self] in self?.close() }) ?? false
        guard ok else {
            watching = false
            return send(DchControlOps.error("watch needs Agent Island listing Remote Terminal's sessions"))
        }
    }

    /// #765: one stream frame, on `queue`; `done` once the socket took it (DchWatchHub's backlog).
    private func streamSend(_ frame: Data, _ done: @escaping @Sendable () -> Void) {
        guard !closed else { return done() }
        if let sendOverride { sendOverride(frame); return done() }
        conn.send(content: frame, completion: .contentProcessed { _ in done() })
    }

    /// Put an image the phone copied onto THIS Mac's clipboard. Claude Code's image
    /// paste reads the clipboard of the machine it runs on, so a phone that only
    /// sends ctrl-V pastes whatever the Mac happens to hold — Universal Clipboard
    /// syncs phone images to the Mac unreliably, which is why the phone ships the
    /// bytes itself and then sends ctrl-V.
    ///
    /// Deliberately synchronous on the connection queue: the ctrl-V arrives as the
    /// very next frame, so the clipboard has to be set before this returns.
    /// #617: also an upload's live image, on main.
    static func setPasteboardImage(_ data: Data) {
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

    /// #877: dch serve's answer to a 0x01 with no name, and to a 0x01/0x02 name it cannot read (serve.c:994@v1.54.0).
    static let needsName = "attach needs a session name"

    /// QA #625 F1: a failed spawn's 0x13, shown on the phone as written.
    static let spawnFailed = "Could not start the session: the Mac could not open a terminal."

    private func startSession(type: UInt8, payload: Data) {
        guard pty == nil else { return }  // one session per connection
        // #838: ctl's --spawn and --revive share this gate; always open on this Mac (dch serve's words without --allow-create).
        guard type != DchFrame.create || createAllowed() else { return send(DchControlOps.error(DchCtl.createOff)) }
        // #617 fix round 1: never on a connection that carried an upload (see `uploaded`).
        // #618: nor on one that chatted. #765: nor on a watch stream.
        guard !uploaded, !chatted, !watching else {
            return send(DchControlOps.error("\(uploaded ? "clipboardUpload" : chatted ? "chat" : "watch") connections cannot attach or create"))
        }
        let o = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any] ?? [:]
        let name = o["name"] as? String
        // #877: dch serve's on_attach checks, in its order, each refused before any dch call (serve.c:990-1011
        // @v1.54.0). QA #727 INFO-3: jstr into name[NAME_CAP + 2] fails on a name that is no string or 257
        // bytes or more, and an attach needs a name at all.
        if (o["name"] != nil && name == nil) || (name?.utf8.count ?? 0) > DchCtl.nameCap + 1
            || (type == DchFrame.attach && (name ?? "").isEmpty) {
            return send(DchControlOps.error(Self.needsName))
        }
        if let name, !name.isEmpty {
            // QA #722 INFO-2, #727 INFO-1/4: a first byte "-" (listed or not), then name_ok for every name.
            guard name.utf8.first != 0x2d else { return send(DchControlOps.error(DchControlOps.dashNameRefusal)) }
            guard DchCtl.nameOK(name) else { return send(DchControlOps.error(DchCtl.invalidName)) }
            // #850: :1006, after name_ok (#727 INFO-2): a new session never takes a session_id's shape; a listed
            // one (legacy) still attaches by its exact listed name. An unavailable list ([] here, -1 there) refuses.
            if DchControlOps.idShaped(name), !listSessions().contains(where: { $0.name == name }) {
                return send(DchControlOps.error(DchControlOps.idShapedRefusal))
            }
        }
        sessionName = name
        // #877 (QA #725 INFO-1): an interactive Claude gets `--name <session name>`, as a Mac New session
        // (#847, AgentIsland.naming); no name (dch picks one): left unnamed. dch serve passes it as sent.
        let raw = (o["command"] as? [String]) ?? []
        let command = name.map { $0.isEmpty ? raw : AgentIsland.naming(raw, name: $0) } ?? raw
        let cols = (o["cols"] as? Int) ?? 80
        let rows = (o["rows"] as? Int) ?? 24

        let args = DchCommand.spawnArgs(name: name, command: command, attach: type == DchFrame.attach)
        do {
            let child = try spawn(
                DchCommand.dchPath, args, cols, rows,
                { [weak self] bytes in
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
                    // link at ~160s anyway, so this only fires when it is truly gone.
                    if sem.wait(timeout: .now() + 20) == .timedOut {
                        self.log.error("dch client stalled 20s — dropping the connection")
                        self.queue.async { self.close() }
                    }
                },
                { [weak self] code in
                    guard let self else { return }
                    // QA #606 F1: the session ended; the phone relists on the exit frame.
                    self.queue.async { self.watch?.changed() }
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
            // QA #606 INFO-9: dch's attach respawns a session whose master is gone (it decides by
            // connect() liveness, which a stat here cannot tell), so every attach that spawned
            // marks the list changed; create already did in handle (listChanging).
            if type == DchFrame.attach { watch?.changed() }
            // Our client is up and has already reported our window size, so retiring
            // the previous one can't leave the master on someone else's size. Order
            // matters: retire AFTER the spawn, never before — a failed spawn would
            // otherwise have killed a working client for nothing.
            if let name, !name.isEmpty { onAttach(ObjectIdentifier(self), name) }
        } catch {
            // QA #625 F1: the error goes before the FIN (an immediate cancel dropped it), and the
            // close discards whatever the client pipelined behind the attach. forkpty is the only
            // throw: the Mac is out of ptys or processes.
            log.error("dch server: spawn failed: \(String(describing: error), privacy: .public)")
            close(after: DchControlOps.error(Self.spawnFailed))
        }
    }
}

// MARK: - Phone library sync (#616)

/// The phone's "From your Mac" snippets and quicklinks, read-only. Each file is served
/// as stored (parsed and re-emitted, keys and its "version" untouched), since the phone
/// keeps its own copies in the same schema and merges nothing. Off the server queue;
/// every request gets exactly one reply.
struct DchLibraryOps: Sendable {
    /// nil: SnippetStore's and QuicklinkStore's own files. Tests point it at a tempDir()
    /// holding snippets.json and quicklinks.json, so no test reads ~/.config/prosper.
    var dir: URL?
    /// Per file. The phone refuses a frame over 8 MB (ProsperTransport.maxFrame), so
    /// two files at the cap still fit in one libraryResp.
    static let fileCap = 3 << 20
    static let maxReply = 8 << 20

    typealias Reply = DchControlOps.Reply

    struct File {
        var bytes = Data()
        var json: Any?
        var error: String?
    }

    /// #731: the phones' own sets, beside snippets.json and never inside it (so not in the etag).
    var phone: PhoneSnippetStore {
        dir.map { PhoneSnippetStore(url: $0.appendingPathComponent(PhoneSnippetStore.fileName)) } ?? .live
    }

    /// #731: 0x2c putPhoneSnippets → ok {count, hash} | error {message}.
    func put(_ payload: Data, reply: Reply) {
        switch phone.put(payload) {
        case let .ok(count, hash): reply(DchFrame.encode(DchFrame.ok, json: ["count": count, "hash": hash]))
        case let .refused(message): reply(DchControlOps.error(message))
        }
    }

    var urls: (snippets: URL, quicklinks: URL) {
        guard let dir else { return (SnippetStore.fileURL, QuicklinkStore.fileURL) }
        return (dir.appendingPathComponent("snippets.json"), dir.appendingPathComponent("quicklinks.json"))
    }

    func handle(_ payload: Data, reply: Reply) {
        let o = payload.isEmpty ? [:] : (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any]
        guard let o, o.isEmpty || (o.count == 1 && o["etag"] is String) else {
            return reply(DchControlOps.error("malformed library request: send nothing, {} or {\"etag\": \"<hex>\"}"))
        }
        let (s, q) = (Self.read(urls.snippets), Self.read(urls.quicklinks))
        let etag = Self.etag(s.bytes, q.bytes)
        if o["etag"] as? String == etag { return reply(Self.encode(["etag": etag, "unchanged": true])) }
        var out: [String: Any] = ["etag": etag, "snippets": s.json ?? NSNull(), "quicklinks": q.json ?? NSNull()]
        var errors: [String: String] = [:]
        errors["snippets"] = s.error
        errors["quicklinks"] = q.error
        if !errors.isEmpty { out["errors"] = errors }
        reply(Self.encode(out))
    }

    /// Lowercase hex sha256 of the snippets bytes, 0x00, the quicklinks bytes.
    static func etag(_ snippets: Data, _ quicklinks: Data) -> String {
        var h = SHA256()
        h.update(data: snippets)
        h.update(data: Data([0]))
        h.update(data: quicklinks)
        return h.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Missing: empty bytes, null, no error. Over the cap: the first cap+1 bytes (for
    /// the etag), null, an error. Unreadable or not a JSON object/array: null, an error.
    /// QA #484 I1: opened O_NONBLOCK and read only as a regular file (as #608), so a
    /// FIFO there never blocks the reply; symlinks are followed (dotfile setups use them).
    static func read(_ url: URL) -> File {
        guard FileManager.default.fileExists(atPath: url.path) else { return File() }
        let fd = Darwin.open(url.path, O_RDONLY | O_NONBLOCK)
        guard fd >= 0 else { return File(error: "unreadable") }
        let h = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG,
              let bytes = try? h.read(upToCount: fileCap + 1) ?? Data() else { return File(error: "unreadable") }
        guard bytes.count <= fileCap else { return File(bytes: bytes, error: "too large (over \(fileCap >> 20) MB)") }
        guard let json = try? JSONSerialization.jsonObject(with: bytes) else { return File(bytes: bytes, error: "malformed JSON") }
        return File(bytes: bytes, json: json)
    }

    /// libraryResp through the frame encoder; an error if the phone would refuse the frame.
    static func encode(_ o: [String: Any]) -> Data {
        guard let data = try? JSONSerialization.data(withJSONObject: o, options: [.withoutEscapingSlashes]) else {
            return DchControlOps.error("library could not be encoded")
        }
        guard data.count <= maxReply else { return DchControlOps.error("library too large for one frame") }
        return DchFrame.encode(DchFrame.libraryResp, [UInt8](data))
    }
}

// MARK: - Sidekick pattern sync (#760)

extension Notification.Name {
    /// #760: a phone's sidekick pattern was adopted; the open Settings field re-reads it.
    static let sidekickPatternChangedExternally = Notification.Name("sidekickPatternChangedExternally")
}

/// #760: 0x2d sidekickSync. The phone sends its pattern and when it last edited it; the
/// newer one wins on both ends, so the pattern set on either applies to both. Exactly
/// one reply: ok {pattern, updated} carrying the winner, or error {message}.
struct DchSidekickOps: Sendable {
    /// The wire cap, in UTF-8 bytes.
    static let maxBytes = 512

    struct Value: Equatable, Sendable {
        /// Raw, as typed: only matching trims.
        var pattern: String
        /// Ms since epoch of the last edit; 0 = never edited.
        var updated: Int64
    }

    /// The newer `updated` wins and the Mac adopts a phone winner; a tie (both 0
    /// included) keeps the Mac's.
    static func merge(mac: Value, phone: Value) -> (winner: Value, adopt: Bool) {
        phone.updated > mac.updated ? (phone, true) : (mac, false)
    }

    /// {"pattern": String, "updated": integer}; nil for anything else.
    static func parse(_ payload: Data) -> Value? {
        guard let o = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any],
              let pattern = o["pattern"] as? String,
              let n = o["updated"] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
              let updated = n as? Int64 else { return nil }
        return Value(pattern: pattern, updated: updated)
    }

    /// After an adopt, on main: the island re-splits and an open Settings field follows.
    /// Tests swap it.
    var adopted: @MainActor @Sendable () -> Void = {
        AgentIslandController.shared.rowDetailsChanged()
        NotificationCenter.default.post(name: .sidekickPatternChangedExternally, object: nil)
    }

    /// #765: the Mac's pattern and stamp now (UserDefaults, any thread).
    static func current() -> Value {
        Value(pattern: Preferences.agentIslandSidekickPattern, updated: Preferences.agentIslandSidekickPatternUpdated)
    }

    /// #765: the watch stream's sidekick frame, ok {"sidekick": <what 0x2d answers>}.
    static func watchFrame(_ v: Value) -> Data {
        DchFrame.encode(DchFrame.ok, json: ["sidekick": ["pattern": v.pattern, "updated": v.updated]])
    }

    func handle(_ payload: Data, reply: @escaping DchControlOps.Reply) {
        guard let phone = Self.parse(payload) else {
            return reply(DchControlOps.error("malformed sidekickSync request: send {\"pattern\": \"<text>\", \"updated\": <ms>}"))
        }
        let adopted = adopted
        // Read, merge and write on main, where Settings edits it, so no edit lands between.
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let m = Self.merge(mac: Value(pattern: Preferences.agentIslandSidekickPattern,
                                              updated: Preferences.agentIslandSidekickPatternUpdated), phone: phone)
                // QA #597 F1: the cap guards the adopt only. A tie or a Mac win answers with the Mac's
                // value whatever the phone sent, so a Mac pattern over the cap echoed back never wedges sync.
                if m.adopt, phone.pattern.utf8.count > Self.maxBytes {
                    return reply(DchControlOps.error("sidekick pattern over \(Self.maxBytes) UTF-8 bytes"))
                }
                if m.adopt {
                    Preferences.adoptSidekickPattern(m.winner.pattern, updated: m.winner.updated)
                    adopted()
                }
                reply(DchFrame.encode(DchFrame.ok, json: ["pattern": m.winner.pattern, "updated": m.winner.updated]))
            }
        }
    }
}

// MARK: - Watch stream (#765)

/// #765: the phone's push stream (0x2e) and the island's list cache behind it. The island's
/// poller (AgentIslandController.onSessions) feeds `island`; nothing here forks dch or polls:
/// the only timers are a stream's 1 s trailing flush and its 25 s heartbeat. One stream:
///   listResp (the list snapshot), ok {"sidekick": {pattern, updated}}, then
///   listResp when the payload differs from the last one sent, at most 1 per second, the
///   trailing change always sent; the sidekick frame when the Mac's pattern changes, on
///   the same 1 s gap (a pattern typed in Settings is one frame per second, not per key);
///   ok {} after 25 s with nothing else sent (the phone calls 60 s of silence dead).
/// All on the server queue; tests drive it directly with their own clock and timers.
final class DchWatchHub: @unchecked Sendable {
    static let maxPerDevice = 4
    static let minGap: TimeInterval = 1
    static let heartbeat: TimeInterval = 25
    /// Frames the socket has not taken yet: past this the phone is not reading (a
    /// suspended app whose socket stays open) and the stream closes instead of piling up.
    static let maxBacklog = 32

    /// Runs `work` after `delay` seconds; the returned closure cancels it.
    typealias Schedule = @Sendable (_ delay: TimeInterval, _ work: @escaping @Sendable () -> Void) -> () -> Void
    typealias Send = (_ frame: Data, _ done: @escaping @Sendable () -> Void) -> Void

    /// The island's rows for one socket dir, sorted by name.
    struct Cache: Equatable, Sendable {
        let dir: String
        let rows: [DchListRow]
    }

    final class Stream: @unchecked Sendable {
        let id: ObjectIdentifier, device: String
        let send: Send, close: () -> Void
        var sent = Data(), pending: Data?, listAt: TimeInterval = 0
        var sidekick: DchSidekickOps.Value?, sidekickAt: TimeInterval = 0
        var backlog = 0
        var cancelFlush: (() -> Void)?, cancelBeat: (() -> Void)?, cancelSidekick: (() -> Void)?

        init(id: ObjectIdentifier, device: String, send: @escaping Send, close: @escaping () -> Void) {
            (self.id, self.device, self.send, self.close) = (id, device, send, close)
        }
    }

    private let now: @Sendable () -> TimeInterval
    private let schedule: Schedule
    /// Remote Terminal's dir now: a cache for another dir (isolation toggled since) is no cache.
    var remoteDir: @Sendable () -> String = { DchCommand.remoteSocketDir() }
    var sidekick: @Sendable () -> DchSidekickOps.Value = { DchSidekickOps.current() }
    private var cache: Cache?
    /// QA #606 F1: when a list-changing request last ran (DchFrame.listChanging, a session's exit).
    /// dch has the change at once, the island a tick later: within ~3 s (a 1 s tick, then a
    /// fetch at most AgentPollGate.floor after its last). A publish sooner than `settle` may
    /// carry a read from before the change (a fork already running, or an activity-only tick),
    /// so only one `settle` or more after it clears this; until then the list frame forks.
    private var changedAt: TimeInterval?
    static let settle: TimeInterval = 5
    /// Open order: the first of a device is its oldest.
    private(set) var streams: [Stream] = []

    init(now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         schedule: @escaping Schedule) {
        self.now = now
        self.schedule = schedule
    }

    static func schedule(on queue: DispatchQueue) -> Schedule {
        { delay, work in
            let item = DispatchWorkItem(block: work)
            queue.asyncAfter(deadline: .now() + delay, execute: item)
            return { item.cancel() }
        }
    }

    /// The island's published sessions as Remote Terminal's rows: nil while the island is
    /// off or does not list `remote` (then a request forks, as before). Sorted by name, so
    /// an activity reorder of the island is no change; `published` already reads a session
    /// the island is auto-answering as working, as Live status does.
    static func cache(island sessions: [AgentSession]?, dirs: [String], remote: String) -> Cache? {
        guard let sessions, dirs.contains(remote) else { return nil }
        let rows = sessions.filter { $0.key.dir == remote }.sorted { $0.name < $1.name }.map { s in
            DchListRow(name: s.name, alias: s.alias, activityEpoch: Int(s.activity), state: wireState(s.state),
                       agents: s.agents, meta: s.meta, metaEpoch: s.metaEpoch, version: s.version, cwd: s.cwd)
        }
        return Cache(dir: remote, rows: rows)
    }

    static func wireState(_ s: AgentState) -> String {
        switch s {
        case .blocked: "blocked"
        case .working: "working"
        case .done: "done"
        case .idle: "idle"
        }
    }

    /// listResp's payload from the cache, nil when there is none for Remote Terminal's dir.
    func cachedList() -> Data? {
        guard let cache, cache.dir == remoteDir() else { return nil }
        return DchFrame.listPayload(cache.rows)
    }

    func available() -> Bool { cache.map { $0.dir == remoteDir() } ?? false }

    /// QA #606 F1: a request changed the list; the list frame forks until the island has it.
    func changed() { changedAt = now() }

    /// The list frame's payload from the cache; nil (one dch fork) with no cache or a change
    /// the island may not have yet.
    func listReply() -> Data? { changedAt == nil ? cachedList() : nil }

    /// Every island publish (nil: it stopped). No list any more closes the streams, so the
    /// phone reconnects and, refused, polls.
    /// ponytail: with no publish after `settle` (every session idle, nothing changes) the list
    /// keeps forking, as before #765, until the next one; add a time cap if that ever costs.
    func island(_ new: Cache?) {
        if let t = changedAt, now() - t >= Self.settle { changedAt = nil }
        cache = new
        guard !streams.isEmpty else { return }
        guard let payload = cachedList() else { return streams.forEach(drop) }
        for s in streams { offer(s, payload) }
    }

    /// A 5th stream of a device closes its oldest first. False (nothing sent): no list.
    func open(_ id: ObjectIdentifier, device: String, send: @escaping Send, close: @escaping () -> Void) -> Bool {
        guard let payload = cachedList() else { return false }
        while streams.filter({ $0.device == device }).count >= Self.maxPerDevice,
              let oldest = streams.first(where: { $0.device == device }) {
            drop(oldest)
        }
        let s = Stream(id: id, device: device, send: send, close: close)
        streams.append(s)
        (s.sent, s.listAt) = (payload, now())
        emit(s, DchFrame.encode(DchFrame.listResp, [UInt8](payload)))
        let v = sidekick()
        (s.sidekick, s.sidekickAt) = (v, now())
        emit(s, DchSidekickOps.watchFrame(v))
        return true
    }

    /// The connection closed: forget the stream and cancel its timers. Idempotent.
    func remove(_ id: ObjectIdentifier) {
        guard let i = streams.firstIndex(where: { $0.id == id }) else { return }
        let s = streams.remove(at: i)
        s.cancelFlush?(); s.cancelBeat?(); s.cancelSidekick?()
        s.cancelFlush = nil; s.cancelBeat = nil; s.cancelSidekick = nil
    }

    /// The Mac's pattern may have changed (AgentIslandController.rowDetailsChanged).
    func sidekickChanged() {
        streams.forEach(offerSidekick)
    }

    /// A pattern that differs from the phone's goes at once, or `minGap` after the last
    /// sidekick frame; the timer re-reads it then, so the trailing edit is the one sent.
    private func offerSidekick(_ s: Stream) {
        guard s.cancelSidekick == nil else { return }
        let v = sidekick()
        guard v != s.sidekick else { return }
        let wait = s.sidekickAt + Self.minGap - now()
        guard wait <= 0 else {
            s.cancelSidekick = schedule(wait) { [weak self, weak s] in
                guard let self, let s, self.streams.contains(where: { $0 === s }) else { return }
                s.cancelSidekick = nil
                self.offerSidekick(s)
            }
            return
        }
        (s.sidekick, s.sidekickAt) = (v, now())
        emit(s, DchSidekickOps.watchFrame(v))
    }

    private func drop(_ s: Stream) {
        remove(s.id)
        s.close()
    }

    private func offer(_ s: Stream, _ payload: Data) {
        guard payload != s.sent else {
            // Back to what the phone has: nothing to send.
            s.pending = nil
            s.cancelFlush?(); s.cancelFlush = nil
            return
        }
        s.pending = payload
        let wait = s.listAt + Self.minGap - now()
        if wait <= 0 { return flush(s) }
        guard s.cancelFlush == nil else { return }
        s.cancelFlush = schedule(wait) { [weak self, weak s] in
            guard let self, let s else { return }
            s.cancelFlush = nil
            self.flush(s)
        }
    }

    private func flush(_ s: Stream) {
        guard let p = s.pending, streams.contains(where: { $0 === s }) else { return }
        s.pending = nil
        (s.sent, s.listAt) = (p, now())
        emit(s, DchFrame.encode(DchFrame.listResp, [UInt8](p)))
    }

    /// Every frame re-arms the heartbeat, so it goes only after 25 s of silence.
    private func emit(_ s: Stream, _ frame: Data) {
        s.backlog += 1
        guard s.backlog <= Self.maxBacklog else { return drop(s) }
        s.send(frame) { [weak s] in s?.backlog -= 1 }
        s.cancelBeat?()
        s.cancelBeat = schedule(Self.heartbeat) { [weak self, weak s] in
            guard let self, let s, self.streams.contains(where: { $0 === s }) else { return }
            self.emit(s, DchFrame.encode(DchFrame.ok, json: [String: Any]()))
        }
    }
}

// MARK: - Phone history and session controls (#591)

/// The phone's History tab and its Resume, Restart and Stop: the same binary,
/// gates, env, runner and argv helpers as Agent Island's own buttons, in Remote
/// Terminal's one socket dir. A wire name reaches argv only after it matched exactly
/// one live session (restart, stop) or history record (revive, pin, forget); argv comes only from
/// AgentIsland's *Args helpers, run without a shell. Every request gets exactly one
/// reply. Seamed: no test runs dch.
struct DchControlOps: Sendable {
    /// QA #462 H2: Remote Terminal's one dir, the one the phone's list, kill and
    /// rename use, so a wire name is a session the phone can see.
    var dirs: @Sendable () -> [String] = { [DchCommand.remoteSocketDir()] }
    /// The island's control binary; none under XCTest, so an unstubbed test is refused.
    var binary: @Sendable () -> DchCommand.Binary? = {
        NSClassFromString("XCTestCase") == nil ? DchCommand.controlDch() : nil
    }
    /// One bounded read: --ls-json/-lj with the island's dch (path nil), --history with the control binary.
    var read: @Sendable (_ args: [String], _ env: [String: String], _ path: String?) -> Data? = {
        DchCommand.runIsland(args: $0, env: $1, path: $2)
    }
    /// A verb's env for one dir, as the island's controlEnv (the user's PATH).
    var env: @Sendable (_ dir: String) -> [String: String] = { dir in
        AgentIsland.controlEnv(dir: dir, login: NSClassFromString("XCTestCase") == nil ? LoginPath.read() : nil)
    }
    /// The island's own runner (QA #462 M2), bounded like its jobs (one SIGTERM on
    /// expiry): a phone job and an island job on one row or dir exclude each other.
    var runner = DchActionRunner.shared
    var now: @Sendable () -> TimeInterval = { Date().timeIntervalSince1970 }
    /// #719: the live sessions' dch records (their Claude ids); none under XCTest.
    var liveRecords: @Sendable ([AgentSession]) -> [DchHistoryRecord] = {
        NSClassFromString("XCTestCase") == nil ? AgentIsland.liveRecords($0) : []
    }
    /// #720: the socket dirs whose live sessions seed those ids (`dirs` and the rest); none under XCTest.
    var seedDirs: @Sendable () -> [String] = {
        NSClassFromString("XCTestCase") == nil ? AgentIsland.seedSocketDirs() : []
    }
    /// After a verb: the island re-reads its history, as after its own Resume and Stop
    /// (its live rows follow on the next poll tick).
    var refresh: @Sendable () -> Void = {
        DispatchQueue.main.async { MainActor.assumeIsolated { AgentIslandController.shared.refreshHistory() } }
    }

    /// Server-wide: every connection's default.
    static let live = DchControlOps()

    /// QA #462 M4: a "names" array longer than this is refused before anything else.
    static let maxNames = 256

    typealias Reply = @Sendable (Data) -> Void

    enum Request: Equatable {
        case names([String])
        case all
    }

    /// `type`'s work, off the server queue. `reply` gets one frame.
    func handle(_ type: UInt8, _ payload: Data, reply: @escaping Reply) {
        let o = payload.isEmpty ? [:] : (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any]
        guard let o else { return reply(Self.error("malformed request: not a JSON object")) }
        if let a = o["names"] as? [Any], a.count > Self.maxNames {
            return reply(Self.error("too many names (max \(Self.maxNames))"))
        }
        switch type {
        case DchFrame.history:
            guard o.isEmpty else { return reply(Self.error("malformed history request: send nothing or {}")) }
            history(reply)
        case DchFrame.revive: revive(o, reply)
        case DchFrame.restart: restart(o, reply)
        case DchFrame.stop: stop(o, reply)
        case DchFrame.pin: pin(o, reply)
        case DchFrame.forget: forget(o, reply)
        case DchFrame.forgetAll:
            guard o.isEmpty else { return reply(Self.error("malformed forgetAll request: send nothing or {}")) }
            forgetAll(reply)
        default: reply(Self.error("unknown request"))
        }
    }

    static func error(_ message: String) -> Data { DchFrame.encode(DchFrame.error, json: ["message": message]) }

    /// `{"<key>": …}` or `{"all": true}`, one key and nothing else (QA #462 L2). "name"
    /// is one non-empty string, "names" a non-empty array of them, deduplicated in
    /// request order. nil for anything else.
    static func request(_ o: [String: Any], key: String, allowAll: Bool) -> Request? {
        guard o.count == 1 else { return nil }
        switch (o[key], o["all"]) {
        case (nil, let all?):
            // JSON true only: JSONSerialization hands 1 over as true too.
            guard allowAll, let n = all as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID(), n.boolValue else { return nil }
            return .all
        case (let v?, nil):
            let raw: [Any] = key == "name" ? [v] : (v as? [Any] ?? [])
            var names: [String] = [], seen = Set<String>()
            for e in raw {
                guard let s = e as? String, !s.isEmpty else { return nil }
                if seen.insert(s).inserted { names.append(s) }
            }
            return names.isEmpty ? nil : .names(names)
        default:
            return nil
        }
    }

    /// historyResp's object for one record. Seconds are whole; a value no Int holds reads 0.
    /// #719: `taken`, AgentIsland.reviveAllTaken's ids (nil: reviveAllTakes alone).
    static func historyWire(_ r: DchHistoryRecord, now: TimeInterval, taken: Set<AgentSessionKey>? = nil) -> [String: Any] {
        func secs(_ t: TimeInterval) -> Int { t.isFinite && abs(t) < 1e15 ? Int(t) : 0 }
        var o: [String: Any] = ["name": r.name, "end": r.end, "last_seen": secs(r.lastSeen), "started": secs(r.started),
                                "runtime": max(0, secs(r.lastSeen - r.started)),
                                "takes": taken?.contains(r.id) ?? AgentIsland.reviveAllTakes(r, now: now)]
        if !r.alias.isEmpty { o["alias"] = r.alias }
        if !r.cwd.isEmpty { o["cwd"] = r.cwd }
        if !r.argv.isEmpty { o["command"] = r.argv }
        if let a = r.agent?.name, !a.isEmpty { o["agent_name"] = a }   // #592: the phone's title fallback
        if r.pinned { o["pinned"] = true }   // #620: only when pinned, so an older phone sees no new key
        // #839: the phone matches "signal N" exactly; the sender's program rides in end_from, never its pid.
        if let s = AgentIsland.signalSender(r.end) {
            o["end"] = s.end
            if let from = s.from { o["end_from"] = from }
        }
        return o
    }

    private func sessions() -> [AgentSession] {
        let read = read
        return AgentIsland.list(dirs: dirs()) { read($0, $1, nil) }
    }

    /// The island's gate: the control binary against `minimum` and every live
    /// master. No binary refuses before any listing, so an unstubbed test forks nothing.
    private func gated(_ verb: String, minimum: [Int], _ reply: Reply) -> (path: String, live: [AgentSession])? {
        guard let bin = binary() else {
            reply(Self.error("\(verb) needs dch \(DchCommand.versionString(minimum))"))
            return nil
        }
        let live = sessions(), gate = DchCommand.gate(bin, masters: live.map(\.version), minimum: minimum)
        guard case .ok(let path) = gate else {
            reply(Self.error("\(verb) \(gate.refusal ?? "refused")"))
            return nil
        }
        return (path, live)
    }

    private func records(_ path: String) -> [DchHistoryRecord] {
        let read = read
        return AgentIsland.history(dirs: dirs()) { read($0, $1, path) }
    }

    /// The History tab's rows: pinned first and never capped, then the newest unpinned
    /// up to the cap (#605), with the binary the island reads them with.
    /// ponytail: no size guard. Pinned rows are uncapped, so ~2000 pinned records with
    /// 4 KB argv each (8.4 MB) pass DchFrame.maxFrame and the phone refuses the frame
    /// (QA #489 I6). Fix if pins ever get that many: past DchLibraryOps.maxReply drop the argv, then
    /// the oldest unpinned rows.
    private func history(_ reply: Reply) {
        let bin = binary(), gate = DchCommand.gate(bin, masters: [], minimum: AgentIsland.controlMinimum)
        guard case .ok(let path) = gate else { return reply(Self.error("History \(gate.refusal ?? "")")) }
        let t = now(), all = records(path)
        // #719 (QA #533 F1): "takes" as dch 1.28.2's --revive --all, which skips a Claude id
        // a live session or a newer record holds; the island's reviveFileGate.
        var held: Set<String>?
        if let bin, DchCommand.isAtLeast(bin.version, AgentIsland.reviveFileMinimum) {
            let live = sessions()
            if Self.reviveExact(bin, live) {
                // #720 (QA #535 M-1): and the sessions of the other socket dir, as dch holds a Claude from any dir.
                let listed = dirs(), read = read
                let other = AgentIsland.list(dirs: seedDirs().filter { !listed.contains($0) }) { read($0, $1, nil) }
                held = Set(liveRecords(live + other).compactMap { $0.agent?.sessionID }.filter { !$0.isEmpty })
            }
        }
        let ended = bin.map { DchCommand.isAtLeast($0.version, AgentIsland.reviveEndedHoldMinimum) } ?? false
        let taken = AgentIsland.reviveAllTaken(all, now: t, held: held, endedHolds: ended)
        reply(DchFrame.encode(DchFrame.historyResp,
                              json: AgentIsland.cappedHistory(all).map { Self.historyWire($0, now: t, taken: taken) }))
    }

    /// #746: the newest record of `name` (`history` is newest first): the phone's row, as
    /// newestPerName folds a by-hand start's aside records into it. Refused when the name
    /// is in two socket dirs (two sessions, the phone cannot say which), or in none.
    static func record(_ name: String, in history: [DchHistoryRecord]) -> Result<DchHistoryRecord, Refusal> {
        let matches = history.filter { $0.name == name }, dirs = Set(matches.map(\.key.dir))
        guard dirs.count == 1, let r = matches.first else {
            return .failure(Refusal(message: matches.isEmpty ? "\(name): no history record of that name"
                                                             : "\(name): history records of that name in \(dirs.count) socket dirs; use the Mac's Agent Island"))
        }
        return .success(r)
    }

    /// #746: a folded row's pin, unpin or forget, every target in one dch call. dch names a
    /// pin's line after its argument (a forget's after the record's name): all read under
    /// `name`. A failed line is the result even when an ok one follows it (answer(named:)
    /// reads the last), so a partial run never reads as done; an unpin's not_found is no failure.
    static func edited(_ r: DchActionResult, _ targets: [String], to name: String, _ verb: AgentIsland.Verb) -> DchActionResult {
        var r = targets.reduce(r) { renamed($0, $1, to: name) }
        if let f = r.json.first(where: { $0.name == name && $0.isFinal && $0.failed && !AgentIsland.unpinGone($0, verb) }) {
            r.json = [f]
        }
        return r
    }

    /// QA #573 INFO-1: a forget by the bare name (below 1.28.1) removes every unpinned record
    /// of it and answers "pinned" for each pinned older one (exit 1): done, once one went.
    /// Ok with a note, as the Mac drops those lines; a "pinned" with nothing gone still fails.
    static let keptPinnedText = "removed the unpinned runs, kept the pinned ones"
    static func forgotten(_ r: DchActionResult, _ targets: [String], to name: String) -> Data {
        var r = targets.reduce(r) { renamed($0, $1, to: name) }
        let kept = { (o: DchJSONLine) in o.name == name && o.isFinal && o.failed && o.reason == "pinned" }
        if !r.stopped, r.json.contains(where: { $0.name == name && $0.isFinal && $0.result == "ok" }), r.json.contains(where: kept) {
            r.json.removeAll(where: kept)   // another failure beside them is the answer
            if !r.json.contains(where: { $0.name == name && $0.isFinal && $0.failed }) {
                return DchFrame.encode(DchFrame.ok, json: ["names": [name], "message": "\(name): \(keptPinnedText)"])
            }
        }
        return answer(named: [(name, edited(r, targets, to: name, .remove))], .remove)
    }

    /// The island's Resume (a record by name, `--as` a free name when it is live
    /// again) or Resume interrupted (`--revive --all` in each dir with history).
    /// #669: an optional JSON-bool "no_message" beside either (false is a plain revive);
    /// true is gated on 1.27.0 and refused there, never run as a plain revive (that types the message).
    private func revive(_ o: [String: Any], _ reply: @escaping Reply) {
        var o = o
        let flag = o.removeValue(forKey: "no_message")
        let bool = flag as? NSNumber
        guard flag == nil || bool.map({ CFGetTypeID($0) == CFBooleanGetTypeID() }) == true,
              let req = Self.request(o, key: "name", allowAll: true) else {
            return reply(Self.error("malformed revive request: send {\"name\": \"…\"} or {\"all\": true}"))
        }
        let noMessage = bool?.boolValue == true
        guard case let (path, live)? = noMessage
            ? gated(AgentIsland.resumeNoMessageLabel, minimum: AgentIsland.reviveNoMessageMinimum, reply)
            : gated("Resume", minimum: AgentIsland.controlMinimum, reply) else { return }
        let history = records(path)
        switch req {
        case .all:
            let args = noMessage ? AgentIsland.reviveAllNoMessageArgs : AgentIsland.reviveAllArgs
            let jobs: [(AgentSessionKey, [String]?)] = Set(history.map(\.key.dir)).sorted().map { (AgentSessionKey(dir: $0, name: ""), args) }
            run(jobs, path: path, bound: nil, reply) { Self.answer(all: Self.merged($0), .resume) }
        case .names(let names):
            let name = names[0], r: DchHistoryRecord
            switch Self.record(name, in: history) {
            case .failure(let why): return reply(Self.error(why.message))
            case .success(let one): r = one
            }
            let liveNames = Set(live.filter { $0.key.dir == r.key.dir }.map(\.name))
            let others = Set(history.filter { $0.key.dir == r.key.dir && $0.key != r.key }.map(\.name))
            // #719: `<file>.json` from dch 1.28.2; the by-hand hint under the record's config dir.
            let exact = Self.reviveExact(binary(), live), arg = r.editTarget(exact: exact)
            run([(r.id, AgentIsland.reviveArgs(r, live: liveNames, records: others, noMessage: noMessage, exact: exact))],
                path: path, bound: nil, reply) {
                Self.answer(named: [(name, Self.renamed($0[0], arg, to: name))], .resume, record: r)   // #716 L-3
            }
        }
    }

    /// The island's Restart agent per name (`-f`), or Restart all per dir with a live session.
    private func restart(_ o: [String: Any], _ reply: @escaping Reply) {
        guard let req = Self.request(o, key: "names", allowAll: true) else {
            return reply(Self.error("malformed restart request: send {\"names\": [\"…\"]} or {\"all\": true}"))
        }
        guard case let (path, live)? = gated("Restart", minimum: AgentIsland.restartMinimum, reply) else { return }
        switch req {
        case .all:
            let jobs: [(AgentSessionKey, [String]?)] = Set(live.map(\.key.dir)).sorted().map { (AgentSessionKey(dir: $0, name: ""), AgentIsland.restartAllArgs) }
            run(jobs, path: path, bound: DchActionRunner.restartBound, yields: true, reply) { Self.answer(all: Self.merged($0), .restart) }
        case .names(let names):
            switch Self.resolve(names, live: live) {
            case .failure(let why): reply(Self.error(why.message))
            case .success(let rows):
                run(rows.map { ($0.key, AgentIsland.restartArgs($0.name)) }, path: path, bound: DchActionRunner.restartBound,
                    yields: true, reply) { Self.answer(named: Array(zip(rows.map(\.name), $0)), .restart) }
            }
        }
    }

    /// The island's Stop, by name only (never `--all`): one `--stop` per dir, on
    /// masters that can stop, under the dir's key (it excludes more than a row's, never less).
    private func stop(_ o: [String: Any], _ reply: @escaping Reply) {
        guard let req = Self.request(o, key: "names", allowAll: false), case .names(let names) = req else {
            return reply(Self.error("malformed stop request: send {\"names\": [\"…\"]}"))
        }
        guard case let (path, live)? = gated("Stop", minimum: AgentIsland.restartMinimum, reply) else { return }
        switch Self.resolve(names, live: live) {
        case .failure(let why): reply(Self.error(why.message))
        case .success(let rows):
            if let old = rows.first(where: { !AgentIsland.canStop($0) }) {
                return reply(Self.error("\(old.name): restart this session first, its dch cannot stop"))
            }
            let groups = Dictionary(grouping: rows, by: \.key.dir).sorted { $0.key < $1.key }
            run(groups.map { (AgentSessionKey(dir: $0.key, name: ""), AgentIsland.stopArgs($0.value.map(\.name))) },
                path: path, bound: DchActionRunner.restartBound, yields: true, reply) { rs in
                let byDir = Dictionary(uniqueKeysWithValues: zip(groups.map(\.key), rs))
                return Self.answer(named: rows.map { ($0.name, byDir[$0.key.dir] ?? DchActionResult(status: -1)) }, .stop)
            }
        }
    }

    /// #620: the island's History pin toggle, `--pin` or `--unpin` on one row in its dir (#746: every record it folds).
    private func pin(_ o: [String: Any], _ reply: @escaping Reply) {
        guard o.count == 2, let name = o["name"] as? String, !name.isEmpty,
              let p = o["pin"] as? NSNumber, CFGetTypeID(p) == CFBooleanGetTypeID() else {
            return reply(Self.error("malformed pin request: send {\"name\": \"…\", \"pin\": true|false}"))
        }
        guard case let (path, live)? = gated("Pin", minimum: AgentIsland.historyEditMinimum, reply) else { return }
        let verb: AgentIsland.Verb = p.boolValue ? .pin : .unpin, history = records(path)
        switch Self.record(name, in: history) {
        case .failure(let why): reply(Self.error(why.message))
        case .success(let r):
            // #714: these records alone where dch can (1.28.1 `<file>.json`, an aside file).
            // #746: every record the row folds, as the Mac row's pin.
            let targets = AgentIsland.editTargets(r, older: AgentIsland.older(r, in: history),
                                                  exact: Self.exact(binary(), live), forget: false)
            run([(r.id, AgentIsland.pinArgs(targets, pin: verb == .pin))], path: path, bound: nil, reply) {
                Self.answer(named: [(name, Self.edited($0[0], targets, to: name, verb))], verb)
            }
        }
    }

    /// #620: the island's History X, `--forget` on one row in its dir (#746: its unpinned records), never -f:
    /// a pinned record is refused before dch runs, as the island shows it no X.
    private func forget(_ o: [String: Any], _ reply: @escaping Reply) {
        guard let req = Self.request(o, key: "name", allowAll: false), case .names(let names) = req else {
            return reply(Self.error("malformed forget request: send {\"name\": \"…\"}"))
        }
        guard case let (path, live)? = gated("Forget", minimum: AgentIsland.historyEditMinimum, reply) else { return }
        let name = names[0], history = records(path)
        switch Self.record(name, in: history) {
        case .failure(let why): reply(Self.error(why.message))
        case .success(let r) where r.pinned: reply(Self.error("\(name): \(AgentIsland.pinnedRefusal)"))
        case .success(let r):
            // #746: the row's unpinned records, as the Mac row's X.
            let targets = AgentIsland.editTargets(r, older: AgentIsland.older(r, in: history),
                                                  exact: Self.exact(binary(), live), forget: true)
            run([(r.id, AgentIsland.forgetArgs(targets))], path: path, bound: nil, reply) {
                Self.forgotten($0[0], targets, to: name)
            }
        }
    }

    /// #714: the island's recordFileGate: `<file>.json` pins and forgets one record (1.28.1).
    static func exact(_ bin: DchCommand.Binary?, _ live: [AgentSession]) -> Bool {
        DchCommand.gate(bin, masters: live.map(\.version), minimum: AgentIsland.recordFileMinimum).isOK
    }

    /// #719: the island's reviveFileGate: `--revive <file>.json` and --all's held ids (1.28.2).
    static func reviveExact(_ bin: DchCommand.Binary?, _ live: [AgentSession]) -> Bool {
        DchCommand.gate(bin, masters: live.map(\.version), minimum: AgentIsland.reviveFileMinimum).isOK
    }

    /// #714: dch names a pin's result line, and a not_found, after its argument (a file
    /// here); the reply reads them under the requested name. #716: a revive's
    /// no_history too, on the phone and the island.
    static func renamed(_ r: DchActionResult, _ arg: String, to name: String) -> DchActionResult {
        var r = r
        r.json = r.json.map { o in
            var o = o
            if o.name == arg { o.name = name }
            return o
        }
        return r
    }

    /// #620: the island's Clear unpinned, `--forget --all` once per History dir.
    private func forgetAll(_ reply: @escaping Reply) {
        guard case let (path, _)? = gated("Clear unpinned", minimum: AgentIsland.historyEditMinimum, reply) else { return }
        let jobs: [(AgentSessionKey, [String]?)] = Set(records(path).map(\.key.dir)).sorted().map { (AgentSessionKey(dir: $0, name: ""), AgentIsland.forgetAllArgs) }
        run(jobs, path: path, bound: nil, reply) { Self.answer(cleared: $0) }
    }

    /// Clear unpinned's one reply: ok {cleared, skipped, failed} summed over the dirs
    /// (the island's counts; a non-zero exit its failed records explain is still ok),
    /// else one error with the island's tally line for the first dir that did not finish.
    static func answer(cleared rs: [DchActionResult]) -> Data {
        if let bad = rs.first(where: { $0.stopped || ($0.status != 0 && AgentIsland.counts($0).failed == 0) }) {
            return error(AgentIsland.tally(bad, .clear, title: "Clear unpinned", empty: "nothing to clear"))
        }
        let c = rs.map(AgentIsland.counts)
        return DchFrame.encode(DchFrame.ok, json: ["cleared": c.map(\.ok).reduce(0, +), "skipped": c.map(\.skipped).reduce(0, +),
                                                   "failed": c.map(\.failed).reduce(0, +)])
    }

    struct Refusal: Error { let message: String }

    static let dashNameRefusal = "a session name starting with - can't be passed to dch"

    /// #850: dch 1.46.1 serve's refusal of a session_id-shaped new name or alias (serve.c:1001, :1161).
    static let idShapedRefusal = "name looks like a session_id"

    /// #850: dch 1.46.1's xr_label_id_shaped (xray.c:222): trimmed of ' ' and \t...\r, then "m" and
    /// 16 hex digits, any case (a case-insensitive file system answers the id to such a name).
    static func idShaped(_ s: String) -> Bool {
        let space: (UInt8) -> Bool = { $0 == 0x20 || (0x09...0x0d).contains($0) }
        var b = Array(s.utf8)[...]
        while let c = b.first, space(c) { b = b.dropFirst() }
        while let c = b.last, space(c) { b = b.dropLast() }
        return b.count == 17 && (b.first == UInt8(ascii: "m") || b.first == UInt8(ascii: "M"))
            && b.dropFirst().allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || (0x61...0x66).contains($0 | 0x20) }
    }

    /// Each name's one live session, in request order; refused whole when any name
    /// is not exactly one live session.
    static func resolve(_ names: [String], live: [AgentSession]) -> Result<[AgentSession], Refusal> {
        var rows: [AgentSession] = []
        for n in names {
            let m = live.filter { $0.name == n }
            guard m.count == 1 else {
                return .failure(Refusal(message: m.isEmpty ? "\(n): no live session of that name" : "\(n): \(m.count) live sessions of that name"))
            }
            rows.append(m[0])
        }
        return .success(rows)
    }

    private final class Results: @unchecked Sendable {
        let lock = NSLock()
        var all: [DchActionResult?]
        init(_ n: Int) { all = Array(repeating: nil, count: n) }
    }

    /// Runs the jobs at once on the runner (a busy key reads as a failed job), then
    /// pokes the island and replies once with `answer` over the results in job order.
    /// #627: any job with nil args (a name dch would read as a flag) refuses the whole request.
    /// #749 (QA #572 INFO-R1): `yields` for a Stop or Restart, as the island's: an island Kill may cut through it.
    private func run(_ jobs: [(AgentSessionKey, [String]?)], path: String, bound: TimeInterval?, yields: Bool = false,
                     _ reply: @escaping Reply,
                     answer: @escaping @Sendable ([DchActionResult]) -> Data) {
        let ready = jobs.compactMap { key, args in args.map { (key, $0) } }
        guard ready.count == jobs.count else { return reply(Self.error(Self.dashNameRefusal)) }
        let group = DispatchGroup(), results = Results(jobs.count), env = env
        for (i, (key, args)) in ready.enumerated() {
            group.enter()
            let started = runner.start(key, path: path, args: args, bound: bound, yields: yields, env: { env(key.dir) }) { r in
                results.lock.withLock { results.all[i] = r }
                group.leave()
            }
            if !started {
                results.lock.withLock { results.all[i] = DchActionResult(status: -1, text: ["dch: busy with an earlier request"]) }
                group.leave()
            }
        }
        let refresh = refresh, ran = !jobs.isEmpty
        group.notify(queue: .global(qos: .utility)) {
            let rs = results.lock.withLock { results.all.map { $0 ?? DchActionResult(status: -1) } }
            if ran { refresh() }
            reply(answer(rs))
        }
    }

    /// Every job's output as one: the first non-zero exit, lines in job order.
    /// #750 (QA #576 INFO-3): the sessions a Kill ended in any of them.
    /// ponytail: by name, so a killed name also failing in another dir reads killed there; key by dir if that matters.
    static func merged(_ rs: [DchActionResult]) -> DchActionResult {
        DchActionResult(status: rs.first { $0.status != 0 }?.status ?? 0, json: rs.flatMap(\.json),
                        text: rs.flatMap(\.text), stopped: rs.contains { $0.stopped }, killed: Set(rs.flatMap(\.killed)))
    }

    /// QA #462 H1: a result that leaves the session done: ok, or a skip with no
    /// agent to act on (not_claude, current: the master moved; restartAllSummary's no-skip).
    static func isOK(_ o: DchJSONLine) -> Bool {
        o.result == "ok" || (o.result == "skipped" && ["not_claude", "current"].contains(o.reason ?? ""))
    }

    /// A named request (QA #462 H1, M1): each name by its job's LAST result for it, as
    /// AgentIsland.rowText reads it; no result is ok only on exit 0. All ok: ok
    /// {"names"} in request order (a revive's under its `as` name). Else one error,
    /// "<name>: <rowText>" per failed name joined by "; " (a cancelled job's names
    /// carry rowText's cancelled text).
    /// #719: an unpin dch finds nothing for (1.28.2's not_found) is ok: the record went.
    /// `record`: a revive's, for the by-hand hint's CLAUDE_CONFIG_DIR.
    /// #861: a revive that came back withdrawn or draft_left is ok under its `as` name, its
    /// "<name>: <rowText>" in the ok's "message" (forget's partial success; remote-frames.md 0x0c).
    static func answer(named: [(String, DchActionResult)], _ verb: AgentIsland.Verb, record: DchHistoryRecord? = nil) -> Data {
        var ok: [String] = [], lines: [String] = [], failed = false
        for (n, r) in named {
            let last = r.json.last { $0.name == n && ($0.isFinal || $0.isMaster) }
            let unsent = !r.stopped && last.map { AgentIsland.resumedUnsent($0, verb) } == true
            if unsent || !r.stopped && last.map({ isOK($0) || AgentIsland.unpinGone($0, verb) }) ?? (r.status == 0) {
                ok.append(last?.revivedAs.flatMap { $0.isEmpty ? nil : $0 } ?? n)
                if !unsent { continue }
            } else {
                failed = true
            }
            lines.append("\(n): \(AgentIsland.byHand(AgentIsland.rowText(r, name: n, verb), record))")
        }
        if failed { return error(lines.joined(separator: "; ")) }
        var reply: [String: Any] = ["names": ok]
        if !lines.isEmpty { reply["message"] = lines.joined(separator: "; ") }
        return DchFrame.encode(DchFrame.ok, json: reply)
    }

    /// An all-request (QA #462 M1): ok {"names"} (each session with an ok result, a
    /// revive's under its `as` name, in dch's order) only when every job exited 0
    /// and no result failed; else one error with the island's own summary line.
    /// #861: a revive whose message was not sent (exit 1) is ok too, its line in "message" as answer(named:)'s.
    /// shortcut: `r` is merged (first non-zero exit), so another dir's no-JSON failure beside such a line
    /// reads ok, as tally's `other` reads it; per-dir results would close it.
    static func answer(all r: DchActionResult, _ verb: AgentIsland.Verb) -> Data {
        let results = r.json.filter { $0.isFinal || $0.isMaster }
        let unsent = results.filter { AgentIsland.resumedUnsent($0, verb) }
        guard !r.stopped, r.status == 0 || !unsent.isEmpty,
              !results.contains(where: { $0.failed && !AgentIsland.resumedUnsent($0, verb) }) else {
            return error(verb == .resume ? AgentIsland.tally(r, .resume, title: "Resume", empty: "nothing to resume")
                                         : AgentIsland.restartAllSummary(r))
        }
        var names: [String] = [], seen = Set<String>()
        for o in results where o.result == "ok" || AgentIsland.resumedUnsent(o, verb) {
            let n = o.revivedAs.flatMap { $0.isEmpty ? nil : $0 } ?? o.name
            if seen.insert(n).inserted { names.append(n) }
        }
        let message = unsent.map { "\($0.name): \(AgentIsland.finalText($0, verb))" }.joined(separator: "; ")
        var reply: [String: Any] = ["names": names]
        if !message.isEmpty { reply["message"] = message }
        return DchFrame.encode(DchFrame.ok, json: reply)
    }
}

// MARK: - Session list rows

/// #792: `--ls-json`'s per-row "auto_allowed" {at, title}: when (epoch seconds) and which
/// dialog the master's auto-allow answered last. nil for null, absent or malformed.
struct DchAutoAllowed: Equatable, Sendable {
    let at: Int
    let title: String

    init(at: Int, title: String) { (self.at, self.title) = (at, title) }

    init?(json: Any?) {
        guard let o = json as? [String: Any], let at = o["at"] as? Int, let title = o["title"] as? String else { return nil }
        (self.at, self.title) = (at, title)
    }
}

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
    /// #792: the prompt the master's own auto-allow answered last (dch 1.29.2+), nil when none.
    var autoAllowed: DchAutoAllowed? = nil
    /// #877: dch 1.52's `cwd` (dch #115), the session's start dir from its live history record; "" when
    /// dch has none (no record, an ended one, an older dch: `null` or no key).
    var cwd: String = ""

    /// #877: listResp's "cwd" as dch serve writes it (serve.c:340, :358-359, :374-378@v1.54.0): the
    /// string as dch gave it, unchecked (no absolute or trailing-slash rule), nil when empty or when its
    /// UTF-8 does not fit serve's cwd[512] with its NUL (512 bytes or more), so the key is left out.
    var wireCwd: String? { cwd.isEmpty || cwd.utf8.count >= Self.maxCwdBytes ? nil : cwd }
    /// dch serve's `char cwd[512]` (serve.c:340@v1.54.0): bytes, the NUL included.
    static let maxCwdBytes = 512

    /// The phone's `meta`/`meta_epoch` row keys, re-encoded from the decoded fields
    /// (never dch's raw JSON); empty when there is no meta or nothing survives the
    /// filter. The phone is a second untrusted-text consumer: only allowlisted PR URLs
    /// go out, repo/title truncated.
    var metaWire: [String: Any] {
        guard let meta else { return [:] }
        var m: [String: Any] = [:]
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
        guard !open.isEmpty || meta.merged != nil else { return [:] }
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

    /// #772: dch's `tasks` key is ignored (iOS #763 stopped reading it), so it never reaches the phone.
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
        if let p = o["prs"] as? [String: Any] {
            merged = Self.count(p["merged"])
            openPRs = ((p["open"] as? [Any]) ?? []).prefix(Self.maxOpenPRs).compactMap { e in
                guard let e = e as? [String: Any] else { return nil }
                return PR(url: e["url"] as? String ?? "", repo: e["repo"] as? String ?? "",
                          num: Self.count(e["num"]), title: e["title"] as? String ?? "")
            }
        }
    }

    init(openPRs: [PR] = [], merged: Int? = nil) {
        (self.openPRs, self.merged) = (openPRs, merged)
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
        /// `until`: a timed-out probe's expiry; nil for an answer, kept for the mtime.
        var map: [String: (mtime: TimeInterval, version: [Int]?, until: Date?)] = [:]
    }
    private static let versionCache = VersionCache()

    /// #704: how long a timed-out probe stays nil before it is run again. A var only
    /// so tests can shorten it. ponytail: no in-flight dedupe, so calls during a hung
    /// candidate's first 4 s each probe it; add one if a hung dch is ever seen.
    nonisolated(unsafe) static var probeTimeoutTTL: TimeInterval = 60

    /// `path --version`, cached per resolved path and mtime (a brew upgrade
    /// retargets the symlink, a rebuild moves the mtime), never per call. A
    /// missing or non-executable path is nil; a timed-out probe is nil for
    /// `probeTimeoutTTL` (#704), or until the mtime moves.
    static func probedVersion(_ path: String) -> [Int]? {
        let real = (path as NSString).resolvingSymlinksInPath
        guard FileManager.default.isExecutableFile(atPath: real), let m = AgentDirScanner.mtime(real) else { return nil }
        if let hit = versionCache.lock.withLock({ versionCache.map[real] }), hit.mtime == m,
           hit.until.map({ Date() < $0 }) ?? true { return hit.version }
        guard let out = bounded(islandTimeout, { onPid in
            runCapturingBoth(args: ["--version"], env: AgentIsland.listEnv(dir: defaultSocketDir), path: real, onPid: onPid).out
        }) else {
            versionCache.lock.withLock {   // never over an overlapping call's answer (QA #518 LOW-1)
                if let e = versionCache.map[real], e.mtime == m, e.until == nil { return }
                versionCache.map[real] = (m, nil, Date().addingTimeInterval(probeTimeoutTTL))
            }
            return nil
        }
        let v = parseVersion(String(decoding: out, as: UTF8.self))
        versionCache.lock.withLock { versionCache.map[real] = (m, v, nil) }
        return v
    }

    /// Whether a control may run: the binary is at least the verb's minimum and
    /// every live master's version ("" = an old master, which passes), so it never
    /// downgrades a newer master. `.refused` carries the one-line reason.
    enum Gate: Equatable {
        case ok(String)
        case refused(String)

        var isOK: Bool { if case .ok = self { true } else { false } }
        /// The reason, nil when it may run.
        var refusal: String? { if case .refused(let why) = self { why } else { nil } }
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
        // #803: "--" ends dch's flags, so a create's command ["-kl"] runs as a command instead
        // of killing every session. Only with a command: dch reads "-E -n x --" exactly as
        // "-E -n x" (dch.c main: "--" breaks the flag loop, inner_argc 0 either way), and the
        // bare form keeps an attach's argv as it always was.
        if !command.isEmpty { args += ["--"] + command }
        return args
    }

    static func childEnv() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        // If Prosper was itself launched from inside a dch session, its env carries
        // DCH_SESSION and dch would refuse to spawn ("nesting disabled"). Strip it.
        env.removeValue(forKey: "DCH_SESSION")
        if isolateRemote {
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
                              version: o["version"] as? String ?? "",
                              autoAllowed: DchAutoAllowed(json: o["auto_allowed"]),
                              cwd: o["cwd"] as? String ?? "")
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
        let (screen, err, _) = runCapturingBoth(args: ["--read", name, "--ansi", "--cursor"])
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

    /// Test seam (#591 r2): stands in for `Preferences.isolateRemoteSessions`; nil reads it.
    nonisolated(unsafe) static var isolateOverride: Bool?

    /// #594: the one isolation input childEnv and remoteSocketDir both read.
    static var isolateRemote: Bool { isolateOverride ?? Preferences.isolateRemoteSessions }

    /// #591 r2 (QA #462 H2): Remote Terminal's one dir, isolated while
    /// `isolateRemoteSessions` is on, else the default. The phone's list, kill and
    /// rename, and its history and control verbs (DchControlOps.dirs), all read it.
    static func remoteSocketDir(isolate: Bool = DchCommand.isolateRemote) -> String {
        isolate ? isolatedSocketDir : defaultSocketDir
    }

    static func socketDir(env: [String: String]) -> String {
        if let d = env["DCH_SOCKET_DIR"], !d.isEmpty { return d }
        if let x = env["XDG_RUNTIME_DIR"], !x.isEmpty { return "\(x)/dch-\(getuid())" }
        return "/tmp/dch-\(getuid())"
    }

    /// True while the transport a remote session needs is up: the default route is
    /// alive AND a Tailscale address is assigned. Nothing here is "remote" without
    /// both: on a network drop the local pty of a detached session keeps stamping
    /// activity and stale NWConnections linger for ~160s of TCP keepalive, so the
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

    /// Set (or clear, when empty) a session's display alias. #811: nil on exit 0, else one
    /// line for the phone: dch's first stderr line, or its exit status.
    static func setAlias(_ name: String, alias: String) -> String? {
        let r = runCapturingBoth(args: ["-m", name, alias])
        guard r.status != 0 else { return nil }
        let line = r.err.split(whereSeparator: \.isNewline).first.map { String($0.prefix(120)) }
        let shown = name.count > 64 ? String(name.prefix(64)) + "…" : name
        return "Couldn't rename \(shown): \(line ?? (r.status < 0 ? "dch could not be run" : "dch exited \(r.status)"))"
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
    private static func runCapturingBoth(args: [String]) -> (out: Data, err: String, status: Int32) {
        runCapturingBoth(args: args, env: remoteEnv())
    }

    /// Remote Terminal's one-shot dch env (list, kill, rename, --read; #838's ctl): its one dir, no DCH_SESSION.
    static func remoteEnv() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "DCH_SESSION")
        env["DCH_SOCKET_DIR"] = remoteSocketDir()
        return env
    }

    /// Run dch with exactly `env` — #474 lists each socket dir with its own
    /// DCH_SOCKET_DIR, whatever the isolation preference says.
    /// `path` defaults to dchPath read here; a bounded caller resolves it on its own
    /// thread instead (#486 r2), so a late-starting body never reads a reset override.
    /// #578: `merge` sends stderr into `out` (a control verb prints results on
    /// stdout and refusals on stderr; its last line is whichever came last), and
    /// `status` is the exit code (-1 when it never started).
    /// #579: `cwd` is the child's working dir (--spawn has no --cwd); `onOutput`
    /// gets each stdout chunk as it comes (a restart reports per session).
    static func runCapturingBoth(args: [String], env: [String: String], path: String = dchPath, merge: Bool = false,
                                 cwd: String? = nil, onPid: (pid_t) -> Void = { _ in },
                                 onOutput: (Data) -> Void = { _ in }) -> (out: Data, err: String, status: Int32) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.environment = env
        if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd, isDirectory: true) }
        let pipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = pipe
        p.standardError = merge ? pipe : errPipe
        do { try p.run() } catch { return (Data(), "", -1) }
        onPid(p.processIdentifier)
        // Screen first (it can be tens of KB), then stderr (one line at most, so it
        // fits the pipe buffer while we drain stdout — no deadlock).
        var data = Data()
        while case let chunk = pipe.fileHandleForReading.availableData, !chunk.isEmpty {
            data.append(chunk)
            onOutput(chunk)
        }
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
