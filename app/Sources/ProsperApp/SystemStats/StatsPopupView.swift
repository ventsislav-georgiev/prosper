// The popover shown when a menu-bar item is clicked. Modelled 1:1 on the
// exelban/Stats module popups: a header strip (a constant bar-chart glyph · the
// centred module title · a settings gear), a row of circular gauges for the
// primary metric(s), a centred-divider "Usage history" chart with per-core bars
// beneath it, centred "Details"/"Frequency"/"Average load" sections with
// colour-dot legends, and a "Top processes" list with real app icons — painted
// in the Prosper neon palette. The sensors popup also hosts the fan readout AND
// its per-fan Automatic/Manual control (confirmation-gated inline), so nothing
// about the fans lives in the settings pane. The controller flips on the
// expensive top-process scan only while this is open.

import SwiftUI
import AppKit
import Charts
import StatsCore

/// Load/cluster legend colours, matched to exelban's CPU popup.
private enum LoadColor {
    static let system = Color(red: 0.98, green: 0.27, blue: 0.22)   // red
    static let user   = Neon.blue                                   // blue
    static let idle   = Neon.textSecondary.opacity(0.55)            // grey
    static let eff    = Color(red: 0.12, green: 0.78, blue: 0.74)   // teal — E-cluster
    static let perf   = Color(red: 0.46, green: 0.42, blue: 0.95)   // purple — P-cluster
}

struct StatsPopupView: View {
    let module: StatsModule
    @ObservedObject var store: StatsStore

    private let facts = SystemFacts.current

    /// Live fan readout for the sensors popover. Refreshed every few store ticks
    /// while open — an unprivileged SMC open/close, never the write path.
    @State private var fans: [FanReading] = []
    @State private var fanTick = 0

    // Fan manual control (sensors popup only). Default OFF, opt-in, confirmation-
    // gated inline (a modal alert would dismiss the transient popover).
    @State private var fanManual = Preferences.fanManualEnabled
    @State private var fanTargets = Preferences.fanTargets
    @State private var pendingManualFan: Int?
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

    // MARK: - Header (bar-chart glyph · centred title · settings gear)

    private var header: some View {
        ZStack {
            Text(title)
                .font(Neon.font(15, weight: .bold, design: .rounded))
                .frame(maxWidth: .infinity)
            HStack {
                Image(systemName: "chart.bar.fill")
                    .font(Neon.font(13, weight: .semibold))
                    .foregroundStyle(Neon.blue)
                Spacer()
                Button {
                    LiveExtensionHostServices.shared.settingsOpener?("system-stats")
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(Neon.font(13, weight: .semibold))
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
        case .cpu: cpuGauges
        case .memory, .gpu: singleGauge
        case .battery: batteryPrimary
        case .network: networkPrimary
        case .power, .sensors: bigReadout
        }
    }

    private var ringColor: Color {
        store.style.config(module).rampColor(module.rampValue(store.snapshot) ?? 0)
    }

    /// CPU's three donuts: temperature · usage (system/user split) · 1-min load.
    private var cpuGauges: some View {
        let c = store.snapshot.cpu
        return HStack(spacing: sz(16)) {
            if let t = maxTemp {
                StatsRing(value: min(1, max(0, (t - 30) / 70)), color: tempColor(t),
                          lineWidth: sz(6), label: String(format: "%.0f°C", t))
                    .frame(width: sz(58), height: sz(58))
            }
            SegmentedRing(
                segments: [(c?.system ?? 0, LoadColor.system), (c?.user ?? 0, LoadColor.user)],
                lineWidth: sz(8),
                label: c.map { StatsFormat.percent($0.total) } ?? "—")
                .frame(width: sz(74), height: sz(74))
            if let l = load1 {
                StatsRing(value: min(1, l / Double(max(facts.logicalCores, 1))),
                          color: Neon.blue, lineWidth: sz(6),
                          label: String(format: "%.2f", l))
                    .frame(width: sz(58), height: sz(58))
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// Memory / GPU: a single usage donut.
    private var singleGauge: some View {
        StatsRing(value: module.rampValue(store.snapshot) ?? 0, color: ringColor,
                  lineWidth: sz(8), label: module.primaryText(store.snapshot, showUnit: true))
            .frame(width: sz(74), height: sz(74))
            .frame(maxWidth: .infinity)
    }

    private var maxTemp: Double? { store.snapshot.temperatures?.map(\.celsius).max() }
    private var load1: Double? {
        guard let l = store.snapshot.cpu?.loadAverage, l.count == 3 else { return nil }
        return l[0]
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
            channelBig("arrow.up", n?.uploadBytesPerSec ?? 0, cfg.up.color)
            channelBig("arrow.down", n?.downloadBytesPerSec ?? 0, cfg.down.color)
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
        case .cpu:
            if let key = module.historyKey {
                section("Usage history")
                areaChart(store.history(key), ringColor, maxV(key))
                if let c = store.snapshot.cpu, !c.perCore.isEmpty { coreBars(c.perCore) }
            }
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
                AreaMark(x: .value("t", i), y: .value("v", min(1, max(0, v / maxV))))
                    .foregroundStyle(color.opacity(0.18))
            }
            LineMark(x: .value("t", i), y: .value("v", min(1, max(0, v / maxV))))
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
            section("Details")
            legend(LoadColor.system, "System", StatsFormat.percent(c.system))
            legend(LoadColor.user, "User", StatsFormat.percent(c.user))
            legend(LoadColor.idle, "Idle", StatsFormat.percent(c.idle))
            if !c.efficiency.isNaN { legend(LoadColor.eff, "Efficiency cores", StatsFormat.percent(c.efficiency)) }
            if !c.performance.isNaN { legend(LoadColor.perf, "Performance cores", StatsFormat.percent(c.performance)) }
            if c.uptimeSeconds > 0 { kv("Uptime", uptimeText(c.uptimeSeconds)) }

            if c.loadAverage.count == 3 {
                section("Average load")
                kv("1 minute", String(format: "%.2f", c.loadAverage[0]))
                kv("5 minutes", String(format: "%.2f", c.loadAverage[1]))
                kv("15 minutes", String(format: "%.2f", c.loadAverage[2]))
            }

            if !c.freqE.isNaN || !c.freqP.isNaN {
                section("Frequency")
                if let all = allCoreFreq(c) { kv("All cores", String(format: "%.0f MHz", all)) }
                if !c.freqE.isNaN { legend(LoadColor.eff, "Efficiency cores", String(format: "%.0f MHz", c.freqE * 1000)) }
                if !c.freqP.isNaN { legend(LoadColor.perf, "Performance cores", String(format: "%.0f MHz", c.freqP * 1000)) }
            }
        }
    }

    /// Core-count-weighted blend of the two cluster frequencies, in MHz.
    private func allCoreFreq(_ c: CPUSample) -> Double? {
        let e = Double(facts.efficiencyCores), p = Double(facts.performanceCores)
        switch (c.freqE.isNaN, c.freqP.isNaN) {
        case (false, false) where e + p > 0: return (c.freqE * e + c.freqP * p) / (e + p) * 1000
        case (false, true): return c.freqE * 1000
        case (true, false): return c.freqP * 1000
        default: return nil
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
            if !fans.isEmpty { fanSection }
            if !temps.isEmpty {
                section("Temperature")
                // offset id, not name: duplicate sensor names (e.g. several "PMU tdie") are common.
                let rows = ForEach(Array(temps.enumerated()), id: \.offset) { _, t in kv(t.name, StatsFormat.tempDetail(t.celsius)) }
                if temps.count > 8 {
                    ScrollView { VStack(spacing: sz(6)) { rows } }.frame(maxHeight: sz(180))
                } else {
                    rows
                }
            }
            let vi = store.snapshot.powerSensors ?? []
            let volts = vi.filter { $0.unit == .volt }
            let amps = vi.filter { $0.unit == .amp }
            if !volts.isEmpty {
                section("Voltage")
                ForEach(Array(volts.enumerated()), id: \.offset) { _, v in kv(v.name, StatsFormat.volts(v.value)) }
            }
            if !amps.isEmpty {
                section("Current")
                ForEach(Array(amps.enumerated()), id: \.offset) { _, a in kv(a.name, StatsFormat.amps(a.value)) }
            }
        }
    }

    // MARK: - Fans (readout + per-fan Automatic/Manual, confirmation-gated inline)

    @ViewBuilder
    private var fanSection: some View {
        section("Fans")
        ForEach(fans) { fan in fanRow(fan) }
        if let pending = pendingManualFan {
            Text("Manual fan control writes speeds to hardware as root. Too low can "
                 + "overheat. Fans reset to automatic on sleep, quit, or disable.")
                .font(Neon.font(10)).foregroundStyle(Neon.textSecondary).padding(.top, sz(2))
            HStack {
                Button("Cancel") { pendingManualFan = nil }
                    .buttonStyle(.plain).foregroundStyle(Neon.textSecondary)
                Spacer()
                Button("Enable manual") { confirmManual(pending) }.foregroundStyle(.red)
            }
            .font(Neon.font(.caption, weight: .semibold))
        }
    }

    @ViewBuilder
    private func fanRow(_ fan: FanReading) -> some View {
        let manual = fanManual && fanTargets[fan.id] != nil
        // While manual, track the live target so the bar follows the slider instead of
        // lagging on the ~3 s SMC re-read of `fan.current`.
        let shownRPM = manual ? (fanTargets[fan.id] ?? fan.current) : fan.current
        let pct = fan.max > 0 ? shownRPM / fan.max : 0
        let adjustable = fan.max > fan.min   // degenerate (single-speed) fans crash Slider
        VStack(alignment: .leading, spacing: sz(5)) {
            HStack(spacing: sz(8)) {
                Text("Fan \(fan.id + 1)").font(Neon.font(.caption, weight: .bold))
                FanBar(fraction: pct)
                Text(StatsFormat.percent(pct))
                    .font(Neon.font(.caption, weight: .semibold).monospacedDigit())
            }
            if adjustable {
                Picker("", selection: Binding(
                    get: { manual ? 1 : 0 },
                    set: { sel in sel == 1 ? selectManual(fan) : selectAuto(fan) })) {
                        Text("Automatic").tag(0)
                        Text("Manual").tag(1)
                    }
                    .labelsHidden().pickerStyle(.segmented).controlSize(.small)
            }
            if manual && adjustable {
                Slider(value: Binding(
                    get: { fanTargets[fan.id] ?? clampRPM(fan.current, fan) },
                    set: { v in fanTargets[fan.id] = v; commitFan(fan.id, v) }),
                       in: fan.min...fan.max)
                    .controlSize(.mini)
                HStack {
                    Text("\(Int(fanTargets[fan.id] ?? fan.current)) rpm")
                        .font(Neon.font(10).monospacedDigit()).foregroundStyle(Neon.textSecondary)
                    Spacer()
                    Text("\(Int(fan.min))–\(Int(fan.max))")
                        .font(Neon.font(10).monospacedDigit()).foregroundStyle(Neon.textSecondary)
                }
            }
        }
    }

    private func selectManual(_ fan: FanReading) {
        if fanManual { confirmManual(fan.id) }   // already trusted — set straight away
        else { pendingManualFan = fan.id }        // first time → inline confirm
    }

    /// Turn one fan manual (post-confirmation): seed its target at the current RPM.
    private func confirmManual(_ index: Int) {
        pendingManualFan = nil
        fanManual = true
        Preferences.fanManualEnabled = true
        let seed = fans.first { $0.id == index }.map { clampRPM($0.current, $0) } ?? 0
        var t = Preferences.fanTargets; t[index] = seed; Preferences.fanTargets = t
        fanTargets = t
        Task { await FanControlHelper.setManual(index, rpm: seed) }
    }

    /// Hand one fan back to the OS. When the last manual fan goes auto, fully tear
    /// down (resets all + drops the daemon connection).
    private func selectAuto(_ fan: FanReading) {
        var t = Preferences.fanTargets; t[fan.id] = nil; Preferences.fanTargets = t
        fanTargets = t
        if t.isEmpty {
            fanManual = false
            Preferences.fanManualEnabled = false
            Task { await FanControlHelper.resetAll(teardown: true) }
        } else {
            Task { await FanControlHelper.setAuto(fan.id) }
        }
    }

    private func clampRPM(_ v: Double, _ fan: FanReading) -> Double {
        Swift.min(Swift.max(v, fan.min), fan.max)
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
            if !b.temperature.isNaN { kv("Temperature", StatsFormat.tempDetail(b.temperature)) }
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

    // MARK: - Per-core histogram (clustered colours: E teal, P purple)

    private func coreBars(_ cores: [Double]) -> some View {
        let eCount = facts.efficiencyCores
        return HStack(alignment: .bottom, spacing: sz(2)) {
            ForEach(cores.indices, id: \.self) { i in
                let v = max(0, min(1, cores[i]))
                // ponytail: host_processor_info lists E-cluster cores first on Apple
                // Silicon, so the first eCount indices are efficiency cores.
                let color = (eCount > 0 && i < eCount) ? LoadColor.eff : LoadColor.perf
                RoundedRectangle(cornerRadius: sz(2))
                    .fill(color.opacity(0.35 + 0.65 * v))
                    .frame(maxWidth: .infinity)
                    .frame(height: max(sz(3), sz(30) * CGFloat(v)))
            }
        }
        .frame(height: sz(30), alignment: .bottom)
    }

    // MARK: - Top processes (CPU / RAM), with real app icons

    private var topProcesses: some View {
        let procs = module == .cpu ? store.snapshot.topByCPU : store.snapshot.topByMemory
        return VStack(alignment: .leading, spacing: sz(5)) {
            section("Top processes")
            HStack {
                Text("Process").font(Neon.font(.caption)).foregroundStyle(Neon.textSecondary)
                Spacer()
                Text(module == .cpu ? "Usage" : "Memory").font(Neon.font(.caption)).foregroundStyle(Neon.textSecondary)
            }
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
            Text(t.uppercased())
                .font(Neon.font(10, weight: .semibold)).tracking(sz(0.6))
                .foregroundStyle(Neon.textSecondary).fixedSize()
            rule
        }
        .padding(.top, sz(2))
    }

    private var rule: some View {
        Rectangle().fill(Neon.textSecondary.opacity(0.22)).frame(height: 1)
    }

    /// A detail row prefixed with a colour dot — exelban's legend style.
    private func legend(_ color: Color, _ k: String, _ v: String) -> some View {
        HStack(spacing: sz(7)) {
            Circle().fill(color).frame(width: sz(8), height: sz(8))
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

// MARK: - Fan bar, process icon, battery glyph, stacked bar

/// A thin capsule track filled to `fraction` — exelban's fan-speed bar.
private struct FanBar: View {
    let fraction: Double
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Neon.textSecondary.opacity(0.2))
                Capsule().fill(Neon.blue)
                    .frame(width: g.size.width * CGFloat(min(1, max(0, fraction))))
            }
        }
        .frame(height: sz(5))
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
