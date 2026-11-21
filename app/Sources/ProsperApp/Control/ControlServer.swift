import Foundation

/// #1807: the agent control channel. The running app listens on one Unix socket (0600, owner uid only);
/// `ProsperApp ctl <cmd>` (ControlCLI) sends one newline-terminated JSON request per connection and reads one
/// JSON reply. Idle cost is one parked accept source: nothing polls, nothing runs until a client connects.
/// Sockets, reads and JSON run off main; only command handlers hop to main (ControlRegistry.reply).
final class ControlServer: @unchecked Sendable {
    static let maxRequest = 64 * 1024
    static let readTimeout: TimeInterval = 2

    /// Application Support/Prosper/control.sock.
    static var defaultPath: String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("Prosper/control.sock").path
    }

    /// Tests point the CLI's default at a temp socket (rows pass paths explicitly; this is the AgentCLI-style override).
    nonisolated(unsafe) static var socketPathOverride: String?
    static var socketPath: String { socketPathOverride ?? defaultPath }

    /// The app's server, set once by startShared().
    nonisolated(unsafe) private(set) static var shared: ControlServer?

    let path: String
    let registry: ControlRegistry
    /// getpeereid's uid for a connected fd (nil when it fails): a test seam, set before start().
    var peerUID: @Sendable (Int32) -> uid_t? = ControlServer.systemPeerUID
    private let queue = DispatchQueue(label: "prosper.control.accept", qos: .utility)
    private let lock = NSLock()
    private var source: DispatchSourceRead?
    private var _reads = 0, _served = 0
    /// Work counters for the perf row: read() calls on client sockets, and connections handled.
    var reads: Int { lock.withLock { _reads } }
    var served: Int { lock.withLock { _served } }

    init(path: String, registry: ControlRegistry = .standard()) {
        self.path = path
        self.registry = registry
    }

    /// Off main, once, from AppDelegate's launch path. Never under XCTest: rows never touch the real Application Support.
    static func startShared() {
        guard NSClassFromString("XCTestCase") == nil else { return }
        DispatchQueue.global(qos: .utility).async {
            let s = ControlServer(path: socketPath)
            if s.start() { shared = s } else { NSLog("prosper: control socket not started at \(s.path)") }
        }
    }

    static func systemPeerUID(_ fd: Int32) -> uid_t? {
        var uid = uid_t.max, gid = gid_t.max
        return getpeereid(fd, &uid, &gid) == 0 ? uid : nil
    }

    /// Bind and listen. False when the path is too long, a live listener already answers there (another Prosper),
    /// or the socket cannot be made. A stale socket file (nothing answers) is replaced.
    /// #1819: the listener is bound, chmodded and listening under a temp name in the same dir first, then renamed over
    /// `path` in one step, so `path` is never a socket with the default mode and never missing between two starters.
    func start() -> Bool {
        guard lock.withLock({ source == nil }), Self.fitsUnixAddr(path) else { return false }
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if let live = Self.connect(path) {
            Darwin.close(live)
            return false
        }
        let tmp = "\(dir)/.ctl-\(getpid())-\(UInt16.random(in: 0...UInt16.max))"
        guard Self.fitsUnixAddr(tmp) else { return false }
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { return false }
        let fl = fcntl(s, F_GETFL)
        guard Self.configure(s), fl >= 0, fcntl(s, F_SETFL, fl | O_NONBLOCK) == 0,
              Self.withUnixAddr(tmp, { Darwin.bind(s, $0, $1) }) == 0 else {
            Darwin.close(s)
            return false
        }
        // The peer uid check below is the real gate; the mode keeps other users from even connecting.
        guard chmod(tmp, 0o600) == 0, listen(s, 16) == 0, rename(tmp, path) == 0 else {
            Darwin.close(s)
            unlink(tmp)
            return false
        }
        let src = DispatchSource.makeReadSource(fileDescriptor: s, queue: queue)
        src.setEventHandler { [weak self] in self?.acceptAll(s) }
        let path = path
        src.setCancelHandler { Darwin.close(s); unlink(path) }
        lock.withLock { source = src }
        src.resume()
        return true
    }

    /// Close the listener and remove the socket file.
    func stop() {
        let s = lock.withLock { () -> DispatchSourceRead? in defer { source = nil }; return source }
        s?.cancel()
    }

    private func acceptAll(_ listener: Int32) {
        while true {
            let c = Darwin.accept(listener, nil, nil)
            if c >= 0 {
                DispatchQueue.global(qos: .utility).async { self.serve(c) }
                continue
            }
            let e = errno
            if e == EINTR || e == ECONNABORTED { continue }
            if e != EAGAIN, let src = lock.withLock({ source }) {
                // EMFILE, ENOBUFS ...: the backlog stays readable; pause instead of spinning.
                src.suspend()
                queue.asyncAfter(deadline: .now() + .milliseconds(100)) { src.resume() }
            }
            return
        }
    }

    /// One request per connection: peer check, bounded read, reply, close. Owns `c`.
    private func serve(_ c: Int32) {
        lock.withLock { _served += 1 }
        let fl = fcntl(c, F_GETFL)
        guard Self.configure(c), fl >= 0, fcntl(c, F_SETFL, fl & ~O_NONBLOCK) == 0 else { Darwin.close(c); return }
        Self.setTimeout(c, SO_SNDTIMEO, Self.readTimeout)
        guard peerUID(c) == getuid() else {
            Self.writeAll(c, ControlReply.failure("refused: peer is not this user").line)
            Darwin.close(c)
            return
        }
        switch readRequest(c) {
        case .failure(let e):
            Self.writeAll(c, ControlReply.failure(e.message).line)
            Darwin.close(c)
        case .success(let line) where ControlDepth.exceeds(line):
            Self.writeAll(c, ControlReply.failure(ControlDepth.message).line)
            Darwin.close(c)
        case .success(let line):
            let registry = registry
            Task.detached(priority: .utility) {
                let reply = await registry.reply(to: line)
                Self.writeAll(c, reply.line)
                Darwin.close(c)
            }
        }
    }

    /// Up to the first newline (or EOF), at most `maxRequest` bytes, within `readTimeout` overall.
    private func readRequest(_ c: Int32) -> Result<Data, ControlError> {
        let deadline = Date().addingTimeInterval(Self.readTimeout)
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let left = deadline.timeIntervalSinceNow
            guard left > 0 else { return .failure(ControlError("request timed out")) }
            Self.setTimeout(c, SO_RCVTIMEO, left)
            lock.withLock { _reads += 1 }
            let n = buf.withUnsafeMutableBytes { Darwin.read(c, $0.baseAddress, $0.count) }
            if n < 0 {
                if errno == EINTR { continue }
                return .failure(ControlError(errno == EAGAIN ? "request timed out" : "read failed"))
            }
            if n == 0 { break }
            data.append(contentsOf: buf[0..<n])
            if let nl = data.firstIndex(of: UInt8(ascii: "\n")) {
                data = data[data.startIndex..<nl]
                break
            }
            if data.count > Self.maxRequest { break }
        }
        guard data.count <= Self.maxRequest else { return .failure(ControlError("request too large (max \(Self.maxRequest) bytes)")) }
        return .success(Data(data))
    }

    // MARK: - Socket helpers (shared with ControlCLI)

    /// SO_NOSIGPIPE and close-on-exec.
    static func configure(_ fd: Int32) -> Bool {
        var one: Int32 = 1
        let fdf = fcntl(fd, F_GETFD)
        return setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size)) == 0
            && fdf >= 0 && fcntl(fd, F_SETFD, fdf | FD_CLOEXEC) == 0
    }

    static func setTimeout(_ fd: Int32, _ opt: Int32, _ seconds: TimeInterval) {
        let s = max(seconds, 0.001)
        var tv = timeval(tv_sec: Int(s), tv_usec: Int32((s - s.rounded(.down)) * 1_000_000))
        _ = setsockopt(fd, SOL_SOCKET, opt, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    /// Blocking write of every byte; false on error (a peer that went away).
    @discardableResult
    static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            var off = 0
            while off < raw.count {
                let n = Darwin.write(fd, raw.baseAddress! + off, raw.count - off)
                if n < 0 { if errno == EINTR { continue }; return false }
                off += n
            }
            return true
        }
    }

    /// A blocking client socket connected to `path`, or nil (no file, nothing listening, path too long).
    static func connect(_ path: String) -> Int32? {
        guard fitsUnixAddr(path) else { return nil }
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { return nil }
        guard configure(s), withUnixAddr(path, { Darwin.connect(s, $0, $1) }) == 0 else {
            Darwin.close(s)
            return nil
        }
        return s
    }

    /// Whether `path` fits sun_path with its NUL.
    static func fitsUnixAddr(_ path: String) -> Bool { path.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) }

    /// Callers check `fitsUnixAddr` first.
    static func withUnixAddr<T>(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
        var a = sockaddr_un()
        a.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8.prefix(MemoryLayout.size(ofValue: a.sun_path) - 1))
        withUnsafeMutableBytes(of: &a.sun_path) { $0.copyBytes(from: bytes) }
        a.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
    }
}
