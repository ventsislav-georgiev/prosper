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
    // airflow, NAND, battery packs, the wireless module.
    private static let temperatureKeys: [(String, String)] = [
        ("TaLP", "Airflow left"), ("TaRF", "Airflow right"),
        ("TH0x", "NAND"),
        ("TB1T", "Battery 1"), ("TB2T", "Battery 2"),
        ("TW0P", "Airport"),
    ]

    // Per-core CPU / per-cluster GPU die temps, keyed BY CHIP GENERATION —
    // exelban/stats' tables. The same four-char key means different cores on
    // different generations (Tp09 = M1 efficiency 1 but M4 performance 3), so the
    // generation MUST gate which table is probed; presence-probing the union would
    // mislabel cores. HID exposes these dies too, but only as anonymous "PMU tdie
    // N" — these named rows are what makes the list read "CPU efficiency core 1"
    // like Stats. M4 lists both the base-die GPU pair (Tg0G/H) and the
    // Pro/Max/Ultra pair (Tg1U/k) under the same labels; resolve keeps whichever
    // is actually present (first present key wins per label).
    static let asTemperatureKeys: [Int: [(String, String)]] = [
        1: [
            ("Tp09", "CPU efficiency core 1"), ("Tp0T", "CPU efficiency core 2"),
            ("Tp01", "CPU performance core 1"), ("Tp05", "CPU performance core 2"),
            ("Tp0D", "CPU performance core 3"), ("Tp0H", "CPU performance core 4"),
            ("Tp0L", "CPU performance core 5"), ("Tp0P", "CPU performance core 6"),
            ("Tp0X", "CPU performance core 7"), ("Tp0b", "CPU performance core 8"),
            ("Tg05", "GPU 1"), ("Tg0D", "GPU 2"), ("Tg0L", "GPU 3"), ("Tg0T", "GPU 4"),
            ("Tm02", "Memory 1"), ("Tm06", "Memory 2"), ("Tm08", "Memory 3"), ("Tm09", "Memory 4"),
        ],
        2: [
            ("Tp1h", "CPU efficiency core 1"), ("Tp1t", "CPU efficiency core 2"),
            ("Tp1p", "CPU efficiency core 3"), ("Tp1l", "CPU efficiency core 4"),
            ("Tp01", "CPU performance core 1"), ("Tp05", "CPU performance core 2"),
            ("Tp09", "CPU performance core 3"), ("Tp0D", "CPU performance core 4"),
            ("Tp0X", "CPU performance core 5"), ("Tp0b", "CPU performance core 6"),
            ("Tp0f", "CPU performance core 7"), ("Tp0j", "CPU performance core 8"),
            ("Tg0f", "GPU 1"), ("Tg0j", "GPU 2"),
        ],
        3: [
            ("Te05", "CPU efficiency core 1"), ("Te0L", "CPU efficiency core 2"),
            ("Te0P", "CPU efficiency core 3"), ("Te0S", "CPU efficiency core 4"),
            ("Tf04", "CPU performance core 1"), ("Tf09", "CPU performance core 2"),
            ("Tf0A", "CPU performance core 3"), ("Tf0B", "CPU performance core 4"),
            ("Tf0D", "CPU performance core 5"), ("Tf0E", "CPU performance core 6"),
            ("Tf44", "CPU performance core 7"), ("Tf49", "CPU performance core 8"),
            ("Tf4A", "CPU performance core 9"), ("Tf4B", "CPU performance core 10"),
            ("Tf4D", "CPU performance core 11"), ("Tf4E", "CPU performance core 12"),
            ("Tf14", "GPU 1"), ("Tf18", "GPU 2"), ("Tf19", "GPU 3"), ("Tf1A", "GPU 4"),
            ("Tf24", "GPU 5"), ("Tf28", "GPU 6"), ("Tf29", "GPU 7"), ("Tf2A", "GPU 8"),
        ],
        4: [
            ("Te05", "CPU efficiency core 1"), ("Te0S", "CPU efficiency core 2"),
            ("Te09", "CPU efficiency core 3"), ("Te0H", "CPU efficiency core 4"),
            ("Tp01", "CPU performance core 1"), ("Tp05", "CPU performance core 2"),
            ("Tp09", "CPU performance core 3"), ("Tp0D", "CPU performance core 4"),
            ("Tp0V", "CPU performance core 5"), ("Tp0Y", "CPU performance core 6"),
            ("Tp0b", "CPU performance core 7"), ("Tp0e", "CPU performance core 8"),
            ("Tg0G", "GPU 1"), ("Tg0H", "GPU 2"),      // M4 base die
            ("Tg1U", "GPU 1"), ("Tg1k", "GPU 2"),      // M4 Pro/Max/Ultra
            ("Tg0K", "GPU 3"), ("Tg0L", "GPU 4"), ("Tg0d", "GPU 5"),
            ("Tg0e", "GPU 6"), ("Tg0j", "GPU 7"), ("Tg0k", "GPU 8"),
            ("Tm0p", "Memory 1"), ("Tm1p", "Memory 2"), ("Tm2p", "Memory 3"),
        ],
        5: [
            ("Tp00", "CPU super core 1"), ("Tp04", "CPU super core 2"),
            ("Tp08", "CPU super core 3"), ("Tp0C", "CPU super core 4"),
            ("Tp0G", "CPU super core 5"), ("Tp0K", "CPU super core 6"),
            ("Tp0O", "CPU performance core 1"), ("Tp0R", "CPU performance core 2"),
            ("Tp0U", "CPU performance core 3"), ("Tp0X", "CPU performance core 4"),
            ("Tp0a", "CPU performance core 5"), ("Tp0d", "CPU performance core 6"),
            ("Tp0g", "CPU performance core 7"), ("Tp0j", "CPU performance core 8"),
            ("Tp0m", "CPU performance core 9"), ("Tp0p", "CPU performance core 10"),
            ("Tp0u", "CPU performance core 11"), ("Tp0y", "CPU performance core 12"),
            ("Tg0U", "GPU 1"), ("Tg0X", "GPU 2"), ("Tg0d", "GPU 3"), ("Tg0g", "GPU 4"),
            ("Tg0j", "GPU 5"), ("Tg1Y", "GPU 6"), ("Tg1c", "GPU 7"), ("Tg1g", "GPU 8"),
        ],
    ]

    /// "Apple M4 Pro" → 4. nil on Intel or an unrecognized brand — the
    /// generation-gated table is then skipped entirely (never presence-probed:
    /// the same key means a different core on a different generation).
    static func chipGeneration(brand: String) -> Int? {
        guard let r = brand.range(of: #"Apple M(\d+)"#, options: .regularExpression)
        else { return nil }
        return Int(brand[r].dropFirst("Apple M".count))
    }

    private static let chipGen: Int? = {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        guard size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &buf, &size, nil, 0) == 0
        else { return nil }
        return chipGeneration(brand: String(cString: buf))
    }()

    // A rail resolved as present on THIS machine: which key to read, its label,
    // and the unit. Built once (the SMC key set is static for a boot) so steady
    // reads never pay a syscall for an absent key — a failed SMC lookup is NOT
    // cached by the SMC layer, so re-probing absent keys every tick is pure waste.
    private struct Rail { let key: String; let label: String; let unit: VISensor.Unit }
    private var resolved: [Rail]?
    private var resolvedTemps: [(key: String, label: String)]?
    /// Last sane reading per temp key — held through parked-core zero reads.
    private var lastTemp: [String: Double] = [:]

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
            // Generation table first so the popup lists cores before the misc
            // sensors; dedupe by label (M4 lists base-die and Pro/Max GPU keys
            // under the same "GPU n" names — first present wins). Core-die keys
            // resolve on EXISTENCE, not value: a parked core reads 0 at resolve
            // time and a value probe would exclude it forever (live M4 Pro showed
            // 6 of 8 performance cores parked at first read). The misc keys keep
            // the value probe — there a key existing but reading 0 means the
            // sensor genuinely isn't fitted on this model (e.g. TB2T).
            let gen = Self.chipGen.flatMap { Self.asTemperatureKeys[$0] } ?? []
            var seen = Set<String>()
            var r: [(key: String, label: String)] = []
            for (key, label) in gen where !seen.contains(label) {
                guard smc.read(key)?.double != nil else { continue }
                r.append((key, label))
                seen.insert(label)
            }
            for (key, label) in Self.temperatureKeys where !seen.contains(label) {
                guard let v = smc.read(key)?.double, v > 10, v < 130 else { continue }
                r.append((key, label))
                seen.insert(label)
            }
            resolvedTemps = r
            return r
        }()
        var out: [TempSensor] = []
        out.reserveCapacity(list.count)
        for (key, label) in list {
            // Hold the last sane value through a parked/bogus reading (exelban's
            // "broken sensors" fix) so rows don't flicker out when a core sleeps.
            var v = smc.read(key)?.double ?? 0
            if !(v > 10 && v < 130) {
                guard let held = lastTemp[key] else { continue }
                v = held
            }
            lastTemp[key] = v
            out.append(TempSensor(name: label, celsius: v))
        }
        return out
    }
}
