import Darwin
import Network
import XCTest
@testable import ProsperApp

/// #715: a failed bind (EADDRINUSE) or a start with no Tailscale address left the
/// Remote Terminal server dead until the toggle was flipped or Prosper relaunched.
/// These drive a real NWListener on 127.0.0.1 only, on a random port in 30000..<45000
/// that a test socket holds to force EADDRINUSE. Never the Tailscale address, never 8771,
/// and `onReady` is a no-op so no real dch client is ever swept.
final class DchSessionServerBindTests: XCTestCase {

    private var servers: [DchSessionServer] = []
    private var heldFDs: [Int32] = []

    override func tearDown() {
        for s in servers { s.stop(); _ = s.isRunning }   // isRunning drains the queue
        for fd in heldFDs { Darwin.close(fd) }
        servers = []; heldFDs = []
        super.tearDown()
    }

    private func server(host: @escaping @Sendable () -> String? = { "127.0.0.1" },
                        port: UInt16, retryBase: Double,
                        onReady: @escaping @Sendable () -> Void = {}) -> DchSessionServer {
        let s = DchSessionServer(bindHost: host, port: port, retryBase: retryBase, onReady: onReady)
        servers.append(s)
        return s
    }

    /// A raw loopback socket on `port`. nil if the bind fails.
    private func rawBind(_ port: UInt16, listen: Bool) -> (fd: Int32, port: UInt16)? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ok = withUnsafeMutablePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(fd, sa, len) == 0 && (!listen || Darwin.listen(fd, 1) == 0)
                    && getsockname(fd, sa, &len) == 0
            }
        }
        guard ok else { Darwin.close(fd); return nil }
        return (fd, UInt16(bigEndian: addr.sin_port))
    }

    /// A free port below the ephemeral range (49152+). A kernel-picked ephemeral port
    /// can be taken by another process's outgoing localhost connection once released,
    /// which failed a bind here for 5 s in about 1 run in 40.
    private func pickPort(listen: Bool) throws -> (fd: Int32, port: UInt16) {
        for _ in 0..<50 {
            if let p = rawBind(UInt16.random(in: 30000..<45000), listen: listen) { return p }
        }
        throw XCTSkip("no free loopback port in 30000..<45000")
    }

    /// Holds a fresh loopback port with a listening socket; returns the port.
    private func holdPort() throws -> UInt16 {
        let held = try pickPort(listen: true)
        heldFDs.append(held.fd)
        return held.port
    }

    private func releasePort() {
        for fd in heldFDs { Darwin.close(fd) }
        heldFDs = []
    }

    /// A port that was free a moment ago.
    private func freePort() throws -> UInt16 {
        let p = try pickPort(listen: false)
        Darwin.close(p.fd)
        return p.port
    }

    /// True while something (the server) holds 127.0.0.1:`port`.
    private func portHeld(_ port: UInt16) -> Bool {
        guard let p = rawBind(port, listen: false) else { return true }
        Darwin.close(p.fd)
        return false
    }

    private func eventually(_ seconds: Double = 5, _ cond: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if cond() { return true }
            usleep(20_000)
        }
        return cond()
    }

    // MARK: -

    func testFailedBindLeavesNotRunningAndLaterStartBinds() throws {
        let port = try holdPort()
        let s = server(port: port, retryBase: 60)   // no retry inside this test
        try s.start()
        XCTAssertFalse(s.isRunning, "a failed bind must not look running (it blocked every later start)")
        releasePort()
        try s.start()
        XCTAssertTrue(s.isRunning)
        XCTAssertTrue(portHeld(port), "the second start() must actually bind")
        s.stop()
        XCTAssertFalse(s.isRunning)
        XCTAssertTrue(eventually { !portHeld(port) }, "stop() must free the port")
    }

    /// The orphan sweep (production onReady) runs once per listener that comes up.
    func testOnReadyRunsOncePerReadyListener() throws {
        let readies = Counter()
        let port = try freePort()
        let s = server(port: port, retryBase: 60, onReady: { _ = readies.next() })
        try s.start()
        try s.start()   // idempotent: no second listener, no second sweep
        XCTAssertTrue(eventually { readies.value == 1 })
        s.stop()
        XCTAssertTrue(eventually { !portHeld(port) })   // cancel frees the port asynchronously
        try s.start()
        XCTAssertTrue(eventually { readies.value == 2 })
        s.queue.sync {}   // let a stray extra call land before the final check
        XCTAssertEqual(readies.value, 2)
    }

    func testFailedBindRetriesOnceThePortFrees() throws {
        let port = try holdPort()
        let s = server(port: port, retryBase: 0.05)
        try s.start()
        XCTAssertFalse(s.isRunning)
        releasePort()
        XCTAssertTrue(eventually { s.isRunning && portHeld(port) }, "no recovery without a toggle")
    }

    func testNoTailscaleStartRetriesUntilAnAddressAppears() throws {
        let calls = Counter()
        // Hold the port until the retry binds, so nothing can take it in the gap.
        let held = try pickPort(listen: false)
        let s = server(host: {
            if calls.next() == 1 { return nil }
            if calls.value == 2 { Darwin.close(held.fd) }
            return "127.0.0.1"
        }, port: held.port, retryBase: 0.05)
        XCTAssertThrowsError(try s.start()) { XCTAssertEqual($0 as? DchSessionServer.ServerError, .noTailscale) }
        XCTAssertTrue(eventually { s.isRunning }, "a start before Tailscale was up never came back")
        XCTAssertEqual(calls.value, 2, "one retry, then bound: no storm")
    }

    /// Deterministic (QA #532 F5): the 60 s backoff cannot fire inside the test; what is
    /// pinned is that stop() cancels the pending item, which then never runs.
    func testStopDuringBackoffCancelsTheRetry() throws {
        let calls = Counter()
        let s = server(host: { calls.next() == 1 ? nil : "127.0.0.1" }, port: try freePort(), retryBase: 60)
        XCTAssertThrowsError(try s.start())
        let pending = try XCTUnwrap(s.lifecycle.sync { s.retry }, "a noTailscale start must schedule a retry")
        s.stop()
        XCTAssertTrue(pending.isCancelled, "a toggle off during backoff must never rebind")
        XCTAssertTrue(s.lifecycle.sync { s.retry == nil })
        XCTAssertFalse(s.isRunning)
        XCTAssertEqual(calls.value, 1)
    }

    func testStaleFailedDoesNotClearTheCurrentListener() throws {
        let port = try freePort()
        let s = server(port: port, retryBase: 60)
        try s.start()
        XCTAssertTrue(s.isRunning)
        let stale = try NWListener(using: .tcp)   // never started; stands in for an old listener
        s.lifecycle.sync {
            s.listenerStateChanged(.failed(.posix(.EADDRINUSE)), of: stale, signal: nil)
        }
        XCTAssertTrue(s.isRunning, "a stale .failed cleared the newer listener")
        XCTAssertTrue(portHeld(port))
    }

    func testRetryDelayDoublesAndCapsAtSixty() {
        XCTAssertEqual((0...7).map { DchSessionServer.retryDelay(attempt: $0) }, [2, 4, 8, 16, 32, 60, 60, 60])
        XCTAssertEqual(DchSessionServer.retryDelay(attempt: 1000), 60)
    }

    /// QA #532 F1/F2: the connection queue runs dch forks with no timeout. A wedged one
    /// must not freeze main on a Remote Terminal toggle, nor keep the port bound after off.
    func testStartAndStopNeverWaitOnABlockedConnectionQueue() throws {
        let port = try freePort()
        let s = server(port: port, retryBase: 60)
        let wedge = DispatchSemaphore(value: 0)
        s.queue.async { wedge.wait() }   // a hung dch call on the connection queue
        defer { wedge.signal() }
        let started = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { try? s.start(); started.signal() }
        XCTAssertEqual(started.wait(timeout: .now() + 6), .success, "start() blocked past its 5 s bound")
        XCTAssertTrue(eventually { portHeld(port) }, "start() did not bind")
        let stopped = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { s.stop(); stopped.signal() }
        XCTAssertEqual(stopped.wait(timeout: .now() + 2), .success, "stop() blocked")
        XCTAssertTrue(eventually(2) { !portHeld(port) }, "stop() left the port bound behind a blocked queue")
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}
