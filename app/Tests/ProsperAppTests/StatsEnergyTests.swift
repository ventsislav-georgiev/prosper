import XCTest

@testable import ProsperApp
@testable import StatsCore

/// #769: fewer Stats wakes — slower defaults for anyone who never picked an interval,
/// and no main-thread publish for a tick nothing on the menu bar would show.
@MainActor
final class StatsEnergyTests: XCTestCase {
    func testDefaultsAreFiveAndTenAndASavedValueStays() {
        let keys = ["statsRefreshInterval", "statsSensorsInterval"]   // Preferences.Keys is private
        let saved = keys.map { Preferences.defaults.object(forKey: $0) }
        defer {
            for (k, v) in zip(keys, saved) {
                if let v { Preferences.defaults.set(v, forKey: k) } else { Preferences.defaults.removeObject(forKey: k) }
            }
        }
        keys.forEach { Preferences.defaults.removeObject(forKey: $0) }
        XCTAssertEqual(Preferences.statsRefreshInterval, 5, "fresh base interval")
        XCTAssertEqual(Preferences.statsSensorsInterval, 10, "fresh sensors interval")
        Preferences.statsRefreshInterval = 3
        Preferences.statsSensorsInterval = 3
        XCTAssertEqual(Preferences.statsRefreshInterval, 3, "a saved 3 s stays 3 s")
        XCTAssertEqual(Preferences.statsSensorsInterval, 3, "a saved sensors 3 s stays")
    }

    private func snap(charge: Double, timeToEmpty: Int = 10, cpuHistory: [Double] = [0.1, 0.2]) -> StatsSnapshot {
        var s = StatsSnapshot()
        s.battery = BatterySample(charge: charge, isCharging: false, isPluggedIn: false,
                                  timeToEmpty: timeToEmpty, timeToFull: -1, cycleCount: 1,
                                  health: 0.9, powerWatts: -5, temperature: 30)
        s.histories = ["cpu": cpuHistory]
        return s
    }

    func testUnchangedSampleDoesNotDeliverAndAChangedOneDoes() {
        let style = StatsWidgetStyle.default   // cpu draws a sparkline, battery text + bar
        let shown: [StatsModule] = [.cpu, .battery]
        func key(_ s: StatsSnapshot) -> [AnyHashable] { StatsDeliverGate.key(shown, s, style: style) }
        var gate = StatsDeliverGate()
        XCTAssertTrue(gate.admit(key(snap(charge: 0.5)), popupShown: false), "first tick publishes")
        XCTAssertFalse(gate.admit(key(snap(charge: 0.5)), popupShown: false), "identical tick is skipped")
        XCTAssertFalse(gate.admit(key(snap(charge: 0.5, timeToEmpty: 99)), popupShown: false),
                       "a popup-only field moving is not drawn on the menu bar")
        XCTAssertTrue(gate.admit(key(snap(charge: 0.49, timeToEmpty: 99)), popupShown: false), "battery moved")
        XCTAssertTrue(gate.admit(key(snap(charge: 0.49, timeToEmpty: 99, cpuHistory: [0.2, 0.3])), popupShown: false),
                      "the sparkline moved")
        XCTAssertTrue(gate.admit(key(snap(charge: 0.49, timeToEmpty: 99, cpuHistory: [0.2, 0.3])), popupShown: true),
                      "an open popup always gets the tick")
    }

    // QA #604 INFO-2: each part of the key, one module at a time.
    private func admits(_ m: StatsModule, _ a: StatsSnapshot, _ b: StatsSnapshot,
                        style: StatsWidgetStyle = .default) -> Bool {
        var gate = StatsDeliverGate()
        _ = gate.admit(StatsDeliverGate.key([m], a, style: style), popupShown: false)
        return gate.admit(StatsDeliverGate.key([m], b, style: style), popupShown: false)
    }

    private func net(_ up: Double, _ down: Double) -> StatsSnapshot {
        var s = StatsSnapshot()
        s.network = NetworkSample(uploadBytesPerSec: up, downloadBytesPerSec: down, totalUploaded: 0, totalDownloaded: 0)
        return s
    }

    private func power(_ watts: Double, history: [Double]) -> StatsSnapshot {
        var s = StatsSnapshot()
        s.power = PowerSample(cpuWatts: watts, gpuWatts: 0, aneWatts: 0, totalWatts: watts)
        s.histories = ["power": history]
        return s
    }

    private func style(_ m: StatsModule, _ mode: StatsDisplayMode) -> StatsWidgetStyle {
        var st = StatsWidgetStyle.default
        var cfg = st.config(m)
        cfg.mode = mode
        st.modules[m.rawValue] = cfg
        return st
    }

    func testNetworkKeysOnTheDrawnRateStrings() {
        XCTAssertFalse(admits(.network, net(10_100, 2_000), net(10_200, 2_000)), "both read \"10 KB/s\"")
        XCTAssertTrue(admits(.network, net(10_000, 2_000), net(10_000, 9_000)), "download string moved")
        XCTAssertTrue(admits(.network, net(10_000, 2_000), net(90_000, 2_000)), "upload string moved")
    }

    func testTextOnlyIgnoresTheSeriesAndGraphOnlyIgnoresTheText() {
        let text = style(.power, .textOnly), graph = style(.power, .graph), both = style(.power, .both)
        XCTAssertFalse(admits(.power, power(5, history: [1]), power(5, history: [2]), style: text),
                       "text-only draws no sparkline")
        XCTAssertTrue(admits(.power, power(5, history: [1]), power(7, history: [1]), style: text), "text moved")
        XCTAssertFalse(admits(.power, power(5, history: [1]), power(7, history: [1]), style: graph),
                       "graph-only draws no text (both under the same ramp band)")
        XCTAssertTrue(admits(.power, power(5, history: [1]), power(5, history: [2]), style: graph), "series moved")
        XCTAssertTrue(admits(.power, power(5, history: [1]), power(5, history: [2]), style: both))
        XCTAssertTrue(admits(.power, power(5, history: [1]), power(55, history: [1]), style: graph),
                      "ramp colour band moved")
    }

    func testChargingBoltMovesTheKey() {
        var plugged = snap(charge: 0.5)
        plugged.battery = BatterySample(charge: 0.5, isCharging: true, isPluggedIn: true,
                                        timeToEmpty: 10, timeToFull: 30, cycleCount: 1,
                                        health: 0.9, powerWatts: 5, temperature: 30)
        XCTAssertTrue(admits(.battery, snap(charge: 0.5), plugged), "bolt appears")
    }

    func testThemeScaleMovesTheKey() {
        let before = ThemeRuntime.scale
        defer { ThemeRuntime.scale = before }
        var gate = StatsDeliverGate()
        ThemeRuntime.scale = 1
        _ = gate.admit(StatsDeliverGate.key([.battery], snap(charge: 0.5), style: .default), popupShown: false)
        ThemeRuntime.scale = 0.85
        XCTAssertTrue(gate.admit(StatsDeliverGate.key([.battery], snap(charge: 0.5), style: .default), popupShown: false),
                      "a scale change must reach resizeItems")
    }

    // #1050: the default setup (CPU + RAM, graph + text) over 240 ticks = 20 min at 5 s,
    // counted, not timed. These are the numbers the "no change" verdict rests on.
    func testDefaultCPUAndRAMAdmitCountsOverTwentyMinutes() {
        func count(_ cpu: [Double], history: [Double]? = nil, popup: Bool = false) -> Int {
            var t = StatsFakeTicker()
            return t.admits(cpu, history: history, popupShown: popup)
        }
        let flat = Array(repeating: 0.07, count: 240)
        var spike = flat
        spike[181] = 0.95
        let noisy = (0..<240).map { $0 % 2 == 0 ? 0.05 : 0.08 }
        XCTAssertEqual(count(flat), 120, "the ring grows for 120 ticks, then a flat full ring skips")
        XCTAssertEqual(count(spike), 179, "the spike's own tick and every tick it sits in the window")
        XCTAssertEqual(count(noisy), 240, "the CPU text moves every tick")
        XCTAssertEqual(count(flat, popup: true), 240, "an open popup gets every tick")
        // Outside values in the drawn series: no trap, published while in the ring,
        // and skipping resumes once they leave it (t = 10 leaves at t = 130).
        for bad in [Double.nan, .infinity, -0.5] {
            var h = flat
            h[10] = bad
            XCTAssertEqual(count(flat, history: h), 131, "history value \(bad)")
        }
    }
}

/// #1050: a fake poller. Two 120-sample rings fed and copied onto the snapshot every
/// tick as StatsPoller does (cpu :290, memory :293, push :412, deliver :388). RAM is
/// fixed at 550/1000. `history` overrides what the cpu ring gets (the text keeps `cpu`).
@MainActor
struct StatsFakeTicker {
    private var cpuRing = RingBuffer<Double>(capacity: 120)
    private var memRing = RingBuffer<Double>(capacity: 120)

    mutating func tick(cpu c: Double, history h: Double? = nil) -> StatsSnapshot {
        var s = StatsSnapshot()
        s.cpu = CPUSample(total: c, performance: 0, efficiency: 0, system: 0, user: c, idle: 1 - c, perCore: [])
        s.memory = MemorySample(total: 1000, used: 550, app: 550, wired: 0, compressed: 0, free: 450,
                                pressure: 0.55, swapUsed: 0)
        cpuRing.append(h ?? c)
        memRing.append(s.memory?.usedFraction ?? 0)
        s.histories = ["cpu": cpuRing.snapshot(), "memory": memRing.snapshot()]
        return s
    }

    /// Admits of one gate over the series, one tick per value, with the real key
    /// unless `key` (given the tick index) replaces it. Runs on the main actor.
    mutating func admits(_ cpu: [Double], history: [Double]? = nil, popupShown: Bool = false,
                         key: ((StatsSnapshot, Int) -> [AnyHashable])? = nil) -> Int {
        var gate = StatsDeliverGate()
        var n = 0
        for (t, c) in cpu.enumerated() {
            let h = history.flatMap { t < $0.count ? $0[t] : nil }
            let s = tick(cpu: c, history: h)
            let k = key?(s, t) ?? StatsDeliverGate.key([.cpu, .memory], s, style: .default)
            if gate.admit(k, popupShown: popupShown) { n += 1 }
        }
        return n
    }
}
