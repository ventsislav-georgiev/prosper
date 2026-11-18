import AppKit
import Foundation

// #1561 (Phase H, X-R b): the warm `dch --xray host:name --requests --json` connection (dch README v1.99.0:1278-1323,
// dch.1 :2567). A remote pane's --json, --ref, --chapter and --clear reads go to the host as NDJSON requests on one
// child, one at a time, instead of one dch per read. --tasks, --memory, --search and the follow stay cold spawns: dch
// takes only those four forms there.

/// The `--requests` child: one NDJSON line out, one line in. The product's is XrayRequestProcess; rows put a fake.
protocol XrayRequestChild: AnyObject, Sendable {
    /// One line to dch's stdin (the newline included). After closeInput: dropped.
    func write(_ line: Data)
    /// The next stdout line, newline stripped; nil at the end of output.
    func nextLine() async -> Data?
    /// End of stdin: dch closes the connection and exits 0; a request running then ends `"why":"cancel"`.
    func closeInput()
    /// A dial that never answered: the child is ended.
    func terminate()
}

/// The window's warm connections, one per remote target ("host:name": dch's form binds the name, so per (window,
/// host) is per (window, host:name)). Owned by XrayPanels (one Agents window), closed on its hide or close.
@MainActor
final class XrayRequests: NSObject {
    typealias Spawn = @Sendable (_ path: String, _ args: [String], _ env: [String: String]) -> (any XrayRequestChild)?

    /// nil: no warm connection, every read is cold (under XCTest, so no row runs a process; rows put a fake here).
    var spawn: Spawn? = NSClassFromString("XCTestCase") == nil ? XrayRequests.process : nil
    nonisolated static let process: Spawn = { path, args, env in XrayRequestProcess.start(path, args, env) }
    private(set) var lines: [String: XrayRequestLine] = [:]

    /// `cold` for a local target (dir set) or no spawn; else a Run that sends the request forms through the target's
    /// connection, dialled on its first request. Any other form, bound stdin, a dial that failed or `busy`: `cold`.
    func run(for target: XrayTarget, cold: @escaping XrayPanels.Run) -> XrayPanels.Run {
        guard target.dir == nil, let spawn else { return cold }
        let line = lines[target.name] ?? XrayRequestLine(name: target.name, spawn: spawn)
        lines[target.name] = line
        let name = target.name
        return { path, args, env in
            guard XrayPanels.stdin.get() == nil, let argv = XrayRequests.form(args, name: name),
                  let r = await line.request(path, argv, env) else { return await cold(path, args, env) }
            return r
        }
    }

    /// dch's request forms (README v1.99.0:1287-1289): the flags after `--xray <name>`, for --json alone, --ref,
    /// --chapter and --clear; nil for anything else (it runs cold).
    nonisolated static func form(_ args: [String], name: String) -> [String]? {
        guard args.count >= 3, args.first == "--xray", args.dropFirst().first == name else { return nil }
        let rest = Array(args.dropFirst(2))
        switch rest.first {
        case "--json": return rest == ["--json"] ? rest : nil
        case "--ref", "--chapter", "--clear": return rest
        default: return nil
        }
    }

    /// Hide: every child gets stdin EOF (a running request ends cancelled); the next request dials again.
    func closeAll() { for l in lines.values { Task { await l.close() } } }

    /// Close: as hide, and the connections go.
    func windowClosed() {
        closeAll()
        lines = [:]
    }

    /// The Agents window's hide (not visible: miniaturized, covered, another Space, the app hidden) and close.
    func observe(_ center: NotificationCenter) {
        center.addObserver(self, selector: #selector(occlusionChanged(_:)), name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        center.addObserver(self, selector: #selector(willClose(_:)), name: NSWindow.willCloseNotification, object: nil)
    }

    @objc private func occlusionChanged(_ n: Notification) {
        guard let w = n.object as? AgentsNSWindow, !w.occlusionState.contains(.visible) else { return }
        closeAll()
    }

    @objc private func willClose(_ n: Notification) {
        guard n.object is AgentsNSWindow else { return }
        windowClosed()
    }
}

/// One target's connection: requests one at a time (dch answers a second one `busy`), each with a fresh N.
actor XrayRequestLine {
    let name: String
    private let spawn: XrayRequests.Spawn
    private var child: (any XrayRequestChild)?
    private var n: Int32 = 0
    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    /// Each start that failed (dch's ready-line exit, 6 / 7 / 4; -1: no process or no line): that request ran cold.
    private(set) var startFailures: [Int32] = []
    /// A request with no end line by then gets {"cancel":N} (DchCommand.remoteTimeout, as a cold read is bounded).
    let timeout: TimeInterval

    init(name: String, spawn: @escaping XrayRequests.Spawn, timeout: TimeInterval = DchCommand.remoteTimeout) {
        (self.name, self.spawn, self.timeout) = (name, spawn, timeout)
    }

    /// One request (`argv`: the flags after `--xray <name>`). nil: run it cold (the dial failed, or dch said busy).
    func request(_ path: String, _ argv: [String], _ env: [String: String]) async -> (status: Int32, out: Data)? {
        await acquire()
        defer { release() }
        guard !Task.isCancelled else { return (-1, Data()) }
        guard let child = await dial(path, env) else { return Task.isCancelled ? (-1, Data()) : nil }
        n = n == Int32.max ? 1 : n + 1   // dch takes 1...2147483647
        let id = n
        guard let req = Self.line(["req": Int(id), "argv": argv]) else { return nil }
        child.write(req)
        let ns = UInt64(max(0, timeout) * 1e9)
        let watchdog = Task { try? await Task.sleep(nanoseconds: ns); if !Task.isCancelled { child.write(Self.cancel(id)) } }
        defer { watchdog.cancel() }
        return await withTaskCancellationHandler { await answer(child, id) } onCancel: { child.write(Self.cancel(id)) }
    }

    /// Stdin EOF: dch exits 0; the next request dials again.
    func close() {
        child?.closeInput()
        child = nil
    }

    private func dial(_ path: String, _ env: [String: String]) async -> (any XrayRequestChild)? {
        if let child { return child }
        guard let c = spawn(path, ["--xray", name, "--requests", "--json"], env) else {
            startFailures.append(-1)
            return nil
        }
        let ns = UInt64(max(0, timeout) * 1e9)   // a dial that hangs is ended, as a cold read's timeout
        let watchdog = Task { try? await Task.sleep(nanoseconds: ns); if !Task.isCancelled { c.terminate() } }
        let first = await withTaskCancellationHandler { await c.nextLine() } onCancel: { c.terminate() }
        watchdog.cancel()
        let o = first.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
        guard o?["ready"] is [String: Any] else {   // {"schema":1,"exit":E,...}: 6 no xray, 7 unreachable, 4 refused
            startFailures.append((o?["exit"] as? Int).map { Int32(clamping: $0) } ?? -1)
            c.closeInput()
            c.terminate()
            return nil
        }
        child = c
        return c
    }

    /// Request `id`'s lines up to its end line; other requests' lines (a late one, `"req":null`) are skipped.
    private func answer(_ child: any XrayRequestChild, _ id: Int32) async -> (status: Int32, out: Data)? {
        var out = Data(), over = false
        while let raw = await child.nextLine() {
            guard let o = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any],
                  (o["req"] as? Int) == Int(id) else { continue }
            if let l = o["line"] {
                guard !over else { continue }
                let bytes = (l as? String).map { Data($0.utf8) }
                    ?? (JSONSerialization.isValidJSONObject(l) ? try? JSONSerialization.data(withJSONObject: l) : nil) ?? Data()
                // the read's byte cap, checked before the append (XrayPanels.maxReadBytes, as runBounded's outputLimit)
                if bytes.count >= XrayPanels.maxReadBytes - out.count {
                    over = true
                    child.write(Self.cancel(id))
                    continue
                }
                out.append(bytes)
                out.append(0x0A)
            } else if o.keys.contains("exit") {
                return Self.status(exit: o["exit"] as? Int ?? -1, why: o["why"] as? String, over: over, out: out)
            }
        }
        if self.child === child { self.child = nil }   // dch went away (or a line past maxLine): the next request dials again
        child.closeInput()
        child.terminate()
        return (-1, Data())
    }

    /// The end line to today's statuses: `cap` (or Prosper's own cap) -> XrayPanels.overCap; `cancel` and `timeout`
    /// -> -1 (a cancelled or timed-out read); `lost` -> 7 (host unreachable); `busy` -> nil (run cold); else the
    /// host's exit (null 0..., `refused` 1, 2, 4, 6).
    static func status(exit e: Int, why: String?, over: Bool, out: Data) -> (status: Int32, out: Data)? {
        if over || why == "cap" { return (XrayPanels.overCap, Data()) }
        switch why {
        case "busy": return nil
        case "cancel", "timeout": return (-1, Data())
        case "lost": return (7, Data())
        default: return (Int32(clamping: e), out)
        }
    }

    static func cancel(_ id: Int32) -> Data { Data("{\"cancel\":\(id)}\n".utf8) }

    static func line(_ o: [String: Any]) -> Data? {
        guard JSONSerialization.isValidJSONObject(o), var d = try? JSONSerialization.data(withJSONObject: o) else { return nil }
        d.append(0x0A)
        return d
    }

    private func acquire() async {
        if busy { await withCheckedContinuation { waiting.append($0) } } else { busy = true }
    }

    private func release() {
        if waiting.isEmpty { busy = false } else { waiting.removeFirst().resume() }   // busy passes to the next
    }
}

/// The product's child: dch with stdin and stdout pipes, stderr dropped (each request's stderr comes in its lines).
final class XrayRequestProcess: XrayRequestChild, @unchecked Sendable {
    private let p = Process(), input = Pipe(), output = Pipe(), lock = NSLock()
    private var closed = false
    private var buf = Data(), scanned = 0
    /// One wrapped line at most: dch's 8 MiB line cap, or a 2.67 MiB string line escaped (6 bytes a byte at worst).
    static let maxLine = 20 << 20

    static func start(_ path: String, _ args: [String], _ env: [String: String]) -> XrayRequestProcess? {
        let c = XrayRequestProcess()
        c.p.executableURL = URL(fileURLWithPath: path)
        c.p.arguments = args
        c.p.environment = env
        c.p.standardInput = c.input
        c.p.standardOutput = c.output
        c.p.standardError = FileHandle.nullDevice
        do { try c.p.run() } catch { return nil }
        return c
    }

    func write(_ line: Data) {
        lock.withLock {
            guard !closed else { return }
            try? input.fileHandleForWriting.write(contentsOf: line)   // SIGPIPE is ignored app-wide (AppDelegate)
        }
    }

    func closeInput() {
        lock.withLock {
            guard !closed else { return }
            closed = true
            try? input.fileHandleForWriting.close()
        }
    }

    func terminate() { if p.isRunning { p.terminate() } }

    func nextLine() async -> Data? {
        await withCheckedContinuation { c in
            DispatchQueue.global(qos: .utility).async { c.resume(returning: self.readLine()) }
        }
    }

    /// Called by one reader at a time (XrayRequestLine holds its lock around every request).
    private func readLine() -> Data? {
        while true {
            if let i = buf[(buf.startIndex + scanned)...].firstIndex(of: 0x0A) {
                let l = Data(buf[..<i])
                buf = Data(buf[(i + 1)...])
                scanned = 0
                return l
            }
            scanned = buf.count
            guard buf.count <= Self.maxLine,
                  let d = try? output.fileHandleForReading.read(upToCount: 1 << 16), !d.isEmpty else { return nil }
            buf.append(d)
        }
    }
}
