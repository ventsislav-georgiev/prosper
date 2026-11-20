import CCPoolKeeperCore
import Foundation
import XCTest
@testable import ProsperApp

/// #1676: the ccpool port keeper. Every keeper here runs in-process (PortKeeper on a temp dir, a fake spawner, a
/// code-sign seam); no row starts the real CCPoolKeeper executable or any process. Ports are 0 (the kernel's pick).
final class CCPoolKeeperTests: XCTestCase {
    private let dead = URL(string: "http://127.0.0.1:9")!

    /// A 0700 dir the keeper accepts (tempDir is 0755), short enough for sun_path.
    private func keeperDir() -> URL { tempDir("kp").appendingPathComponent("k", isDirectory: true) }

    private func service(keeper: CCPoolKeeperLink?, port: UInt16 = 0, probes: KeeperCounter = KeeperCounter()) -> CCPoolService {
        var cfg = CCPoolServiceConfig()
        cfg.port = port
        cfg.upstream = dead
        cfg.keeper = keeper
        cfg.portProbe = { _, _ in probes.bump(); return .free }
        return CCPoolService(config: cfg, store: CCPoolStore(directory: tempDir("st").appendingPathComponent("ccpool")),
                             secrets: CCPoolMemorySecrets(), logger: CCPoolCapturingLogger())
    }

    /// An in-process keeper on `dir`, holding `listening` (owned from here on); its socket is named for `label`.
    /// Shut down at teardown.
    private func keeper(_ listening: Int32, dir: URL, label: UInt16 = 1, control: Int32? = nil, signed: Bool = true,
                        otherUID: Bool = false, idle: DispatchTimeInterval = PortKeeper.idleLimit,
                        exited: XCTestExpectation? = nil, team: String? = "TEAMID0001",
                        accept: (@Sendable (Int32) -> (fd: Int32, err: Int32))? = nil) -> PortKeeper? {
        let k = Self.makeKeeper(listening, dir: dir, label: label, control: control, signed: signed, otherUID: otherUID,
                                idle: idle, exited: exited, team: team, accept: accept)
        if let k { addTeardownBlock { k.queue.sync { k.shutdown() } } }
        return k
    }

    private static func makeKeeper(_ listening: Int32, dir: URL, label: UInt16, control: Int32?, signed: Bool = true,
                                   otherUID: Bool = false, idle: DispatchTimeInterval = PortKeeper.idleLimit,
                                   exited: XCTestExpectation? = nil, team: String? = "TEAMID0001",
                                   accept: (@Sendable (Int32) -> (fd: Int32, err: Int32))? = nil) -> PortKeeper? {
        let port = PortKeeper.boundPort(listening) ?? 0
        let k = PortKeeper(listening: listening, port: port, onExit: { exited?.fulfill() })
        k.signedLikeApp = { _, _ in signed }
        k.ownTeam = { team }
        if let accept { k.acceptCall = accept }
        if otherUID { k.peerUID = { _ in getuid() &+ 1 } }
        k.idleAfter = idle
        guard PortKeeper.secureDir(dir.path), k.start(socketPath: PortKeeper.socketPath(dir: dir.path, port: label), control: control) else {
            return nil
        }
        return k
    }

    /// The app's link as from an app signed with a team (R1676 n14: the test runner has none).
    private func keeperLink(_ dir: URL, _ spawner: @escaping @Sendable (Int32, Int32) -> pid_t? = { _, _ in nil }) -> CCPoolKeeperLink {
        CCPoolKeeperLink(directory: dir, port: 1, spawner: spawner, team: "TEAMID0001")!
    }

    /// One reply byte with an SCM_RIGHTS control message per entry of `messages` (each that entry's fds).
    private static func sendRights(_ sock: Int32, _ messages: [[Int32]]) -> Bool {
        let head = MemoryLayout<cmsghdr>.size
        let total = messages.reduce(0) { $0 + head + 4 * $1.count }
        let ctl = UnsafeMutableRawPointer.allocate(byteCount: total, alignment: 4)
        defer { ctl.deallocate() }
        ctl.initializeMemory(as: UInt8.self, repeating: 0, count: total)
        var off = 0
        for fds in messages {
            ctl.storeBytes(of: cmsghdr(cmsg_len: socklen_t(head + 4 * fds.count), cmsg_level: SOL_SOCKET, cmsg_type: SCM_RIGHTS),
                           toByteOffset: off, as: cmsghdr.self)
            for (i, fd) in fds.enumerated() { ctl.storeBytes(of: fd, toByteOffset: off + head + 4 * i, as: Int32.self) }
            off += head + 4 * fds.count
        }
        var byte = PortKeeper.reply
        return withUnsafeMutablePointer(to: &byte) { b in
            var iov = iovec(iov_base: UnsafeMutableRawPointer(b), iov_len: 1)
            return withUnsafeMutablePointer(to: &iov) { iovp in
                var msg = msghdr(msg_name: nil, msg_namelen: 0, msg_iov: iovp, msg_iovlen: 1,
                                 msg_control: ctl, msg_controllen: socklen_t(total), msg_flags: 0)
                return sendmsg(sock, &msg, 0) == 1
            }
        }
    }

    private static func listener() throws -> CCPoolListener {
        guard case .success(let l) = CCPoolListener.open(port: 0) else { throw XCTSkip("no loopback listener") }
        return l
    }

    private static func connects(_ port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var a = sockaddr_in()
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        a.sin_family = sa_family_t(AF_INET)
        a.sin_port = port.bigEndian
        a.sin_addr.s_addr = UInt32(0x7f00_0001).bigEndian
        return withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
        } }
    }

    /// Connect, send a health request, read to EOF (5 s read timeout). The fd is returned connected for `finish`.
    private static func healthClient(_ port: UInt16) -> Int32? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var a = sockaddr_in()
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        a.sin_family = sa_family_t(AF_INET)
        a.sin_port = port.bigEndian
        a.sin_addr.s_addr = UInt32(0x7f00_0001).bigEndian
        let ok = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
        } }
        let req = Array("GET \(CCPoolService.healthPath) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nConnection: close\r\n\r\n".utf8)
        guard ok, req.withUnsafeBytes({ write(fd, $0.baseAddress, $0.count) }) == req.count else { close(fd); return nil }
        return fd
    }

    private static func finish(_ fd: Int32) -> String {
        defer { close(fd) }
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            out.append(contentsOf: buf.prefix(n))
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// The fake spawner: an in-process keeper on dups of the two fds (posix_spawn's dup2), retained by `box` and
    /// shut down at teardown.
    private func spawner(dir: URL, label: UInt16, box: KeeperBox) -> @Sendable (Int32, Int32) -> pid_t? {
        addTeardownBlock { box.shutdownAll() }
        return { listening, control in
            guard let k = Self.makeKeeper(dup(listening), dir: dir, label: label, control: dup(control)) else { return nil }
            box.add(k)
            return 1
        }
    }

    // SCM_RIGHTS over a socketpair: the received fd is a listener the service starts on and serves from.
    func testHandOffOverSocketpairYieldsAListenerTheServiceStartsOn() throws {
        let l = try Self.listener()
        let port = try XCTUnwrap(l.port?.rawValue)
        var pair: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
        defer { close(pair[0]); close(pair[1]) }
        XCTAssertTrue(PortKeeper.sendFD(pair[0], l.fd))
        let got = try XCTUnwrap(PortKeeper.receiveFD(pair[1]))
        XCTAssertNotEqual(got, l.fd, "a new fd, not the sender's number")
        XCTAssertTrue(fcntl(got, F_GETFD) & FD_CLOEXEC != 0, "close-on-exec")
        l.cancel()   // the first holder goes; the handed fd still holds the port
        let s = service(keeper: nil)
        defer { s.stop() }
        XCTAssertEqual(s.start(listening: got), .running(port: port))
        let c = try XCTUnwrap(Self.healthClient(port))
        XCTAssertTrue(Self.finish(c).hasPrefix("HTTP/1.1 200 OK"))
    }

    // A reply without an fd, or with two, hands out nothing (and the extra fds are closed).
    func testReceiveRefusesAReplyWithoutExactlyOneFD() throws {
        var pair: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
        defer { close(pair[0]); close(pair[1]) }
        var b = PortKeeper.reply
        XCTAssertEqual(write(pair[0], &b, 1), 1)
        XCTAssertTrue(PortKeeper.receiveFD(pair[1]) == nil, "a bare byte carries no fd")
    }

    // R1675 n11: a listener on another port than the configured one is refused like any adopt refusal, fd left open.
    func testStartListeningRefusesAnotherPortThanConfigured() throws {
        let l = try Self.listener()
        defer { l.cancel() }
        let port = try XCTUnwrap(l.port?.rawValue)
        let other: UInt16 = port == UInt16.max ? port - 1 : port + 1
        let log = CCPoolCapturingLogger()
        var cfg = CCPoolServiceConfig()
        cfg.port = other
        cfg.upstream = dead
        let s = CCPoolService(config: cfg, store: CCPoolStore(directory: tempDir("st").appendingPathComponent("ccpool")),
                              secrets: CCPoolMemorySecrets(), logger: log)
        XCTAssertEqual(s.start(listening: l.fd), .failed(CCPoolService.reasonCreate))
        XCTAssertGreaterThanOrEqual(fcntl(l.fd, F_GETFD), 0, "the refused fd is still its owner's")
        XCTAssertEqual(log.lines.filter { $0.contains("another port") }.count, 1, "logged once")
    }

    // A peer of another uid, or one failing the code-sign check, gets nothing; a passing one gets the fd.
    func testPeerWithAnotherUIDOrFailingTheSignCheckGetsNothing() throws {
        for (signed, otherUID) in [(true, true), (false, false)] {
            let l = try Self.listener()
            let dir = keeperDir()
            let k = try XCTUnwrap(keeper(dup(l.fd), dir: dir, signed: signed, otherUID: otherUID))
            l.cancel()
            let link = keeperLink(dir)
            XCTAssertTrue(link.fetch() == nil, "signed \(signed) otherUID \(otherUID)")
            link.detach()
            XCTAssertEqual(k.queue.sync { k.handedOut }, 0)
            XCTAssertEqual(k.queue.sync { k.refused }, 1)
        }
        let l = try Self.listener()
        let dir = keeperDir()
        let k = try XCTUnwrap(keeper(dup(l.fd), dir: dir))
        l.cancel()
        let link = keeperLink(dir)
        let fd = try XCTUnwrap(link.fetch())
        close(fd)
        link.detach()
        XCTAssertEqual(k.queue.sync { k.handedOut }, 1)
        XCTAssertEqual(k.queue.sync { k.refused }, 0)
    }

    // Fail closed: a keeper with no team of its own (ad-hoc or self-signed build) hands the socket to nobody, even a
    // peer the sign seam passes; the service then binds its own socket as with no keeper.
    func testKeeperWithNoTeamRefusesEveryPeer() throws {
        let l = try Self.listener()
        let dir = keeperDir()
        let k = try XCTUnwrap(keeper(dup(l.fd), dir: dir, team: nil))
        l.cancel()
        let link = keeperLink(dir)
        XCTAssertTrue(link.fetch() == nil, "no team: nothing handed out")
        link.detach()
        XCTAssertEqual(k.queue.sync { k.handedOut }, 0)
        XCTAssertEqual(k.queue.sync { k.refused }, 1)
        XCTAssertTrue(PortKeeper.systemPeerToken(-1) == nil, "no token from a bad fd")
    }

    // One keeper per user and port: a second lock fails at once; the lock frees with its holder; an unsafe dir refuses.
    func testSecondKeeperExitsOnTheLock() throws {
        let dir = keeperDir().path
        let first = try XCTUnwrap(PortKeeper.lock(dir: dir, port: 1))
        XCTAssertTrue(PortKeeper.lock(dir: dir, port: 1) == nil, "a second keeper of the same port exits")
        let otherPort = try XCTUnwrap(PortKeeper.lock(dir: dir, port: 2))
        close(otherPort)
        close(first)
        let again = try XCTUnwrap(PortKeeper.lock(dir: dir, port: 1))
        close(again)
        XCTAssertEqual(chmod(dir, 0o755), 0)
        XCTAssertTrue(PortKeeper.lock(dir: dir, port: 1) == nil, "a dir others can read is refused")
    }

    // The idle exit: no timer while an app is connected; one one-shot timer after it leaves, cancelled by a new app,
    // firing once, never repeating.
    func testIdleExitIsOneShotAndFiresOnlyWithNoAppConnected() throws {
        // Connected from the start (the spawning app's socketpair end): nothing armed, nothing fires.
        let l = try Self.listener()
        let dir = keeperDir()
        var pair: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
        let exited = expectation(description: "idle exit")
        let k = try XCTUnwrap(keeper(dup(l.fd), dir: dir, control: pair[1], idle: .milliseconds(300), exited: exited))
        l.cancel()
        Thread.sleep(forTimeInterval: 0.6)
        XCTAssertEqual(k.queue.sync { k.idleArmed }, 0, "no timer while an app is connected")
        XCTAssertEqual(k.queue.sync { k.listenFD } >= 0, true)
        close(pair[0])   // the app goes
        wait(for: [exited], timeout: 5)
        XCTAssertEqual(k.queue.sync { k.idleArmed }, 1)
        XCTAssertEqual(k.queue.sync { k.idleFired }, 1)
        XCTAssertEqual(k.queue.sync { k.listenFD }, -1)

        // Armed with no app, then an app connects before it fires: cancelled, never fires.
        let l2 = try Self.listener()
        let dir2 = keeperDir()
        let k2 = try XCTUnwrap(keeper(dup(l2.fd), dir: dir2, idle: .milliseconds(400)))
        l2.cancel()
        XCTAssertEqual(k2.queue.sync { k2.idleArmed }, 1)
        let link = keeperLink(dir2)
        let fd = try XCTUnwrap(link.fetch())
        close(fd)
        Thread.sleep(forTimeInterval: 0.8)
        XCTAssertEqual(k2.queue.sync { k2.idleFired }, 0, "an app is connected")
        XCTAssertEqual(k2.queue.sync { k2.idleArmed }, 1, "no re-arm, no repeat")
        link.detach()
    }

    // "exit" closes the held fd (the port is unbound), removes the socket file and exits; a fd on another port is refused.
    func testExitClosesTheFD() throws {
        let l = try Self.listener()
        let port = try XCTUnwrap(l.port?.rawValue)
        let dir = keeperDir()
        let exited = expectation(description: "exit")
        let k = try XCTUnwrap(keeper(dup(l.fd), dir: dir, exited: exited))
        l.cancel()
        XCTAssertTrue(Self.connects(port), "the keeper holds the port")
        let link = keeperLink(dir)
        link.exit()
        wait(for: [exited], timeout: 5)
        XCTAssertEqual(k.queue.sync { k.listenFD }, -1)
        XCTAssertFalse(Self.connects(port), "the port is unbound")
        XCTAssertFalse(FileManager.default.fileExists(atPath: link.socketPath))

        let l2 = try Self.listener()
        defer { l2.cancel() }
        let wrong = PortKeeper(listening: dup(l2.fd), port: (l2.port?.rawValue ?? 0) &+ 1, onExit: {})
        XCTAssertFalse(wrong.start(socketPath: PortKeeper.socketPath(dir: keeperDir().path, port: 1), control: nil),
                       "a keeper whose fd is not on its port does not start")
    }

    // #1676 cause: a fresh link's exit reaches a keeper that accepts late (admit runs after the peer would have closed).
    func testFreshLinkExitReachesAKeeperThatAcceptsLate() throws {
        let l = try Self.listener()
        let dir = keeperDir()
        let exited = expectation(description: "exit")
        _ = try XCTUnwrap(keeper(dup(l.fd), dir: dir, exited: exited, accept: { s in
            Thread.sleep(forTimeInterval: 0.2)
            let c = Darwin.accept(s, nil, nil)
            return (c, c >= 0 ? 0 : errno)
        }))
        l.cancel()
        keeperLink(dir).exit()
        wait(for: [exited], timeout: 5)
    }

    // R1676 n25: a spawned link whose keeper is alive but never answers: exit() is bounded by the 2 s receive timeout.
    func testExitOverASpawnedLinkWhoseKeeperNeverAnswersReturns() throws {
        final class Peer: @unchecked Sendable { var fd: Int32 = -1 }
        let peer = Peer()
        let link = keeperLink(keeperDir()) { _, control in peer.fd = dup(control); return 1 }
        XCTAssertTrue(link.spawn(listening: -1))
        defer { close(peer.fd) }
        let done = expectation(description: "exit returned")
        let start = Date()
        DispatchQueue.global().async { link.exit(); done.fulfill() }
        wait(for: [done], timeout: 4)
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
        var b: UInt8 = 0
        XCTAssertEqual(read(peer.fd, &b, 1), 1, "the keeper end got the exit byte")
        XCTAssertEqual(read(peer.fd, &b, 1), 0, "the link dropped its control fd")
    }

    // The service: no keeper answers, so it binds and spawns one with its listener; a second service (the relaunch)
    // fetches that socket with no probe, no bind and no spawn.
    func testServiceFetchesFromAKeeperAndSpawnsOneOnlyWhenNoneAnswers() throws {
        let dir = keeperDir()
        let box = KeeperBox()
        let probes = KeeperCounter()
        let a = service(keeper: keeperLink(dir, spawner(dir: dir, label: 1, box: box)), probes: probes)
        guard case .running(let port) = a.start() else { return XCTFail("first start") }
        XCTAssertEqual(box.count, 1, "one keeper spawned")
        a.stop()
        a.config.keeper?.detach()

        let bProbes = KeeperCounter()
        let b = service(keeper: keeperLink(dir, spawner(dir: dir, label: 1, box: box)), probes: bProbes)
        defer { b.stop(); b.config.keeper?.exit() }
        XCTAssertEqual(b.start(), .running(port: port))
        XCTAssertEqual(bProbes.count, 0, "no probe")
        XCTAssertEqual(box.count, 1, "no second keeper")
        let k = try XCTUnwrap(box.last)
        XCTAssertEqual(k.queue.sync { k.handedOut }, 1)
    }

    // A quit after Sparkle's relaunch notice leaves the keeper holding the port; ccpool off (or a plain quit) tells it
    // to exit.
    func testQuitForAnUpdateKeepsTheKeeperAndTurningOffEndsIt() throws {
        let l = try Self.listener()
        let port = try XCTUnwrap(l.port?.rawValue)
        let dir = keeperDir()
        let exited = expectation(description: "exit")
        let k = try XCTUnwrap(keeper(dup(l.fd), dir: dir, exited: exited))
        l.cancel()
        let relaunch = CCPoolLifecycle(service: service(keeper: keeperLink(dir)))
        relaunch.relaunching = true
        XCTAssertTrue(relaunch.quit(timeout: 5))
        XCTAssertTrue(k.queue.sync { k.listenFD } >= 0, "the update's quit leaves the keeper")
        XCTAssertTrue(Self.connects(port))
        let off = CCPoolLifecycle(service: service(keeper: keeperLink(dir)))
        XCTAssertTrue(off.quit(timeout: 5))
        wait(for: [exited], timeout: 5)
        XCTAssertFalse(Self.connects(port), "the port is released")
    }

    // R1676 n15 (operator 2026-11-19): with no app connected the keeper exits after 60 s, not 15 min.
    func testIdleLimitIsSixtySeconds() {
        XCTAssertEqual(PortKeeper.idleLimit, .seconds(60))
    }

    // R1676 n14: an app with no team of its own gets no link (a keeper would refuse it), so the service binds its own
    // socket exactly as with no keeper and never spawns one.
    func testAppWithNoTeamHasNoKeeperAndNeverSpawnsOne() throws {
        let spawns = KeeperCounter()
        let none = CCPoolKeeperLink(directory: keeperDir(), port: 1, spawner: { _, _ in spawns.bump(); return 1 }, team: nil)
        XCTAssertTrue(none == nil, "no team: no link")
        let s = service(keeper: none)
        defer { s.stop() }
        guard case .running = s.start() else { return XCTFail("binds its own socket") }
        XCTAssertEqual(spawns.count, 0, "no keeper spawned")
        XCTAssertNotNil(CCPoolKeeperLink(directory: keeperDir(), port: 1, spawner: { _, _ in spawns.bump(); return 1 }, team: "TEAMID0001"),
                        "a team: a link")
    }

    // R1676 n17: a reply carrying two fds is refused and every received fd closed (the pipe's write end reaches EOF).
    // Two SCM_RIGHTS messages in one sendmsg are refused by the Darwin kernel (EINVAL); if one ever arrives, every fd
    // of every message is closed too.
    func testReceiveClosesEveryFDOfAReplyWithTwo() throws {
        for messages in [[2], [1, 1]] {
            var pair: [Int32] = [-1, -1]
            XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
            defer { close(pair[0]); close(pair[1]) }
            var p: [Int32] = [-1, -1]
            XCTAssertEqual(pipe(&p), 0)
            defer { close(p[0]) }
            XCTAssertEqual(fcntl(p[0], F_SETFL, O_NONBLOCK), 0)
            let sent = Self.sendRights(pair[0], messages.map { Array(repeating: p[1], count: $0) })
            let err = errno
            close(p[1])
            guard sent else {
                XCTAssertEqual(messages.count, 2, "one message with two fds is sent")
                XCTAssertEqual(err, EINVAL)
                continue
            }
            let got = PortKeeper.receiveFD(pair[1])
            if let got { close(got) }
            XCTAssertTrue(got == nil, "\(messages): refused")
            var b: UInt8 = 0
            XCTAssertEqual(read(p[0], &b, 1), 0, "\(messages): every received copy of the write end is closed")
        }
    }

    // R1676 n18: accept on the control socket failing with EMFILE (the connection stays queued) pauses the source for
    // 100 ms per failure instead of spinning; once accept works the next app is served.
    func testControlAcceptErrorPausesInsteadOfSpinning() throws {
        let l = try Self.listener()
        let dir = keeperDir()
        let calls = KeeperCounter()
        let failing = KeeperFlag()
        let k = try XCTUnwrap(keeper(dup(l.fd), dir: dir, accept: { s in
            calls.bump()
            if failing.on { return (-1, EMFILE) }
            let c = Darwin.accept(s, nil, nil)
            return (c, c >= 0 ? 0 : errno)
        }))
        l.cancel()
        let raw = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(raw) }
        XCTAssertEqual(PortKeeper.withUnixAddr(PortKeeper.socketPath(dir: dir.path, port: 1), { Darwin.connect(raw, $0, $1) }), 0)
        Thread.sleep(forTimeInterval: 0.35)
        let (spun, pauses) = k.queue.sync { (calls.count, k.pauses) }
        XCTAssertGreaterThanOrEqual(spun, 1)
        XCTAssertLessThanOrEqual(spun, 8, "one accept per 100 ms pause, not a spin")
        XCTAssertEqual(pauses, spun, "every failure pauses")
        failing.on = false
        let link = keeperLink(dir)
        let fd = try XCTUnwrap(link.fetch(), "the source resumed")
        close(fd)
        link.detach()
        XCTAssertEqual(k.queue.sync { k.handedOut }, 1)
    }

    // R1676 n19: a keeper socket path too long for sun_path is refused by the app, never connected truncated.
    func testLinkRefusesASocketPathTooLongForSunPath() throws {
        let base = tempDir("kp")
        let room = 102 - base.path.utf8.count
        guard room >= 1 else { throw XCTSkip("temp dir too long for this row") }
        let link = keeperLink(base.appendingPathComponent(String(repeating: "a", count: room + 8), isDirectory: true))
        XCTAssertFalse(PortKeeper.fitsUnixAddr(link.socketPath))
        let truncated = base.path + "/" + String(repeating: "a", count: room)
        XCTAssertEqual(String(decoding: Array(link.socketPath.utf8.prefix(103)), as: UTF8.self), truncated)
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(s); unlink(truncated) }
        XCTAssertEqual(PortKeeper.withUnixAddr(truncated, { Darwin.bind(s, $0, $1) }), 0)
        XCTAssertEqual(listen(s, 4), 0)
        XCTAssertEqual(fcntl(s, F_SETFL, O_NONBLOCK), 0)
        XCTAssertTrue(link.fetch() == nil)
        link.exit()
        let c = accept(s, nil, nil)
        if c >= 0 { close(c) }
        XCTAssertEqual(c, -1, "nothing connected to the truncated path")
    }

    // MEASUREMENT (the operator's done-condition): the first holder closes its fd while the keeper holds a dup; the
    // port is never unbound (every connect in the gap succeeds) and a request made in the gap waits in the backlog
    // until the next holder fetches the socket. Prints the backlog wait.
    func testRelaunchHandOffNeverUnbindsThePortAndPrintsTheBacklogWait() throws {
        let dir = keeperDir()
        let box = KeeperBox()
        let a = service(keeper: keeperLink(dir, spawner(dir: dir, label: 1, box: box)))
        guard case .running(let port) = a.start() else { return XCTFail("first start") }
        XCTAssertTrue(Self.connects(port))
        a.stop()   // the app quits: its fd closes
        a.config.keeper?.detach()
        let gapStart = Date()
        let queued = try XCTUnwrap(Self.healthClient(port), "a request in the gap is accepted into the backlog")
        var tries = 0
        var refused = 0
        while Date().timeIntervalSince(gapStart) < 0.3, tries < 40 {   // the relaunch stand-in, bounded
            tries += 1
            if !Self.connects(port) { refused += 1 }
            Thread.sleep(forTimeInterval: 0.01)
        }
        let b = service(keeper: keeperLink(dir, spawner(dir: dir, label: 1, box: box)))
        defer { b.stop(); b.config.keeper?.exit() }
        XCTAssertEqual(b.start(), .running(port: port))
        let reply = Self.finish(queued)
        let wait = Date().timeIntervalSince(gapStart)
        print("MEASURE ccpool keeper: unbound connects \(refused) of \(tries), backlog wait \(Int(wait * 1000)) ms")
        XCTAssertEqual(refused, 0, "the port is never unbound")
        XCTAssertTrue(tries > 0)
        XCTAssertTrue(reply.hasPrefix("HTTP/1.1 200 OK"), "the queued request is served by the next holder")
        XCTAssertEqual(box.count, 1)
    }
}

final class KeeperCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    var count: Int { lock.withLock { n } }
    func bump() { lock.withLock { n += 1 } }
}

final class KeeperBox: @unchecked Sendable {
    private let lock = NSLock()
    private var keepers: [PortKeeper] = []
    var count: Int { lock.withLock { keepers.count } }
    var last: PortKeeper? { lock.withLock { keepers.last } }
    func add(_ k: PortKeeper) { lock.withLock { keepers.append(k) } }
    func shutdownAll() { lock.withLock { keepers }.forEach { k in k.queue.sync { k.shutdown() } } }
}

final class KeeperFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = true
    var on: Bool {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}
