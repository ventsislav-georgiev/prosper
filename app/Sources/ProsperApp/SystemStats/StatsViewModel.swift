// Shared observable state for every System Stats view (menu-bar widgets +
// popover). The controller pushes a fresh snapshot here once per poll tick on
// the main thread; all hosted SwiftUI views observe this one object, so the
// menu bar and any open popover redraw together off a single source of truth.

import SwiftUI
import StatsCore

@MainActor
final class StatsStore: ObservableObject {
    @Published var snapshot = StatsSnapshot()
    @Published var style: StatsWidgetStyle

    init(style: StatsWidgetStyle) { self.style = style }

    /// History for a metric — read straight off the delivered snapshot (no cross-
    /// queue hop; the poller already snapshotted its rings onto it).
    func history(_ key: String) -> [Double] { snapshot.histories[key] ?? [] }
}

// MARK: - Number formatting (allocation-light, no NumberFormatter on the hot path)

enum StatsFormat {
    /// Compact bytes/sec for the menu bar: "1.2M", "840K", "12B".
    static func rate(_ bytesPerSec: Double) -> String {
        let v = max(0, bytesPerSec)
        if v >= 1_000_000_000 { return String(format: "%.1fG", v / 1_000_000_000) }
        if v >= 1_000_000 { return String(format: "%.1fM", v / 1_000_000) }
        if v >= 1_000 { return String(format: "%.0fK", v / 1_000) }
        return String(format: "%.0fB", v)
    }

    /// Bytes/sec for the popover, with the per-second suffix.
    static func rateLong(_ bytesPerSec: Double) -> String { rate(bytesPerSec) + "B/s" }

    static func percent(_ fraction: Double) -> String { "\(Int((fraction * 100).rounded()))%" }
    static func temp(_ celsius: Double) -> String { String(format: "%.0f°", celsius) }
    static func watts(_ w: Double) -> String { String(format: "%.1fW", w) }

    static func bytes(_ count: Double) -> String {
        let v = max(0, count)
        if v >= 1_073_741_824 { return String(format: "%.1f GB", v / 1_073_741_824) }
        if v >= 1_048_576 { return String(format: "%.0f MB", v / 1_048_576) }
        return String(format: "%.0f KB", v / 1024)
    }
}

// MARK: - Module presentation

extension StatsModule {
    var shortLabel: String {
        switch self {
        case .cpu: "CPU"; case .memory: "RAM"; case .network: "NET"
        case .gpu: "GPU"; case .power: "PWR"; case .sensors: "TMP"; case .battery: "BAT"
        }
    }

    var sfSymbol: String {
        switch self {
        case .cpu: "cpu"; case .memory: "memorychip"; case .network: "network"
        case .gpu: "display"; case .power: "bolt.fill"; case .sensors: "thermometer.medium"; case .battery: "battery.100"
        }
    }

    var historyKey: String? {
        switch self {
        case .cpu: "cpu"; case .memory: "memory"; case .gpu: "gpu"; case .power: "power"
        case .network, .sensors, .battery: nil
        }
    }

    /// The 0…1 value the threshold ramp keys off (1 = "hot"). nil if the module
    /// isn't ramp-driven (network uses channel colours).
    func rampValue(_ s: StatsSnapshot) -> Double? {
        switch self {
        case .cpu: return s.cpu?.total
        case .memory: return s.memory?.usedFraction
        case .gpu: return s.gpu?.utilization
        // Normalize temp to 0…1 over a 30–100 °C comfort→hot band.
        case .sensors: return s.temperatures?.map(\.celsius).max().map { min(1, max(0, ($0 - 30) / 70)) }
        case .battery: return s.battery.map { 1 - $0.charge }   // ramp reddens as it drains
        case .power: return s.power.map { min(1, $0.totalWatts / 60) }
        case .network: return nil
        }
    }

    /// Widest string the primary text can ever be, used to reserve a FIXED widget
    /// width so the menu-bar item doesn't resize (and shove its neighbours) as the
    /// value changes. Monospaced digits make every same-length string equal-width,
    /// so the worst case is just "max digits + unit".
    func primaryWidthSample() -> String {
        switch self {
        case .cpu, .memory, .gpu, .battery: return "100%"
        case .sensors: return "100°"
        case .power: return "99.9W"
        case .network: return ""
        }
    }

    /// Primary menu-bar text (non-network). Empty string if no sample yet.
    func primaryText(_ s: StatsSnapshot, showUnit: Bool) -> String {
        switch self {
        case .cpu: return s.cpu.map { StatsFormat.percent($0.total) } ?? "—"
        case .memory: return s.memory.map { StatsFormat.percent($0.usedFraction) } ?? "—"
        case .gpu: return s.gpu.map { StatsFormat.percent($0.utilization) } ?? "—"
        case .sensors: return s.temperatures?.map(\.celsius).max().map { StatsFormat.temp($0) } ?? "—"
        case .battery: return s.battery.map { StatsFormat.percent($0.charge) } ?? "—"
        case .power: return s.power.map { StatsFormat.watts($0.totalWatts) } ?? "—"
        case .network: return ""   // rendered as two channels
        }
    }
}
