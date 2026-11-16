import XCTest

@testable import ProsperApp
@testable import StatsCore

/// #188: the CPU clock, the voltage/current rails and the ping thread are popup-only
/// readouts, so a closed popup must not sample them.
final class StatsPopupGateTests: XCTestCase {

    override func tearDown() {
        CPUReader.onFrequencySample = nil
        StatsPoller.onPowerRailsRead = nil
        NetPingReader.pinger = NetPingReader.ping(host:seq:timeout:)
        URLProtocol.unregisterClass(NoNetwork.self)
        super.tearDown()
    }

    /// The ping thread runs at background QoS, so on a loaded Mac its first turn can come late:
    /// the event ends these waits, the ceiling only fails a hang.
    private static let ceiling: TimeInterval = 20

    private func poller(_ modules: Set<StatsModule>, ticks: Int) -> (StatsPoller, () -> StatsSnapshot?) {
        var cfg = StatsPoller.Config()
        cfg.baseInterval = 0.05; cfg.activeInterval = 0.05; cfg.slowDivider = 1
        let p = StatsPoller(modules: modules, config: cfg, deliverQueue: DispatchQueue(label: "test.stats.gate"))
        let lock = NSLock()
        var last: StatsSnapshot?
        let got = expectation(description: "\(ticks) ticks")
        got.expectedFulfillmentCount = ticks
        got.assertForOverFulfill = false
        p.onSnapshot = { s in lock.withLock { last = s }; got.fulfill() }
        p.start()
        wait(for: [got], timeout: 3)
        return (p, { lock.withLock { last } })
    }

    func testClosedPopupSkipsClockAndPowerRails() {
        let lock = NSLock()
        var freq = 0, rails = 0
        CPUReader.onFrequencySample = { lock.withLock { freq += 1 } }
        StatsPoller.onPowerRailsRead = { lock.withLock { rails += 1 } }
        let (p, _) = poller([.cpu], ticks: 5)   // slowDivider 1: every tick is a slow tick
        defer { p.stop() }
        XCTAssertEqual(lock.withLock { freq }, 0, "closed popup must not sample the CPU clock")
        XCTAssertEqual(lock.withLock { rails }, 0, "closed popup must not read the power rails")

        p.setPopupActive(true)
        _ = p.history("cpu")   // queue.sync: the open's immediate poll has run
        XCTAssertGreaterThan(lock.withLock { freq }, 0, "open popup samples the clock")
        XCTAssertGreaterThan(lock.withLock { rails }, 0, "open popup reads the power rails")
    }

    func testPingThreadRunsOnlyWhilePopupOpen() throws {
        try requireHeavyTests()
        // An open popup refreshes the public IP (api.country.is); keep it in-process.
        URLProtocol.registerClass(NoNetwork.self)
        let lock = NSLock()
        var pings = 0
        var firstPing: XCTestExpectation?
        NetPingReader.pinger = { _, _, _ in
            lock.withLock { pings += 1; firstPing?.fulfill(); firstPing = nil }
            return 5
        }
        let (p, last) = poller([.network], ticks: 5)
        defer { p.stop() }
        XCTAssertEqual(lock.withLock { pings }, 0, "closed popup must not ping")
        XCTAssertNotNil(last()?.netLatency, "reachability comes from the path monitor")
        XCTAssertEqual(last()?.netLatency?.latencyMs.isNaN, true, "no latency without a ping")

        let opened = expectation(description: "first echo on open")
        lock.withLock { firstPing = opened }
        p.setPopupActive(true)
        wait(for: [opened], timeout: Self.ceiling)   // the echo ends the wait; the ceiling only guards a hang

        p.setPopupActive(false)
        _ = p.history("net.up")   // queue.sync: the stop has been applied
        Thread.sleep(forTimeInterval: 1.5)   // past the loop's 1 s sleep: a live loop pings again (one-sided: a late thread can only hide it, never fail a stopped one)
        XCTAssertEqual(lock.withLock { pings }, 1, "closing the popup stops the ping thread")
    }

    func testPauseStopsPingAndResumeRestartsItOnlyForOpenPopup() throws {
        try requireHeavyTests()
        URLProtocol.registerClass(NoNetwork.self)
        let lock = NSLock()
        var pings = 0
        var nextPing: XCTestExpectation?
        NetPingReader.pinger = { _, _, _ in
            lock.withLock { pings += 1; nextPing?.fulfill(); nextPing = nil }
            return 5
        }
        let (p, _) = poller([.network], ticks: 2)
        defer { p.stop() }
        func expectPing(_ what: String, _ action: () -> Void) {
            let e = expectation(description: what)
            lock.withLock { nextPing = e }
            action()
            wait(for: [e], timeout: Self.ceiling)
        }
        func settled() -> Int {   // queue.sync, then past the loop's 1 s sleep
            _ = p.history("net.up")
            Thread.sleep(forTimeInterval: 1.5)
            return lock.withLock { pings }
        }

        expectPing("echo on open") { p.setPopupActive(true) }
        p.setPaused(true)
        var n = settled()
        XCTAssertEqual(settled(), n, "pause stops the ping thread")

        expectPing("echo on resume with popup open") { p.setPaused(false) }

        p.setPaused(true)
        p.setPopupActive(false)   // closed while paused: flag only
        p.setPaused(false)
        n = settled()
        XCTAssertEqual(settled(), n, "resume with a closed popup must not ping")
    }

    /// QA #265 G6: each run (one per popup open) starts with an empty history, so the
    /// popup never stitches a closed period into its connectivity strip.
    func testEachPingRunStartsWithAFreshHistory() {
        let lock = NSLock()
        var calls = 0
        let hold = DispatchSemaphore(value: 0)
        let secondRun = expectation(description: "the second run's first echo started")
        NetPingReader.pinger = { _, seq, _ in
            let n = lock.withLock { calls += 1; return calls }
            if n == 1 { return 5 }
            if seq == 0 { secondRun.fulfill() }   // seq restarts at 0 per run
            hold.wait()   // later echoes wait for the test: nothing lands mid-assert
            return 7
        }
        let reader = NetPingReader(historyLength: 10, interval: 1)
        reader.start()
        let landed = expectation(for: NSPredicate { _, _ in reader.connectivity() == [true] }, evaluatedWith: nil)
        wait(for: [landed], timeout: Self.ceiling)

        reader.stop()
        reader.start()   // the next popup open
        wait(for: [secondRun], timeout: Self.ceiling)
        XCTAssertEqual(reader.connectivity(), [], "a new run keeps nothing from the last one")
        XCTAssertTrue(reader.latest() == nil, "no latency until this run's first echo")
        reader.stop()
        hold.signal(); hold.signal()
    }

    /// QA #265 G7: a poller rebuilt while the popup is open (a config change) is told so
    /// at once, so its ping thread runs without waiting for the next open.
    func testPollerRebuiltWithPopupOpenPingsAtOnce() {
        URLProtocol.registerClass(NoNetwork.self)
        let lock = NSLock()
        let echo = expectation(description: "echo from the rebuilt poller")
        var firstPing: XCTestExpectation? = echo
        NetPingReader.pinger = { _, _, _ in
            lock.withLock { firstPing?.fulfill(); firstPing = nil }
            return 5
        }
        var cfg = StatsPoller.Config()
        cfg.baseInterval = 0.05; cfg.activeInterval = 0.05; cfg.slowDivider = 1
        let p = StatsPoller(modules: [.network], config: cfg, deliverQueue: DispatchQueue(label: "test.stats.rebuilt"))
        StatsController.startPrimed(p, popupShown: true, screenHidden: false)
        wait(for: [echo], timeout: Self.ceiling)
        p.stop()
        _ = p.history("net.up")   // queue.sync: the stop has been applied
    }

    // MARK: - #1051: the rebuilt poller's state, counted through a second poller's ticks

    /// Delivers `n` snapshots from an unpaused reference poller: the clock the checks below
    /// count in, instead of a fixed wait.
    private func referenceTicks(_ n: Int) {
        var cfg = StatsPoller.Config()
        cfg.baseInterval = 0.05; cfg.activeInterval = 0.05; cfg.slowDivider = 1
        let ref = StatsPoller(modules: [.memory], config: cfg, deliverQueue: DispatchQueue(label: "test.stats.ref"))
        let got = expectation(description: "\(n) reference ticks")
        got.expectedFulfillmentCount = n
        got.assertForOverFulfill = false
        ref.onSnapshot = { _ in got.fulfill() }
        ref.start()
        wait(for: [got], timeout: 5)
        ref.stop()
    }

    /// Item 1: a poller rebuilt while the screen is hidden takes no sample and delivers
    /// nothing until resumed; a mutant that drops setPaused ticks like the reference does.
    func testPollerRebuiltWithScreenHiddenTakesNoSampleUntilResumed() {
        var cfg = StatsPoller.Config()
        cfg.baseInterval = 0.05; cfg.activeInterval = 0.05; cfg.slowDivider = 1
        let p = StatsPoller(modules: [.memory], config: cfg, deliverQueue: DispatchQueue(label: "test.stats.hidden"))
        let lock = NSLock()
        var delivered = 0
        var resumed: XCTestExpectation?
        p.onSnapshot = { _ in lock.withLock { delivered += 1; resumed?.fulfill(); resumed = nil } }
        defer { p.stop() }
        StatsController.startPrimed(p, popupShown: false, screenHidden: true)
        referenceTicks(8)   // the unpaused reference ticks eight times (about 0.4 s)
        XCTAssertEqual(p.history("memory").count, 0, "a hidden screen takes no sample")   // queue.sync
        XCTAssertEqual(lock.withLock { delivered }, 0, "a hidden screen delivers nothing")

        let back = expectation(description: "first sample on resume")
        lock.withLock { resumed = back }
        p.setPaused(false)
        wait(for: [back], timeout: 5)
        XCTAssertGreaterThan(p.history("memory").count, 0, "resume polls")
    }

    /// Item 2: a poller rebuilt with the popup closed never starts the ping thread. The
    /// poller's own eight ticks are the clock; a mutant that opens the popup pings at start.
    func testPollerRebuiltWithPopupClosedDoesNotPing() {
        URLProtocol.registerClass(NoNetwork.self)
        let lock = NSLock()
        var pings = 0
        NetPingReader.pinger = { _, _, _ in lock.withLock { pings += 1 }; return 5 }
        var cfg = StatsPoller.Config()
        cfg.baseInterval = 0.05; cfg.activeInterval = 0.05; cfg.slowDivider = 1
        let p = StatsPoller(modules: [.network], config: cfg, deliverQueue: DispatchQueue(label: "test.stats.closed"))
        let got = expectation(description: "eight ticks")
        got.expectedFulfillmentCount = 8
        got.assertForOverFulfill = false
        p.onSnapshot = { _ in got.fulfill() }
        StatsController.startPrimed(p, popupShown: false, screenHidden: false)
        wait(for: [got], timeout: 5)
        p.stop()
        _ = p.history("net.up")   // queue.sync: the stop has been applied
        XCTAssertEqual(lock.withLock { pings }, 0, "a closed popup must not ping")
    }

    /// Item 4: the popover delegate's step with a fake shown state. Shown turns the popup
    /// readers on and clears a stale pause; closed leaves them off and the pause alone.
    func testPopupStateChangedTellsThePollerTheShownState() {
        let lock = NSLock()
        var freq = 0
        CPUReader.onFrequencySample = { lock.withLock { freq += 1 } }
        let (p, _) = poller([.cpu], ticks: 3)
        defer { p.stop() }
        var lit = ScreenGate()
        StatsController.popupStateChanged(shown: false, screen: &lit, poller: p)
        _ = p.history("cpu")   // queue.sync
        XCTAssertEqual(lock.withLock { freq }, 0, "closed on a lit screen: the clock stays off")

        var screen = ScreenGate()
        screen.apply(.sleep)
        StatsController.popupStateChanged(shown: false, screen: &screen, poller: p)
        _ = p.history("cpu")   // queue.sync
        XCTAssertEqual(lock.withLock { freq }, 0, "closed: the clock stays off")
        XCTAssertTrue(screen.hidden, "closed: a stale pause stays")

        StatsController.popupStateChanged(shown: true, screen: &screen, poller: p)
        _ = p.history("cpu")
        XCTAssertGreaterThan(lock.withLock { freq }, 0, "shown: the clock is sampled")
        XCTAssertFalse(screen.hidden, "shown: the stale pause is cleared")
    }
}

/// Fails every URLSession request in-process so no test traffic leaves the machine.
private final class NoNetwork: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
    override func stopLoading() {}
}
