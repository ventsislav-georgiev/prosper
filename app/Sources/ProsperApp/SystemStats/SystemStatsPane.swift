// Settings pane for System Stats. Master enable, menu-bar alignment, and a
// per-module section: show/hide, display mode, label & unit toggles, and the
// colour controls (threshold ramp, or up/down channels for Network). Every edit
// writes through to UserDefaults and posts `.systemStatsConfigChanged` so the
// live controller reconfigures immediately.

import SwiftUI
import StatsCore

struct SystemStatsPane: View {
    @State private var enabled = Preferences.systemStatsEnabled
    @State private var style = SystemStatsStore.load()
    /// Coalesces the persist+notify burst a ColorPicker drag emits (one set per
    /// frame) into a single commit, so we don't JSON-encode + reconfigure the live
    /// controller dozens of times a second mid-drag.
    @State private var commitWork: DispatchWorkItem?

    // Fan control (default OFF, opt-in, confirmation-gated).
    @State private var fans: [FanReading] = []
    @State private var fanManual = Preferences.fanManualEnabled
    @State private var fanTargets = Preferences.fanTargets
    @State private var showFanConfirm = false
    /// Debounces the slow privileged fan write (the AS unlock sleeps ~3s) so a slider
    /// drag doesn't fire dozens of root SMC writes — only the last value lands.
    @State private var fanCommitWork: DispatchWorkItem?

    var body: some View {
        NeonScroll {
            PaneTitle(title: "System Stats", accent: "Stats",
                      subtitle: "Native CPU, memory, GPU, network, sensor and battery monitors in your menu bar")

            NeonSection("Menu Bar") {
                NeonRow("Show System Stats", subtitle: "Adds one menu-bar item per enabled module") {
                    Toggle("", isOn: $enabled).labelsHidden()
                        .onChange(of: enabled) { _, v in Preferences.systemStatsEnabled = v; notify() }
                }
                if enabled {
                    NeonDivider()
                    NeonRow("Number alignment") {
                        Picker("", selection: alignmentBinding) {
                            ForEach(StatsWidgetAlignment.allCases, id: \.self) { Text($0.label).tag($0) }
                        }
                        .labelsHidden().pickerStyle(.segmented).frame(width: sz(220))
                    }
                }
            }

            if enabled {
                ForEach(StatsModule.allCases, id: \.self) { moduleSection($0) }
            }

            if !fans.isEmpty { fanControlSection }
        }
        .onAppear { fans = FanInfo.read() }
    }

    // MARK: - Fan control

    @ViewBuilder
    private var fanControlSection: some View {
        NeonSection("Fan Control") {
            NeonRow("Manual fan control",
                    subtitle: "Override OS thermal control. Resets to automatic on sleep, quit, or disable.") {
                Toggle("", isOn: Binding(
                    get: { fanManual },
                    set: { want in
                        if want { showFanConfirm = true }   // confirm BEFORE any privileged write
                        else { disableFans() }
                    })).labelsHidden()
            }
            if fanManual {
                ForEach(fans) { fan in
                    NeonDivider()
                    fanSlider(fan)
                }
            }
        }
        .alert("Enable manual fan control?", isPresented: $showFanConfirm) {
            Button("Cancel", role: .cancel) { fanManual = false }
            Button("Enable", role: .destructive) { enableFans() }
        } message: {
            Text("This writes fan speeds directly to your Mac's hardware as root. "
                 + "Setting a fan too low can cause overheating or thermal throttling. "
                 + "Fans return to automatic control on sleep, when you quit Prosper, or when you turn this off.")
        }
    }

    @ViewBuilder
    private func fanSlider(_ fan: FanReading) -> some View {
        let value = fanTargets[fan.id] ?? clampRPM(fan.current, fan)
        NeonRow("Fan \(fan.id + 1)",
                subtitle: "\(Int(value)) rpm  (\(Int(fan.min))–\(Int(fan.max)))") {
            Slider(value: Binding(
                get: { fanTargets[fan.id] ?? clampRPM(fan.current, fan) },
                set: { v in fanTargets[fan.id] = v; commitFan(fan.id, v) }),
                   in: fan.min...fan.max)
                .frame(width: sz(220))
        }
    }

    private func clampRPM(_ v: Double, _ fan: FanReading) -> Double {
        Swift.min(Swift.max(v, fan.min), fan.max)
    }

    private func enableFans() {
        fanManual = true
        Preferences.fanManualEnabled = true
        // Seed any unset fan at its current RPM so nothing jumps speed on enable.
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

    // MARK: - Per-module section

    @ViewBuilder
    private func moduleSection(_ m: StatsModule) -> some View {
        let cfg = binding(m)
        NeonSection(m.shortLabel + " — " + sectionTitle(m)) {
            NeonRow("Show in menu bar") {
                Toggle("", isOn: cfg.enabled).labelsHidden()
            }
            if cfg.wrappedValue.enabled {
                if m.historyKey != nil {
                    NeonDivider()
                    NeonRow("Display") {
                        Picker("", selection: cfg.mode) {
                            ForEach(StatsDisplayMode.allCases, id: \.self) { Text($0.label).tag($0) }
                        }.labelsHidden().pickerStyle(.segmented).frame(width: sz(220))
                    }
                }
                if m != .network {
                    NeonDivider()
                    NeonRow("Show label") { Toggle("", isOn: cfg.showLabel).labelsHidden() }
                    NeonRow("Show unit") { Toggle("", isOn: cfg.showUnit).labelsHidden() }
                }
                NeonDivider()
                colorControls(m, cfg)
            }
        }
    }

    @ViewBuilder
    private func colorControls(_ m: StatsModule, _ cfg: Binding<ModuleWidgetConfig>) -> some View {
        if m == .network {
            NeonRow("Download colour") { colorPicker(cfg.down) }
            NeonRow("Upload colour") { colorPicker(cfg.up) }
        } else {
            NeonRow("Low colour") { colorPicker(cfg.low) }
            NeonRow("Medium colour", subtitle: "From \(pct(cfg.medThreshold.wrappedValue))") { colorPicker(cfg.med) }
            NeonRow("High colour", subtitle: "From \(pct(cfg.highThreshold.wrappedValue))") { colorPicker(cfg.high) }
        }
    }

    private func colorPicker(_ rgba: Binding<RGBAColor>) -> some View {
        ColorPicker("", selection: Binding(
            get: { rgba.wrappedValue.color },
            set: { rgba.wrappedValue = RGBAColor($0) }))   // setter routes through binding(m) → commit()
            .labelsHidden()
    }

    private func sectionTitle(_ m: StatsModule) -> String {
        switch m {
        case .cpu: "Processor"; case .memory: "Memory"; case .network: "Network"
        case .gpu: "Graphics"; case .power: "Power"; case .sensors: "Temperature"; case .battery: "Battery"
        }
    }

    private func pct(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }

    // MARK: - Bindings (write-through + notify)

    private var alignmentBinding: Binding<StatsWidgetAlignment> {
        Binding(get: { style.alignment },
                set: { style.alignment = $0; commit() })
    }

    /// A binding into one module's config. Mutates the @State immediately (so the
    /// UI is responsive) and schedules a debounced persist+notify.
    private func binding(_ m: StatsModule) -> Binding<ModuleWidgetConfig> {
        Binding(
            get: { style.modules[m.rawValue] ?? .defaultFor(m) },
            set: { style.modules[m.rawValue] = $0; commit() })
    }

    /// Debounced save + controller reload — 120 ms after the last edit.
    private func commit() {
        commitWork?.cancel()
        let snapshot = style
        let work = DispatchWorkItem {
            SystemStatsStore.save(snapshot)
            NotificationCenter.default.post(name: .systemStatsConfigChanged, object: nil)
        }
        commitWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    /// Immediate (un-debounced) notify for the master toggle — a single discrete event.
    private func notify() { NotificationCenter.default.post(name: .systemStatsConfigChanged, object: nil) }
}
