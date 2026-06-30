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
        // Network feeds two channels for the popover's dual up/down area chart.
        case .network: ["net.up", "net.down"]
        case .sensors, .battery: []
        }
    }
}

public struct StatsSnapshot: Sendable {
    public var cpu: CPUSample?
    public var memory: MemorySample?
    public var network: NetworkSample?
    public var gpu: GPUSample?
    public var power: PowerSample?
    public var temperatures: [TempSensor]?
    public var powerSensors: [VISensor]?
    public var battery: BatterySample?
    public var topByCPU: [ProcInfo]?
    public var topByPower: [ProcInfo]?
    public var topByMemory: [ProcInfo]?
    public var topByNetwork: [NetProcInfo]?
    public var netLatency: NetLatency?
    public var netLink: NetLinkInfo?
    /// Reachability history (oldest→newest); true = an ICMP echo round-tripped.
    public var connectivity: [Bool] = []
    /// Headline metric histories (oldest→newest), keyed cpu/memory/net.up/net.down/
    /// gpu/power. Carried on the snapshot so the UI reads a plain array on the main
    /// thread — no cross-queue `sync` hop into the poller during view rendering.
    public var histories: [String: [Double]] = [:]
    public init() {}

    /// The temperature shown as the Sensors headline (menu bar + popup big readout).
    /// `pinned` names a sensor the user chose; if it's present its value wins. With no
    /// pick we take the hottest LIVE sensor, skipping static calibration references
    /// (names containing "cal", e.g. "PMU tcal") that never move and would otherwise
    /// peg the readout — the "stuck at 52°" report. Falls back to the plain max if a
    /// machine somehow exposes only calibration sensors.
    public func headlineTemperature(pinned: String? = nil) -> Double? {
        guard let temps = temperatures, !temps.isEmpty else { return nil }
        if let pinned, let s = temps.first(where: { $0.name == pinned }) { return s.celsius }
        let live = temps.filter { !$0.name.lowercased().contains("cal") }
        return (live.isEmpty ? temps : live).map(\.celsius).max()
    }
}

public final class StatsPoller {
    public struct Config {
        public var baseInterval: TimeInterval = 1.0
        public var slowDivider: Int = 2       // temps/power
        public var batteryDivider: Int = 10
        public var historyLength: Int = 120
        /// Faster cadence used WHILE a popup is open, so the live process list and
        /// charts refresh quickly for inspection then drop back to `baseInterval` (the
        /// quiet background rate) on close. Floored against baseInterval so a user who
        /// already set a sub-1.5 s base never gets slowed down.
        public var activeInterval: TimeInterval = 1.0
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
    /// Set true while a popup is open: enables the expensive top-process scan AND
    /// reschedules the timer to the faster `activeInterval` (back to baseInterval on
    /// close). One call from the popover delegate drives both.
    private let procFlag = ManagedAtomicFlag()
    public func setPopupActive(_ on: Bool) {
        procFlag.set(on)
        queue.async { [self] in
            guard let timer else { return }   // not running → nothing to reschedule
            // Kick a sample at the instant of open so the ~1 s reader work (top/nettop)
            // starts now, not at the next background tick — which may be seconds away
            // if the user picked a slow update interval. Readers deliver via onUpdate.
            if on { poll() }
            let target = on ? Swift.min(config.activeInterval, config.baseInterval) : config.baseInterval
            guard abs(target - currentInterval) > 0.01 else { return }
            currentInterval = target
            timer.schedule(deadline: .now() + target, repeating: target, leeway: .milliseconds(100))
        }
    }
    private var currentInterval: TimeInterval = 0

    // Readers (only those for enabled modules are created).
    private var cpu: CPUReader?
    private var memory: MemoryReader?
    private var network: NetworkReader?
    private var gpu: GPUReader?
    private var power: IOReportKit?
    private var sensors: IOHIDSensors?
    private var powerSensors: PowerSensorReader?
    private var battery: BatteryReader?
    private var procs: ProcSampler?
    private var topProc: TopProcessReader?
    private var ping: NetPingReader?
    private var netLink: NetLinkReader?
    private var netProc: NetProcessReader?

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
            currentInterval = config.baseInterval
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
            topProc = nil
            ping?.stop(); ping = nil
            netProc = nil; netLink = nil
        }
    }

    private func instantiateReaders() {
        if enabled.contains(.cpu) { cpu = CPUReader() }
        if enabled.contains(.memory) { memory = MemoryReader() }
        if enabled.contains(.network) {
            network = NetworkReader()
            ping = NetPingReader(historyLength: config.historyLength); ping?.start()
            netLink = NetLinkReader()
        }
        if enabled.contains(.gpu) { gpu = GPUReader() }
        // GPU's popup shows ANE utilization, derived from ANE power — so the
        // IOReport reader is created for GPU too, but its history is only pushed
        // when the Power module itself is enabled (see poll()).
        if enabled.contains(.power) || enabled.contains(.gpu) { power = IOReportKit() }
        if enabled.contains(.sensors) { sensors = IOHIDSensors(); powerSensors = PowerSensorReader() }
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
            latest.network = s
            push("net.up", s.uploadBytesPerSec); push("net.down", s.downloadBytesPerSec)
            latest.netLatency = ping?.latest()
            if let c = ping?.connectivity() { latest.connectivity = c }
            // netLink recomputes off-queue (CoreWLAN RSSI can block ~tens of ms) and
            // we read its cache here — never blocks this serial tick.
            if slow { netLink?.refresh(interface: s.interfaceName) }
            latest.netLink = netLink?.latest()
        }
        if gpu != nil, let s = try? gpu!.read() {
            latest.gpu = s; push("gpu", s.utilization)
        }
        if slow, let p = power?.read() {
            latest.power = p
            if enabled.contains(.power) { push("power", p.totalWatts) }
        }
        if slow, let temps = sensors?.read() {
            latest.temperatures = temps
        }
        if slow, let vi = powerSensors?.read(), !vi.isEmpty {
            latest.powerSensors = vi
        }
        if batt, battery != nil, let b = try? battery!.read() {
            latest.battery = b
        }
        // While a popup is open (and at the faster activeInterval), refresh the
        // process lists every tick. CPU comes from `top` so root-owned daemons (mds,
        // kernel_task, the security agent) are included — libproc can't read them
        // unprivileged. Memory stays on the libproc ProcSampler: it's exact for the
        // user apps that actually dominate RAM, and the root daemons it misses are
        // tiny on the memory axis.
        if procFlag.get() {
            if procs == nil { procs = ProcSampler() }
            latest.topByMemory = procs!.sample(limit: 5).byMemory
            if topProc == nil {
                topProc = TopProcessReader()
                topProc!.onUpdate = { [weak self] in self?.deliverProcUpdate() }
            }
            // 12 = enough headroom that the cpu-ranked window also contains the energy
            // leaders; both lists are trimmed to 5 below.
            topProc!.refresh(limit: 12)
            let rows = topProc!.latest()   // empty until the first top frame lands
            if !rows.isEmpty {
                latest.topByCPU = Array(rows.prefix(5))                              // already cpu-sorted
                latest.topByPower = Array(rows.sorted { $0.power > $1.power }.prefix(5))
            }
            if enabled.contains(.network) {
                if netProc == nil {
                    netProc = NetProcessReader()
                    netProc!.onUpdate = { [weak self] in self?.deliverProcUpdate() }
                }
                netProc!.refresh(limit: 8)
                latest.topByNetwork = netProc!.latest()
            }
        }

        deliver()
    }

    /// Snapshot the rings onto the delivered value (so the UI never reaches back into
    /// `queue`) and hand it to the delivery queue. Small (≤120 Doubles × 6 keys).
    /// Must run on `queue`.
    private func deliver() {
        latest.histories = histories.mapValues { $0.snapshot() }
        let snap = latest
        deliverQueue.async { [onSnapshot] in onSnapshot?(snap) }
    }

    /// Called (off-queue) by the process/network readers the instant their async
    /// sample lands. Pulls the fresh caches into `latest` and delivers immediately so
    /// a just-opened popup fills in ~1 s after open instead of waiting a poll tick.
    private func deliverProcUpdate() {
        queue.async { [self] in
            guard procFlag.get() else { return }   // popup closed mid-flight → drop
            if let r = topProc?.latest(), !r.isEmpty {
                latest.topByCPU = Array(r.prefix(5))
                latest.topByPower = Array(r.sorted { $0.power > $1.power }.prefix(5))
            }
            if let n = netProc?.latest(), !n.isEmpty { latest.topByNetwork = n }
            deliver()
        }
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
