import Darwin
import Network
import XCTest
@testable import ProsperApp

/// #871 P2a follow-ups (c), (d), (e) from the P1 review. (a) and (b) need the proxy rig and live in
/// CCPoolProxyTests. Loopback and ephemeral ports only, dummy tokens, CCPoolMemorySecrets.
final class CCPoolFollowUpTests: XCTestCase {
    private let dead = URL(string: "http://127.0.0.1:9")!

    /// A TCP socket bound to 127.0.0.1:<ephemeral> but not listening: a connect is refused (the
    /// probe calls the port free) while a bind to it fails with EADDRINUSE.
    private func boundNotListening() throws -> (fd: Int32, port: UInt16) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw XCTSkip("no socket") }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, len) == 0 && getsockname(fd, $0, &len) == 0 }
        }
        guard bound else { close(fd); throw XCTSkip("bind failed") }
        return (fd, UInt16(bigEndian: addr.sin_port))
    }

    // (c): a state write that fails leaves no Keychain item behind and no account listed.
    func testCCPoolAddWithFailedStateWriteLeavesNoOrphanItem() throws {
        let blocker = tempDir().appendingPathComponent("blocker")
        try Data().write(to: blocker)
        let log = CCPoolCapturingLogger()
        let store = CCPoolStore(directory: blocker.appendingPathComponent("ccpool"), logger: log)
        let secrets = CCPoolMemorySecrets()
        XCTAssertThrowsError(try store.addAccount(label: "alpha", token: "tok-alpha", secrets: secrets)) {
            XCTAssertEqual($0 as? CCPoolStoreError, .stateWriteFailed)
            XCTAssertFalse("\($0)".contains("tok-"))
        }
        XCTAssertEqual(secrets.count, 0, "the item written first is removed again")
        XCTAssertEqual(store.snapshot.order, [], "and the in-memory list is undone too")
        XCTAssertEqual(store.snapshot.accounts, [:])
        XCTAssertTrue(log.lines.contains { $0.contains("state write failed; change undone") }, "\(log.lines)")

        // The same store, once writable, takes the account.
        let ok = CCPoolStore(directory: tempDir().appendingPathComponent("ccpool"))
        try ok.addAccount(label: "alpha", token: "tok-alpha", secrets: secrets)
        XCTAssertEqual(secrets.count, 1)
        XCTAssertEqual(ok.snapshot.order, ["alpha"])
    }

    // (d): start retries a bind that lost to a socket the probe saw as free; a live listener is
    // never retried; restart rebinds the same port.
    func testCCPoolStartRetriesARacedBindAndRestartRebinds() throws {
        let (fd, port) = try boundNotListening()
        var fdOpen = true
        defer { if fdOpen { close(fd) } }
        var cfg = CCPoolServiceConfig()
        cfg.port = port
        cfg.upstream = dead
        // The real probe waits on a bound, not listening socket (run 5: it answered "other" after
        // its timeout, or "free" once the socket closed). "Free" here stages the race a TIME_WAIT
        // socket makes for real: connect refused, bind EADDRINUSE.
        var raced = cfg
        raced.portProbe = { _, _ in .free }
        let log = CCPoolCapturingLogger()
        let svc = CCPoolService(config: raced, store: CCPoolStore(directory: tempDir()), secrets: CCPoolMemorySecrets(),
                                logger: log)
        defer { svc.stop() }
        var t = Date()
        XCTAssertEqual(svc.start(), .heldByOther, "bind loses to the bound socket")
        XCTAssertEqual(svc.start(bindRetry: 0), .heldByOther, "no retry budget, one try")
        let lostBefore = log.lines.filter { $0.contains("listener did not start") }.count
        XCTAssertEqual(lostBefore, 2, "each lost bind is logged once: \(log.lines)")
        let failFast = Date().timeIntervalSince(t)

        let closer = DispatchSemaphore(value: 0)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.6) { close(fd); closer.signal() }
        t = Date()
        XCTAssertEqual(svc.start(bindRetry: 8), .running(port: port), "the retry wins once the socket goes")
        let waited = Date().timeIntervalSince(t)
        XCTAssertGreaterThanOrEqual(waited, 0.5)
        let lost = log.lines.filter { $0.contains("listener did not start") }.count - lostBefore
        XCTAssertGreaterThanOrEqual(lost, 1, "the win came from a retry after a lost bind, not one waiting bind "
                                    + "(two lost binds took \(failFast) s; this start took \(waited) s)")
        closer.wait()
        fdOpen = false

        XCTAssertEqual(svc.restart(), .running(port: port), "restart rebinds the same port")
        XCTAssertEqual(CCPoolPortProbe.probe(port: port, timeout: 5), .ccpool(pid: Int(getpid()), impl: "prosper"))

        // A live ccpool listener on the port: reported at once, never retried, never touched.
        let other = CCPoolService(config: cfg, store: CCPoolStore(directory: tempDir()), secrets: CCPoolMemorySecrets(),
                                  logger: CCPoolCapturingLogger())
        let t1 = Date()
        XCTAssertEqual(other.start(bindRetry: 5), .heldByCCPool(pid: Int(getpid())))
        XCTAssertLessThan(Date().timeIntervalSince(t1), 4, "no retry loop against a live listener")
        XCTAssertEqual(svc.status, .running(port: port), "the holder is left alone")
    }

    // (e): removing an account drops its upstream URLSession with it.
    func testCCPoolRemoveAccountDropsItsUpstreamSession() throws {
        let anthropic = CCPoolFakeAnthropic()
        let up = try CCPoolFakeServer { h, b in anthropic.reply(h, b) }
        defer { up.stop() }
        let store = CCPoolStore(directory: tempDir())
        let secrets = CCPoolMemorySecrets()
        try store.addAccount(label: "one", token: "tok-one", secrets: secrets)
        try store.addAccount(label: "two", token: "tok-two", secrets: secrets)
        var cfg = CCPoolServiceConfig()
        cfg.port = 0
        cfg.upstream = URL(string: "http://127.0.0.1:\(up.port)")!
        let svc = CCPoolService(config: cfg, store: store, secrets: secrets, logger: CCPoolCapturingLogger())
        guard case .running(let port) = svc.start() else { return XCTFail("no listener: \(svc.status)") }
        defer { svc.stop() }
        store.mutate { $0.current = "one" }
        XCTAssertEqual(CCPoolTestClient.request(port: port)?.status, 200)
        let id = try XCTUnwrap(store.snapshot.accounts["one"]?.id)
        XCTAssertTrue(svc.upstream.hasSession(accountID: id), "the request opened the account's session")

        try svc.removeAccount(label: "one")
        XCTAssertFalse(svc.upstream.hasSession(accountID: id), "removed with the account")
        XCTAssertNil(try secrets.token(id: id))
        XCTAssertEqual(store.snapshot.order, ["two"])
        XCTAssertThrowsError(try svc.removeAccount(label: "one")) { XCTAssertEqual($0 as? CCPoolStoreError, .noSuchAccount) }
        XCTAssertEqual(CCPoolTestClient.request(port: port)?.status, 200, "the pool still serves from the rest")
        // (f) on the wire: "one" was current; the health answer names no account after it goes.
        let health = try XCTUnwrap(CCPoolTestClient.request(port: port, method: "GET", path: CCPoolService.healthPath, headers: []))
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: health.body) as? [String: Any])
        XCTAssertNotEqual(obj["current"] as? String, "one", "health never names a removed account: \(obj)")
    }

    // (f): removing the current account clears `current` (on disk too); removing another leaves
    // it; rename carries it; reorder never touches it.
    func testCCPoolCurrentFollowsRemoveRenameAndMove() throws {
        let dir = tempDir()
        let store = CCPoolStore(directory: dir)
        let secrets = CCPoolMemorySecrets()
        for l in ["a", "b", "c"] { try store.addAccount(label: l, token: "tok-\(l)", secrets: secrets) }
        store.mutate { $0.current = "b" }
        try store.removeAccount(label: "a", secrets: secrets)
        XCTAssertEqual(store.snapshot.current, "b", "removing a non-current account leaves current alone")
        try store.renameAccount("b", to: "bee")
        XCTAssertEqual(store.snapshot.current, "bee", "rename carries current")
        XCTAssertEqual(CCPoolStore(directory: dir).snapshot.current, "bee", "after a reload too")
        XCTAssertTrue(store.moveAccount("c", by: -1))
        XCTAssertEqual(store.snapshot.order, ["c", "bee"])
        XCTAssertEqual(store.snapshot.current, "bee", "reorder leaves current alone")

        try store.removeAccount(label: "bee", secrets: secrets)
        XCTAssertNil(store.snapshot.current, "removing the current account clears it")
        XCTAssertNil(CCPoolStore(directory: dir).snapshot.current, "and the reload agrees")
        let health = try XCTUnwrap(JSONSerialization.jsonObject(with: CCPoolService.healthBody(store: store)) as? [String: Any])
        XCTAssertTrue(health["current"] is NSNull, "the health answer names no account: \(health)")
        try store.addAccount(label: "bee", token: "tok-bee-2", secrets: secrets)
        XCTAssertNil(store.snapshot.current, "a new account under the old label is not current at once")
    }

    // QA #734 INFO-4: a state.json that exists but cannot be read is never replaced, and account
    // changes are refused with the reason.
    func testCCPoolUnreadableStateIsNeverOverwritten() throws {
        let dir = tempDir().appendingPathComponent("ccpool")
        let inTheWay = dir.appendingPathComponent("state.json")
        try FileManager.default.createDirectory(at: inTheWay, withIntermediateDirectories: true)
        let keep = inTheWay.appendingPathComponent("keep")
        try Data("x".utf8).write(to: keep)
        let log = CCPoolCapturingLogger()
        let store = CCPoolStore(directory: dir, logger: log)
        XCTAssertTrue(store.unreadable)
        XCTAssertEqual(store.snapshot, CCPoolState(), "an empty pool in memory")
        XCTAssertNil(CCPoolCore.pick(store.snapshot, model: "claude-opus-5", exclude: [], now: store.now))
        store.mutate { $0.current = "x" }
        let secrets = CCPoolMemorySecrets()
        XCTAssertThrowsError(try store.addAccount(label: "alpha", token: "tok-alpha", secrets: secrets)) {
            XCTAssertEqual($0 as? CCPoolStoreError, .stateUnreadable)
            XCTAssertEqual("\($0)", CCPoolStore.unreadableNote)
        }
        XCTAssertEqual(secrets.count, 0, "no secret added")
        XCTAssertEqual(store.snapshot.order, [])
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: inTheWay.path, isDirectory: &isDir) && isDir.boolValue,
                      "not moved, not replaced")
        XCTAssertEqual(try Data(contentsOf: keep), Data("x".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["state.json"], "nothing written beside it")
        XCTAssertTrue(log.lines.contains { $0.contains("could not be read") }, "\(log.lines)")
        XCTAssertFalse(log.lines.contains { $0.contains("state write failed") }, "a refused write is not retried and logged per change")

        // A missing file still starts empty and writes.
        let fresh = CCPoolStore(directory: tempDir().appendingPathComponent("ccpool"))
        XCTAssertFalse(fresh.unreadable)
        try fresh.addAccount(label: "alpha", token: "tok-alpha", secrets: secrets)
        XCTAssertEqual(CCPoolStore(directory: fresh.directory).snapshot.order, ["alpha"])
    }

    // QA #734 INFO-6: account-set changes are written or refused; rotation state may stay in memory.
    func testCCPoolFailedWriteRefusesAccountChanges() throws {
        final class WriteSwitch: @unchecked Sendable {
            private let lock = NSLock()
            private var _fail = false
            var fail: Bool {
                get { lock.withLock { _fail } }
                set { lock.withLock { _fail = newValue } }
            }
        }
        let sw = WriteSwitch()
        let dir = tempDir().appendingPathComponent("ccpool")
        let store = CCPoolStore(directory: dir, logger: CCPoolCapturingLogger(),
                                writer: { data, url in sw.fail ? false : CCPoolStore.atomicWrite(data, url) })
        let secrets = CCPoolMemorySecrets()
        try store.addAccount(label: "one", token: "tok-one", secrets: secrets)
        let before = store.snapshot
        sw.fail = true
        XCTAssertThrowsError(try store.addAccount(label: "two", token: "tok-two", secrets: secrets)) {
            XCTAssertEqual($0 as? CCPoolStoreError, .stateWriteFailed)
        }
        XCTAssertEqual(store.snapshot, before, "the state did not advance")
        XCTAssertEqual(secrets.count, 1, "the secret added for two is removed again")
        XCTAssertThrowsError(try store.removeAccount(label: "one", secrets: secrets)) {
            XCTAssertEqual($0 as? CCPoolStoreError, .stateWriteFailed)
        }
        let id = try XCTUnwrap(store.snapshot.accounts["one"]?.id)
        XCTAssertEqual(try secrets.token(id: id), "tok-one", "remove kept both the account and its secret")
        XCTAssertThrowsError(try store.renameAccount("one", to: "uno")) {
            XCTAssertEqual($0 as? CCPoolStoreError, .stateWriteFailed)
        }
        XCTAssertEqual(store.snapshot.order, ["one"])
        let now = store.now
        store.mutate { $0.bench("one", claim: "five_hour", until: Int(now) + 60, now: now) }
        XCTAssertEqual(store.snapshot.accounts["one"]?.cooldown["five_hour"], Int(now) + 60, "a bench still holds in memory")
        sw.fail = false
        XCTAssertEqual(CCPoolStore(directory: dir).snapshot.order, ["one"], "the disk never saw two")
    }

    // QA #734 INFO-10: the usage probe never follows a redirect; the 3xx is its answer.
    func testCCPoolProbeNeverFollowsARedirect() async throws {
        let second = try CCPoolFakeServer { _, _ in .respond(200, [], Data()) }
        defer { second.stop() }
        let first = try CCPoolFakeServer { _, _ in
            .respond(307, [("Location", "http://127.0.0.1:\(second.port)/v1/messages")], Data())
        }
        defer { first.stop() }
        let probe = await CCPoolUsage.probe(token: "tok-probe", base: URL(string: "http://127.0.0.1:\(first.port)")!, timeout: 10)
        XCTAssertEqual(probe?.status, 307)
        XCTAssertEqual(probe?.limits, [:], "no rate-limit headers: could not answer")
        XCTAssertEqual(first.accepted, 1)
        XCTAssertEqual(second.accepted, 0, "the token never reached the Location host")
    }

    // QA #734: a listener that fails after it was running stops reading "running"; Start works again.
    @MainActor
    func testCCPoolListenerLostAfterStartIsNotRunning() throws {
        let r = try ccpoolPaneRig()
        guard case .running = r.service.start() else { return XCTFail("\(r.service.status)") }
        XCTAssertTrue(r.model.proxyRunning)
        let stale = try NWListener(using: .tcp)
        r.service.listenerLost(.posix(.ENETDOWN), from: stale)
        XCTAssertTrue(r.model.proxyRunning, "a listener that is not the live one changes nothing")
        r.service.listenerLost(.posix(.ENETDOWN))
        XCTAssertEqual(r.service.status, .failed("\(NWError.posix(.ENETDOWN))"))
        XCTAssertFalse(r.model.proxyRunning, "the pane offers Start, not Restart")
        XCTAssertEqual(r.model.proxyText, "Could not start")
        XCTAssertTrue(r.log.lines.contains { $0.contains("listener failed after start") }, "\(r.log.lines)")
        guard case .running = r.service.start() else { return XCTFail("start again: \(r.service.status)") }
    }
}
