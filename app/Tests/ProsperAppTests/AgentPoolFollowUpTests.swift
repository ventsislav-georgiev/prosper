import Darwin
import Network
import XCTest
@testable import ProsperApp

/// #871 P2a follow-ups (c), (d), (e) from the P1 review. (a) and (b) need the proxy rig and live in
/// AgentPoolProxyTests. Loopback and ephemeral ports only, dummy tokens, AgentPoolMemorySecrets.
final class AgentPoolFollowUpTests: XCTestCase {
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

    /// A plain foreign listener on 127.0.0.1:<ephemeral> that accepts nothing and answers nothing.
    private func foreignListener() throws -> (fd: Int32, port: UInt16) {
        let (fd, port) = try boundNotListening()
        guard listen(fd, 8) == 0 else { close(fd); throw XCTSkip("listen failed") }
        return (fd, port)
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func bump() { lock.withLock { n += 1 } }
        var count: Int { lock.withLock { n } }
    }

    // (c): a state write that fails leaves no Keychain item behind and no account listed.
    func testAgentPoolAddWithFailedStateWriteLeavesNoOrphanItem() throws {
        let blocker = tempDir().appendingPathComponent("blocker")
        try Data().write(to: blocker)
        let log = AgentPoolCapturingLogger()
        let store = AgentPoolStore(directory: blocker.appendingPathComponent("ccpool"), logger: log)
        let secrets = AgentPoolMemorySecrets()
        XCTAssertThrowsError(try store.addAccount(label: "alpha", token: "tok-alpha", secrets: secrets)) {
            XCTAssertEqual($0 as? AgentPoolStoreError, .stateWriteFailed)
            XCTAssertFalse("\($0)".contains("tok-"))
        }
        XCTAssertEqual(secrets.count, 0, "the item written first is removed again")
        XCTAssertEqual(store.snapshot.order, [], "and the in-memory list is undone too")
        XCTAssertEqual(store.snapshot.accounts, [:])
        XCTAssertTrue(log.lines.contains { $0.contains("state write failed; change undone") }, "\(log.lines)")

        // The same store, once writable, takes the account.
        let ok = AgentPoolStore(directory: tempDir().appendingPathComponent("ccpool"))
        try ok.addAccount(label: "alpha", token: "tok-alpha", secrets: secrets)
        XCTAssertEqual(secrets.count, 1)
        XCTAssertEqual(ok.snapshot.order, ["alpha"])
    }

    // (d): start retries a bind that lost to a socket the probe saw as free; a live listener is
    // never retried; restart rebinds the same port.
    func testAgentPoolStartRetriesARacedBindAndRestartRebinds() throws {
        // #1094: a port number given back can be taken by another process (an outgoing connection's
        // source port) before the service binds it; the scenario then runs again on a fresh port.
        for _ in 1...5 { if try racedBindScenario() { return } }
        XCTFail("every attempt lost its released port to another process")
    }

    /// One run of (d) on its own ephemeral port. False when the port was lost to another process after the
    /// test released it: the service's retry loop ran to its deadline (3 or more lost binds in one start)
    /// and still read heldByOther. One lost bind is the product failing to retry, which stays a failure.
    private func racedBindScenario() throws -> Bool {
        let (fd, port) = try boundNotListening()
        var fdOpen = true
        defer { if fdOpen { close(fd) } }
        var cfg = AgentPoolServiceConfig()
        cfg.port = port
        cfg.upstream = dead
        // The real probe waits on a bound, not listening socket (run 5: it answered "other" after
        // its timeout, or "free" once the socket closed). "Free" here stages the race a TIME_WAIT
        // socket makes for real: connect refused, bind EADDRINUSE.
        var raced = cfg
        raced.portProbe = { _, _ in .free }
        let log = AgentPoolCapturingLogger()
        let svc = AgentPoolService(config: raced, store: AgentPoolStore(directory: tempDir()), secrets: AgentPoolMemorySecrets(),
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
        let won = svc.start(bindRetry: 8)
        let waited = Date().timeIntervalSince(t)
        closer.wait()
        fdOpen = false
        let lostAfterRetry = log.lines.filter { $0.contains("listener did not start") }.count - lostBefore
        if won == .heldByOther, lostAfterRetry >= 3 { return false }
        XCTAssertEqual(won, .running(port: port), "the retry wins once the socket goes")
        XCTAssertGreaterThanOrEqual(waited, 0.5)
        let lost = log.lines.filter { $0.contains("listener did not start") }.count - lostBefore
        XCTAssertGreaterThanOrEqual(lost, 1, "the win came from a retry after a lost bind, not one waiting bind "
                                    + "(two lost binds took \(failFast) s; this start took \(waited) s)")

        let lostBeforeRestart = log.lines.filter { $0.contains("listener did not start") }.count
        let restarted = svc.restart()
        let lostInRestart = log.lines.filter { $0.contains("listener did not start") }.count - lostBeforeRestart
        if restarted == .heldByOther, lostInRestart >= 3 { return false }
        XCTAssertEqual(restarted, .running(port: port), "restart rebinds the same port")
        XCTAssertEqual(AgentPoolPortProbe.probe(port: port, timeout: 5), .ccpool(pid: Int(getpid()), impl: "prosper"))

        // A live ccpool listener on the port: reported at once, never retried, never touched.
        let other = AgentPoolService(config: cfg, store: AgentPoolStore(directory: tempDir()), secrets: AgentPoolMemorySecrets(),
                                  logger: AgentPoolCapturingLogger())
        let t1 = Date()
        XCTAssertEqual(other.start(bindRetry: 5), .heldByAgentPool(pid: Int(getpid())))
        XCTAssertLessThan(Date().timeIntervalSince(t1), 4, "no retry loop against a live listener")
        XCTAssertEqual(svc.status, .running(port: port), "the holder is left alone")
        return true
    }

    // (e): removing an account drops its upstream URLSession with it.
    func testAgentPoolRemoveAccountDropsItsUpstreamSession() throws {
        let anthropic = AgentPoolFakeAnthropic()
        let up = try AgentPoolFakeServer { h, b in anthropic.reply(h, b) }
        defer { up.stop() }
        let store = AgentPoolStore(directory: tempDir())
        let secrets = AgentPoolMemorySecrets()
        try store.addAccount(label: "one", token: "tok-one", secrets: secrets)
        try store.addAccount(label: "two", token: "tok-two", secrets: secrets)
        var cfg = AgentPoolServiceConfig()
        cfg.port = 0
        cfg.upstream = URL(string: "http://127.0.0.1:\(up.port)")!
        let svc = AgentPoolService(config: cfg, store: store, secrets: secrets, logger: AgentPoolCapturingLogger())
        guard case .running(let port) = svc.start() else { return XCTFail("no listener: \(svc.status)") }
        defer { svc.stop() }
        store.mutate { $0.current = "one" }
        XCTAssertEqual(AgentPoolTestClient.request(port: port)?.status, 200)
        let id = try XCTUnwrap(store.snapshot.accounts["one"]?.id)
        XCTAssertTrue(svc.upstream.hasSession(accountID: id), "the request opened the account's session")

        try svc.removeAccount(label: "one")
        XCTAssertFalse(svc.upstream.hasSession(accountID: id), "removed with the account")
        XCTAssertNil(try secrets.token(id: id))
        XCTAssertEqual(store.snapshot.order, ["two"])
        XCTAssertThrowsError(try svc.removeAccount(label: "one")) { XCTAssertEqual($0 as? AgentPoolStoreError, .noSuchAccount) }
        XCTAssertEqual(AgentPoolTestClient.request(port: port)?.status, 200, "the pool still serves from the rest")
        // (f) on the wire: "one" was current; the health answer names no account after it goes.
        let health = try XCTUnwrap(AgentPoolTestClient.request(port: port, method: "GET", path: AgentPoolService.healthPath, headers: []))
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: health.body) as? [String: Any])
        XCTAssertNotEqual(obj["current"] as? String, "one", "health never names a removed account: \(obj)")
    }

    // (f): removing the current account clears `current` (on disk too); removing another leaves
    // it; rename carries it; rewriting the member list never touches it.
    func testAgentPoolCurrentFollowsRemoveRenameAndMove() throws {
        let dir = tempDir()
        let store = AgentPoolStore(directory: dir)
        let secrets = AgentPoolMemorySecrets()
        for l in ["a", "b", "c"] { try store.addAccount(label: l, token: "tok-\(l)", secrets: secrets) }
        store.mutate { $0.current = "b" }
        try store.removeAccount(label: "a", secrets: secrets)
        XCTAssertEqual(store.snapshot.current, "b", "removing a non-current account leaves current alone")
        try store.renameAccount("b", to: "bee")
        XCTAssertEqual(store.snapshot.current, "bee", "rename carries current")
        XCTAssertEqual(AgentPoolStore(directory: dir).snapshot.current, "bee", "after a reload too")
        store.mutate { $0.order = ["c", "bee"] }   // #1838: moveAccount is gone; a rewritten order is the same write
        XCTAssertEqual(store.snapshot.order, ["c", "bee"])
        XCTAssertEqual(store.snapshot.current, "bee", "rewriting the member list leaves current alone")

        try store.removeAccount(label: "bee", secrets: secrets)
        XCTAssertNil(store.snapshot.current, "removing the current account clears it")
        XCTAssertNil(AgentPoolStore(directory: dir).snapshot.current, "and the reload agrees")
        let health = try XCTUnwrap(JSONSerialization.jsonObject(with: AgentPoolService.healthBody(store: store)) as? [String: Any])
        XCTAssertTrue(health["current"] is NSNull, "the health answer names no account: \(health)")
        try store.addAccount(label: "bee", token: "tok-bee-2", secrets: secrets)
        XCTAssertNil(store.snapshot.current, "a new account under the old label is not current at once")
    }

    // #1673: health "sessions" = session id -> label of the live pins; main agent first, removed accounts skipped.
    func testHealthSessionsMapsLivePinsToLabels() throws {
        let store = AgentPoolStore(directory: tempDir())
        let secrets = AgentPoolMemorySecrets()
        for l in ["a", "b", "gone"] { try store.addAccount(label: l, token: "tok-\(l)", secrets: secrets) }
        let now = store.now
        store.mutate {
            $0.pin("api/", to: "a", now: now)
            $0.pin("two/agent1", to: "a", now: now)
            $0.pin("two/", to: "b", now: now - 100)   // the main agent wins though older
            $0.pin("sub/x", to: "a", now: now - 10)
            $0.pin("sub/y", to: "b", now: now - 5)     // no main: the most recent
            $0.pin("old/", to: "a", now: now - AgentPoolState.pinIdle - 5)   // idle: not live
            $0.pin("dead/", to: "gone", now: now)
        }
        try store.removeAccount(label: "gone", secrets: secrets)
        func sessions() throws -> [String: String] {
            let h = try XCTUnwrap(JSONSerialization.jsonObject(with: AgentPoolService.healthBody(store: store)) as? [String: Any])
            XCTAssertEqual(h["service"] as? String, AgentPoolService.serviceName)
            return try XCTUnwrap(h["sessions"] as? [String: String])
        }
        XCTAssertEqual(try sessions(), ["api": "a", "two": "b", "sub": "b"])
        let fresh = AgentPoolStore(directory: tempDir())
        let h = try XCTUnwrap(JSONSerialization.jsonObject(with: AgentPoolService.healthBody(store: fresh)) as? [String: Any])
        XCTAssertTrue((h["sessions"] as? [String: String]) == [:], "no pins: an empty map: \(h)")
    }

    // QA R1673 n22: the health map holds the 64 most recently seen sessions, so it stays under the probe's 64 KiB read.
    func testSessionLabelsKeepTheMostRecentSixtyFour() {
        let now: Double = 1_800_000_000
        var st = AgentPoolState(current: "a", order: ["a"], accounts: ["a": .init(id: "id-a")])
        for n in 0..<70 { st.pins["sess-\(n)/"] = .init(account: "a", seen: now - 1000 + Double(n)) }
        let got = st.sessionLabels(now: now)
        XCTAssertEqual(AgentPoolState.sessionLabelsCap, 64)
        XCTAssertEqual(got.count, 64)
        XCTAssertEqual(Set(got.keys), Set((6..<70).map { "sess-\($0)" }), "the oldest 6 are dropped")
        st.pins.removeValue(forKey: "sess-69/")
        st.pins.removeValue(forKey: "sess-68/")
        XCTAssertEqual(st.sessionLabels(now: now).count, 64, "68 sessions: still 64")
        st.pins = st.pins.filter { $0.key < "sess-3" }   // sess-0..2 and sess-10..29: 23
        XCTAssertEqual(st.sessionLabels(now: now).count, 23, "under the cap: every live session")
    }

    // QA #734 INFO-4: a state.json that exists but cannot be read is never replaced, and account
    // changes are refused with the reason.
    func testAgentPoolUnreadableStateIsNeverOverwritten() throws {
        let dir = tempDir().appendingPathComponent("ccpool")
        let inTheWay = dir.appendingPathComponent("state.json")
        try FileManager.default.createDirectory(at: inTheWay, withIntermediateDirectories: true)
        let keep = inTheWay.appendingPathComponent("keep")
        try Data("x".utf8).write(to: keep)
        let log = AgentPoolCapturingLogger()
        let store = AgentPoolStore(directory: dir, logger: log)
        XCTAssertTrue(store.unreadable)
        XCTAssertEqual(store.snapshot, AgentPoolState(), "an empty pool in memory")
        XCTAssertNil(AgentPoolCore.pick(store.snapshot, model: "claude-opus-5", exclude: [], now: store.now))
        store.mutate { $0.current = "x" }
        let secrets = AgentPoolMemorySecrets()
        XCTAssertThrowsError(try store.addAccount(label: "alpha", token: "tok-alpha", secrets: secrets)) {
            XCTAssertEqual($0 as? AgentPoolStoreError, .stateUnreadable)
            XCTAssertEqual("\($0)", AgentPoolStore.unreadableNote)
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
        let fresh = AgentPoolStore(directory: tempDir().appendingPathComponent("ccpool"))
        XCTAssertFalse(fresh.unreadable)
        try fresh.addAccount(label: "alpha", token: "tok-alpha", secrets: secrets)
        XCTAssertEqual(AgentPoolStore(directory: fresh.directory).snapshot.order, ["alpha"])
    }

    // QA #738 INFO-3 (A3): a REGULAR state.json at mode 000 is never replaced either. A directory
    // in its place would also stop the rename; this file only stays because persist() refuses.
    func testAgentPoolUnreadableRegularStateIsNeverReplaced() throws {
        let dir = tempDir().appendingPathComponent("ccpool")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("state.json")
        let original = Data(#"{"order": ["alpha"]}"#.utf8)
        try original.write(to: url)
        XCTAssertEqual(chmod(url.path, 0), 0)
        defer { chmod(url.path, 0o600) }
        if FileManager.default.isReadableFile(atPath: url.path) { throw XCTSkip("mode 000 is readable to this user") }
        var before = stat()
        XCTAssertEqual(lstat(url.path, &before), 0)

        let log = AgentPoolCapturingLogger()
        let store = AgentPoolStore(directory: dir, logger: log)
        XCTAssertTrue(store.unreadable)
        store.mutate { $0.current = "x" }   // a rotation change: persist() is the only guard on this path
        store.mutate { $0.order = ["x"] }
        XCTAssertThrowsError(try store.addAccount(label: "alpha", token: "tok-alpha", secrets: AgentPoolMemorySecrets()))

        var after = stat()
        XCTAssertEqual(lstat(url.path, &after), 0)
        XCTAssertEqual(after.st_ino, before.st_ino, "state.json was not replaced")
        XCTAssertEqual(after.st_mode & 0o777, 0, "still mode 000")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["state.json"], "nothing written beside it")
        XCTAssertEqual(chmod(url.path, 0o600), 0)
        XCTAssertEqual(try Data(contentsOf: url), original, "the bytes are the user's")
    }

    // Supervisor mutant k2 (A4): a live FOREIGN listener on the port is looked at once and never
    // retried, and no bind is tried against it. Its own ephemeral port, never the production one.
    func testAgentPoolForeignListenerIsNeverRetried() throws {
        let (fd, port) = try foreignListener()
        defer { close(fd) }
        let starts = Counter()
        var cfg = AgentPoolServiceConfig()
        cfg.port = port
        cfg.upstream = dead
        cfg.probeTimeout = 0.5
        cfg.portProbe = { p, t in starts.bump(); return AgentPoolPortProbe.probe(port: p, timeout: t) }
        let log = AgentPoolCapturingLogger()
        let svc = AgentPoolService(config: cfg, store: AgentPoolStore(directory: tempDir()), secrets: AgentPoolMemorySecrets(), logger: log)
        defer { svc.stop() }
        XCTAssertEqual(svc.start(bindRetry: 3), .heldByOther)
        XCTAssertEqual(starts.count, 1, "one look, no retry loop: \(log.lines)")
        XCTAssertEqual(log.lines.filter { $0.contains("listener did not start") }.count, 0, "no bind was tried")
        XCTAssertEqual(log.lines.filter { $0.contains("port held by another program") }.count, 1)
    }

    // #1190 INFO-5 (c): the configured port is held when the life cycle starts the proxy (launch with an
    // account). Not running, no bind tried, one look per event and never a loop on the queue. The port
    // is this row's own ephemeral listener, never a fixed one.
    @MainActor
    func testAgentPoolLifeCycleLeavesAHeldPortAlone() async throws {
        let (fd, port) = try foreignListener()
        defer { close(fd) }
        let probes = Counter()
        var cfg = AgentPoolServiceConfig()
        cfg.port = port
        cfg.upstream = dead
        cfg.probeTimeout = 0.5
        cfg.portProbe = { p, t in probes.bump(); return AgentPoolPortProbe.probe(port: p, timeout: t) }
        let log = AgentPoolCapturingLogger()
        let dir = tempDir()
        let rt = AgentPoolRuntime(directory: dir.appendingPathComponent("ccpool"), secrets: AgentPoolMemorySecrets(), config: cfg,
                               vaultURL: dir.appendingPathComponent("old").appendingPathComponent(AgentPoolVaultImport.vaultFileName),
                               defaults: scratchDefaults("ccpool-held"), probeBase: dead, logger: log, trash: { _ in })
        defer { rt.service.stop() }
        try rt.store.addAccount(label: "Example Org", token: "tok-example", secrets: rt.secrets)
        await rt.setLive(true)?.value
        XCTAssertEqual(rt.service.status, .heldByOther)
        XCTAssertEqual(probes.count, 1, "one look: \(log.lines)")
        XCTAssertEqual(log.lines.filter { $0.contains("listener did not start") }.count, 0, "no bind was tried")
        await rt.model.reconcileProxy()?.value
        XCTAssertEqual(probes.count, 2, "the next event looks once more")
        XCTAssertEqual(rt.service.status, .heldByOther)
        rt.quit()
        XCTAssertEqual(rt.service.status, .stopped)
    }

    // Review carry 2 (A6 a): a listener that goes to .waiting (or is cancelled by nobody) after it
    // was running stops reading "running", and no session routes to it.
    @MainActor
    func testAgentPoolListenerWaitingAfterStartIsNotRunning() async throws {
        let r = try ccpoolPaneRig()
        try r.add(["a"])
        for state in [NWListener.State.waiting(.posix(.ENETDOWN)), .failed(.posix(.ENETDOWN)), .cancelled] {
            guard case .running = r.service.start() else { return XCTFail("\(r.service.status)") }
            XCTAssertTrue(r.service.routable)
            let l = try XCTUnwrap(r.service.currentListener)
            l.stateUpdateHandler?(state)
            XCTAssertEqual(r.service.status, .failed(AgentPoolService.reasonLost), "\(state)")
            XCTAssertNil(r.service.currentListener)
            XCTAssertFalse(r.service.routable, "\(state)")
            XCTAssertTrue(r.service.sessionEnv(command: ["claude"], on: true).isEmpty, "\(state)")
            XCTAssertEqual(r.model.proxyText, "Not running: " + AgentPoolService.reasonLost)
            XCTAssertEqual(r.model.routeDisabledReason, "The proxy is not running.")
        }
        // A stop we asked for reads Stopped, also after its own .cancelled arrives.
        guard case .running = r.service.start() else { return XCTFail("\(r.service.status)") }
        r.service.stop()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(r.service.status, .stopped)
    }

    // Review carry 2 (A6 b): a failure between .ready and the publish of the listener is not lost.
    func testAgentPoolListenerFailingBeforeItIsPublishedIsNotRunning() throws {
        final class Once: @unchecked Sendable {
            private let lock = NSLock()
            private var fired = false
            func take() -> Bool { lock.withLock { defer { fired = true }; return !fired } }
        }
        let once = Once()
        var cfg = AgentPoolServiceConfig()
        cfg.port = 0
        cfg.upstream = dead
        cfg.afterReady = { l in if once.take() { l.stateUpdateHandler?(.failed(.posix(.ENETDOWN))) } }
        let store = AgentPoolStore(directory: tempDir())
        let secrets = AgentPoolMemorySecrets()
        try store.addAccount(label: "a", token: "tok-a", secrets: secrets)
        let svc = AgentPoolService(config: cfg, store: store, secrets: secrets, logger: AgentPoolCapturingLogger())
        defer { svc.stop() }
        XCTAssertEqual(svc.start(), .failed(AgentPoolService.reasonLost))
        XCTAssertEqual(svc.status, .failed(AgentPoolService.reasonLost))
        XCTAssertNil(svc.currentListener)
        XCTAssertFalse(svc.routable)
        XCTAssertTrue(svc.sessionEnv(command: ["claude"], on: true).isEmpty)
        guard case .running = svc.start() else { return XCTFail("start again: \(svc.status)") }
        XCTAssertTrue(svc.routable)
    }

    // QA #734 INFO-6: account-set changes are written or refused; rotation state may stay in memory.
    func testAgentPoolFailedWriteRefusesAccountChanges() throws {
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
        let store = AgentPoolStore(directory: dir, logger: AgentPoolCapturingLogger(),
                                writer: { data, url in sw.fail ? false : AgentPoolStore.atomicWrite(data, url) })
        let secrets = AgentPoolMemorySecrets()
        try store.addAccount(label: "one", token: "tok-one", secrets: secrets)
        let before = store.snapshot
        sw.fail = true
        XCTAssertThrowsError(try store.addAccount(label: "two", token: "tok-two", secrets: secrets)) {
            XCTAssertEqual($0 as? AgentPoolStoreError, .stateWriteFailed)
        }
        XCTAssertEqual(store.snapshot, before, "the state did not advance")
        XCTAssertEqual(secrets.count, 1, "the secret added for two is removed again")
        XCTAssertThrowsError(try store.removeAccount(label: "one", secrets: secrets)) {
            XCTAssertEqual($0 as? AgentPoolStoreError, .stateWriteFailed)
        }
        let id = try XCTUnwrap(store.snapshot.accounts["one"]?.id)
        XCTAssertEqual(try secrets.token(id: id), "tok-one", "remove kept both the account and its secret")
        XCTAssertThrowsError(try store.renameAccount("one", to: "uno")) {
            XCTAssertEqual($0 as? AgentPoolStoreError, .stateWriteFailed)
        }
        XCTAssertEqual(store.snapshot.order, ["one"])
        let now = store.now
        store.mutate { $0.bench("one", claim: "five_hour", until: Int(now) + 60, now: now) }
        XCTAssertEqual(store.snapshot.accounts["one"]?.cooldown["five_hour"], Int(now) + 60, "a bench still holds in memory")
        sw.fail = false
        XCTAssertEqual(AgentPoolStore(directory: dir).snapshot.order, ["one"], "the disk never saw two")
    }

    // QA #734 INFO-10: the usage probe never follows a redirect; the 3xx is its answer.
    func testAgentPoolProbeNeverFollowsARedirect() async throws {
        let second = try AgentPoolFakeServer { _, _ in .respond(200, [], Data()) }
        defer { second.stop() }
        let first = try AgentPoolFakeServer { _, _ in
            .respond(307, [("Location", "http://127.0.0.1:\(second.port)/v1/messages")], Data())
        }
        defer { first.stop() }
        let probe = await AgentPoolUsage.probe(token: "tok-probe", base: URL(string: "http://127.0.0.1:\(first.port)")!, timeout: 10)
        XCTAssertEqual(probe?.status, 307)
        XCTAssertEqual(probe?.limits, [:], "no rate-limit headers: could not answer")
        XCTAssertEqual(first.accepted, 1)
        XCTAssertEqual(second.accepted, 0, "the token never reached the Location host")
    }

    // QA #734: a listener that fails after it was running stops reading "running"; Start works again.
    @MainActor
    func testAgentPoolListenerLostAfterStartIsNotRunning() throws {
        let r = try ccpoolPaneRig()
        guard case .running = r.service.start() else { return XCTFail("\(r.service.status)") }
        XCTAssertTrue(r.model.proxyRunning)
        let stale = try AgentPoolListener.open(port: 0).get()
        defer { stale.cancel() }
        r.service.listenerLost(.posix(.ENETDOWN), from: stale)
        XCTAssertTrue(r.model.proxyRunning, "a listener that is not the live one changes nothing")
        r.service.listenerLost(.posix(.ENETDOWN))
        XCTAssertEqual(r.service.status, .failed(AgentPoolService.reasonLost))
        XCTAssertFalse(r.model.proxyRunning, "the pane offers Start, not Restart")
        XCTAssertEqual(r.model.proxyText, "Not running: " + AgentPoolService.reasonLost)
        XCTAssertTrue(r.log.lines.contains { $0.contains("listener stopped after start") }, "\(r.log.lines)")
        guard case .running = r.service.start() else { return XCTFail("start again: \(r.service.status)") }
    }
}
