// The popover shown when a menu-bar item is clicked. Mirrors the exelban/Stats
// popovers in the Prosper neon style: a leading ring/glyph headline, a history
// chart (single for cpu/mem/gpu/power, dual up/down for network), a per-module
// detail grid grouped under small-caps section headers, plus the live top-process
// list (CPU/RAM), a per-core load histogram (CPU), a stacked usage bar (RAM) and
// read-only fan RPM (sensors). The controller flips on the expensive top-process
// scan only while this is open.

import SwiftUI
import Charts
import StatsCore

struct StatsPopupView: View {
    let module: StatsModule
    @ObservedObject var store: StatsStore
    /// Read-only fan readout for the sensors popover. Refreshed every few store
    /// ticks while open — an unprivileged SMC open/close, never the write path; fan
    /// specs don't change at runtime so RPM is just a coarse live hint.
    @State private var fans: [FanReading] = []
    @State private var fanTick = 0

    var body: some View {
        VStack(alignment: .leading, spacing: sz(12)) {
            header
            chart
            detail
            if module == .cpu || module == .memory { topProcesses }
        }
        .padding(sz(16))
        .frame(width: sz(320))
        .background(Neon.bgTop)
        .foregroundStyle(Neon.textPrimary)
        .onAppear { if module == .sensors { fans = FanInfo.read() } }
        .onReceive(store.$snapshot) { _ in
            guard module == .sensors else { return }
            fanTick += 1
            if fanTick % 3 == 0 { fans = FanInfo.read() }   // ~3 s, not every 1 Hz tick
        }
    }

    // MARK: - Header (leading ring / battery glyph / icon)

    @ViewBuilder
    private var header: some View {
        switch module {
        case .cpu, .memory, .gpu: ringHeader
        case .battery: batteryHeader
        case .network: networkHeader
        case .sensors, .power: plainHeader
        }
    }

    private var ringColor: Color {
        store.style.config(module).rampColor(module.rampValue(store.snapshot) ?? 0)
    }

    private var ringHeader: some View {
        HStack(spacing: sz(12)) {
            StatsRing(value: module.rampValue(store.snapshot) ?? 0,
                      color: ringColor,
                      lineWidth: sz(7),
                      label: module.primaryText(store.snapshot, showUnit: true))
                .frame(width: sz(54), height: sz(54))
            VStack(alignment: .leading, spacing: sz(2)) {
                Text(title).font(Neon.font(15, weight: .bold, design: .rounded))
                if let sub = ringSubtitle {
                    Text(sub).font(Neon.font(.caption)).foregroundStyle(Neon.textSecondary).lineLimit(1)
                }
            }
            Spacer()
        }
    }

    private var ringSubtitle: String? {
        switch module {
        case .cpu:
            guard let c = store.snapshot.cpu else { return nil }
            var parts: [String] = []
            if !c.performance.isNaN { parts.append("P " + StatsFormat.percent(c.performance)) }
            if !c.efficiency.isNaN { parts.append("E " + StatsFormat.percent(c.efficiency)) }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        case .memory:
            guard let m = store.snapshot.memory else { return nil }
            return "\(StatsFormat.bytes(Double(m.used))) / \(StatsFormat.bytes(Double(m.total)))"
        case .gpu:
            return store.snapshot.gpu?.name
        default: return nil
        }
    }

    private var plainHeader: some View {
        HStack(spacing: sz(10)) {
            Image(systemName: module.sfSymbol)
                .font(Neon.font(16, weight: .semibold)).foregroundStyle(Neon.blue)
            Text(title).font(Neon.font(15, weight: .bold, design: .rounded))
            Spacer()
            Text(module.primaryText(store.snapshot, showUnit: true))
                .font(Neon.font(20, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(ringColor)
        }
    }

    private var networkHeader: some View {
        let n = store.snapshot.network
        return HStack(spacing: sz(10)) {
            Image(systemName: module.sfSymbol)
                .font(Neon.font(16, weight: .semibold)).foregroundStyle(Neon.blue)
            Text("Network").font(Neon.font(15, weight: .bold, design: .rounded))
            Spacer()
            VStack(alignment: .trailing, spacing: sz(1)) {
                channel("arrow.down", n?.downloadBytesPerSec ?? 0, store.style.config(.network).down.color)
                channel("arrow.up", n?.uploadBytesPerSec ?? 0, store.style.config(.network).up.color)
            }
        }
    }

    private func channel(_ symbol: String, _ rate: Double, _ color: Color) -> some View {
        HStack(spacing: sz(3)) {
            Image(systemName: symbol).font(Neon.font(9, weight: .bold)).foregroundStyle(color)
            Text(StatsFormat.rateLong(rate))
                .font(Neon.font(12, weight: .semibold, design: .rounded).monospacedDigit())
        }
    }

    private var batteryHeader: some View {
        let b = store.snapshot.battery
        return HStack(spacing: sz(12)) {
            BatteryGlyph(charge: b?.charge ?? 0,
                         charging: b?.isCharging ?? false,
                         color: ringColor)
            VStack(alignment: .leading, spacing: sz(2)) {
                Text("Battery").font(Neon.font(15, weight: .bold, design: .rounded))
                if let b { Text(batteryState(b)).font(Neon.font(.caption)).foregroundStyle(Neon.textSecondary) }
            }
            Spacer()
            Text(module.primaryText(store.snapshot, showUnit: true))
                .font(Neon.font(20, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(ringColor)
        }
    }

    private var title: String {
        switch module {
        case .cpu: "Processor"; case .memory: "Memory"; case .network: "Network"
        case .gpu: "Graphics"; case .power: "Power"
        case .sensors: "Temperature"; case .battery: "Battery"
        }
    }

    // MARK: - History chart (single, or dual up/down for network)

    @ViewBuilder
    private var chart: some View {
        switch module {
        case .network: networkChart
        default: if let key = module.historyKey { areaChart(store.history(key), ringColor, maxV(key)) }
        }
    }

    private func maxV(_ key: String) -> Double {
        key == "power" ? max(store.history(key).max() ?? 1, 0.0001) : 1.0
    }

    private func areaChart(_ values: [Double], _ color: Color, _ maxV: Double,
                           xMax: Int? = nil, lineOnly: Bool = false) -> some View {
        // Pin X to a shared domain so overlaid charts share one time axis (else
        // each auto-scales to its own count and the curves slide apart).
        let upper = Double(max((xMax ?? values.count) - 1, 1))
        return Chart(Array(values.enumerated()), id: \.offset) { i, v in
            if !lineOnly {
                AreaMark(x: .value("t", i), y: .value("v", min(1, v / maxV)))
                    .foregroundStyle(color.opacity(0.18))
            }
            LineMark(x: .value("t", i), y: .value("v", min(1, v / maxV)))
                .foregroundStyle(color)
        }
        .chartXAxis(.hidden).chartYAxis(.hidden)
        .chartYScale(domain: 0...1).chartXScale(domain: 0...upper)
        .frame(height: sz(70))
        .animation(nil, value: values.count)   // live-feed chart: no morphing tweens
    }

    // Two overlaid charts on a SHARED x-domain + peak. Download is the filled area;
    // upload draws as a line on top (no second fill) so neither occludes the other.
    private var networkChart: some View {
        let up = store.history("net.up"), down = store.history("net.down")
        let peak = max(up.max() ?? 0, down.max() ?? 0, 1)
        let n = max(up.count, down.count)
        let cfg = store.style.config(.network)
        return ZStack {
            areaChart(down, cfg.down.color, peak, xMax: n)
            areaChart(up, cfg.up.color, peak, xMax: n, lineOnly: true)
        }
    }

    // MARK: - Per-module detail

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
        VStack(alignment: .leading, spacing: sz(4)) {
            if !c.perCore.isEmpty {
                sectionHeader("CORES")
                coreBars(c.perCore)
            }
            sectionHeader("LOAD")
            kv("System", StatsFormat.percent(c.system))
            kv("User", StatsFormat.percent(c.user))
            kv("Idle", StatsFormat.percent(c.idle))
            if !c.efficiency.isNaN { kv("Efficiency cores", StatsFormat.percent(c.efficiency)) }
            if !c.performance.isNaN { kv("Performance cores", StatsFormat.percent(c.performance)) }
            if !c.freqE.isNaN || !c.freqP.isNaN {
                sectionHeader("FREQUENCY")
                if !c.freqE.isNaN { kv("Efficiency", String(format: "%.2f GHz", c.freqE)) }
                if !c.freqP.isNaN { kv("Performance", String(format: "%.2f GHz", c.freqP)) }
            }
            if c.loadAverage.count == 3 || c.uptimeSeconds > 0 {
                sectionHeader("SYSTEM")
                if c.loadAverage.count == 3 {
                    kv("Load average", c.loadAverage.map { String(format: "%.2f", $0) }.joined(separator: "  "))
                }
                if c.uptimeSeconds > 0 { kv("Uptime", uptimeText(c.uptimeSeconds)) }
            }
        }
    }

    private func uptimeText(_ s: Int) -> String {
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }

    private func memDetail(_ m: MemorySample) -> some View {
        VStack(alignment: .leading, spacing: sz(4)) {
            StackedBar(segments: [(Double(m.app), Neon.blue),
                                  (Double(m.wired), .orange),
                                  (Double(m.compressed), .purple)],
                       total: Double(m.total))
            sectionHeader("DETAILS")
            kv("Used", StatsFormat.bytes(Double(m.used)))
            kv("App", StatsFormat.bytes(Double(m.app)))
            kv("Wired", StatsFormat.bytes(Double(m.wired)))
            kv("Compressed", StatsFormat.bytes(Double(m.compressed)))
            kv("Free", StatsFormat.bytes(Double(m.free)))
            kv("Pressure", StatsFormat.percent(m.pressure))
            if m.swapUsed > 0 { kv("Swap used", StatsFormat.bytes(Double(m.swapUsed))) }
        }
    }

    private func netDetail(_ n: NetworkSample) -> some View {
        VStack(alignment: .leading, spacing: sz(4)) {
            sectionHeader("DETAILS")
            kv("Download", StatsFormat.rateLong(n.downloadBytesPerSec))
            kv("Upload", StatsFormat.rateLong(n.uploadBytesPerSec))
            kv("Total down", StatsFormat.bytes(Double(n.totalDownloaded)))
            kv("Total up", StatsFormat.bytes(Double(n.totalUploaded)))
            if n.interfaceName != nil || n.ipv4 != nil || n.ssid != nil {
                sectionHeader("INTERFACE")
                if let s = n.ssid { kv("Wi-Fi", s) }
                if let i = n.interfaceName { kv("Interface", i) }
                if let ip = n.ipv4 { kv("IP address", ip) }
            }
        }
    }

    private func gpuDetail(_ g: GPUSample) -> some View {
        VStack(alignment: .leading, spacing: sz(4)) {
            sectionHeader("DETAILS")
            kv("Utilization", StatsFormat.percent(g.utilization))
            if !g.renderUtil.isNaN { kv("Renderer", StatsFormat.percent(g.renderUtil)) }
            if !g.tilerUtil.isNaN { kv("Tiler", StatsFormat.percent(g.tilerUtil)) }
            if g.usedMemory > 0 { kv("VRAM in use", StatsFormat.bytes(Double(g.usedMemory))) }
            if g.coreCount > 0 { kv("GPU cores", "\(g.coreCount)") }
            if !g.fps.isNaN && g.fps > 0 { kv("Frames presented", String(format: "%.0f fps", g.fps)) }
        }
    }

    private func powerDetail(_ p: PowerSample) -> some View {
        VStack(alignment: .leading, spacing: sz(4)) {
            sectionHeader("DETAILS")
            kv("CPU", StatsFormat.watts(p.cpuWatts))
            kv("GPU", StatsFormat.watts(p.gpuWatts))
            kv("ANE", StatsFormat.watts(p.aneWatts))
            kv("Total", StatsFormat.watts(p.totalWatts))
        }
    }

    private var sensorDetail: some View {
        let temps = (store.snapshot.temperatures ?? []).sorted { $0.celsius > $1.celsius }
        return VStack(alignment: .leading, spacing: sz(4)) {
            if !temps.isEmpty {
                sectionHeader("TEMPERATURES")
                let rows = ForEach(temps, id: \.name) { t in kv(t.name, StatsFormat.temp(t.celsius)) }
                if temps.count > 8 {
                    ScrollView { VStack(spacing: sz(4)) { rows } }.frame(maxHeight: sz(150))
                } else {
                    rows
                }
            }
            if !fans.isEmpty {
                sectionHeader("FANS")
                ForEach(fans) { f in kv("Fan \(f.id + 1)", "\(Int(f.current.rounded())) rpm") }
            }
            let vi = store.snapshot.powerSensors ?? []
            let volts = vi.filter { $0.unit == .volt }
            let amps = vi.filter { $0.unit == .amp }
            if !volts.isEmpty {
                sectionHeader("VOLTAGE")
                ForEach(volts, id: \.name) { v in kv(v.name, String(format: "%.2f V", v.value)) }
            }
            if !amps.isEmpty {
                sectionHeader("CURRENT")
                ForEach(amps, id: \.name) { a in kv(a.name, String(format: "%.2f A", a.value)) }
            }
        }
    }

    private func batteryDetail(_ b: BatterySample) -> some View {
        VStack(alignment: .leading, spacing: sz(4)) {
            sectionHeader("DETAILS")
            if !b.health.isNaN { kv("Health", StatsFormat.percent(b.health)) }
            kv("Cycles", "\(b.cycleCount)")
            if b.maxCapacity > 0 { kv("Capacity", "\(b.currentCapacity) / \(b.maxCapacity) mAh") }
            kv("Power", StatsFormat.watts(b.powerWatts))
            if !b.voltage.isNaN { kv("Voltage", String(format: "%.2f V", b.voltage)) }
            if !b.amperage.isNaN { kv("Amperage", String(format: "%.2f A", b.amperage)) }
            if !b.temperature.isNaN { kv("Temperature", StatsFormat.temp(b.temperature)) }
            if b.adapterWatts > 0 { kv("Power adapter", StatsFormat.watts(b.adapterWatts)) }
            if b.isCharging, b.timeToFull > 0 { kv("Time to full", timeText(b.timeToFull)) }
            if !b.isCharging, b.timeToEmpty > 0 { kv("Time remaining", timeText(b.timeToEmpty)) }
        }
    }

    private func batteryState(_ b: BatterySample) -> String {
        b.isCharging ? "Charging" : (b.isPluggedIn ? "Plugged in" : "On battery")
    }

    private func timeText(_ minutes: Int) -> String {
        minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes) min"
    }

    // MARK: - Per-core histogram

    private func coreBars(_ cores: [Double]) -> some View {
        HStack(alignment: .bottom, spacing: sz(2)) {
            ForEach(cores.indices, id: \.self) { i in
                let v = max(0, min(1, cores[i]))
                RoundedRectangle(cornerRadius: sz(1))
                    .fill(store.style.config(.cpu).rampColor(v))
                    .frame(maxWidth: .infinity)
                    .frame(height: max(sz(2), sz(30) * CGFloat(v)))
            }
        }
        .frame(height: sz(30), alignment: .bottom)
    }

    // MARK: - Top processes (CPU / RAM)

    private var topProcesses: some View {
        let procs = module == .cpu ? store.snapshot.topByCPU : store.snapshot.topByMemory
        return VStack(alignment: .leading, spacing: sz(4)) {
            sectionHeader(module == .cpu ? "TOP PROCESSES — CPU" : "TOP PROCESSES — MEMORY")
            if let procs, !procs.isEmpty {
                ForEach(procs, id: \.pid) { p in
                    kv(p.name, module == .cpu ? StatsFormat.percent(p.cpu) : StatsFormat.bytes(Double(p.memory)))
                }
            } else {
                Text("Sampling…").font(Neon.font(.caption)).foregroundStyle(Neon.textSecondary)
            }
        }
    }

    // MARK: - Shared rows

    private func sectionHeader(_ t: String) -> some View {
        VStack(alignment: .leading, spacing: sz(4)) {
            NeonDivider()
            Text(t).font(Neon.font(9, weight: .bold)).tracking(sz(1)).foregroundStyle(Neon.textSecondary)
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

// MARK: - Battery glyph + stacked bar

/// A small battery outline filled to `charge`, with a charging bolt overlay.
private struct BatteryGlyph: View {
    let charge: Double
    let charging: Bool
    let color: Color

    var body: some View {
        HStack(spacing: sz(2)) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: sz(3))
                    .stroke(Neon.textSecondary, lineWidth: sz(1.5))
                    .frame(width: sz(36), height: sz(17))
                RoundedRectangle(cornerRadius: sz(1.5))
                    .fill(color)
                    .frame(width: max(sz(2), sz(30) * CGFloat(min(1, max(0, charge)))), height: sz(11))
                    .padding(.leading, sz(2.5))
                if charging {
                    Image(systemName: "bolt.fill")
                        .font(Neon.font(9, weight: .bold))
                        .foregroundStyle(Neon.textPrimary)
                        .frame(width: sz(36), height: sz(17))
                }
            }
            RoundedRectangle(cornerRadius: sz(1))
                .fill(Neon.textSecondary)
                .frame(width: sz(2.5), height: sz(7))
        }
    }
}

/// A horizontal usage bar split into coloured segments over `total`; the unused
/// remainder shows dim. Widths are computed against the live geometry width.
private struct StackedBar: View {
    let segments: [(Double, Color)]
    let total: Double
    var height: CGFloat = 8

    var body: some View {
        GeometryReader { g in
            HStack(spacing: 0) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                    Rectangle().fill(seg.1)
                        .frame(width: total > 0 ? g.size.width * CGFloat(max(0, seg.0) / total) : 0)
                }
                Rectangle().fill(Neon.textSecondary.opacity(0.15))
            }
        }
        .frame(height: sz(height))
        .clipShape(RoundedRectangle(cornerRadius: sz(height / 2)))
    }
}
