// Tiered polling scheduler — the single clock for every module.
//
// One serial queue, one base-interval timer. Each module polls on its own tick
// divider (fast: CPU/RAM/Net/GPU every tick; slow: temps/power every 2; battery
// every 10) so cheap fast metrics stay responsive while expensive/slow-moving
// ones don't burn cycles. Only ENABLED modules instantiate readers and run.
// ProcSampler (the ~4 ms all-pid scan) runs only while a popup is open.
//
// The timer fires on `queue`; snapshots are delivered on `deliverQueue` (main
// by default) so the UI never touches reader state. Stop tears the timer down
// fully (no idle wakeups when every menu-bar item is hidden).

import Foundation
import os

public enum StatsModule: String, CaseIterable, Sendable {
    case cpu, memory, network, gpu, power, sensors, battery

    /// Metric history series this module feeds (empty = not charted). Drives both
    /// which rings the poller allocates and what it snapshots each tick.
    public var historyKeys: [String] {
        switch self {
        case .cpu: ["cpu"]; case .memory: ["memory"]; case .gpu: ["gpu"]
        case .power: ["power"]
        // Network renders live up/down text, not a sparkline, and its popover has
        // no chart — so it feeds no history ring (was allocating 2 dead rings/tick).
        case .network, .sensors, .battery: []
        }
    }
}

public struct StatsSnapshot: Sendable, Equatable {
    public var cpu: CPUSample?
    public var memory: MemorySample?
    public var network: NetworkSample?
    public var gpu: GPUSample?
    public var power: PowerSample?
    public var temperatures: [TempSensor]?
    public var battery: BatterySample?
    public var topByCPU: [ProcInfo]?
    public var topByMemory: [ProcInfo]?
    /// Headline metric histories (oldest→newest), keyed cpu/memory/net.up/net.down/
    /// gpu/power. Carried on the snapshot so the UI reads a plain array on the main
    /// thread — no cross-queue `sync` hop into the poller during view rendering.
    public var histories: [String: [Double]] = [:]
    public init() {}
}

public final class StatsPoller {
    public struct Config {
        public var baseInterval: TimeInterval = 1.0
        public var slowDivider: Int = 2       // temps/power
        public var batteryDivider: Int = 10
        public var historyLength: Int = 120
        public init() {}
    }

    private let queue = DispatchQueue(label: "com.prosper.stats.poller", qos: .utility)
    private let deliverQueue: DispatchQueue
    private let config: Config
    private var timer: DispatchSourceTimer?
    private var tick: UInt64 = 0

    private let enabled: Set<StatsModule>
    /// The module set this poller was created for (controller compares it to
    /// decide whether a config change needs a fresh poller).
    public var enabledSet: Set<StatsModule> { enabled }
    public var onSnapshot: ((StatsSnapshot) -> Void)?
    /// Set true while a popup is open to enable the expensive top-process scan.
    private let procFlag = ManagedAtomicFlag()
    public func setProcSampling(_ on: Bool) { procFlag.set(on) }

    // Readers (only those for enabled modules are created).
    private var cpu: CPUReader?
    private var memory: MemoryReader?
    private var network: NetworkReader?
    private var gpu: GPUReader?
    private var power: IOReportKit?
    private var sensors: IOHIDSensors?
    private var battery: BatteryReader?
    private var procs: ProcSampler?

    // Headline histories for charts. Mutated only on `queue`; read via history().
    private var histories: [String: RingBuffer<Double>] = [:]
    private var latest = StatsSnapshot()

    public init(modules: Set<StatsModule>, config: Config = Config(),
                deliverQueue: DispatchQueue = .main) {
        self.enabled = modules
        self.config = config
        self.deliverQueue = deliverQueue
        // Only ring the metrics an enabled module actually pushes — the per-tick
        // snapshot below is then proportional to what's on screen, not a fixed 6.
        for m in modules { for key in m.historyKeys {
            histories[key] = RingBuffer<Double>(capacity: config.historyLength)
        } }
    }

    public func start() {
        queue.async { [self] in
            guard timer == nil else { return }
            instantiateReaders()
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now(), repeating: config.baseInterval, leeway: .milliseconds(100))
            t.setEventHandler { [weak self] in self?.poll() }
            timer = t
            t.resume()
        }
    }

    public func stop() {
        queue.async { [self] in
            timer?.cancel(); timer = nil
            procs = nil   // drop the pid cpu-time map
        }
    }

    private func instantiateReaders() {
        if enabled.contains(.cpu) { cpu = CPUReader() }
        if enabled.contains(.memory) { memory = MemoryReader() }
        if enabled.contains(.network) { network = NetworkReader() }
        if enabled.contains(.gpu) { gpu = GPUReader() }
        if enabled.contains(.power) { power = IOReportKit() }
        if enabled.contains(.sensors) { sensors = IOHIDSensors() }
        if enabled.contains(.battery) { battery = BatteryReader() }
    }

    private func poll() {
        let slow = tick % UInt64(max(1, config.slowDivider)) == 0
        let batt = tick % UInt64(max(1, config.batteryDivider)) == 0
        tick &+= 1

        if cpu != nil, let s = try? cpu!.read() {
            latest.cpu = s; push("cpu", s.total)
        }
        if memory != nil, let s = try? memory!.read() {
            latest.memory = s; push("memory", s.usedFraction)
        }
        if network != nil, let s = try? network!.read() {
            latest.network = s   // rendered as live text, not charted — no history ring
        }
        if gpu != nil, let s = try? gpu!.read() {
            latest.gpu = s; push("gpu", s.utilization)
        }
        if slow, let p = power?.read() {
            latest.power = p; push("power", p.totalWatts)
        }
        if slow, let temps = sensors?.read() {
            latest.temperatures = temps
        }
        if batt, battery != nil, let b = try? battery!.read() {
            latest.battery = b
        }
        if procFlag.get() && slow {
            if procs == nil { procs = ProcSampler() }
            let (byCPU, byMem) = procs!.sample(limit: 5)
            latest.topByCPU = byCPU; latest.topByMemory = byMem
        }

        // Snapshot the rings onto the delivered value so the UI never reaches back
        // into `queue`. Small (≤120 Doubles × 6 keys) — copied once per tick.
        latest.histories = histories.mapValues { $0.snapshot() }

        let snap = latest
        deliverQueue.async { [onSnapshot] in onSnapshot?(snap) }
    }

    private func push(_ key: String, _ value: Double) {
        histories[key]?.append(value)
    }

    /// Thread-safe snapshot of a metric's history (call from any queue).
    public func history(_ key: String) -> [Double] {
        queue.sync { histories[key]?.snapshot() ?? [] }
    }
}

/// Thread-safe boolean flag (popup open/closed). `OSAllocatedUnfairLock` owns the
/// state behind a stable heap pointer — avoids the `os_unfair_lock`-as-stored-var
/// move hazard for zero contention.
final class ManagedAtomicFlag {
    private let lock = OSAllocatedUnfairLock(initialState: false)
    func set(_ v: Bool) { lock.withLock { $0 = v } }
    func get() -> Bool { lock.withLock { $0 } }
}
