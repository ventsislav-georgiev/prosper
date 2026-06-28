// The popover shown when a menu-bar item is clicked. Modelled 1:1 on the
// exelban/Stats module popups — a header strip (module glyph · centred title ·
// settings gear), a row of circular gauges for the primary metric(s), a
// centred-divider "Usage history" chart, centred "Details" sections with
// colour-square legends, and a "Top processes" list with real app icons — but
// painted in the Prosper neon palette. The sensors popup also hosts the fan
// readout AND its manual control (confirmation-gated inline), so nothing about
// the fans lives in the settings pane. The controller flips on the expensive
// top-process scan only while this is open.

import SwiftUI
import AppKit
import Charts
import StatsCore

struct StatsPopupView: View {
    let module: StatsModule
    @ObservedObject var store: StatsStore

    /// Live fan readout for the sensors popover. Refreshed every few store ticks
    /// while open — an unprivileged SMC open/close, never the write path.
    @State private var fans: [FanReading] = []
    @State private var fanTick = 0

    // Fan manual control (sensors popup only). Default OFF, opt-in, confirmation-
    // gated inline (a modal alert would dismiss the transient popover).
    @State private var fanManual = Preferences.fanManualEnabled
    @State private var fanTargets = Preferences.fanTargets
    @State private var fanConfirming = false
    @State private var fanCommitWork: DispatchWorkItem?

    var body: some View {
        VStack(alignment: .leading, spacing: sz(12)) {
            header
            primary
            historySection
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

    // MARK: - Header (glyph · centred title · settings gear)

    private var header: some View {
        ZStack {
            Text(title)
                .font(Neon.font(14, weight: .bold, design: .rounded))
                .frame(maxWidth: .infinity)
            HStack {
                Image(systemName: module.sfSymbol)
                    .font(Neon.font(13, weight: .semibold))
                    .foregroundStyle(Neon.blue)
                Spacer()
                Button {
                    LiveExtensionHostServices.shared.settingsOpener?("system-stats")
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(Neon.font(12, weight: .semibold))
                        .foregroundStyle(Neon.textSecondary)
                }
                .buttonStyle(.plain)
                .help("System Stats settings")
            }
        }
    }

    private var title: String {
        switch module {
        case .cpu: "CPU"; case .memory: "Memory"; case .network: "Network"
        case .gpu: "GPU"; case .power: "Power"
        case .sensors: "Sensors"; case .battery: "Battery"
        }
    }

    // MARK: - Primary metric display (gauges / glyph / readout)

    @ViewBuilder
    private var primary: some View {
        switch module {
        case .cpu, .memory, .gpu: gaugeRow
        case .battery: batteryPrimary
        case .network: networkPrimary
        case .power, .sensors: bigReadout
        }
    }

    private var ringColor: Color {
        store.style.config(module).rampColor(module.rampValue(store.snapshot) ?? 0)
    }

    /// One or two circular gauges, centred — exelban's signature donut layout.
    private var gaugeRow: some View {
        HStack(spacing: sz(28)) {
            StatsGauge(value: module.rampValue(store.snapshot) ?? 0,
                       color: ringColor,
                       big: module.primaryText(store.snapshot, showUnit: true),
                       caption: gaugeCaption)
            if module == .cpu, let t = maxTemp {
                StatsGauge(value: min(1, max(0, (t - 30) / 70)),
                           color: tempColor(t),
                           big: StatsFormat.temp(t),
                           caption: "Temperature")
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var gaugeCaption: String {
        switch module {
        case .cpu: return "Usage"
        case .memory:
            guard let m = store.snapshot.memory else { return "Usage" }
            return "\(StatsFormat.bytes(Double(m.used))) / \(StatsFormat.bytes(Double(m.total)))"
        case .gpu: return store.snapshot.gpu?.name ?? "Usage"
        default: return "Usage"
        }
    }

    private var maxTemp: Double? {
        store.snapshot.temperatures?.map(\.celsius).max()
    }

    private func tempColor(_ c: Double) -> Color {
        store.style.config(.sensors).rampColor(min(1, max(0, (c - 30) / 70)))
    }

    private var batteryPrimary: some View {
        let b = store.snapshot.battery
        return HStack(spacing: sz(12)) {
            BatteryGlyph(charge: b?.charge ?? 0, charging: b?.isCharging ?? false, color: ringColor)
            VStack(alignment: .leading, spacing: sz(2)) {
                Text(module.primaryText(store.snapshot, showUnit: true))
                    .font(Neon.font(20, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(ringColor)
                if let b { Text(batteryState(b)).font(Neon.font(.caption)).foregroundStyle(Neon.textSecondary) }
            }
            Spacer()
        }
    }

    private var networkPrimary: some View {
        let n = store.snapshot.network
        let cfg = store.style.config(.network)
        return HStack(spacing: sz(24)) {
            channelBig("arrow.down", n?.downloadBytesPerSec ?? 0, cfg.down.color)
            channelBig("arrow.up", n?.uploadBytesPerSec ?? 0, cfg.up.color)
        }
        .frame(maxWidth: .infinity)
    }

    private func channelBig(_ symbol: String, _ rate: Double, _ color: Color) -> some View {
        HStack(spacing: sz(6)) {
            Image(systemName: symbol).font(Neon.font(13, weight: .bold)).foregroundStyle(color)
            Text(StatsFormat.rateLong(rate))
                .font(Neon.font(15, weight: .bold, design: .rounded).monospacedDigit())
        }
    }

    private var bigReadout: some View {
        Text(module.primaryText(store.snapshot, showUnit: true))
            .font(Neon.font(28, weight: .bold, design: .rounded).monospacedDigit())
            .foregroundStyle(ringColor)
            .frame(maxWidth: .infinity)
    }

    // MARK: - Usage history chart (single, or dual up/down for network)

    @ViewBuilder
    private var historySection: some View {
        switch module {
        case .network:
            section("Usage history")
            networkChart
        default:
            if let key = module.historyKey {
                section("Usage history")
                areaChart(store.history(key), ringColor, maxV(key))
            }
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
        VStack(alignment: .leading, spacing: sz(6)) {
            if !c.perCore.isEmpty {
                section("Cores")
                coreBars(c.perCore)
            }
            section("Details")
            legend(Neon.blue, "System", StatsFormat.percent(c.system))
            legend(Color(red: 0.30, green: 0.85, blue: 0.40), "User", StatsFormat.percent(c.user))
            legend(Neon.textSecondary.opacity(0.5), "Idle", StatsFormat.percent(c.idle))
            if !c.efficiency.isNaN { kv("Efficiency cores", StatsFormat.percent(c.efficiency)) }
            if !c.performance.isNaN { kv("Performance cores", StatsFormat.percent(c.performance)) }
            if !c.freqE.isNaN || !c.freqP.isNaN {
                section("Frequency")
                if !c.freqE.isNaN { kv("Efficiency", String(format: "%.2f GHz", c.freqE)) }
                if !c.freqP.isNaN { kv("Performance", String(format: "%.2f GHz", c.freqP)) }
            }
            if c.loadAverage.count == 3 || c.uptimeSeconds > 0 {
                section("System")
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
        VStack(alignment: .leading, spacing: sz(6)) {
            StackedBar(segments: [(Double(m.app), Neon.blue),
                                  (Double(m.wired), .orange),
                                  (Double(m.compressed), .purple)],
                       total: Double(m.total))
            section("Details")
            legend(Neon.blue, "App", StatsFormat.bytes(Double(m.app)))
            legend(.orange, "Wired", StatsFormat.bytes(Double(m.wired)))
            legend(.purple, "Compressed", StatsFormat.bytes(Double(m.compressed)))
            kv("Used", StatsFormat.bytes(Double(m.used)))
            if m.cached > 0 { kv("Cached files", StatsFormat.bytes(Double(m.cached))) }
            kv("Free", StatsFormat.bytes(Double(m.free)))
            kv("Pressure", m.pressureState)
            if m.swapTotal > 0 {
                kv("Swap", "\(StatsFormat.bytes(Double(m.swapUsed))) / \(StatsFormat.bytes(Double(m.swapTotal)))")
            } else if m.swapUsed > 0 {
                kv("Swap used", StatsFormat.bytes(Double(m.swapUsed)))
            }
        }
    }

    private func netDetail(_ n: NetworkSample) -> some View {
        VStack(alignment: .leading, spacing: sz(6)) {
            section("Details")
            kv("Download", StatsFormat.rateLong(n.downloadBytesPerSec))
            kv("Upload", StatsFormat.rateLong(n.uploadBytesPerSec))
            kv("Total down", StatsFormat.bytes(Double(n.totalDownloaded)))
            kv("Total up", StatsFormat.bytes(Double(n.totalUploaded)))
            if n.interfaceName != nil || n.ipv4 != nil || n.ssid != nil {
                section("Interface")
                if let s = n.ssid { kv("Wi-Fi", s) }
                if let i = n.interfaceName { kv("Interface", i) }
                if let ip = n.ipv4 { kv("IP address", ip) }
            }
        }
    }

    private func gpuDetail(_ g: GPUSample) -> some View {
        VStack(alignment: .leading, spacing: sz(6)) {
            section("Details")
            kv("Utilization", StatsFormat.percent(g.utilization))
            if !g.renderUtil.isNaN { kv("Renderer", StatsFormat.percent(g.renderUtil)) }
            if !g.tilerUtil.isNaN { kv("Tiler", StatsFormat.percent(g.tilerUtil)) }
            if g.usedMemory > 0 { kv("VRAM in use", StatsFormat.bytes(Double(g.usedMemory))) }
            if g.coreCount > 0 { kv("GPU cores", "\(g.coreCount)") }
            if !g.fps.isNaN && g.fps > 0 { kv("Frames presented", String(format: "%.0f fps", g.fps)) }
        }
    }

    private func powerDetail(_ p: PowerSample) -> some View {
        VStack(alignment: .leading, spacing: sz(6)) {
            section("Details")
            kv("CPU", StatsFormat.watts(p.cpuWatts))
            kv("GPU", StatsFormat.watts(p.gpuWatts))
            kv("ANE", StatsFormat.watts(p.aneWatts))
            if p.dramWatts > 0 { kv("DRAM", StatsFormat.watts(p.dramWatts)) }
            kv("Total", StatsFormat.watts(p.totalWatts))
        }
    }

    private var sensorDetail: some View {
        let temps = (store.snapshot.temperatures ?? []).sorted { $0.celsius > $1.celsius }
        return VStack(alignment: .leading, spacing: sz(6)) {
            if !temps.isEmpty {
                section("Temperatures")
                let rows = ForEach(temps, id: \.name) { t in kv(t.name, StatsFormat.temp(t.celsius)) }
                if temps.count > 8 {
                    ScrollView { VStack(spacing: sz(4)) { rows } }.frame(maxHeight: sz(150))
                } else {
                    rows
                }
            }
            if !fans.isEmpty { fanSection }
            let vi = store.snapshot.powerSensors ?? []
            let volts = vi.filter { $0.unit == .volt }
            let amps = vi.filter { $0.unit == .amp }
            if !volts.isEmpty {
                section("Voltage")
                ForEach(volts, id: \.name) { v in kv(v.name, String(format: "%.2f V", v.value)) }
            }
            if !amps.isEmpty {
                section("Current")
                ForEach(amps, id: \.name) { a in kv(a.name, String(format: "%.2f A", a.value)) }
            }
        }
    }

    // MARK: - Fans (display + manual control, confirmation-gated inline)

    @ViewBuilder
    private var fanSection: some View {
        section("Fans")
        ForEach(fans) { f in kv("Fan \(f.id + 1)", "\(Int(f.current.rounded())) rpm") }
        Toggle(isOn: Binding(
            get: { fanManual },
            set: { want in
                if want { fanConfirming = true }    // confirm BEFORE any privileged write
                else { fanConfirming = false; disableFans() }
            })) {
                Text("Manual control").font(Neon.font(.caption)).foregroundStyle(Neon.textSecondary)
            }
            .toggleStyle(.switch).controlSize(.mini)
            .padding(.top, sz(2))
        if fanConfirming && !fanManual {
            Text("Writes fan speeds to hardware as root. Too low can overheat. "
                 + "Resets to automatic on sleep, quit, or disable.")
                .font(Neon.font(10)).foregroundStyle(Neon.textSecondary)
            HStack {
                Button("Cancel") { fanConfirming = false }.buttonStyle(.plain).foregroundStyle(Neon.textSecondary)
                Spacer()
                Button("Enable") { enableFans() }.foregroundStyle(.red)
            }
            .font(Neon.font(.caption, weight: .semibold))
        }
        if fanManual {
            ForEach(fans) { fan in fanSlider(fan) }
        }
    }

    private func fanSlider(_ fan: FanReading) -> some View {
        let value = fanTargets[fan.id] ?? clampRPM(fan.current, fan)
        return VStack(alignment: .leading, spacing: sz(2)) {
            HStack {
                Text("Fan \(fan.id + 1)").font(Neon.font(.caption)).foregroundStyle(Neon.textSecondary)
                Spacer()
                Text("\(Int(value)) rpm").font(Neon.font(.caption, weight: .semibold).monospacedDigit())
            }
            Slider(value: Binding(
                get: { fanTargets[fan.id] ?? clampRPM(fan.current, fan) },
                set: { v in fanTargets[fan.id] = v; commitFan(fan.id, v) }),
                   in: fan.min...fan.max)
                .controlSize(.mini)
        }
    }

    private func clampRPM(_ v: Double, _ fan: FanReading) -> Double {
        Swift.min(Swift.max(v, fan.min), fan.max)
    }

    private func enableFans() {
        fanConfirming = false
        fanManual = true
        Preferences.fanManualEnabled = true
        var t = Preferences.fanTargets
        for f in fans where t[f.id] == nil { t[f.id] = clampRPM(f.current, f) }
        Preferences.fanTargets = t
        fanTargets = t
        Task { await FanControlHelper.reapplyFromPreferences() }
    }

    private func disableFans() {
        fanManual = false
        Preferences.fanManualEnabled = false
        Task { await FanControlHelper.resetAll(teardown: true) }
    }

    /// Persist immediately (cheap) but debounce the slow root SMC write.
    private func commitFan(_ index: Int, _ rpm: Double) {
        var t = Preferences.fanTargets; t[index] = rpm; Preferences.fanTargets = t
        fanCommitWork?.cancel()
        let work = DispatchWorkItem { Task { await FanControlHelper.setManual(index, rpm: rpm) } }
        fanCommitWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func batteryDetail(_ b: BatterySample) -> some View {
        VStack(alignment: .leading, spacing: sz(6)) {
            section("Details")
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

    // MARK: - Top processes (CPU / RAM), with real app icons

    private var topProcesses: some View {
        let procs = module == .cpu ? store.snapshot.topByCPU : store.snapshot.topByMemory
        return VStack(alignment: .leading, spacing: sz(5)) {
            section("Top processes")
            if let procs, !procs.isEmpty {
                ForEach(procs, id: \.pid) { p in
                    procRow(p, module == .cpu ? StatsFormat.percent(p.cpu) : StatsFormat.bytes(Double(p.memory)))
                }
            } else {
                Text("Sampling…").font(Neon.font(.caption)).foregroundStyle(Neon.textSecondary)
            }
        }
    }

    private func procRow(_ p: ProcInfo, _ value: String) -> some View {
        HStack(spacing: sz(7)) {
            ProcessIcon(pid: p.pid)
            Text(p.name).font(Neon.font(.caption)).foregroundStyle(Neon.textPrimary).lineLimit(1)
            Spacer(minLength: sz(8))
            Text(value).font(Neon.font(.caption, weight: .semibold).monospacedDigit())
        }
    }

    // MARK: - Shared rows

    /// Centred section header — a small-caps title flanked by hairline rules,
    /// matching exelban's divider style.
    private func section(_ t: String) -> some View {
        HStack(spacing: sz(8)) {
            rule
            Text(t).font(Neon.font(10, weight: .semibold)).foregroundStyle(Neon.textSecondary).fixedSize()
            rule
        }
        .padding(.top, sz(2))
    }

    private var rule: some View {
        Rectangle().fill(Neon.textSecondary.opacity(0.22)).frame(height: 1)
    }

    /// A detail row prefixed with a colour square — exelban's legend style.
    private func legend(_ color: Color, _ k: String, _ v: String) -> some View {
        HStack(spacing: sz(6)) {
            RoundedRectangle(cornerRadius: sz(2)).fill(color).frame(width: sz(9), height: sz(9))
            Text(k).font(Neon.font(.caption)).foregroundStyle(Neon.textSecondary).lineLimit(1)
            Spacer(minLength: sz(8))
            Text(v).font(Neon.font(.caption, weight: .semibold).monospacedDigit())
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

// MARK: - Gauge, process icon, battery glyph, stacked bar

/// A circular gauge: a ring with the value centred and a caption beneath —
/// exelban's primary-metric donut.
private struct StatsGauge: View {
    let value: Double
    let color: Color
    let big: String
    let caption: String

    var body: some View {
        VStack(spacing: sz(5)) {
            StatsRing(value: value, color: color, lineWidth: sz(6), label: big)
                .frame(width: sz(64), height: sz(64))
            Text(caption)
                .font(Neon.font(10, weight: .semibold))
                .foregroundStyle(Neon.textSecondary)
                .lineLimit(1)
        }
    }
}

/// The running app's Dock icon for a pid, or a neutral glyph for daemons that
/// have none. Looked up live — the lookup is cheap and the list is short.
private struct ProcessIcon: View {
    let pid: Int32
    var body: some View {
        if let icon = NSRunningApplication(processIdentifier: pid)?.icon {
            Image(nsImage: icon).resizable().interpolation(.high)
                .frame(width: sz(15), height: sz(15))
        } else {
            Image(systemName: "terminal")
                .font(Neon.font(10))
                .foregroundStyle(Neon.textSecondary)
                .frame(width: sz(15), height: sz(15))
        }
    }
}

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
