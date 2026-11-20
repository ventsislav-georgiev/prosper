import Foundation
import Network

/// #1675: the proxy's listening socket, a BSD socket on 127.0.0.1. NWListener with endpoint reuse behaves like
/// SO_REUSEPORT and still refuses a port in TIME_WAIT (a restart or a takeover waited up to 30 s); SO_REUSEADDR
/// binds past TIME_WAIT. Beside a live listener on exactly 127.0.0.1:P it gets EADDRINUSE, but it DOES bind beside a
/// live 0.0.0.0:P one; there the real port probe (a connect to 127.0.0.1) finds the wildcard listener first, so only
/// the probe-to-bind race is exposed. SO_REUSEPORT is never set.
/// The surface the service and its rows use (port, state, stateUpdateHandler, cancel) keeps NWListener's shapes.
final class CCPoolListener: @unchecked Sendable {
    enum Failure: Error, Equatable {
        /// socket() or an option failed.
        case create(POSIXErrorCode)
        /// bind() or listen() failed (EADDRINUSE: something listens on the port).
        case bind(POSIXErrorCode)
    }

    static let backlog: Int32 = 128
    let fd: Int32
    let port: NWEndpoint.Port?
    private let lock = NSLock()
    private var _state: NWListener.State = .ready
    private var _handler: (@Sendable (NWListener.State) -> Void)?
    private var source: DispatchSourceRead?
    private var cancelled = false
    /// The accept source is suspended for `fdPause` after such an error (one resume is scheduled).
    private var paused = false
    /// Confined to the start queue: an accept-error episode was already reported (reset by the next accept).
    private var exhausted = false
    static let fdPause: DispatchTimeInterval = .milliseconds(100)
    /// accept(2) as (fd, errno): a test seam, set before start().
    var acceptCall: @Sendable (Int32) -> (fd: Int32, err: Int32) = CCPoolListener.systemAccept

    static func systemAccept(_ fd: Int32) -> (fd: Int32, err: Int32) {
        let c = Darwin.accept(fd, nil, nil)
        return (c, c < 0 ? errno : 0)
    }

    var state: NWListener.State { lock.withLock { _state } }
    /// Called with .cancelled once the socket is closed (on the start queue; on cancel()'s thread when never started).
    var stateUpdateHandler: (@Sendable (NWListener.State) -> Void)? {
        get { lock.withLock { _handler } }
        set { lock.withLock { _handler = newValue } }
    }

    /// socket, SO_REUSEADDR, SO_NOSIGPIPE, non-blocking, close-on-exec, bind 127.0.0.1:`port` (0: any), listen.
    static func open(port: UInt16) -> Result<CCPoolListener, Failure> {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return .failure(.create(code(errno))) }
        var one: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size)) == 0,
              configure(fd) else {
            let e = errno
            Darwin.close(fd)
            return .failure(.create(code(e)))
        }
        var a = sockaddr_in()
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        a.sin_family = sa_family_t(AF_INET)
        a.sin_port = port.bigEndian
        a.sin_addr.s_addr = UInt32(0x7f00_0001).bigEndian
        let bound = withUnsafePointer(to: &a) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, Darwin.listen(fd, backlog) == 0 else {
            let e = errno
            Darwin.close(fd)
            return .failure(.bind(code(e)))
        }
        guard let l = CCPoolListener(adopting: fd) else {
            Darwin.close(fd)
            return .failure(.create(.EBADF))
        }
        return .success(l)
    }

    /// #1676: adopt a listening socket made elsewhere (the port keeper's). nil, the fd left to its owner, unless it is
    /// an IPv4 socket bound to 127.0.0.1 and listening; once started or cancelled the listener owns and closes it.
    init?(adopting fd: Int32) {
        var a = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &a) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        var listening: Int32 = 0
        var olen = socklen_t(MemoryLayout<Int32>.size)
        guard fd >= 0, named == 0, a.sin_family == sa_family_t(AF_INET), a.sin_addr.s_addr == UInt32(0x7f00_0001).bigEndian,
              getsockopt(fd, SOL_SOCKET, SO_ACCEPTCONN, &listening, &olen) == 0, listening != 0,
              Self.configure(fd) else { return nil }
        self.fd = fd
        port = NWEndpoint.Port(rawValue: UInt16(bigEndian: a.sin_port))
    }

    /// SO_NOSIGPIPE, O_NONBLOCK and FD_CLOEXEC (set on every accepted fd too: accept() does not carry them all).
    static func configure(_ fd: Int32) -> Bool {
        var one: Int32 = 1
        let fl = fcntl(fd, F_GETFL)
        let fdf = fcntl(fd, F_GETFD)
        return setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size)) == 0
            && fl >= 0 && fcntl(fd, F_SETFL, fl | O_NONBLOCK) == 0
            && fdf >= 0 && fcntl(fd, F_SETFD, fdf | FD_CLOEXEC) == 0
    }

    static func code(_ e: Int32) -> POSIXErrorCode { POSIXErrorCode(rawValue: e) ?? .EIO }

    /// Accept on `queue` until EAGAIN, each connected fd handed to `accept` (which owns it). No-op once cancelled.
    /// After any error but EAGAIN/EINTR/ECONNABORTED (EMFILE, ENOBUFS ...) the source is suspended for `fdPause`, never spun; `exhausted` runs once per episode.
    func start(queue: DispatchQueue, accept: @escaping @Sendable (Int32) -> Void, exhausted onExhausted: (@Sendable () -> Void)? = nil) {
        lock.withLock {
            guard !cancelled, source == nil else { return }
            let fd = fd
            let call = acceptCall
            let s = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            s.setEventHandler { [weak self] in
                while true {
                    let (c, e) = call(fd)
                    if c >= 0 { self?.exhausted = false; accept(c); continue }
                    if e == EINTR || e == ECONNABORTED { continue }
                    if e != EAGAIN, let self {   // EMFILE, ENFILE, ENOBUFS, ENOMEM ...: the backlog stays non-empty
                        self.pause(queue)
                        if !self.exhausted { self.exhausted = true; onExhausted?() }
                    }
                    return
                }
            }
            // The fd is closed here even when the listener itself is gone by then.
            s.setCancelHandler { [weak self] in Darwin.close(fd); self?.reportCancelled() }
            source = s
            s.resume()
        }
    }

    /// Close the socket once; the handler then sees .cancelled.
    func cancel() {
        let (first, started) = lock.withLock { () -> (Bool, DispatchSourceRead?) in
            defer { cancelled = true }
            guard !cancelled else { return (false, nil) }
            // A paused source is cancelled, then resumed here (its cancel handler runs only when resumed); the
            // scheduled resume then finds `paused` false and does nothing.
            if paused, let source { paused = false; source.cancel(); source.resume(); return (true, nil) }
            return (true, source)
        }
        guard first else { return }
        if let started { return started.cancel() }   // its cancel handler closes the fd
        if lock.withLock({ source != nil }) { return }   // cancelled while paused: the cancel handler closes the fd
        Darwin.close(fd)
        reportCancelled()
    }

    /// Suspend the accept source and resume it once after `fdPause`, unless a cancel came in between.
    private func pause(_ queue: DispatchQueue) {
        lock.withLock {
            guard !cancelled, !paused, let source else { return }
            paused = true
            source.suspend()
        }
        queue.asyncAfter(deadline: .now() + Self.fdPause) { [weak self] in
            guard let self else { return }
            self.lock.withLock {
                guard self.paused, !self.cancelled, let source = self.source else { return }
                self.paused = false
                source.resume()
            }
        }
    }

    private func reportCancelled() {
        let h = lock.withLock { () -> (@Sendable (NWListener.State) -> Void)? in
            _state = .cancelled
            return _handler
        }
        h?(.cancelled)
    }

    deinit {
        // A started listener released without cancel() still closes its fd (its source's cancel handler). One never
        // started nor cancelled leaves the fd to whoever handed it over (start(listening:) refused it).
        guard !cancelled, let source else { return }
        source.cancel()
        if paused { source.resume() }
    }
}

/// #1675: what CCPoolConnection needs of its client socket (NWConnection's surface before #1675). Every call but
/// cancel() is made on the queue given to start(), and every callback runs there, never inside the call that asked.
protocol CCPoolTransport: AnyObject, Sendable {
    /// `onFailed` runs once when the socket errs (not after cancel()).
    func start(queue: DispatchQueue, onFailed: @escaping @Sendable () -> Void)
    /// 1 to 64 KiB, or done at EOF, or an error.
    func receive(_ handler: @escaping @Sendable (_ data: Data?, _ done: Bool, _ error: Error?) -> Void)
    /// `completion` once every byte is written (or with the error).
    func send(_ data: Data, completion: (@Sendable (_ error: Error?) -> Void)?)
    /// FIN after every queued send, then `completion`.
    func finish(_ completion: @escaping @Sendable () -> Void)
    /// Close once; pending callbacks are dropped. Any thread.
    func cancel()
}

/// #1675: CCPoolTransport over a connected non-blocking fd (accepted by CCPoolListener), with read and write sources.
final class CCPoolFDTransport: CCPoolTransport, @unchecked Sendable {
    static let maxRead = 1 << 16
    private struct Chunk {
        let data: Data
        var sent: Int
        let done: (@Sendable (Error?) -> Void)?
    }

    private let fd: Int32
    private let lock = NSLock()
    private var cancelled = false
    private var queue: DispatchQueue?   // set once under `lock`
    // Confined to `queue`:
    private var reader: DispatchSourceRead?
    private var writer: DispatchSourceWrite?
    private var readArmed = false, writeArmed = false
    private var onRead: (@Sendable (Data?, Bool, Error?) -> Void)?
    private var onFailed: (@Sendable () -> Void)?
    private var pending: [Chunk] = []
    private var head = 0
    private var finishing: (@Sendable () -> Void)?
    /// One read buffer for every read() of this transport (queue-confined); chunks are copies of exactly n bytes.
    private let readBuf = UnsafeMutableRawPointer.allocate(byteCount: CCPoolFDTransport.maxRead, alignment: 16)
    private var closedFD = false
    private var live = 0
    /// Counts for the per-chunk work row: read() and write() calls made.
    private(set) var reads = 0, writes = 0

    /// Takes ownership of `fd`.
    init(fd: Int32) {
        self.fd = fd
        _ = CCPoolListener.configure(fd)
    }

    deinit { readBuf.deallocate() }

    private var isCancelled: Bool { lock.withLock { cancelled } }

    func start(queue: DispatchQueue, onFailed: @escaping @Sendable () -> Void) {
        guard lock.withLock({ () -> Bool in
            guard !cancelled, self.queue == nil else { return false }
            self.queue = queue
            return true
        }) else { return }
        self.onFailed = onFailed
        let r = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        let w = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
        // The sources hold the transport until both are cancelled; closeOnce() cancels them.
        r.setEventHandler { self.readable() }
        w.setEventHandler { self.flush() }
        for s in [r, w] as [DispatchSourceProtocol] {
            s.setCancelHandler {
                self.live -= 1
                if self.live == 0, !self.closedFD { self.closedFD = true; Darwin.close(self.fd) }
            }
        }
        live = 2
        reader = r
        writer = w
        // Created suspended; armed (resumed) only while a receive or a send waits.
    }

    func receive(_ handler: @escaping @Sendable (Data?, Bool, Error?) -> Void) {
        guard !isCancelled, let reader else { return }
        onRead = handler
        if !readArmed { readArmed = true; reader.resume() }
    }

    private func readable() {
        guard !isCancelled, let h = onRead else { return disarmRead() }
        reads += 1
        let n = Darwin.read(fd, readBuf, Self.maxRead)
        if n < 0, errno == EAGAIN || errno == EINTR { return }
        let e = errno
        onRead = nil
        disarmRead()
        if n > 0 { h(Data(bytes: readBuf, count: n), false, nil) } else if n == 0 { h(nil, true, nil) } else { h(nil, false, POSIXError(CCPoolListener.code(e))) }
    }

    private func disarmRead() {
        if readArmed { readArmed = false; reader?.suspend() }
    }

    func send(_ data: Data, completion: (@Sendable (Error?) -> Void)?) {
        guard !isCancelled, queue != nil else { return }
        pending.append(Chunk(data: data, sent: 0, done: completion))
        armWrite()
    }

    func finish(_ completion: @escaping @Sendable () -> Void) {
        guard !isCancelled, queue != nil else { return }
        finishing = completion
        armWrite()
    }

    private func armWrite() {
        if !writeArmed, let writer { writeArmed = true; writer.resume() }
    }

    /// Writes what the socket takes (partial writes stay at their offset); completions in order.
    private func flush() {
        while head < pending.count {
            guard !isCancelled else { return disarmWrite() }
            let c = pending[head]
            if c.sent < c.data.count {
                writes += 1
                let n = c.data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress! + c.sent, c.data.count - c.sent) }
                if n < 0 {
                    if errno == EAGAIN || errno == EINTR { return }
                    return fail(POSIXError(CCPoolListener.code(errno)))
                }
                pending[head].sent += n
                if pending[head].sent < c.data.count { continue }
            }
            head += 1
            c.done?(nil)
        }
        pending.removeAll(keepingCapacity: true)
        head = 0
        disarmWrite()
        guard !isCancelled, let f = finishing else { return }
        finishing = nil
        Darwin.shutdown(fd, SHUT_WR)
        f()
    }

    private func disarmWrite() {
        if writeArmed { writeArmed = false; writer?.suspend() }
    }

    /// EPIPE, ECONNRESET ...: every waiting send gets the error, then onFailed.
    private func fail(_ e: Error) {
        let waiting = pending[head...].compactMap(\.done)
        pending.removeAll()
        head = 0
        finishing = nil
        disarmWrite()
        waiting.forEach { $0(e) }
        let f = onFailed
        onFailed = nil
        if !isCancelled { f?() }
    }

    func cancel() {
        let (first, q) = lock.withLock { () -> (Bool, DispatchQueue?) in
            defer { cancelled = true }
            return (!cancelled, queue)
        }
        guard first else { return }
        guard let q else {
            // Never started (no sources): nothing else touches the fd.
            closedFD = true
            Darwin.close(fd)
            return
        }
        q.async { self.closeOnce() }
    }

    private func closeOnce() {
        onRead = nil
        onFailed = nil
        finishing = nil
        pending.removeAll()
        head = 0
        // A suspended source must be resumed to deliver its cancel handler (and before it is released).
        if let reader { reader.cancel(); if !readArmed { reader.resume() } }
        if let writer { writer.cancel(); if !writeArmed { writer.resume() } }
        readArmed = true
        writeArmed = true
    }
}
