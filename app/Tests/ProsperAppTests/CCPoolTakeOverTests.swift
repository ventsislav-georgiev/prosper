import Darwin
import XCTest
@testable import ProsperApp

/// A scripted port probe: answers in order, the last answer repeats; counts every call.
final class CCPoolProbeScript: @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [CCPoolPortProbe.Result]
    private var n = 0
    init(_ answers: [CCPoolPortProbe.Result]) { self.answers = answers }
    func next() -> CCPoolPortProbe.Result {
        lock.withLock {
            n += 1
            return answers.count > 1 ? answers.removeFirst() : answers[0]
        }
    }
    var calls: Int { lock.withLock { n } }
}

/// #1665: a scripted listensOn: true for the first `listening` calls, then false; counts every call.
final class CCPoolListenScript: @unchecked Sendable {
    private let lock = NSLock()
    private let listening: Int
    private var n = 0
    init(listening: Int) { self.listening = listening }
    func next() -> Bool { lock.withLock { n += 1; return n <= listening } }
    var calls: Int { lock.withLock { n } }
}

/// The signal seam's recorder: nothing is ever sent to a process.
final class CCPoolSignalRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _sent: [String] = []
    /// "pid:signal" per call, in order.
    var sent: [String] { lock.withLock { _sent } }
    func record(_ pid: pid_t, _ sig: Int32) -> Bool {
        lock.withLock { _sent.append("\(pid):\(sig)") }
        return true
    }
}

/// #1660 "Stop ccpool and start": the probe and the signal are fakes; no process is ever signalled.
/// A row that reaches the bind uses a free ephemeral loopback port; the others never bind.
final class CCPoolTakeOverTests: XCTestCase {
    private let dead = URL(string: "http://127.0.0.1:9")!

    /// A loopback port nothing listens on: bound by the kernel's pick, then closed at once.
    private func freePort() -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { XCTFail("socket"); return 0 }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ok = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, len) == 0 && getsockname(fd, $0, &len) == 0 }
        }
        XCTAssertTrue(ok, "bind")
        return UInt16(bigEndian: addr.sin_port)
    }

    private func service(port: UInt16, probe: CCPoolProbeScript, signals: CCPoolSignalRecorder,
                         owned: @escaping @Sendable (pid_t) -> Bool = { _ in true },
                         listens: (@Sendable (pid_t, UInt16) -> Bool)? = nil,
                         ceiling: TimeInterval = 0.3, afterListen: TimeInterval = 30, pids: [pid_t] = [], parent: [pid_t: pid_t] = [:],
                         exe: [pid_t: String] = [:], args: [pid_t: [String]] = [:]) -> CCPoolService {
        var cfg = CCPoolServiceConfig()
        cfg.port = port
        cfg.upstream = dead
        cfg.portProbe = { _, _ in probe.next() }
        cfg.signal = { signals.record($0, $1) }
        cfg.ownedByUser = owned
        // Default fake: every pid listens on the configured port, and only on that one.
        cfg.listensOn = listens ?? { _, p in p == port }
        cfg.takeOverCeiling = ceiling
        cfg.takeOverAfterListenBound = afterListen
        cfg.takeOverPoll = 0.05
        // #1665: fake processes only; no row reads a real pid's parent, path or argv.
        cfg.userPids = { pids }
        cfg.parentPid = { parent[$0] }
        cfg.executable = { exe[$0] }
        cfg.argv = { args[$0] ?? [] }
        let svc = CCPoolService(config: cfg, store: CCPoolStore(directory: tempDir()), secrets: CCPoolMemorySecrets(),
                                logger: CCPoolCapturingLogger())
        addTeardownBlock { svc.stop() }
        return svc
    }

    func testTakeOverSignalsTheProbedCCPoolOnceThenStarts() {
        let port = freePort()
        let probe = CCPoolProbeScript([.ccpool(pid: 4242, impl: "python"), .free])
        let signals = CCPoolSignalRecorder()
        // #1665: listens at the pre-signal check and one wait tick, then its socket is closed.
        let listens = CCPoolListenScript(listening: 2)
        let svc = service(port: port, probe: probe, signals: signals, listens: { _, _ in listens.next() })
        XCTAssertEqual(svc.takeOver(pid: 4242, bindRetry: 0), .started(.running(port: port)))
        XCTAssertEqual(signals.sent, ["4242:\(SIGTERM)"], "SIGTERM to the probed pid, once")
        XCTAssertEqual(probe.calls, 3, "re-probe, one wait probe once the socket closed (#1714), then start's own probe")
        XCTAssertEqual(listens.calls, 3, "pre-signal check, one tick still listening, one tick closed")
    }

    func testTakeOverStopsWaitingAndStartsNothingWhenTheProxyIsNoLongerWanted() {
        let port = freePort()
        let probe = CCPoolProbeScript([.ccpool(pid: 4242, impl: "python"), .free])
        let signals = CCPoolSignalRecorder()
        let polls = CCPoolListenScript(listening: 1000)  // never closes its socket
        let svc = service(port: port, probe: probe, signals: signals, listens: { _, _ in polls.next() }, ceiling: 30)
        let wanted = CCPoolListenScript(listening: 3)  // wanted at three checks, then a toggle-off
        let began = Date()
        XCTAssertEqual(svc.takeOver(pid: 4242, bindRetry: 0, stillWanted: { wanted.next() }), .started(svc.status))
        XCTAssertLessThan(Date().timeIntervalSince(began), 5, "the loop exits within a tick, not at the ceiling")
        XCTAssertEqual(probe.calls, 1, "no start: start's own probe never ran")
        XCTAssertEqual(signals.sent, ["4242:\(SIGTERM)"])
        if case .running = svc.status { XCTFail("nothing bound") }
    }

    func testProcessArgvOfThisProcessIsItsCommandLine() {
        XCTAssertEqual(CCPoolService.processArgv(getpid()), CommandLine.arguments)
    }

    func testTakeOverNeverSignalsAHolderTheReprobeDidNotName() {
        let port = freePort()
        let rows: [(String, CCPoolPortProbe.Result, CCPoolService.TakeOver)] = [
            ("port freed meanwhile", .free, .started(.running(port: port))),
            ("another ccpool pid now", .ccpool(pid: 5151, impl: "python"), .started(.heldByCCPool(pid: 5151))),
            ("ccpool with no pid", .ccpool(pid: nil, impl: nil), .started(.heldByCCPool(pid: nil))),
            ("not ccpool any more", .other, .started(.heldByOther)),
        ]
        for (name, now, want) in rows {
            let signals = CCPoolSignalRecorder()
            let svc = service(port: port, probe: CCPoolProbeScript([now]), signals: signals)
            XCTAssertEqual(svc.takeOver(pid: 4242, bindRetry: 0), want, name)
            XCTAssertEqual(signals.sent, [], name)
            svc.stop()
        }
    }

    func testTakeOverThatNeverFreesStopsAtTheCeilingWithOneSignal() {
        // Frees only on the 200th probe: far past the 0.3 s ceiling at a 0.05 s poll.
        let probe = CCPoolProbeScript(Array(repeating: .ccpool(pid: 4242, impl: "python"), count: 199) + [.free])
        let signals = CCPoolSignalRecorder()
        let svc = service(port: 47_013, probe: probe, signals: signals)
        XCTAssertEqual(svc.takeOver(pid: 4242, bindRetry: 0), .didNotStop(pid: 4242))
        XCTAssertEqual(signals.sent, ["4242:\(SIGTERM)"], "one SIGTERM, never a second signal or SIGKILL")
        XCTAssertEqual(svc.status, .heldByCCPool(pid: 4242))
        XCTAssertTrue(probe.calls < 30, "bounded poll, not a busy loop: \(probe.calls)")
    }

    func testTakeOverNeverSignalsPidOneOwnPidOrAnotherUsersPid() {
        let own = Int(getpid())
        for pid in [1, 0, -7, own, Int(Int32.max) + 1] {
            let signals = CCPoolSignalRecorder()
            let svc = service(port: 47_014, probe: CCPoolProbeScript([.ccpool(pid: pid, impl: "python")]), signals: signals)
            XCTAssertEqual(svc.takeOver(pid: pid, bindRetry: 0), .refused(pid: pid), "pid \(pid)")
            XCTAssertEqual(signals.sent, [], "pid \(pid)")
        }
        let signals = CCPoolSignalRecorder()
        let svc = service(port: 47_014, probe: CCPoolProbeScript([.ccpool(pid: 4242, impl: "python")]), signals: signals,
                          owned: { _ in false })
        XCTAssertEqual(svc.takeOver(pid: 4242, bindRetry: 0), .refused(pid: 4242))
        XCTAssertEqual(signals.sent, [], "another user's ccpool is never signalled")
    }

    func testTakeOverNeverSignalsAPidWithoutAListeningSocketOnThePort() {
        let rows: [(String, @Sendable (pid_t, UInt16) -> Bool)] = [
            ("no listening socket", { _, _ in false }),
            ("listens on another port only", { _, p in p == 47_020 &+ 1 }),
            ("another pid listens", { pid, p in pid == 5151 && p == 47_020 }),
        ]
        for (name, listens) in rows {
            let signals = CCPoolSignalRecorder()
            let svc = service(port: 47_020, probe: CCPoolProbeScript([.ccpool(pid: 4242, impl: "python")]), signals: signals,
                              listens: listens)
            XCTAssertEqual(svc.takeOver(pid: 4242, bindRetry: 0), .refused(pid: 4242), name)
            XCTAssertEqual(signals.sent, [], name)
            XCTAssertEqual(svc.status, .heldByCCPool(pid: 4242), name)
        }
    }

    /// The real libproc check, on a socket this test opens itself. It only reads; nothing is signalled.
    func testListensOnLoopbackFindsOnlyAListeningSocketOnThatPort() {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return XCTFail("socket") }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, len) == 0 && getsockname(fd, $0, &len) == 0 }
        }
        XCTAssertTrue(bound, "bind")
        let port = UInt16(bigEndian: addr.sin_port)
        let me = getpid()
        XCTAssertFalse(CCPoolService.listensOnLoopback(me, port), "bound but not listening")
        XCTAssertEqual(listen(fd, 1), 0)
        XCTAssertTrue(CCPoolService.listensOnLoopback(me, port), "this process listens on 127.0.0.1:\(port)")
        XCTAssertFalse(CCPoolService.listensOnLoopback(me, freePort()), "a port nobody holds")
        XCTAssertFalse(CCPoolService.listensOnLoopback(1, port), "launchd does not hold this socket")
    }

    func testTakeOverDefaultSignalRefusesUnderTestAndOwnerCheckReadsTheUid() {
        // Signal 0 delivers nothing (an existence check): even a broken guard sends no signal here.
        XCTAssertFalse(CCPoolServiceConfig().signal(getpid(), 0), "the production seam never signals under XCTest")
        XCTAssertTrue(CCPoolService.runsAsCurrentUser(getpid()))
        XCTAssertFalse(CCPoolService.runsAsCurrentUser(1), "launchd runs as root")
    }

    func testTakeOverReportsTheNewHolderWhenTheSignalledPidStopsListening() {
        let rows: [(String, CCPoolPortProbe.Result, CCPoolService.Status)] = [
            ("a new ccpool pid", .ccpool(pid: 5353, impl: "python"), .heldByCCPool(pid: 5353)),
            ("another program", .other, .heldByOther),
        ]
        for (name, later, want) in rows {
            // #1665: the re-probe names 4242; it stops listening after the signal; start's probe finds the new holder.
            let probe = CCPoolProbeScript([.ccpool(pid: 4242, impl: "python"), later])
            let signals = CCPoolSignalRecorder()
            let listens = CCPoolListenScript(listening: 1)
            let svc = service(port: 47_021, probe: probe, signals: signals, listens: { _, _ in listens.next() })
            XCTAssertEqual(svc.takeOver(pid: 4242, bindRetry: 0), .started(want), name)
            XCTAssertEqual(svc.status, want, name)
            XCTAssertEqual(signals.sent, ["4242:\(SIGTERM)"], name)
            XCTAssertTrue(probe.calls < 30, "\(name): \(probe.calls)")
            // #1714: a new ccpool ends the wait at once (re-probe, one wait probe, start's probe), "other" waits to the ceiling.
            if case .heldByCCPool = want { XCTAssertEqual(probe.calls, 3, name) }
        }
    }

    func testLifecycleTakesOverOnlyWhileTheProxyShouldRun() async throws {
        let signals = CCPoolSignalRecorder()
        let svc = service(port: 47_015, probe: CCPoolProbeScript([.ccpool(pid: 4242, impl: "python")]), signals: signals)
        try svc.store.addAccount(label: "a", token: "tok-a", secrets: svc.secrets)
        let lc = CCPoolLifecycle(service: svc)
        lc.live = false
        let off = await lc.takeOver(pid: 4242)
        XCTAssertEqual(off, .started(.stopped))
        XCTAssertEqual(signals.sent, [], "a stopped extension never signals")
        lc.live = true
        let on = await lc.takeOver(pid: 4242)
        XCTAssertEqual(on, .didNotStop(pid: 4242))
        XCTAssertEqual(signals.sent, ["4242:\(SIGTERM)"])
    }

    @MainActor
    func testPaneOffersStopCCPoolAndStartThenSaysWhenItDidNotStop() async throws {
        let r = try ccpoolPaneRig()
        try r.add(["personal"])
        let probe = CCPoolProbeScript([.ccpool(pid: 4242, impl: "python")])
        let signals = CCPoolSignalRecorder()
        let svc = service(port: 47_016, probe: probe, signals: signals)
        XCTAssertEqual(svc.start(), .heldByCCPool(pid: 4242))
        let m = CCPoolPaneModel(store: r.store, secrets: r.secrets, service: svc, logger: r.log, defaults: r.defaults,
                                vaultURL: r.vault)
        XCTAssertEqual(m.proxyButtonTitle, "Stop ccpool and start")
        XCTAssertEqual(m.proxyText, "Another ccpool proxy (pid 4242) holds port 47016. "
                       + "Stop ccpool and start stops it and starts Prosper's proxy on the same port.")
        XCTAssertEqual(signals.sent, [], "showing the button signals nothing")

        await m.proxyButtonAction().value
        XCTAssertEqual(signals.sent, ["4242:\(SIGTERM)"])
        XCTAssertEqual(m.stuckPid, 4242)
        XCTAssertEqual(m.proxyText, "ccpool (pid 4242) did not stop; quit it, then Start proxy.")
        XCTAssertEqual(m.proxyButtonTitle, "Start proxy")
        XCTAssertFalse(m.proxyBusy)

        // "Start proxy" after that is a plain start: re-probed, never signalled again.
        await m.proxyButtonAction().value
        XCTAssertEqual(signals.sent.count, 1)
        XCTAssertTrue(m.stuckPid == nil)
        XCTAssertEqual(m.proxyButtonTitle, "Stop ccpool and start", "offered again for the next click")
    }

    @MainActor
    func testPaneNeverOffersToStopAnotherProgramOrItsOwnPid() async throws {
        let r = try ccpoolPaneRig()
        try r.add(["personal"])
        let signals = CCPoolSignalRecorder()
        let other = service(port: 47_017, probe: CCPoolProbeScript([.other]), signals: signals)
        let m = CCPoolPaneModel(store: r.store, secrets: r.secrets, service: other, logger: r.log, defaults: r.defaults,
                                vaultURL: r.vault)
        await m.proxyButtonAction().value
        XCTAssertEqual(other.status, .heldByOther)
        XCTAssertEqual(m.proxyButtonTitle, "Start proxy")
        XCTAssertEqual(m.proxyText, "Port 47017 is in use by another program")
        await m.proxyButtonAction().value
        XCTAssertEqual(signals.sent, [], "a program that is not ccpool is never signalled")

        let own = Int(getpid())
        let mine = service(port: 47_018, probe: CCPoolProbeScript([.ccpool(pid: own, impl: "prosper")]), signals: signals)
        let m2 = CCPoolPaneModel(store: r.store, secrets: r.secrets, service: mine, logger: r.log, defaults: r.defaults,
                                 vaultURL: r.vault)
        await m2.proxyButtonAction().value
        XCTAssertEqual(mine.status, .heldByCCPool(pid: own))
        XCTAssertEqual(m2.proxyButtonTitle, "Start proxy")
        XCTAssertEqual(m2.proxyText, "Another ccpool proxy (pid \(own)) holds port 47018. Quit it, then Start proxy.")
        await m2.proxyButtonAction().value
        XCTAssertEqual(signals.sent, [])
    }

    // MARK: #1665 a draining Python proxy under a respawn loop

    private let loopArgv = ["zsh", "-c", "while true; do python3 \"$dir/ccpool_proxy.py\" \"$port\" >>\"$log\" 2>&1; sleep 2; done"]
    private let proxyArgv = ["/usr/bin/python3", "/Users/example/ccpool/ccpool_proxy.py", "47022"]

    func testTakeOverSignalsTheRespawnLoopBeforeTheHolder() {
        let port = freePort()
        let signals = CCPoolSignalRecorder()
        let listens = CCPoolListenScript(listening: 2)
        let svc = service(port: port, probe: CCPoolProbeScript([.ccpool(pid: 4242, impl: "python"), .free]), signals: signals,
                          listens: { _, _ in listens.next() }, parent: [4242: 4000], exe: [4000: "/bin/zsh"],
                          args: [4000: loopArgv, 4242: proxyArgv])
        XCTAssertEqual(svc.takeOver(pid: 4242, bindRetry: 0), .started(.running(port: port)))
        XCTAssertEqual(signals.sent, ["4000:\(SIGTERM)", "4242:\(SIGTERM)"], "the loop first, then the proxy; SIGTERM only")
    }

    func testTakeOverNeverSignalsAParentThatIsNotTheLoop() {
        let rows: [(String, pid_t, String, [String], @Sendable (pid_t) -> Bool)] = [
            ("launchd", 1, "/sbin/launchd", loopArgv, { _ in true }),
            ("not a shell", 4000, "/usr/bin/python3", loopArgv, { _ in true }),
            ("a login shell, no loop", 4000, "/bin/zsh", ["-zsh"], { _ in true }),
            ("another user's shell", 4000, "/bin/zsh", loopArgv, { $0 != 4000 }),
            ("this process's parent", getppid(), "/bin/zsh", loopArgv, { _ in true }),
            ("this process", getpid(), "/bin/zsh", loopArgv, { _ in true }),
        ]
        for (name, pp, path, argv, owned) in rows {
            let signals = CCPoolSignalRecorder()
            let svc = service(port: 47_024, probe: CCPoolProbeScript([.ccpool(pid: 4242, impl: "python")]), signals: signals,
                              owned: owned, parent: [4242: pp], exe: [pp: path], args: [pp: argv])
            XCTAssertEqual(svc.takeOver(pid: 4242, bindRetry: 0), .didNotStop(pid: 4242), name)
            XCTAssertEqual(signals.sent, ["4242:\(SIGTERM)"], "\(name): only the holder")
        }
    }

    func testTakeOverWaitsForTheSocketNotTheHealthAnswer() {
        let port = freePort()
        // The health answer is gone right after the signal (free), but the socket listens for 4 more ticks.
        let probe = CCPoolProbeScript([.ccpool(pid: 4242, impl: "python"), .free])
        let signals = CCPoolSignalRecorder()
        let listens = CCPoolListenScript(listening: 5)
        let svc = service(port: port, probe: probe, signals: signals, listens: { _, _ in listens.next() }, ceiling: 5)
        XCTAssertEqual(svc.takeOver(pid: 4242, bindRetry: 0), .started(.running(port: port)))
        XCTAssertEqual(listens.calls, 6, "no start until listensOn flips; one call per tick, not a busy loop")
        XCTAssertEqual(probe.calls, 3, "re-probe, one wait probe after listensOn flips (#1714), start's own probe: never while it listens")
        XCTAssertEqual(CCPoolServiceConfig().takeOverCeiling, 600, "a draining proxy gets 600 s by default")
        XCTAssertEqual(signals.sent, ["4242:\(SIGTERM)"])
    }

    func testCCPoolArgvRecognition() {
        XCTAssertTrue(CCPoolService.isCCPoolArgv(proxyArgv))
        XCTAssertTrue(CCPoolService.isCCPoolArgv(["ccpool", "serve"]))
        XCTAssertTrue(CCPoolService.isCCPoolArgv(["/bin/bash", "/Users/example/bin/ccpool", "serve"]))
        XCTAssertFalse(CCPoolService.isCCPoolArgv(["grep", "ccpool"]))
        XCTAssertFalse(CCPoolService.isCCPoolArgv(["/usr/bin/python3", "-m", "http.server", "47022"]))
        XCTAssertFalse(CCPoolService.isCCPoolArgv([]))
    }

    @MainActor
    func testArgvRecognizedHolderOffersTakeOverWithoutAHealthAnswer() async throws {
        let r = try ccpoolPaneRig()
        try r.add(["personal"])
        let signals = CCPoolSignalRecorder()
        // The holder answers no health GET (draining): the probe says "other".
        let svc = service(port: 47_022, probe: CCPoolProbeScript([.other]), signals: signals,
                          listens: { pid, p in pid == 4242 && p == 47_022 }, pids: [1, getpid(), 3131, 4242],
                          args: [3131: ["/bin/zsh"], 4242: proxyArgv])
        XCTAssertEqual(svc.start(), .heldByCCPool(pid: 4242))
        let m = CCPoolPaneModel(store: r.store, secrets: r.secrets, service: svc, logger: r.log, defaults: r.defaults,
                                vaultURL: r.vault)
        XCTAssertEqual(m.proxyButtonTitle, "Stop ccpool and start")
        await m.proxyButtonAction().value
        XCTAssertEqual(signals.sent, ["4242:\(SIGTERM)"], "the argv-recognized holder is the one signalled")

        let other = service(port: 47_025, probe: CCPoolProbeScript([.other]), signals: signals,
                            listens: { pid, p in pid == 4242 && p == 47_025 }, pids: [4242],
                            args: [4242: ["/usr/bin/python3", "-m", "http.server", "47025"]])
        XCTAssertEqual(other.start(), .heldByOther, "a listener whose argv is not ccpool stays another program")
    }

    func testBindFailureReasonIsLoggedOncePerStart() throws {
        XCTAssertEqual(CCPoolService.errorWord(.posix(.EADDRINUSE)), "EADDRINUSE")
        XCTAssertEqual(CCPoolService.errorWord(.posix(.ENOENT)), "errno \(POSIXErrorCode.ENOENT.rawValue)", "an unlisted code is its number")
        // Bound, not listening: connect is refused and bind fails with EADDRINUSE (CCPoolFollowUpTests' staging).
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw XCTSkip("no socket") }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, len) == 0 && getsockname(fd, $0, &len) == 0 }
        }
        guard bound else { throw XCTSkip("bind failed") }
        var cfg = CCPoolServiceConfig()
        cfg.port = UInt16(bigEndian: addr.sin_port)
        cfg.upstream = dead
        cfg.portProbe = { _, _ in .free }
        let log = CCPoolCapturingLogger()
        let svc = CCPoolService(config: cfg, store: CCPoolStore(directory: tempDir()), secrets: CCPoolMemorySecrets(), logger: log)
        defer { svc.stop() }
        XCTAssertEqual(svc.start(bindRetry: 0.5), .heldByOther)
        let ticks = log.lines.filter { $0.contains("listener did not start") }.count
        XCTAssertGreaterThanOrEqual(ticks, 2, "the retry ran several ticks: \(log.lines)")
        XCTAssertEqual(log.lines.filter { $0.contains("bind failed: EADDRINUSE") }.count, 1, "once per start: \(log.lines)")
    }

    func testBindRetryOutlastsTimeWaitAndStartsOnceThePortFrees() throws {
        XCTAssertGreaterThanOrEqual(CCPoolService.timeWaitRetry, 31, "TIME_WAIT is 2 x MSL = 2 x 15 s (net.inet.tcp.msl 15000 ms) = 30 s: the bind retry must outlast it")
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw XCTSkip("no socket") }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, len) == 0 && getsockname(fd, $0, &len) == 0 }
        }
        guard bound else { close(fd); throw XCTSkip("bind failed") }
        var cfg = CCPoolServiceConfig()
        cfg.port = UInt16(bigEndian: addr.sin_port)
        cfg.upstream = dead
        cfg.portProbe = { _, _ in .free }
        let log = CCPoolCapturingLogger()
        let svc = CCPoolService(config: cfg, store: CCPoolStore(directory: tempDir()), secrets: CCPoolMemorySecrets(), logger: log)
        defer { svc.stop() }
        // The port frees after a few failed ticks (stands in for TIME_WAIT expiring), well inside the retry window.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.7) { close(fd) }
        XCTAssertEqual(svc.start(bindRetry: CCPoolService.timeWaitRetry), .running(port: cfg.port))
        let ticks = log.lines.filter { $0.contains("listener did not start") }.count
        XCTAssertGreaterThanOrEqual(ticks, 2, "EADDRINUSE for several ticks, then it bound: \(log.lines)")
    }

    @MainActor
    func testTakeOverLinkRunsTheButtonPathOnlyWhileTheProxyShouldRun() async throws {
        let dir = tempDir()
        let probe = CCPoolProbeScript([.ccpool(pid: 4242, impl: "python")])
        let signals = CCPoolSignalRecorder()
        var cfg = CCPoolServiceConfig()
        cfg.port = 47_023
        cfg.upstream = dead
        cfg.portProbe = { _, _ in probe.next() }
        cfg.signal = { signals.record($0, $1) }
        cfg.ownedByUser = { _ in true }
        cfg.listensOn = { _, p in p == 47_023 }
        cfg.parentPid = { _ in nil }
        cfg.takeOverCeiling = 0.3
        cfg.takeOverPoll = 0.05
        let rt = CCPoolRuntime(directory: dir.appendingPathComponent("ccpool"), secrets: CCPoolMemorySecrets(), config: cfg,
                               vaultURL: dir.appendingPathComponent("old"), defaults: scratchDefaults("ccpool-link"),
                               probeBase: dead, logger: CCPoolCapturingLogger())
        let svc = rt.service
        addTeardownBlock { svc.stop() }
        let link = URL(string: "prosper://ccpool/takeover")!
        XCTAssertTrue(CCPoolRuntime.openLink(link, runtime: nil) == nil, "no runtime built: nothing")
        XCTAssertTrue(CCPoolRuntime.openLink(link, runtime: rt) == nil, "extension not live: nothing")
        rt.lifecycle.live = true
        XCTAssertTrue(CCPoolRuntime.openLink(link, runtime: rt) == nil, "no account: nothing")
        try rt.store.addAccount(label: "a", token: "tok-a", secrets: rt.secrets)
        XCTAssertTrue(CCPoolRuntime.openLink(URL(string: "prosper://ccpool/other")!, runtime: rt) == nil, "unknown path")
        XCTAssertEqual(probe.calls, 0, "nothing probed")
        XCTAssertEqual(signals.sent, [])

        // #2012: the new host reaches the same handler as the ccpool alias above, and the log names the link used.
        let task = CCPoolRuntime.openLink(URL(string: "prosper://agentpool/takeover")!, runtime: rt)
        XCTAssertTrue(task != nil)
        await task?.value
        XCTAssertTrue((rt.service.logger as? CCPoolCapturingLogger)?.lines.contains("-: prosper://agentpool/takeover") == true)
        XCTAssertEqual(signals.sent, ["4242:\(SIGTERM)"], "the pane button's takeover ran")
        XCTAssertEqual(rt.model.stuckPid, 4242, "the pane shows the outcome")
        XCTAssertFalse(rt.model.proxyBusy)
    }

    // MARK: #1714 the signalled pid stopped listening, the port is not free yet

    func testTakeOverWaitsForThePortAfterThePidStopsListeningThenBinds() {
        let port = freePort()
        // Out of LISTEN on the first wait tick, but the port answers no health GET twice more (a socket still
        // closing): the parent took the first "other" for another program and bound nothing (the 2026-11-20 outage).
        let probe = CCPoolProbeScript([.ccpool(pid: 4242, impl: "python"), .other, .other, .free])
        let signals = CCPoolSignalRecorder()
        let listens = CCPoolListenScript(listening: 1)
        let svc = service(port: port, probe: probe, signals: signals, listens: { _, _ in listens.next() }, ceiling: 5)
        XCTAssertEqual(svc.takeOver(pid: 4242, bindRetry: 0), .started(.running(port: port)))
        XCTAssertEqual(probe.calls, 5, "re-probe, one probe per wait tick (other, other, free), start's own probe")
        XCTAssertEqual(listens.calls, 4, "pre-signal check, then one per wait tick")
        XCTAssertEqual(signals.sent, ["4242:\(SIGTERM)"], "one SIGTERM, never a second signal")
    }

    // MARK: #1720 a holder that is not ccpool keeps the port after the flip

    func testTakeOverReportsAnotherHolderAtTheAfterListenBoundNotTheCeiling() {
        // Bound 0: the first wait tick out of LISTEN that still sees "other" ends the wait; start() reports it.
        let probe = CCPoolProbeScript([.ccpool(pid: 4242, impl: "python"), .other])
        let signals = CCPoolSignalRecorder()
        let listens = CCPoolListenScript(listening: 1)
        let began = Date()
        let svc = service(port: 47_022, probe: probe, signals: signals, listens: { _, _ in listens.next() },
                          ceiling: 3, afterListen: 0)
        XCTAssertEqual(svc.takeOver(pid: 4242, bindRetry: 0), .started(.heldByOther))
        XCTAssertEqual(svc.status, .heldByOther)
        XCTAssertEqual(probe.calls, 3, "re-probe, one wait probe (other, bound reached), start's own probe")
        XCTAssertEqual(listens.calls, 2, "pre-signal check, one wait tick")
        XCTAssertLessThan(Date().timeIntervalSince(began), 2.5, "not held to the 3 s ceiling")
        XCTAssertEqual(signals.sent, ["4242:\(SIGTERM)"])
        XCTAssertEqual(CCPoolServiceConfig().takeOverAfterListenBound, 30, "30 s after the flip by default")
    }

    func testTakeOverAfterListenBoundCountsTicksFromTheFlipAndStaysBounded() {
        // Still listening for 4 ticks (the ceiling governs that phase), then "other" until the 0.2 s bound.
        let probe = CCPoolProbeScript([.ccpool(pid: 4242, impl: "python"), .other])
        let signals = CCPoolSignalRecorder()
        let listens = CCPoolListenScript(listening: 5)
        let svc = service(port: 47_023, probe: probe, signals: signals, listens: { _, _ in listens.next() },
                          ceiling: 20, afterListen: 0.2)
        XCTAssertEqual(svc.takeOver(pid: 4242, bindRetry: 0), .started(.heldByOther))
        // 0.2 s at a 0.05 s poll: about 4 probes after the flip, one per tick, never one while listening.
        XCTAssertGreaterThanOrEqual(probe.calls, 4, "the bound waited a few ticks: \(probe.calls)")
        XCTAssertLessThan(probe.calls, 15, "bounded, not the 20 s ceiling: \(probe.calls)")
        XCTAssertEqual(listens.calls - 1, probe.calls - 2 + 4, "one listensOn per tick; probes only after the flip")
    }

    /// A fake holder the row spawns: python3 listening on 127.0.0.1 at a port the kernel picks, printed first.
    /// "fork": SIGTERM forks a child that keeps the listening socket 2 s and exits on its own (never signalled),
    /// prints its pid, and the holder exits: the holder no longer listens, the port is still held.
    /// "ignore": SIGTERM is ignored. The row SIGKILLs only the holder it spawned, at teardown, while unreaped.
    private static let holderScript = """
    import os, signal, socket, sys, time
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.bind(("127.0.0.1", 0))
    s.listen(8)
    def term(*_):
        pid = os.fork()
        if pid == 0:
            time.sleep(2.0)
            os._exit(0)
        print(pid, flush=True)
        os._exit(0)
    signal.signal(signal.SIGTERM, signal.SIG_IGN if sys.argv[1] == "ignore" else term)
    print(s.getsockname()[1], flush=True)
    while True:
        time.sleep(1)
    """

    private final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var buf = ""
        func add(_ d: Data) { lock.withLock { buf += String(decoding: d, as: UTF8.self) } }
        /// The next whole line, waiting up to `timeout`.
        func next(timeout: TimeInterval) -> String? {
            let end = Date().addingTimeInterval(timeout)
            while Date() < end {
                let line: String? = lock.withLock {
                    guard let nl = buf.firstIndex(of: "\n") else { return nil }
                    defer { buf.removeSubrange(...nl) }
                    return String(buf[..<nl])
                }
                if let line { return line }
                Thread.sleep(forTimeInterval: 0.02)
            }
            return nil
        }
    }

    private func spawnHolder(_ mode: String) throws -> (Process, Lines, UInt16) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = ["-I", "-c", Self.holderScript, mode]
        let out = Pipe()
        p.standardOutput = out
        let lines = Lines()
        let reader = out.fileHandleForReading
        reader.readabilityHandler = { lines.add($0.availableData) }
        try p.run()
        addTeardownBlock {
            reader.readabilityHandler = nil
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
            p.waitUntilExit()
        }
        guard let first = lines.next(timeout: 10), let port = UInt16(first), port != 0 else {
            throw XCTSkip("the fake holder did not report its port")
        }
        return (p, lines, port)
    }

    /// prosper://ccpool/takeover against the spawned holder: the real libproc listensOn, the real port probe on the
    /// row's own port; the holder is recognized as ccpool by an argv seam; only the holder can be signalled.
    @MainActor
    private func takeOverByLink(holder: pid_t, port: UInt16, ceiling: TimeInterval,
                                signals: CCPoolSignalRecorder) async throws -> (CCPoolRuntime, CCPoolCapturingLogger) {
        let dir = tempDir()
        let argv = proxyArgv
        var cfg = CCPoolServiceConfig()
        cfg.port = port
        cfg.upstream = dead
        cfg.probeTimeout = 0.3
        cfg.signal = { pid, sig in signals.record(pid, sig) && pid == holder && kill(pid, sig) == 0 }
        cfg.userPids = { [holder] }
        cfg.argv = { $0 == holder ? argv : [] }
        cfg.parentPid = { _ in nil }
        cfg.takeOverCeiling = ceiling
        cfg.takeOverPoll = 0.05
        let log = CCPoolCapturingLogger()
        let rt = CCPoolRuntime(directory: dir.appendingPathComponent("ccpool"), secrets: CCPoolMemorySecrets(), config: cfg,
                               vaultURL: dir.appendingPathComponent("old"), defaults: scratchDefaults("ccpool-drain"),
                               probeBase: dead, logger: log)
        let svc = rt.service
        addTeardownBlock { svc.stop() }
        try rt.store.addAccount(label: "a", token: "tok-a", secrets: rt.secrets)
        rt.lifecycle.live = true
        let task = CCPoolRuntime.openLink(URL(string: "prosper://ccpool/takeover")!, runtime: rt)
        XCTAssertTrue(task != nil, "the link ran the takeover")
        await task?.value
        return (rt, log)
    }

    @MainActor
    func testTakeOverLinkBindsAfterAHolderWhosePortOutlivesItByTwoSeconds() async throws {
        let (p, lines, port) = try spawnHolder("fork")
        let signals = CCPoolSignalRecorder()
        let (rt, log) = try await takeOverByLink(holder: p.processIdentifier, port: port, ceiling: 20, signals: signals)
        XCTAssertTrue(lines.next(timeout: 5) != nil, "the holder forked its socket keeper on SIGTERM")
        XCTAssertEqual(signals.sent, ["\(p.processIdentifier):\(SIGTERM)"], "one SIGTERM to the holder only")
        XCTAssertEqual(rt.service.status, .running(port: port), "bound once the port freed: \(log.lines)")
        XCTAssertFalse(log.lines.contains { $0.contains("not binding") }, "never gave up on the draining port: \(log.lines)")
        XCTAssertTrue(rt.model.stuckPid == nil)
    }

    @MainActor
    func testTakeOverLinkAgainstAHolderThatNeverExitsEndsInAClearFailure() async throws {
        let (p, _, port) = try spawnHolder("ignore")
        let signals = CCPoolSignalRecorder()
        let began = Date()
        let (rt, log) = try await takeOverByLink(holder: p.processIdentifier, port: port, ceiling: 1, signals: signals)
        XCTAssertLessThan(Date().timeIntervalSince(began), 15, "bounded by the ceiling")
        XCTAssertEqual(signals.sent, ["\(p.processIdentifier):\(SIGTERM)"], "one SIGTERM, never SIGKILL from Prosper")
        XCTAssertEqual(rt.service.status, .heldByCCPool(pid: Int(p.processIdentifier)), "nothing bound")
        XCTAssertEqual(rt.model.stuckPid, Int(p.processIdentifier))
        XCTAssertEqual(rt.model.proxyText, "ccpool (pid \(p.processIdentifier)) did not stop; quit it, then Start proxy.")
        XCTAssertTrue(log.lines.contains { $0.contains("the signalled ccpool proxy did not free the port") }, "\(log.lines)")
        XCTAssertTrue(p.isRunning, "the holder still runs: Prosper sent nothing more")
    }
}
