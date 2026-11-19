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
                         ceiling: TimeInterval = 0.3) -> CCPoolService {
        var cfg = CCPoolServiceConfig()
        cfg.port = port
        cfg.upstream = dead
        cfg.portProbe = { _, _ in probe.next() }
        cfg.signal = { signals.record($0, $1) }
        cfg.ownedByUser = owned
        cfg.takeOverCeiling = ceiling
        cfg.takeOverPoll = 0.05
        let svc = CCPoolService(config: cfg, store: CCPoolStore(directory: tempDir()), secrets: CCPoolMemorySecrets(),
                                logger: CCPoolCapturingLogger())
        addTeardownBlock { svc.stop() }
        return svc
    }

    func testTakeOverSignalsTheProbedCCPoolOnceThenStarts() {
        let port = freePort()
        let probe = CCPoolProbeScript([.ccpool(pid: 4242, impl: "python"), .ccpool(pid: 4242, impl: "python"), .free])
        let signals = CCPoolSignalRecorder()
        let svc = service(port: port, probe: probe, signals: signals)
        XCTAssertEqual(svc.takeOver(pid: 4242, bindRetry: 0), .started(.running(port: port)))
        XCTAssertEqual(signals.sent, ["4242:\(SIGTERM)"], "SIGTERM to the probed pid, once")
        XCTAssertEqual(probe.calls, 4, "re-probe, one wait probe (ccpool), one (free), start's own probe")
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

    func testTakeOverDefaultSignalRefusesUnderTestAndOwnerCheckReadsTheUid() {
        // Signal 0 delivers nothing (an existence check): even a broken guard sends no signal here.
        XCTAssertFalse(CCPoolServiceConfig().signal(getpid(), 0), "the production seam never signals under XCTest")
        XCTAssertTrue(CCPoolService.runsAsCurrentUser(getpid()))
        XCTAssertFalse(CCPoolService.runsAsCurrentUser(1), "launchd runs as root")
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
}
