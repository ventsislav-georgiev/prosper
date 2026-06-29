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

    /// Rough full-load ANE power for util estimation — no residency channel exists.
    /// ponytail: calibration knob; Apple-silicon ANE peaks roughly here, tune per chip.
    private let aneWattsPeak: Double = 8.0

    /// Live fan readout for the sensors popover. Refreshed every few store ticks
    /// while open — an unprivileged SMC open/close, never the write path.
    @State private var fans: [FanReading] = []

    // Fan manual control (sensors popup only). Default OFF, opt-in, confirmation-
    // gated inline (a modal alert would dismiss the transient popover).
    @State private var fanManual = Preferences.fanManualEnabled
    @State private var fanTargets = Preferences.fanTargets
    @State private var pendingManual = false
    @State private var fanCommitWork: DispatchWorkItem?
    @State private var fanBusy = false           // engage in flight (daemon round-trip)
    @State private var fanError: String?         // last engage failure, shown inline

    /// Sensor the user pinned as the headline (menu bar + big readout); nil = auto.
    @State private var headlineSensor = Preferences.sensorsHeadlineSensor

    var body: some View {
        VStack(alignment: .leading, spacing: sz(12)) {
            header
            primary
            historySection
            detail
            if module == .cpu || module == .memory || module == .battery { topProcesses }
            if module == .network { networkProcesses }
        }
        .padding(sz(16))
        .frame(width: sz(320))
        .background(Neon.bgTop)
        .foregroundStyle(Neon.textPrimary)
        .onAppear { if module == .sensors { fans = FanInfo.read() } }
        .onReceive(store.$snapshot) { _ in
            guard module == .sensors else { return }
            // Re-read every tick: a cheap unprivileged SMC read, only while this popup
            // is open, and the readout must track real RPM closely enough to expose a
            // fan that isn't responding to a manual write.
            fans = FanInfo.read()
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
        case .memory: memoryGauges
        case .gpu: gpuGauges
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

    /// Memory: a pressure half-gauge (left) + a segmented app/wired/compressed
    /// usage donut (right), matching exelban's RAM popup.
    private var memoryGauges: some View {
        let m = store.snapshot.memory
        let total = Double(m?.total ?? 0)
        func frac(_ v: UInt64?) -> Double { total > 0 ? Double(v ?? 0) / total : 0 }
        return HStack(spacing: sz(24)) {
            PressureGauge(fraction: m?.pressure ?? 0, state: m?.pressureState ?? "—")
                .frame(width: sz(120), height: sz(78))
            SegmentedRing(
                segments: [(frac(m?.app), Neon.blue),
                           (frac(m?.wired), .orange),
                           (frac(m?.compressed), LoadColor.system)],
                lineWidth: sz(8),
                label: m.map { StatsFormat.percent($0.usedFraction) } ?? "—")
                .frame(width: sz(78), height: sz(78))
        }
        .frame(maxWidth: .infinity)
    }

    /// GPU: render · utilization (big) · tiler donuts, single-colour like exelban.
    private var gpuGauges: some View {
        let g = store.snapshot.gpu
        return HStack(spacing: sz(16)) {
            if let r = g?.renderUtil, !r.isNaN {
                StatsRing(value: r, color: Neon.blue, lineWidth: sz(6), label: StatsFormat.percent(r))
                    .frame(width: sz(58), height: sz(58))
            }
            StatsRing(value: g?.utilization ?? 0, color: ringColor, lineWidth: sz(8),
                      label: g.map { StatsFormat.percent($0.utilization) } ?? "—")
                .frame(width: sz(74), height: sz(74))
            if let t = g?.tilerUtil, !t.isNaN {
                StatsRing(value: t, color: Neon.blue, lineWidth: sz(6), label: StatsFormat.percent(t))
                    .frame(width: sz(58), height: sz(58))
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var maxTemp: Double? { store.snapshot.headlineTemperature(pinned: Preferences.sensorsHeadlineSensor) }
    private var load1: Double? {
        guard let l = store.snapshot.cpu?.loadAverage, l.count == 3 else { return nil }
        return l[0]
    }

    private func tempColor(_ c: Double) -> Color {
        store.style.config(.sensors).rampColor(min(1, max(0, (c - 30) / 70)))
    }

    /// A large centred battery glyph (green when on power), the charge percent, and
    /// a state pill — exelban's battery popup.
    private var batteryPrimary: some View {
        let b = store.snapshot.battery
        let onPower = b?.isCharging == true || b?.isPluggedIn == true
        return VStack(spacing: sz(8)) {
            BigBattery(charge: b?.charge ?? 0, charging: b?.isCharging ?? false,
                       onPower: onPower)
                .frame(width: sz(150), height: sz(74))
            HStack(alignment: .firstTextBaseline, spacing: sz(1)) {
                Text("\(Int(((b?.charge ?? 0) * 100).rounded()))")
                    .font(Neon.font(34, weight: .bold, design: .rounded).monospacedDigit())
                Text("%").font(Neon.font(15, weight: .semibold)).foregroundStyle(Neon.textSecondary)
            }
            if let b {
                StatusBadge(text: batteryState(b),
                            color: onPower ? .green : Neon.textSecondary,
                            symbol: b.isCharging ? "bolt.fill" : (b.isPluggedIn ? "powerplug.fill" : nil))
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// Download (left) and Upload (right): big rate, small unit, a colour dot + label
    /// beneath — exelban's network header.
    private var networkPrimary: some View {
        let n = store.snapshot.network
        let cfg = store.style.config(.network)
        return HStack(spacing: sz(40)) {
            channelBig(n?.downloadBytesPerSec ?? 0, "Download", cfg.down.color)
            channelBig(n?.uploadBytesPerSec ?? 0, "Upload", cfg.up.color)
        }
        .frame(maxWidth: .infinity)
    }

    private func channelBig(_ rate: Double, _ label: String, _ color: Color) -> some View {
        let parts = StatsFormat.rateMenu(rate).split(separator: " ", maxSplits: 1)
        return VStack(spacing: sz(2)) {
            HStack(alignment: .firstTextBaseline, spacing: sz(3)) {
                Text(parts.first.map(String.init) ?? "0")
                    .font(Neon.font(24, weight: .bold, design: .rounded).monospacedDigit())
                Text(parts.count > 1 ? String(parts[1]) : "B/s")
                    .font(Neon.font(11, weight: .semibold)).foregroundStyle(Neon.textSecondary)
            }
            HStack(spacing: sz(5)) {
                Circle().fill(color).frame(width: sz(8), height: sz(8))
                Text(label).font(Neon.font(.caption)).foregroundStyle(Neon.textSecondary)
            }
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
        // Hand-drawn in a Canvas, NOT Swift Charts. Swift Charts' first synchronous
        // layout (which `.preferredContentSize` forces on every freshly-built popover
        // hosting controller) cost ~2s per open — the whole popover felt frozen. A
        // Canvas area+line is the same picture for a fraction of the cost and matches
        // the network chart's renderer. X pinned to `upper` so overlaid charts share
        // one time axis; Y normalised 0…1 against maxV (Canvas y grows downward).
        let upper = CGFloat(max((xMax ?? values.count) - 1, 1))
        return Canvas { ctx, size in
            guard values.count > 1 else { return }
            func pt(_ i: Int) -> CGPoint {
                let frac = CGFloat(min(1, max(0, values[i] / maxV)))
                return CGPoint(x: size.width * CGFloat(i) / upper, y: size.height - frac * size.height)
            }
            var line = Path()
            line.move(to: pt(0))
            for i in 1..<values.count { line.addLine(to: pt(i)) }
            if !lineOnly {
                var area = line
                area.addLine(to: CGPoint(x: size.width * CGFloat(values.count - 1) / upper, y: size.height))
                area.addLine(to: CGPoint(x: pt(0).x, y: size.height))
                area.closeSubpath()
                ctx.fill(area, with: .color(color.opacity(0.18)))
            }
            ctx.stroke(line, with: .color(color), lineWidth: 1.5)
        }
        .frame(height: sz(70))
    }

    // Mirrored about the centre line — upload fills upward, download downward — each
    // normalised to its own peak, with the peak rates labelled top-left/bottom-left.
    // exelban's network history.
    private var networkChart: some View {
        let up = store.history("net.up"), down = store.history("net.down")
        let cfg = store.style.config(.network)
        let upPeak = up.max() ?? 0, downPeak = down.max() ?? 0
        return ZStack(alignment: .leading) {
            MirrorNetChart(up: up, upPeak: upPeak, upColor: cfg.up.color,
                           down: down, downPeak: downPeak, downColor: cfg.down.color)
                .frame(height: sz(90))
            VStack(alignment: .leading) {
                Text(StatsFormat.rateMenu(upPeak))
                Spacer()
                Text(StatsFormat.rateMenu(downPeak))
            }
            .font(Neon.font(10).monospacedDigit())
            .foregroundStyle(Neon.textSecondary)
            .padding(sz(4))
        }
        .frame(height: sz(90))
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
            section("Details")
            kv("Used", StatsFormat.bytes(Double(m.used)))
            StackedBar(segments: [(Double(m.app), Neon.blue),
                                  (Double(m.wired), .orange),
                                  (Double(m.compressed), LoadColor.system)],
                       total: Double(m.total))
            legend(Neon.blue, "App", StatsFormat.bytes(Double(m.app)))
            legend(.orange, "Wired", StatsFormat.bytes(Double(m.wired)))
            legend(LoadColor.system, "Compressed", StatsFormat.bytes(Double(m.compressed)))
            legend(LoadColor.idle, "Free", StatsFormat.bytes(Double(m.free)))
            if m.swapTotal > 0 {
                kv("Swap", "\(StatsFormat.bytes(Double(m.swapUsed))) / \(StatsFormat.bytes(Double(m.swapTotal)))")
            } else {
                kv("Swap", StatsFormat.bytes(Double(m.swapUsed)))
            }
        }
    }

    private func netDetail(_ n: NetworkSample) -> some View {
        let cfg = store.style.config(.network)
        let lat = store.snapshot.netLatency
        let link = store.snapshot.netLink
        return VStack(alignment: .leading, spacing: sz(6)) {
            if !store.snapshot.connectivity.isEmpty {
                section("Connectivity history")
                ConnectivityGrid(history: store.snapshot.connectivity, up: cfg.down.color)
            }
            section("Details")
            legend(cfg.up.color, "Total upload", StatsFormat.bytes(Double(n.totalUploaded)))
            legend(cfg.down.color, "Total download", StatsFormat.bytes(Double(n.totalDownloaded)))
            if let lat {
                kvBadge("Internet connection") {
                    StatusBadge(text: lat.reachable ? "UP" : "DOWN",
                                color: lat.reachable ? Color.green : LoadColor.system,
                                symbol: lat.reachable ? "arrow.up" : "arrow.down")
                }
                if !lat.latencyMs.isNaN { kv("Latency", String(format: "%.0f ms", lat.latencyMs)) }
                if !lat.jitterMs.isNaN { kv("Jitter", String(format: "%.0f ms", lat.jitterMs)) }
            }
            if n.interfaceName != nil || n.ssid != nil || link?.macAddress != nil {
                section("Interface")
                kvBadge("Status") {
                    StatusBadge(text: "UP", color: Color.green, symbol: "arrow.up")
                }
                if let i = n.interfaceName {
                    kv("Interface", n.ssid != nil ? "Wi-Fi (\(i))" : i)
                }
                if let mac = link?.macAddress { kv("Physical address", mac) }
                if let s = n.ssid {
                    kv("Network", link?.rssi.map { "\(s) (\($0))" } ?? s)
                }
            }
            if n.ipv4 != nil || link?.publicIP != nil {
                section("Address")
                if let ip = n.ipv4 { kv("Local IP", ip) }
                if let pub = link?.publicIP {
                    kv("Public IP", flag(link?.countryCode).map { "\($0) \(pub)" } ?? pub)
                }
            }
        }
    }

    /// ISO-3166 alpha-2 → regional-indicator flag emoji ("BG" → 🇧🇬). nil if absent/malformed.
    private func flag(_ iso2: String?) -> String? {
        guard let iso2, iso2.count == 2 else { return nil }
        var s = ""
        for u in iso2.uppercased().unicodeScalars {
            guard u.value >= 65, u.value <= 90, let r = Unicode.Scalar(127397 + u.value) else { return nil }
            s.unicodeScalars.append(r)
        }
        return s
    }

    private func gpuDetail(_ g: GPUSample) -> some View {
        VStack(alignment: .leading, spacing: sz(6)) {
            section("Details")
            kv("Model", facts.chipName)
            if g.coreCount > 0 { kv("Cores", "\(g.coreCount)") }
            kv("Utilization", StatsFormat.percent(g.utilization))
            if !g.renderUtil.isNaN { kv("Render utilization", StatsFormat.percent(g.renderUtil)) }
            if !g.tilerUtil.isNaN { kv("Tiler utilization", StatsFormat.percent(g.tilerUtil)) }
            // ANE has no public residency channel; derive a rough utilization from its
            // power draw vs a peak estimate. ponytail: heuristic divisor, tune if it
            // reads wrong on other chips — there's no exact source to compare against.
            if let p = store.snapshot.power, p.aneWatts > 0.01 {
                kv("ANE utilization", StatsFormat.percent(min(1, p.aneWatts / aneWattsPeak)))
            }
            if g.usedMemory > 0 { kv("VRAM in use", StatsFormat.bytes(Double(g.usedMemory))) }
            if !g.fps.isNaN && g.fps > 0 { kv("FPS", String(format: "%.0f", g.fps)) }
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
                headlinePicker(temps)
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

    // MARK: - Fans (readout + ONE synced Automatic/Manual control, like exelban/Stats)

    // Fans are governed together, not individually: one Automatic|Manual segmented
    // control plus min/max quick buttons drive every fan off a single 0…1 fraction
    // (each fan mapped into its own min…max range). Matches Stats' "sync" behaviour
    // and keeps the popover compact. The write path is still per-fan under the hood.

    private var fansAdjustable: [FanReading] { fans.filter { $0.max > $0.min } }

    @ViewBuilder
    private var fanSection: some View {
        section("Fans")
        ForEach(fans) { fan in fanReadout(fan) }

        let adj = fansAdjustable
        if !adj.isEmpty {
            let manual = fanManual && !fanTargets.isEmpty
            // Auto|Manual on its own line; the two quick buttons (min / max) sit to the
            // right and only act once manual is engaged.
            HStack(spacing: sz(6)) {
                // Segment tracks INTENT, not just the committed state: the moment Manual
                // is clicked it stays selected through confirm → enabling → success. Else
                // the bound value never left 0 during the multi-second engage and the
                // segment snapped straight back to Automatic ("resets instantly"). Locked
                // while a write is in flight so it can't be toggled mid-unlock.
                Picker("", selection: Binding(
                    get: { (manual || pendingManual || fanBusy) ? 1 : 0 },
                    set: { sel in sel == 1 ? selectManualAll() : selectAutoAll() })) {
                        Text("Automatic").tag(0)
                        Text("Manual").tag(1)
                    }
                    .labelsHidden().pickerStyle(.segmented).controlSize(.large)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .disabled(fanBusy)
                Button { applyFraction(0) } label: { Image(systemName: "minus.circle").font(Neon.font(18)) }
                    .buttonStyle(.plain).foregroundStyle(manual ? Neon.textPrimary : Neon.textSecondary.opacity(0.4))
                    .disabled(!manual).help("Quietest (minimum RPM)")
                Button { applyFraction(1) } label: { Image(systemName: "snowflake").font(Neon.font(18)) }
                    .buttonStyle(.plain).foregroundStyle(manual ? Neon.blueBright : Neon.textSecondary.opacity(0.4))
                    .disabled(!manual).help("Full speed (maximum RPM)")
            }
            .frame(maxWidth: .infinity)
            if manual {
                Slider(value: Binding(get: { fanFraction }, set: { applyFraction($0) }), in: 0...1)
                    .controlSize(.mini)
                HStack {
                    Text(StatsFormat.percent(fanFraction))
                        .font(Neon.font(10).monospacedDigit()).foregroundStyle(Neon.textSecondary)
                    Spacer()
                    Text("all fans").font(Neon.font(10)).foregroundStyle(Neon.textSecondary)
                }
            }
        }

        if pendingManual && !fanBusy {
            Text("Manual fan control writes speeds to hardware as root. Too low can "
                 + "overheat. Fans reset to automatic on sleep, quit, or disable.")
                .font(Neon.font(10)).foregroundStyle(Neon.textSecondary).padding(.top, sz(2))
            HStack {
                Button("Cancel") { pendingManual = false }
                    .buttonStyle(.plain).foregroundStyle(Neon.textSecondary)
                Spacer()
                Button("Enable manual") { confirmManualAll() }
                    .foregroundStyle(.red)
            }
            .font(Neon.font(.caption, weight: .semibold))
        }

        // Progress is its own block (NOT gated on pendingManual): confirmManualAll clears
        // pendingManual on click, and unlocking the SMC fan controller takes up to ~15s
        // (Ftst → thermalmonitord yield → spaced mode-key retries). Show a live spinner so
        // the click is never a dead button.
        if fanBusy {
            HStack(spacing: sz(6)) {
                ProgressView().controlSize(.small)
                Text("Enabling manual control…")
                    .font(Neon.font(.caption, weight: .semibold)).foregroundStyle(Neon.textPrimary)
            }
            .padding(.top, sz(2))
            Text("Unlocking the fan controller can take up to ~15 seconds.")
                .font(Neon.font(10)).foregroundStyle(Neon.textSecondary)
        }

        if let err = fanError {
            Text(err).font(Neon.font(10)).foregroundStyle(.red).padding(.top, sz(2))
        }
    }

    /// Live per-fan bar — ALWAYS the real measured RPM (`F{i}Ac`), never the slider
    /// target. The bar/percent must reflect what the hardware is actually doing so a
    /// fan that isn't responding to a manual write reads honestly (stays put) instead
    /// of optimistically tracking the drag. RPM number shown so it's unambiguous.
    private func fanReadout(_ fan: FanReading) -> some View {
        // Normalize into the fan's operating range (min…max), same basis as the slider
        // fraction (line ~641) and exelban/Stats — else readout % and slider % disagree.
        let pct = fan.max > fan.min ? Swift.min(1, Swift.max(0, (fan.current - fan.min) / (fan.max - fan.min))) : 0
        let target = (fanManual ? fanTargets[fan.id] : nil)
        return HStack(spacing: sz(8)) {
            Text("Fan \(fan.id + 1)").font(Neon.font(.caption, weight: .bold))
            FanBar(fraction: pct)
            // Show the manual target alongside actual so a non-responding fan is obvious
            // (e.g. "1200 → 3000 rpm" while the bar sits at 1200).
            Text(target != nil ? "\(Int(fan.current)) → \(Int(target!)) rpm" : "\(Int(fan.current)) rpm")
                .font(Neon.font(10).monospacedDigit()).foregroundStyle(Neon.textSecondary)
            Text(StatsFormat.percent(pct))
                .font(Neon.font(.caption, weight: .semibold).monospacedDigit())
        }
    }

    /// Shared 0…1 fraction across all adjustable fans (mean of each fan's position in
    /// its own range). Drives the sync slider and the percent readout.
    private var fanFraction: Double {
        let fs = fansAdjustable.compactMap { f -> Double? in
            guard let t = fanTargets[f.id] else { return nil }
            return (t - f.min) / (f.max - f.min)
        }
        guard !fs.isEmpty else { return 0 }
        return fs.reduce(0, +) / Double(fs.count)
    }

    private func selectManualAll() {
        if fanManual { applyFraction(fanFraction) }            // already engaged
        else if Preferences.fanManualConsent { confirmManualAll() }  // acknowledged before → straight to engage
        else { pendingManual = true }                          // first time → inline confirm
    }

    /// Turn manual on (post-confirmation): seed every fan at its current RPM, then
    /// AWAIT the daemon. Only flip the UI to "manual" if the privileged write actually
    /// engaged — otherwise the popover lied (helper not installed/approved). The first
    /// `setManual` is what triggers helper registration + the macOS approval prompt.
    /// Run an engage with a hard wall-clock ceiling. If it exceeds `seconds` (e.g. a
    /// wedged SMAppService registration), return false so the UI resolves; the orphaned
    /// work harmlessly completes later (the daemon resets fans on its own cold start).
    private func withFanTimeout(_ seconds: Double, _ op: @escaping @Sendable () async -> Bool) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { await op() }
            group.addTask { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)); return false }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }

    private func confirmManualAll() {
        pendingManual = false
        Preferences.fanManualConsent = true   // remember the acknowledgement; don't re-prompt on re-engage
        fanError = nil
        fanBusy = true
        var t = Preferences.fanTargets
        for f in fansAdjustable { t[f.id] = clampRPM(f.current, f) }
        let targets = t
        Task {
            guard let first = targets.first else { fanBusy = false; return }
            // Engage ONE fan first. This is what registers/approves the helper and runs
            // the daemon's full AS unlock (Ftst + 3s thermalmonitord yield + spaced mode-
            // key retries) — far slower than a steady commit, so give it a ceiling that
            // clears the daemon's worst case instead of timing out mid-dance and lying.
            // If it fails, the helper isn't available — bail now rather than repeat the
            // same long wait per fan. On success the connection + unlock are live, so the
            // remaining fans commit instantly at the default ceiling.
            // Overall wall-clock watchdog. setManual's own ceiling only bounds the XPC
            // call; the registration/approval step before it (SMAppService smd IPC,
            // plus a drift re-register after a Sparkle update) is unbounded and can
            // hang there — which is exactly a stuck "Enabling…" with no daemon log,
            // since the call never reaches the daemon. Race the whole engage so the
            // button always resolves and surfaces the actionable error.
            let ok = await withFanTimeout(45) {
                await FanControlHelper.setManual(first.key, rpm: first.value, timeout: 35)
            }
            guard ok else {
                fanBusy = false
                fanError = "Couldn’t enable manual control — the Prosper helper isn’t "
                    + "running or wasn’t approved. Turn on “Prosper” under System Settings ▸ "
                    + "General ▸ Login Items ▸ Allow in the Background, then try again."
                return
            }
            for (i, rpm) in targets where i != first.key { _ = await FanControlHelper.setManual(i, rpm: rpm) }
            fanBusy = false
            fanManual = true
            Preferences.fanManualEnabled = true
            Preferences.fanTargets = targets; fanTargets = targets
        }
    }

    /// Hand every fan back to the OS and tear the daemon connection down.
    private func selectAutoAll() {
        fanManual = false
        Preferences.fanManualEnabled = false
        Preferences.fanTargets = [:]; fanTargets = [:]
        Task { await FanControlHelper.resetAll(teardown: true) }
    }

    /// Map a single 0…1 fraction onto every fan's own range and commit them together.
    private func applyFraction(_ frac: Double) {
        let f = Swift.min(1, Swift.max(0, frac))
        var t = Preferences.fanTargets
        for fan in fansAdjustable { t[fan.id] = fan.min + f * (fan.max - fan.min) }
        Preferences.fanTargets = t; fanTargets = t
        commitAll(t)
    }

    private func clampRPM(_ v: Double, _ fan: FanReading) -> Double {
        Swift.min(Swift.max(v, fan.min), fan.max)
    }

    /// Persist immediately (cheap) but debounce the slow root SMC writes; one
    /// debounced burst sets all fans so a slider drag doesn't hammer the daemon.
    private func commitAll(_ targets: [Int: Double]) {
        fanCommitWork?.cancel()
        let work = DispatchWorkItem {
            Task { for (i, rpm) in targets { await FanControlHelper.setManual(i, rpm: rpm) } }
        }
        fanCommitWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func batteryDetail(_ b: BatterySample) -> some View {
        VStack(alignment: .leading, spacing: sz(6)) {
            section("Details")
            kv("Source", b.isPluggedIn ? "AC Power" : "Battery")
            if b.isCharging {
                kv("Time to charge", b.timeToFull > 0 ? timeText(b.timeToFull) : "Calculating…")
            } else if b.isPluggedIn {
                kv("Time to charge", "Fully charged")
            } else if b.timeToEmpty > 0 {
                kv("Time remaining", timeText(b.timeToEmpty))
            }
            kv("Power", StatsFormat.watts(abs(b.powerWatts)))
            if !b.amperage.isNaN { kv("Current", String(format: "%.0f mA", abs(b.amperage) * 1000)) }
            if !b.voltage.isNaN { kv("Voltage", String(format: "%.2f V", b.voltage)) }

            section("Battery")
            if b.maxCapacity > 0 {
                HStack {
                    Text("Max capacity").font(Neon.font(.caption)).foregroundStyle(Neon.textSecondary)
                    Spacer()
                    Text("Designed capacity").font(Neon.font(.caption)).foregroundStyle(Neon.textSecondary)
                }
                StackedBar(segments: [(b.health.isNaN ? 1 : b.health, .green)], total: 1)
            }
            if !b.health.isNaN { kv("Health", StatsFormat.percent(b.health)) }
            kv("Cycles", "\(b.cycleCount)")
            if !b.temperature.isNaN { kv("Temperature", StatsFormat.tempDetail(b.temperature)) }

            section("Power adapter")
            HStack {
                Text("Is charging").font(Neon.font(.caption)).foregroundStyle(Neon.textSecondary)
                Spacer()
                StatusBadge(text: b.isCharging ? "Yes" : "No",
                            color: b.isCharging ? .green : LoadColor.system, symbol: nil)
            }
            if b.adapterWatts > 0 { kv("Power", StatsFormat.watts(b.adapterWatts)) }
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
        // Battery ranks by ENERGY using top's `power` column — the same relative
        // energy-impact score Activity Monitor shows in its "Energy" tab. CPU/RAM
        // popups keep their own axes.
        let byMem = module == .memory
        let byEnergy = module == .battery
        let procs = byMem ? store.snapshot.topByMemory
                  : byEnergy ? store.snapshot.topByPower
                  : store.snapshot.topByCPU
        return VStack(alignment: .leading, spacing: sz(5)) {
            section("Top processes")
            HStack {
                Text("Process").font(Neon.font(.caption)).foregroundStyle(Neon.textSecondary)
                Spacer()
                Text(module == .memory ? "Memory" : (module == .battery ? "Energy" : "Usage"))
                    .font(Neon.font(.caption)).foregroundStyle(Neon.textSecondary)
            }
            if let procs, !procs.isEmpty {
                ForEach(procs, id: \.pid) { p in
                    procRow(p, byMem ? StatsFormat.bytes(Double(p.memory))
                              : byEnergy ? String(format: "%.1f", p.power)
                              : StatsFormat.percent(p.cpu))
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

    /// Per-process network throughput (nettop-backed): name + down/up rate columns,
    /// each column headed by its colour dot. exelban's network "Top processes".
    private var networkProcesses: some View {
        let procs = store.snapshot.topByNetwork
        let cfg = store.style.config(.network)
        return VStack(alignment: .leading, spacing: sz(5)) {
            section("Top processes")
            HStack(spacing: sz(8)) {
                Text("Process").font(Neon.font(.caption)).foregroundStyle(Neon.textSecondary)
                Spacer(minLength: sz(8))
                Circle().fill(cfg.down.color).frame(width: sz(7), height: sz(7))
                Text("Download").font(Neon.font(.caption)).foregroundStyle(Neon.textSecondary)
                    .frame(width: sz(64), alignment: .trailing)
                Circle().fill(cfg.up.color).frame(width: sz(7), height: sz(7))
                Text("Upload").font(Neon.font(.caption)).foregroundStyle(Neon.textSecondary)
                    .frame(width: sz(64), alignment: .trailing)
            }
            if let procs, !procs.isEmpty {
                ForEach(procs, id: \.pid) { netProcRow($0) }
            } else {
                Text("Sampling…").font(Neon.font(.caption)).foregroundStyle(Neon.textSecondary)
            }
        }
    }

    private func netProcRow(_ p: NetProcInfo) -> some View {
        HStack(spacing: sz(7)) {
            ProcessIcon(pid: p.pid)
            Text(p.name).font(Neon.font(.caption)).foregroundStyle(Neon.textPrimary).lineLimit(1)
            Spacer(minLength: sz(8))
            Text(StatsFormat.rateMenu(p.downBytesPerSec))
                .font(Neon.font(.caption, weight: .semibold).monospacedDigit())
                .frame(width: sz(71), alignment: .trailing)
            Text(StatsFormat.rateMenu(p.upBytesPerSec))
                .font(Neon.font(.caption, weight: .semibold).monospacedDigit())
                .frame(width: sz(71), alignment: .trailing)
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

    /// Lets the user pin which sensor drives the headline (menu bar + big readout),
    /// exelban-style. "Auto" picks the hottest live sensor (skipping the static
    /// calibration reference that otherwise pegs the value). A pinned sensor that
    /// later disappears falls back to Auto automatically (headlineTemperature returns
    /// the auto value when the name isn't found).
    private func headlinePicker(_ temps: [TempSensor]) -> some View {
        HStack {
            Text("Headline").font(Neon.font(.caption)).foregroundStyle(Neon.textSecondary)
            Spacer(minLength: sz(8))
            Menu {
                Picker("", selection: Binding(
                    get: { headlineSensor ?? "" },
                    set: { sel in
                        let v = sel.isEmpty ? nil : sel
                        headlineSensor = v
                        Preferences.sensorsHeadlineSensor = v
                    })) {
                        Text("Auto (hottest)").tag("")
                        ForEach(Array(temps.enumerated()), id: \.offset) { _, t in
                            Text(t.name).tag(t.name)
                        }
                    }
                    .labelsHidden().pickerStyle(.inline)
            } label: {
                Text(headlineSensor ?? "Auto (hottest)")
                    .font(Neon.font(.caption, weight: .semibold)).lineLimit(1)
            }
            .menuStyle(.borderlessButton).fixedSize()
        }
    }

    private func kv(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).font(Neon.font(.caption)).foregroundStyle(Neon.textSecondary).lineLimit(1)
            Spacer(minLength: sz(8))
            Text(v).font(Neon.font(.caption, weight: .semibold).monospacedDigit())
        }
    }

    /// kv whose trailing value is a view (a status badge), not text.
    private func kvBadge<V: View>(_ k: String, @ViewBuilder _ trailing: () -> V) -> some View {
        HStack {
            Text(k).font(Neon.font(.caption)).foregroundStyle(Neon.textSecondary).lineLimit(1)
            Spacer(minLength: sz(8))
            trailing()
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

/// The large battery glyph for the popup header: a rounded outline + nub, filled
/// green when on power (with a plug/bolt) else neon, scaled to its frame.
private struct BigBattery: View {
    let charge: Double
    let charging: Bool
    let onPower: Bool

    var body: some View {
        GeometryReader { g in
            let h = g.size.height
            let bodyW = g.size.width - h * 0.12
            let fill = onPower ? Color.green : Neon.blue
            HStack(spacing: h * 0.04) {
                ZStack {
                    RoundedRectangle(cornerRadius: h * 0.28)
                        .stroke(Neon.textSecondary.opacity(0.6), lineWidth: h * 0.07)
                    RoundedRectangle(cornerRadius: h * 0.2)
                        .fill(fill)
                        .padding(h * 0.12)
                        .scaleEffect(x: CGFloat(min(1, max(0.02, charge))), anchor: .leading)
                    if onPower {
                        Image(systemName: charging ? "bolt.fill" : "powerplug.fill")
                            .font(.system(size: h * 0.42, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: bodyW)
                RoundedRectangle(cornerRadius: h * 0.06)
                    .fill(Neon.textSecondary.opacity(0.6))
                    .frame(width: h * 0.08, height: h * 0.34)
            }
        }
    }
}

/// A grid of small squares — one per reachability sample (green = up, red = down),
/// oldest→newest. exelban's connectivity history. Shows the most recent `cols × rows`.
private struct ConnectivityGrid: View {
    let history: [Bool]
    let up: Color
    private let cols = 30, rows = 2

    var body: some View {
        let cap = cols * rows
        let recent = Array(history.suffix(cap))
        return VStack(alignment: .leading, spacing: sz(2)) {
            ForEach(0..<rows, id: \.self) { row in
                HStack(spacing: sz(2)) {
                    ForEach(0..<cols, id: \.self) { col in
                        let i = row * cols + col
                        let on = i < recent.count ? recent[i] : nil
                        RoundedRectangle(cornerRadius: sz(1))
                            .fill(on == nil ? Neon.textSecondary.opacity(0.12)
                                  : (on! ? up : LoadColor.system))
                            .frame(height: sz(7))
                    }
                }
            }
        }
    }
}

/// exelban's RAM pressure half-gauge: a 180° green→yellow→red arc with a needle at
/// `fraction`, and the textual state below.
private struct PressureGauge: View {
    let fraction: Double
    let state: String

    var body: some View {
        VStack(spacing: sz(2)) {
            Canvas { ctx, size in
                let lw = size.height * 0.14
                let r = min(size.width / 2, size.height) - lw
                let c = CGPoint(x: size.width / 2, y: size.height - lw / 2)
                // Arc spans 180°→360° (left to right across the top). Draw three zones.
                let zones: [(Double, Double, Color)] = [
                    (180, 240, .green), (240, 300, .yellow), (300, 360, LoadColor.system)]
                for (a0, a1, col) in zones {
                    var p = Path()
                    p.addArc(center: c, radius: r,
                             startAngle: .degrees(a0), endAngle: .degrees(a1), clockwise: false)
                    ctx.stroke(p, with: .color(col), style: StrokeStyle(lineWidth: lw, lineCap: .butt))
                }
                // Needle.
                let f = min(1, max(0, fraction))
                let ang = (180 + 180 * f) * .pi / 180
                let tip = CGPoint(x: c.x + cos(ang) * r, y: c.y + sin(ang) * r)
                var needle = Path()
                needle.move(to: c); needle.addLine(to: tip)
                ctx.stroke(needle, with: .color(Neon.blue), style: StrokeStyle(lineWidth: lw * 0.6, lineCap: .round))
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - lw * 0.5, y: c.y - lw * 0.5, width: lw, height: lw)),
                         with: .color(Neon.blue))
            }
            Text(state).font(Neon.font(.caption, weight: .semibold)).foregroundStyle(Neon.textPrimary)
        }
    }
}

/// A small pill badge (status / state), optionally with a leading symbol.
private struct StatusBadge: View {
    let text: String
    let color: Color
    let symbol: String?

    var body: some View {
        HStack(spacing: sz(3)) {
            if let symbol { Image(systemName: symbol).font(Neon.font(9, weight: .bold)) }
            Text(text).font(Neon.font(.caption, weight: .semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, sz(8)).padding(.vertical, sz(2))
        .background(Capsule().fill(color.opacity(0.18)))
    }
}

/// Mirrored network history: upload fills upward from the centre, download
/// downward, each normalised to its own peak. exelban's network chart.
private struct MirrorNetChart: View {
    let up: [Double]; let upPeak: Double; let upColor: Color
    let down: [Double]; let downPeak: Double; let downColor: Color

    var body: some View {
        Canvas { ctx, size in
            let mid = size.height / 2
            func fillArea(_ vals: [Double], _ peak: Double, _ color: Color, up: Bool) {
                guard vals.count > 1 else { return }
                let maxV = Swift.max(peak, 0.0001)
                let n = vals.count
                var p = Path()
                p.move(to: CGPoint(x: 0, y: mid))
                for i in 0..<n {
                    let x = size.width * CGFloat(i) / CGFloat(n - 1)
                    let frac = CGFloat(min(1, max(0, vals[i] / maxV)))
                    let y = up ? mid - frac * mid : mid + frac * mid
                    p.addLine(to: CGPoint(x: x, y: y))
                }
                p.addLine(to: CGPoint(x: size.width, y: mid))
                p.closeSubpath()
                ctx.fill(p, with: .color(color.opacity(0.5)))
                ctx.stroke(p, with: .color(color), lineWidth: 1)
            }
            fillArea(up, upPeak, upColor, up: true)
            fillArea(down, downPeak, downColor, up: false)
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
