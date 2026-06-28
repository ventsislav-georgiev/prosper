// Customization model for the System Stats menu-bar widgets.
//
// One JSON blob in UserDefaults drives every menu-bar item: which modules show,
// how each renders (text / graph / both), label & unit toggles, alignment, and
// the threshold colour ramp (low → med → high) per module. Network is the one
// special case — it shows two channels, so it carries an up/down colour pair
// instead of a single ramp. Everything has a sane default that mirrors the
// reference screenshots, so a fresh enable looks right with zero configuration.

import SwiftUI
import StatsCore

enum StatsDisplayMode: String, Codable, CaseIterable, Sendable {
    case textOnly, graph, both
    var label: String { switch self { case .textOnly: "Text"; case .graph: "Graph"; case .both: "Text + Graph" } }
}

enum StatsWidgetAlignment: String, Codable, CaseIterable, Sendable {
    case leading, center, trailing
    var label: String { switch self { case .leading: "Left"; case .center: "Center"; case .trailing: "Right" } }
}

/// Codable colour (SwiftUI `Color` isn't `Codable`). sRGB components 0…1.
struct RGBAColor: Codable, Equatable, Hashable, Sendable {
    var r: Double, g: Double, b: Double, a: Double
    init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) { self.r = r; self.g = g; self.b = b; self.a = a }
    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }

    /// Lossy read of a SwiftUI Color via NSColor → sRGB. Used by the colour pickers.
    init(_ c: Color) {
        let ns = NSColor(c).usingColorSpace(.sRGB) ?? .white
        self.init(Double(ns.redComponent), Double(ns.greenComponent), Double(ns.blueComponent), Double(ns.alphaComponent))
    }
}

/// Per-module widget configuration. `low/med/high` form a threshold ramp keyed
/// off a 0…1 metric (CPU load, mem fraction, GPU util, normalized temp). Network
/// ignores the ramp and uses `up/down`. Power uses `low` as a flat accent.
struct ModuleWidgetConfig: Codable, Equatable, Sendable {
    var enabled: Bool
    var mode: StatsDisplayMode
    var showLabel: Bool
    var showUnit: Bool
    var low: RGBAColor
    var med: RGBAColor
    var high: RGBAColor
    var medThreshold: Double   // fraction at which `med` kicks in
    var highThreshold: Double  // fraction at which `high` kicks in
    var up: RGBAColor          // network upload channel
    var down: RGBAColor        // network download channel

    /// Threshold colour for a 0…1 value (clamped). Below med → low, etc.
    func rampColor(_ value: Double) -> Color {
        if value >= highThreshold { return high.color }
        if value >= medThreshold { return med.color }
        return low.color
    }
}

struct StatsWidgetStyle: Codable, Equatable, Sendable {
    var alignment: StatsWidgetAlignment
    var modules: [String: ModuleWidgetConfig]   // key = StatsModule.rawValue
    var order: [String]                          // menu-bar left→right order

    /// Enabled modules in display order. Unknown/disabled keys dropped.
    var enabledModules: [StatsModule] {
        order.compactMap { key in
            guard let m = StatsModule(rawValue: key), modules[key]?.enabled == true else { return nil }
            return m
        }
    }

    func config(_ m: StatsModule) -> ModuleWidgetConfig { modules[m.rawValue] ?? .defaultFor(m) }

    static let `default` = StatsWidgetStyle(
        alignment: .center,
        modules: Dictionary(uniqueKeysWithValues: StatsModule.allCases.map { ($0.rawValue, ModuleWidgetConfig.defaultFor($0)) }),
        // CPU + RAM on by default — the two everyone wants; the rest opt-in to
        // keep a fresh enable from flooding the menu bar.
        order: [StatsModule.cpu.rawValue, StatsModule.memory.rawValue, StatsModule.gpu.rawValue,
                StatsModule.network.rawValue, StatsModule.sensors.rawValue, StatsModule.power.rawValue,
                StatsModule.battery.rawValue])
}

extension ModuleWidgetConfig {
    /// Green→amber→red ramp; network gets a blue(down)/orange(up) pair. Only CPU
    /// and RAM start enabled.
    static func defaultFor(_ m: StatsModule) -> ModuleWidgetConfig {
        let green = RGBAColor(0.30, 0.85, 0.40)
        let amber = RGBAColor(0.98, 0.78, 0.20)
        let red   = RGBAColor(0.96, 0.34, 0.34)
        let blue  = RGBAColor(0.36, 0.68, 1.00)
        let orange = RGBAColor(1.00, 0.58, 0.20)
        let defaultOn: Bool = (m == .cpu || m == .memory)
        let mode: StatsDisplayMode = (m == .cpu || m == .memory || m == .gpu) ? .both : .textOnly
        return ModuleWidgetConfig(
            enabled: defaultOn, mode: mode, showLabel: true, showUnit: true,
            low: green, med: amber, high: red,
            medThreshold: 0.5, highThreshold: 0.8,
            up: orange, down: blue)
    }
}
