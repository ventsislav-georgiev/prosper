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

    // Named SMC temperature sensors (exelban/stats' Apple Silicon set). These are
    // the friendly rows Stats shows that the HID sensor list can't provide —
    // airflow, NAND, battery packs, the wireless module. The per-core CPU/GPU die
    // temps already come from IOHIDSensors, so this stays a small curated list.
    private static let temperatureKeys: [(String, String)] = [
        ("TaLP", "Airflow left"), ("TaRF", "Airflow right"),
        ("TH0x", "NAND"),
        ("TB1T", "Battery 1"), ("TB2T", "Battery 2"),
        ("TW0P", "Airport"),
    ]

    // A rail resolved as present on THIS machine: which key to read, its label,
    // and the unit. Built once (the SMC key set is static for a boot) so steady
    // reads never pay a syscall for an absent key — a failed SMC lookup is NOT
    // cached by the SMC layer, so re-probing absent keys every tick is pure waste.
    private struct Rail { let key: String; let label: String; let unit: VISensor.Unit }
    private var resolved: [Rail]?
    private var resolvedTemps: [(key: String, label: String)]?

    public init?() {
        guard let smc = try? SMC() else { return nil }
        self.smc = smc
    }

    /// Probe the curated keys ONCE, keeping only those present as `flt ` rails.
    /// First label wins when two keys map to one name (e.g. VM0R/VDMA → "Memory").
    private func resolve() -> [Rail] {
        var rails: [Rail] = []
        var seen = Set<String>()
        func probe(_ keys: [(String, String)], _ unit: VISensor.Unit) {
            for (key, label) in keys where !seen.contains(label) {
                guard smc.read(key)?.type == "flt " else { continue }
                rails.append(Rail(key: key, label: label, unit: unit))
                seen.insert(label)
            }
        }
        probe(Self.voltageKeys, .volt)
        probe(Self.currentKeys, .amp)
        return rails
    }

    /// Present, sane-valued labeled rails. Reads only keys resolved present on
    /// this Mac; the per-read range check drops a transient bogus value.
    public func read() -> [VISensor] {
        let rails = resolved ?? { let r = resolve(); resolved = r; return r }()
        var out: [VISensor] = []
        out.reserveCapacity(rails.count)
        for r in rails {
            guard let v = smc.read(r.key), v.double.isFinite else { continue }
            // USB-C PD tops out ~48V; a real rail is above noise. Current rails
            // sit below ~100A even on desktops; allow 0 (an idle rail reads zero).
            switch r.unit {
            case .volt: guard v.double > 0.1 && v.double < 60 else { continue }
            case .amp:  guard v.double >= 0 && v.double < 100 else { continue }
            }
            out.append(VISensor(name: r.label, value: v.double, unit: r.unit))
        }
        return out
    }

    /// Named SMC temperatures present on this Mac. Same resolve-once pattern as
    /// the rails: probe the curated keys with a sanity range (a key can exist but
    /// read 0 on a model without that sensor), then read only the live ones.
    public func temperatures() -> [TempSensor] {
        let list = resolvedTemps ?? {
            let r = Self.temperatureKeys.filter { key, _ in
                guard let v = smc.read(key)?.double else { return false }
                return v > 10 && v < 130
            }
            resolvedTemps = r
            return r
        }()
        var out: [TempSensor] = []
        out.reserveCapacity(list.count)
        for (key, label) in list {
            guard let v = smc.read(key)?.double, v > 10, v < 130 else { continue }
            out.append(TempSensor(name: label, celsius: v))
        }
        return out
    }
}
