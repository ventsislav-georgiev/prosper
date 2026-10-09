import XCTest

@testable import StatsCore

/// #186: while the display sleeps or the screen is locked the poller must stop
/// ticking (no samples, no deliveries), and resuming must deliver a fresh sample
/// at once rather than waiting a full interval.
final class StatsPollerPauseTests: XCTestCase {

    func testPausedPollerStopsTickingAndResumePollsImmediately() {
        var cfg = StatsPoller.Config()
        cfg.baseInterval = 0.25
        cfg.activeInterval = 0.25
        let deliver = DispatchQueue(label: "test.stats.deliver")
        let poller = StatsPoller(modules: [.memory], config: cfg, deliverQueue: deliver)
        let lock = NSLock()
        var count = 0
        var waiter: XCTestExpectation?
        poller.onSnapshot = { _ in
            lock.withLock { count += 1; waiter?.fulfill(); waiter = nil }
        }
        defer { poller.stop() }

        let first = expectation(description: "first tick")
        lock.withLock { waiter = first }
        poller.start()
        wait(for: [first], timeout: 2)

        poller.setPaused(true)
        _ = poller.history("memory")   // queue.sync: the pause has been applied
        deliver.sync {}                // drain deliveries already in flight
        lock.withLock { count = 0 }
        let samplesAtPause = poller.history("memory").count

        Thread.sleep(forTimeInterval: 0.6)   // ~2.5 intervals
        XCTAssertEqual(lock.withLock { count }, 0, "a paused poller must not deliver")
        XCTAssertEqual(poller.history("memory").count, samplesAtPause, "no samples while paused")

        let resumed = expectation(description: "poll on resume")
        lock.withLock { waiter = resumed }
        poller.setPaused(false)
        wait(for: [resumed], timeout: 0.2)   // shorter than one interval: the immediate poll
    }
}
