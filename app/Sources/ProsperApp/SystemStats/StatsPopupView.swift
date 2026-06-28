// The popover shown when a menu-bar item is clicked: a headline ring/value, a
// history chart for the metrics that keep one, a per-module key/value detail
// grid, and (CPU/RAM) the live top-process list. The controller flips on the
// expensive top-process scan only while this is open.

import SwiftUI
import Charts
import StatsCore

struct StatsPopupView: View {
    let module: StatsModule
    @ObservedObject var store: StatsStore

    var body: some View {
        VStack(alignment: .leading, spacing: sz(12)) {
            header
            if let key = module.historyKey { historyChart(key) }
            detail
            if module == .cpu || module == .memory { topProcesses }
        }
        .padding(sz(16))
        .frame(width: sz(320))
        .background(Neon.bgTop)
        .foregroundStyle(Neon.textPrimary)
    }

    private var header: some View {
        HStack(spacing: sz(10)) {
            Image(systemName: module.sfSymbol)
                .font(Neon.font(16, weight: .semibold))
                .foregroundStyle(Neon.blue)
            Text(title).font(Neon.font(15, weight: .bold, design: .rounded))
            Spacer()
            Text(module.primaryText(store.snapshot, showUnit: true))
                .font(Neon.font(20, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(store.style.config(module).rampColor(module.rampValue(store.snapshot) ?? 0))
        }
    }

    private var title: String {
        switch module {
        case .cpu: "Processor"; case .memory: "Memory"; case .network: "Network"
        case .gpu: store.snapshot.gpu?.name ?? "Graphics"; case .power: "Power"
        case .sensors: "Temperature"; case .battery: "Battery"
        }
    }

    private func historyChart(_ key: String) -> some View {
        let values = store.history(key)
        let normalized = (key == "power")
        let maxV = normalized ? max(values.max() ?? 1, 0.0001) : 1.0
        let color = store.style.config(module).rampColor(module.rampValue(store.snapshot) ?? 0)
        return Chart(Array(values.enumerated()), id: \.offset) { i, v in
            AreaMark(x: .value("t", i), y: .value("v", min(1, v / maxV)))
                .foregroundStyle(color.opacity(0.18))
            LineMark(x: .value("t", i), y: .value("v", min(1, v / maxV)))
                .foregroundStyle(color)
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: 0...1)
        .frame(height: sz(70))
        .animation(nil, value: values.count)   // live-feed chart: no morphing tweens
    }

    // MARK: - Per-module detail grid

    @ViewBuilder
    private var detail: some View {
        switch module {
        case .cpu:    if let c = store.snapshot.cpu { cpuDetail(c) }
        case .memory: if let m = store.snapshot.memory { memDetail(m) }
        case .network: if let n = store.snapshot.network { netDetail(n) }
        case .gpu:    if let g = store.snapshot.gpu { gpuDetail(g) }
        case .power:  if let p = store.snapshot.power { powerDetail(p) }
        case .sensors: sensorDetail
        case .battery: if let b = store.snapshot.battery { batteryDetail(b) }
        }
    }

    private func cpuDetail(_ c: CPUSample) -> some View {
        VStack(spacing: sz(4)) {
            kv("System", StatsFormat.percent(c.system))
            kv("User", StatsFormat.percent(c.user))
            if !c.efficiency.isNaN { kv("Efficiency cores", StatsFormat.percent(c.efficiency)) }
            if !c.performance.isNaN { kv("Performance cores", StatsFormat.percent(c.performance)) }
        }
    }

    private func memDetail(_ m: MemorySample) -> some View {
        VStack(spacing: sz(4)) {
            kv("Used", StatsFormat.bytes(Double(m.used)))
            kv("App", StatsFormat.bytes(Double(m.app)))
            kv("Wired", StatsFormat.bytes(Double(m.wired)))
            kv("Compressed", StatsFormat.bytes(Double(m.compressed)))
            kv("Free", StatsFormat.bytes(Double(m.free)))
            if m.swapUsed > 0 { kv("Swap used", StatsFormat.bytes(Double(m.swapUsed))) }
        }
    }

    private func netDetail(_ n: NetworkSample) -> some View {
        VStack(spacing: sz(4)) {
            kv("Download", StatsFormat.rateLong(n.downloadBytesPerSec))
            kv("Upload", StatsFormat.rateLong(n.uploadBytesPerSec))
            kv("Total down", StatsFormat.bytes(Double(n.totalDownloaded)))
            kv("Total up", StatsFormat.bytes(Double(n.totalUploaded)))
        }
    }

    private func gpuDetail(_ g: GPUSample) -> some View {
        VStack(spacing: sz(4)) {
            kv("Utilization", StatsFormat.percent(g.utilization))
            if g.usedMemory > 0 { kv("VRAM in use", StatsFormat.bytes(Double(g.usedMemory))) }
        }
    }

    private func powerDetail(_ p: PowerSample) -> some View {
        VStack(spacing: sz(4)) {
            kv("CPU", StatsFormat.watts(p.cpuWatts))
            kv("GPU", StatsFormat.watts(p.gpuWatts))
            kv("ANE", StatsFormat.watts(p.aneWatts))
            kv("Total", StatsFormat.watts(p.totalWatts))
        }
    }

    private var sensorDetail: some View {
        let temps = (store.snapshot.temperatures ?? []).sorted { $0.celsius > $1.celsius }.prefix(8)
        return VStack(spacing: sz(4)) {
            ForEach(Array(temps), id: \.name) { t in kv(t.name, StatsFormat.temp(t.celsius)) }
        }
    }

    private func batteryDetail(_ b: BatterySample) -> some View {
        VStack(spacing: sz(4)) {
            kv("Charge", StatsFormat.percent(b.charge))
            kv("State", b.isCharging ? "Charging" : (b.isPluggedIn ? "Plugged in" : "On battery"))
            if !b.health.isNaN { kv("Health", StatsFormat.percent(b.health)) }
            kv("Cycles", "\(b.cycleCount)")
            kv("Power", StatsFormat.watts(b.powerWatts))
            if !b.temperature.isNaN { kv("Temperature", StatsFormat.temp(b.temperature)) }
            if b.isCharging, b.timeToFull > 0 { kv("Time to full", "\(b.timeToFull) min") }
            if !b.isCharging, b.timeToEmpty > 0 { kv("Time remaining", "\(b.timeToEmpty) min") }
        }
    }

    // MARK: - Top processes (CPU / RAM)

    private var topProcesses: some View {
        let procs = module == .cpu ? store.snapshot.topByCPU : store.snapshot.topByMemory
        return VStack(alignment: .leading, spacing: sz(4)) {
            NeonDivider()
            Text(module == .cpu ? "TOP PROCESSES — CPU" : "TOP PROCESSES — MEMORY")
                .font(Neon.font(9, weight: .bold)).tracking(sz(1))
                .foregroundStyle(Neon.textSecondary)
            if let procs, !procs.isEmpty {
                ForEach(procs, id: \.pid) { p in
                    kv(p.name, module == .cpu ? StatsFormat.percent(p.cpu) : StatsFormat.bytes(Double(p.memory)))
                }
            } else {
                Text("Sampling…").font(Neon.font(.caption)).foregroundStyle(Neon.textSecondary)
            }
        }
    }

    private func kv(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).font(Neon.font(.caption)).foregroundStyle(Neon.textSecondary).lineLimit(1)
            Spacer(minLength: sz(8))
            Text(v).font(Neon.font(.caption, weight: .semibold).monospacedDigit())
        }
    }
}
