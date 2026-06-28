// Labeled voltage / current rails via the SMC.
//
// The SMC exposes dozens of V*/I* `flt ` rails, but most are cryptic sub-1V
// internal SoC rails with no documented meaning (exelban leaves them unlabeled
// too). Rather than scan all ~3000 keys every tick and dump noise, we read a
// CURATED set of keys with known, validated meaning — DC input, the main
// system rail, memory, and the CPU/GPU/power-board rails when present — and keep
// only the ones this Mac actually reports in a sane range.
//
// Validated on M4 Pro: VD0R≈27.8V (USB-C PD adapter), VP0R≈13.2V (main rail),
// VDMA≈3.79V (memory), ID0R≈0.3A (DC in). Keys absent on a given model are
// simply skipped, so the same table works across Macs.

import Foundation
import SMCKit

public final class PowerSensorReader {
    private let smc: SMC

    // key → human label. Split by unit; the SMC type/range check below rejects
    // anything that isn't a real `flt ` reading (e.g. VBUS is a ui32 status flag).
    private static let voltageKeys: [(String, String)] = [
        ("VD0R", "DC In"), ("VP0R", "System Rail"),
        ("VM0R", "Memory"), ("VDMA", "Memory"),
        ("VG0R", "GPU"), ("VG0C", "GPU"),
        ("VC0C", "CPU Core"), ("VN0C", "MCH"),
    ]
    private static let currentKeys: [(String, String)] = [
        ("ID0R", "DC In"), ("IPBR", "Power Board"),
        ("IG0R", "GPU"), ("IG0C", "GPU"),
        ("IC0R", "CPU"), ("IC0C", "CPU"),
        ("IM0C", "Memory"), ("IBAC", "Battery"),
        ("IDBR", "Display"),   // backlight rail (validated present on M4 Pro)
    ]

    public init?() {
        guard let smc = try? SMC() else { return nil }
        self.smc = smc
    }

    /// Present, sane-valued labeled rails. Voltages then currents; first label
    /// wins when two keys map to the same name (e.g. VM0R/VDMA → "Memory").
    public func read() -> [VISensor] {
        var out: [VISensor] = []
        var seen = Set<String>()
        func add(_ keys: [(String, String)], _ unit: VISensor.Unit, valid: (Double) -> Bool) {
            for (key, label) in keys where !seen.contains(label) {
                guard let v = smc.read(key), v.type == "flt ",
                      v.double.isFinite, valid(v.double) else { continue }
                out.append(VISensor(name: label, value: v.double, unit: unit))
                seen.insert(label)
            }
        }
        // USB-C PD tops out ~48V; a real rail is above noise. Current rails sit
        // below ~100A even on desktops; allow 0 (an idle rail reads zero).
        add(Self.voltageKeys, .volt) { $0 > 0.1 && $0 < 60 }
        add(Self.currentKeys, .amp) { $0 >= 0 && $0 < 100 }
        return out
    }
}
