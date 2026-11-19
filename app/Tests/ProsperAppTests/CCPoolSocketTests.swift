import Foundation
import XCTest
@testable import ProsperApp

/// #1675: the proxy's BSD listener (SO_REUSEADDR, never SO_REUSEPORT) and the fd transport of its connections.
/// Ports are 0 (the kernel's pick) or the one a row just bound itself; never the production port.
final class CCPoolSocketTests: XCTestCase {
    private let dead = URL(string: "http://127.0.0.1:9")!

    private func service(port: UInt16, log: CCPoolCapturingLogger = CCPoolCapturingLogger(),
                         probe: (@Sendable (UInt16, TimeInterval) -> CCPoolPortProbe.Result)? = nil) -> CCPoolService {
        var cfg = CCPoolServiceConfig()
        cfg.port = port
        cfg.upstream = dead
        if let probe { cfg.portProbe = probe }
        return CCPoolService(config: cfg, store: CCPoolStore(directory: tempDir().appendingPathComponent("ccpool")),
                             secrets: CCPoolMemorySecrets(), logger: log)
    }

    private static func loopback(_ port: UInt16) -> sockaddr_in {
        var a = sockaddr_in()
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        a.sin_family = sa_family_t(AF_INET)
        a.sin_port = port.bigEndian
        a.sin_addr.s_addr = UInt32(0x7f00_0001).bigEndian
        return a
    }

    private static func withAddr<T>(_ port: UInt16, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
        var a = loopback(port)
        return withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
    }

    /// A blocking client: sends `request`, reads to EOF (5 s read timeout), closes. nil on any error.
    private static func exchange(port: UInt16, _ request: String) -> Data? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        guard withAddr(port, { connect(fd, $0, $1) }) == 0 else { return nil }
        let req = Array(request.utf8)
        guard req.withUnsafeBytes({ write(fd, $0.baseAddress, $0.count) }) == req.count else { return nil }
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &buf, buf.count)
            if n == 0 { return out }
            if n < 0 { return nil }
            out.append(contentsOf: buf.prefix(n))
        }
    }

    private static func health(_ port: UInt16) -> String {
        "GET \(CCPoolService.healthPath) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nConnection: close\r\n\r\n"
    }

    /// A raw listener on 127.0.0.1:`port` with the given options, or the bind's errno as a negative number.
    private static func rawListener(port: UInt16, options: [Int32]) -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return -errno }
        var one: Int32 = 1
        for o in options { setsockopt(fd, SOL_SOCKET, o, &one, socklen_t(MemoryLayout<Int32>.size)) }
        guard withAddr(port, { Darwin.bind(fd, $0, $1) }) == 0, Darwin.listen(fd, 8) == 0 else {
            let e = errno
            close(fd)
            return -e
        }
        return fd
    }

    private static func boundPort(_ fd: Int32) -> UInt16 {
        var a = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        return UInt16(bigEndian: a.sin_port)
    }

    // The operator's ask (#1675): a proxy that served a connection and closed it first (its side in TIME_WAIT) is
    // stopped, and a new service binds the same port within 1 s. The gap is printed. Before #1675 (NWListener, no
    // reuse) this start got EADDRINUSE for up to 30 s.
    func testRebindPastTimeWaitIsWithinOneSecond() throws {
        let first = service(port: 0)
        guard case .running(let port) = first.start(), port != 0 else { return XCTFail("\(first.status)") }
        let reply = try XCTUnwrap(Self.exchange(port: port, Self.health(port)), "the health answer")
        XCTAssertTrue(String(decoding: reply, as: UTF8.self).hasPrefix("HTTP/1.1 200 OK"))
        let stopped = Date()
        first.stop()
        // The premise: the port is in TIME_WAIT (or FIN_WAIT_2), so a bind without SO_REUSEADDR is refused.
        let plain = Self.rawListener(port: port, options: [])
        if plain >= 0 { close(plain) }
        XCTAssertEqual(plain, -EADDRINUSE, "the served connection left the port in TIME_WAIT")
        let log = CCPoolCapturingLogger()
        let second = service(port: port, log: log)
        defer { second.stop() }
        let status = second.start(bindRetry: 0)
        let gap = Date().timeIntervalSince(stopped)
        print("ccpool rebind past TIME_WAIT: \(String(format: "%.3f", gap)) s (port \(port))")
        XCTAssertEqual(status, .running(port: port), "\(log.lines)")
        XCTAssertLessThan(gap, 1, "rebound within 1 s")
        XCTAssertEqual(log.lines.filter { $0.contains("bind failed") }.count, 0, "\(log.lines)")
        XCTAssertNotNil(Self.exchange(port: port, Self.health(port)), "the new listener serves")
    }

    // A live foreign listener (even one sharing with SO_REUSEADDR and SO_REUSEPORT) is never bound beside: the
    // probe is staged "free" so only the bind decides; start reports heldByOther with EADDRINUSE and no retry wins.
    func testLiveForeignListenerIsNeverBoundBeside() throws {
        let foreign = Self.rawListener(port: 0, options: [SO_REUSEADDR, SO_REUSEPORT])
        XCTAssertGreaterThanOrEqual(foreign, 0)
        guard foreign >= 0 else { return }
        defer { close(foreign) }
        let port = Self.boundPort(foreign)
        let log = CCPoolCapturingLogger()
        let s = service(port: port, log: log, probe: { _, _ in .free })
        defer { s.stop() }
        XCTAssertEqual(s.start(bindRetry: 0.5), .heldByOther)
        XCTAssertTrue(s.currentListener == nil)
        XCTAssertEqual(log.lines.filter { $0.contains("bind failed: EADDRINUSE") }.count, 1, "\(log.lines)")
    }

    // #1676's seam: a listening fd made elsewhere is served as given (no probe, no bind); a socket that is not
    // listening is refused and left open for its owner.
    func testServiceServesAGivenListeningFD() throws {
        let fd = Self.rawListener(port: 0, options: [SO_REUSEADDR])
        XCTAssertGreaterThanOrEqual(fd, 0)
        guard fd >= 0 else { return }
        let port = Self.boundPort(fd)
        let probes = CCPoolCounterBox()
        let s = service(port: 0, probe: { _, _ in probes.bump(); return .other })
        defer { s.stop() }
        XCTAssertEqual(s.start(listening: fd), .running(port: port))
        XCTAssertEqual(probes.count, 0, "no probe")
        let reply = try XCTUnwrap(Self.exchange(port: port, Self.health(port)))
        XCTAssertTrue(String(decoding: reply, as: UTF8.self).hasPrefix("HTTP/1.1 200 OK"))

        // Bound to 127.0.0.1 but not listening.
        let idle = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(idle) }
        XCTAssertEqual(Self.withAddr(0, { Darwin.bind(idle, $0, $1) }), 0)
        let other = service(port: 0)
        XCTAssertEqual(other.start(listening: idle), .failed(CCPoolService.reasonCreate))
        XCTAssertGreaterThanOrEqual(fcntl(idle, F_GETFD), 0, "the refused fd is still its owner's")
    }

    // The transport over a socketpair: an idle receive makes no read() call (no busy poll); one chunk is one read;
    // EOF is done; a send to a closed peer fails with an error and onFailed; a second cancel is a no-op.
    func testFDTransportReadsOnlyWhenReadableAndReportsEOFAndEPIPE() throws {
        var pair: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
        let peer = pair[1]
        var tv = timeval(tv_sec: 5, tv_usec: 0)   // a lost byte ends the drain below, never hangs it
        setsockopt(peer, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        let t = CCPoolFDTransport(fd: pair[0])
        let q = DispatchQueue(label: "test.ccpool.transport")
        let failed = expectation(description: "onFailed")
        q.sync { t.start(queue: q) { failed.fulfill() } }

        let got = expectation(description: "one chunk")
        q.sync { t.receive { data, done, error in
            XCTAssertEqual(data, Data("hello".utf8))
            XCTAssertFalse(done)
            XCTAssertTrue(error == nil)
            got.fulfill()
        } }
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(q.sync { t.reads }, 0, "an idle receive calls no read()")
        XCTAssertEqual(write(peer, "hello", 5), 5)
        wait(for: [got], timeout: 5)
        XCTAssertEqual(q.sync { t.reads }, 1, "one chunk, one read()")

        let sent = expectation(description: "send completes")
        let big = Data(repeating: 0x61, count: 300_000)
        q.sync { t.send(big) { error in XCTAssertTrue(error == nil); sent.fulfill() } }
        var drained = 0
        var buf = [UInt8](repeating: 0, count: 65_536)
        while drained < big.count {
            let n = read(peer, &buf, buf.count)
            guard n > 0 else { break }
            drained += n
        }
        wait(for: [sent], timeout: 5)
        XCTAssertEqual(drained, big.count, "partial writes resume at their offset")

        let eof = expectation(description: "done at EOF")
        q.sync { t.receive { data, done, error in
            XCTAssertTrue(data == nil && error == nil)
            XCTAssertTrue(done)
            eof.fulfill()
        } }
        close(peer)
        wait(for: [eof], timeout: 5)

        let refused = expectation(description: "EPIPE")
        q.sync { t.send(Data("x".utf8)) { error in XCTAssertTrue(error != nil); refused.fulfill() } }
        wait(for: [refused, failed], timeout: 5)
        t.cancel()
        t.cancel()   // once: the second is a no-op
        q.sync {}
    }

    // Out of fds: accept(2) answers EMFILE twice, then a connection. The source is suspended between attempts
    // (>= ~100 ms apart, not a spin), the episode is reported once, and the connection is then accepted. Calls:
    // EMFILE, EMFILE, the connection, and the EAGAIN that ends that drain: 4, not hundreds.
    func testAcceptOutOfFDsPausesInsteadOfSpinning() throws {
        let l = try CCPoolListener.open(port: 0).get()
        defer { l.cancel() }
        let calls = CCPoolCallLog()
        l.acceptCall = { fd in
            calls.add()
            return calls.count <= 2 ? (-1, EMFILE) : CCPoolListener.systemAccept(fd)
        }
        let reports = CCPoolCounterBox()
        let accepted = expectation(description: "the connection is accepted")
        let q = DispatchQueue(label: "test.ccpool.accept")
        l.start(queue: q, accept: { fd in close(fd); accepted.fulfill() }, exhausted: { reports.bump() })
        let client = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(client) }
        XCTAssertEqual(Self.withAddr(l.port?.rawValue ?? 0, { connect(client, $0, $1) }), 0)
        wait(for: [accepted], timeout: 5)
        Thread.sleep(forTimeInterval: 0.3)
        let times = calls.times
        XCTAssertEqual(times.count, 4, "EMFILE, EMFILE, the connection, EAGAIN")
        if times.count >= 3 {
            XCTAssertGreaterThanOrEqual(times[1] - times[0], 0.09, "suspended between the attempts")
            XCTAssertGreaterThanOrEqual(times[2] - times[1], 0.09, "suspended between the attempts")
        }
        XCTAssertEqual(reports.count, 1, "one report per episode")
    }

    // A cancel while the source is paused closes the listener (.cancelled) and the scheduled resume never runs it.
    func testCancelWhileAcceptIsPausedNeverResumes() throws {
        let l = try CCPoolListener.open(port: 0).get()
        let calls = CCPoolCallLog()
        let first = expectation(description: "the first EMFILE")
        l.acceptCall = { _ in
            calls.add()
            if calls.count == 1 { first.fulfill() }
            return (-1, EMFILE)
        }
        let gone = expectation(description: ".cancelled")
        l.stateUpdateHandler = { if case .cancelled = $0 { gone.fulfill() } }
        let q = DispatchQueue(label: "test.ccpool.accept.cancel")
        l.start(queue: q, accept: { close($0) })
        let client = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(client) }
        XCTAssertEqual(Self.withAddr(l.port?.rawValue ?? 0, { connect(client, $0, $1) }), 0)
        wait(for: [first], timeout: 5)
        l.cancel()
        wait(for: [gone], timeout: 5)
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(calls.count, 1, "no accept after the cancel")
    }
}

/// Accept-seam calls with their times (seconds, monotonic).
private final class CCPoolCallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var t: [TimeInterval] = []
    var count: Int { lock.withLock { t.count } }
    var times: [TimeInterval] { lock.withLock { t } }
    func add() { lock.withLock { t.append(ProcessInfo.processInfo.systemUptime) } }
}

private final class CCPoolCounterBox: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    var count: Int { lock.withLock { n } }
    func bump() { lock.withLock { n += 1 } }
}
