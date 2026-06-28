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
    @State private var interval = Preferences.statsRefreshInterval
    /// Coalesces the persist+notify burst a ColorPicker drag emits (one set per
    /// frame) into a single commit, so we don't JSON-encode + reconfigure the live
    /// controller dozens of times a second mid-drag.
    @State private var commitWork: DispatchWorkItem?

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
                    NeonRow("Update interval", subtitle: "Lower = more responsive, more CPU. Slow metrics (temps, power, battery) sample less often.") {
                        Picker("", selection: intervalBinding) {
                            Text("1s").tag(1.0); Text("2s").tag(2.0)
                            Text("3s").tag(3.0); Text("5s").tag(5.0)
                        }
                        .labelsHidden().pickerStyle(.segmented).frame(width: sz(180))
                    }
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
        }
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

    private var intervalBinding: Binding<Double> {
        Binding(get: { interval },
                set: { interval = $0; Preferences.statsRefreshInterval = $0; notify() })
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
