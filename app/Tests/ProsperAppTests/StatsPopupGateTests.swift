import XCTest

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

    func testPingThreadRunsOnlyWhilePopupOpen() {
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
        wait(for: [opened], timeout: 1)

        p.setPopupActive(false)
        _ = p.history("net.up")   // queue.sync: the stop has been applied
        Thread.sleep(forTimeInterval: 1.5)   // past the loop's 1 s sleep: a live loop pings again
        XCTAssertEqual(lock.withLock { pings }, 1, "closing the popup stops the ping thread")
    }
}

/// Fails every URLSession request in-process so no test traffic leaves the machine.
private final class NoNetwork: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
    override func stopLoading() {}
}
