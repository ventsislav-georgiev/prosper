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
    // both directions
    static let data: UInt8    = 0x10  // raw pty bytes
    // server → client
    static let listResp: UInt8 = 0x11 // [{name, alias?}]
    static let exit: UInt8     = 0x12 // {code}
    static let error: UInt8    = 0x13 // {message}
    static let ok: UInt8       = 0x14 // (empty) ack for kill

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
    private var closed = false
    private var buffer = Data()
    private var pty: PtyChild?

    init(conn: NWConnection, queue: DispatchQueue, log: Logger,
         onClose: @escaping (ObjectIdentifier) -> Void) {
        self.conn = conn
        self.queue = queue
        self.log = log
        self.onClose = onClose
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
                row.alias.isEmpty ? ["name": row.name] : ["name": row.name, "alias": row.alias]
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
        default:
            break
        }
    }

    private func startSession(type: UInt8, payload: Data) {
        guard pty == nil else { return }  // one session per connection
        let o = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any] ?? [:]
        let name = o["name"] as? String
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
                    sem.wait()
                },
                onExit: { [weak self] code in
                    self?.send(DchFrame.encode(DchFrame.exit, json: ["code": code]))
                    self?.close()
                })
            pty = child
            child.run()
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

    /// Parse `dch -lj` (one `name\talias` per line; alias may be empty).
    static func listSessions() -> [(name: String, alias: String)] {
        runCapturing(args: ["-lj"])
            .split(separator: "\n")
            .compactMap { line in
                let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
                guard let name = parts.first, !name.isEmpty else { return nil }
                let alias = parts.count > 1 ? String(parts[1]) : ""
                return (String(name), alias)
            }
    }

    static func kill(_ name: String) {
        _ = runCapturing(args: ["-k", name])
    }

    /// Set (or clear, when empty) a session's display alias.
    static func setAlias(_ name: String, alias: String) {
        _ = runCapturing(args: ["-m", name, alias])
    }

    /// Run dch for a short control command and capture stdout. Not used for attach
    /// (that needs a pty) — only for `-ls` / `-k`.
    private static func runCapturing(args: [String]) -> String {
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
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
