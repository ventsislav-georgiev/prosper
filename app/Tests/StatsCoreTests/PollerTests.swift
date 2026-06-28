import XCTest
@testable import StatsCore

final class BatteryReaderTests: XCTestCase {
    func testReadOrSkipOnDesktop() throws {
        var r = BatteryReader()
        do {
            let s = try r.read()
            XCTAssert(s.charge >= 0 && s.charge <= 1, "charge \(s.charge) out of range")
            XCTAssert(s.health.isNaN || (s.health > 0 && s.health <= 1.2), "health \(s.health)")
            XCTAssertGreaterThanOrEqual(s.cycleCount, 0)
            if !s.voltage.isNaN { XCTAssert(s.voltage > 0 && s.voltage < 30, "Li-ion V \(s.voltage)") }
            XCTAssertGreaterThanOrEqual(s.currentCapacity, 0)
            XCTAssertGreaterThanOrEqual(s.adapterWatts, 0)
            print("Battery: \(Int(s.charge * 100))% health=\(String(format: "%.0f", s.health * 100))% cycles=\(s.cycleCount) \(String(format: "%.1f", s.powerWatts))W \(String(format: "%.1f", s.temperature))°C")
        } catch StatsError.unavailable {
            throw XCTSkip("no battery on this machine")
        }
    }
}

final class StatsPollerTests: XCTestCase {
    func testDeliversSnapshotsForEnabledModules() {
        var cfg = StatsPoller.Config()
        cfg.baseInterval = 0.05
        let bg = DispatchQueue(label: "test.deliver")
        let poller = StatsPoller(modules: [.cpu, .memory, .network], config: cfg, deliverQueue: bg)

        let exp = expectation(description: "received CPU+memory snapshot")
        let lock = NSLock(); var fulfilled = false
        poller.onSnapshot = { snap in
            // CPU first read is baseline; wait for memory present + at least 2 ticks.
            if snap.memory != nil, snap.cpu != nil {
                lock.lock(); defer { lock.unlock() }
                if !fulfilled { fulfilled = true; exp.fulfill() }
            }
        }
        poller.start()
        wait(for: [exp], timeout: 3.0)
        poller.stop()
    }

    func testHistoryAccumulates() {
        var cfg = StatsPoller.Config()
        cfg.baseInterval = 0.02
        cfg.historyLength = 50
        let poller = StatsPoller(modules: [.memory], config: cfg,
                                 deliverQueue: DispatchQueue(label: "t2"))
        poller.start()
        let deadline = Date().addingTimeInterval(1.0)
        while poller.history("memory").count < 5, Date() < deadline { usleep(20_000) }
        poller.stop()
        XCTAssertGreaterThanOrEqual(poller.history("memory").count, 5, "history should accumulate")
    }

    func testSnapshotCarriesHistory() {
        // Regression: the UI reads history off the delivered snapshot (no queue
        // hop). A delivered snapshot must carry a growing per-metric series.
        var cfg = StatsPoller.Config(); cfg.baseInterval = 0.02
        let poller = StatsPoller(modules: [.memory], config: cfg,
                                 deliverQueue: DispatchQueue(label: "thist"))
        let lock = NSLock(); var maxCount = 0
        poller.onSnapshot = { snap in
            lock.lock(); maxCount = max(maxCount, snap.histories["memory"]?.count ?? 0); lock.unlock()
        }
        poller.start()
        let deadline = Date().addingTimeInterval(1.0)
        while true { lock.lock(); let c = maxCount; lock.unlock(); if c >= 3 || Date() > deadline { break }; usleep(20_000) }
        poller.stop()
        lock.lock(); let c = maxCount; lock.unlock()
        XCTAssertGreaterThanOrEqual(c, 3, "snapshot.histories must accumulate the metric series")
    }

    func testDisabledModuleNeverSampled() {
        var cfg = StatsPoller.Config(); cfg.baseInterval = 0.02
        let poller = StatsPoller(modules: [.memory], config: cfg,
                                 deliverQueue: DispatchQueue(label: "t3"))
        let lock = NSLock(); var sawGPU = false
        poller.onSnapshot = { snap in if snap.gpu != nil { lock.lock(); sawGPU = true; lock.unlock() } }
        poller.start()
        usleep(300_000)
        poller.stop()
        lock.lock(); let v = sawGPU; lock.unlock()
        XCTAssertFalse(v, "GPU disabled → never present in snapshot")
    }

    func testPerTickHistorySnapshotWithinBudget() {
        // Hot-path budget: poll() materializes the ring histories onto the snapshot
        // every tick. With every metric ringed and full (worst case), one
        // materialization must stay well under the 1s tick — assert < 200µs so a
        // regression (e.g. O(n²) copy) trips here, not in the field.
        var rings: [String: RingBuffer<Double>] = [:]
        for key in ["cpu", "memory", "net.up", "net.down", "gpu", "power"] {
            var r = RingBuffer<Double>(capacity: 120)
            for i in 0..<120 { r.append(Double(i)) }
            rings[key] = r
        }
        let iterations = 1000
        let t0 = DispatchTime.now().uptimeNanoseconds
        var sink = 0
        for _ in 0..<iterations {
            let snap = rings.mapValues { $0.snapshot() }
            sink &+= snap["cpu"]?.count ?? 0
        }
        let perCall = Double(DispatchTime.now().uptimeNanoseconds - t0) / Double(iterations)
        XCTAssertEqual(sink, iterations * 120)
        XCTAssertLessThan(perCall, 200_000, "per-tick history snapshot \(Int(perCall))ns exceeds 200µs budget")
    }

    func testStopHaltsDelivery() {
        var cfg = StatsPoller.Config(); cfg.baseInterval = 0.02
        let poller = StatsPoller(modules: [.memory], config: cfg,
                                 deliverQueue: DispatchQueue(label: "t4"))
        let counter = Counter()
        poller.onSnapshot = { _ in counter.bump() }
        poller.start()
        usleep(200_000)
        poller.stop()
        usleep(100_000)
        let afterStop = counter.value
        usleep(300_000)
        XCTAssertEqual(counter.value, afterStop, "no deliveries after stop()")
    }
}

private final class Counter {
    private let lock = NSLock(); private var _v = 0
    func bump() { lock.lock(); _v += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return _v }
}
