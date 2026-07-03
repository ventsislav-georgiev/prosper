// Temperature sensors via the private IOHIDEventSystem API.
//
// No public temperature API exists on Apple Silicon (SMC temp keys are sparse
// and unlabeled). exelban/stats and every Mac monitor use this same private
// path: match HID services on page 0xff00 / usage 0x05, pull a Temperature
// event, read its float. Resolved by dlsym from the IOKit framework so the app
// links no private symbol at build time.
//
// Validated on M4 Pro (spike): 6 symbols resolve, 77 temp services, die temps
// 36–38°C. Prosper is NOT sandboxed, so the client creates successfully.
//
// CRITICAL: the @convention(c) signatures below are load-bearing — a wrong one
// segfaults at call time, not link time. Keep them exact.

import Foundation
import CoreFoundation

public struct TempSensor: Sendable, Equatable {
    public let name: String
    public let celsius: Double
    public init(name: String, celsius: Double) { self.name = name; self.celsius = celsius }
}

/// exelban/stats-style synthetic aggregate rows: "Average CPU" / "Hottest CPU"
/// over the per-core CPU sensors, same for GPU. Appended after the real sensors
/// so the popup reads like Stats' Temperature list. Pure — unit-tested.
public func tempAggregates(_ temps: [TempSensor]) -> [TempSensor] {
    var out: [TempSensor] = []
    for (prefix, label) in [("CPU ", "CPU"), ("GPU ", "GPU")] {
        let vals = temps.filter { $0.name.hasPrefix(prefix) }.map(\.celsius)
        guard vals.count > 1, let mx = vals.max() else { continue }
        out.append(TempSensor(name: "Average \(label)", celsius: vals.reduce(0, +) / Double(vals.count)))
        out.append(TempSensor(name: "Hottest \(label)", celsius: mx))
    }
    return out
}

/// A labeled voltage or current rail (SMC `flt ` sensor). `unit` distinguishes
/// the two so the UI can group and format them.
public struct VISensor: Sendable, Equatable {
    public enum Unit: Sendable { case volt, amp }
    public let name: String
    public let value: Double
    public let unit: Unit
    public init(name: String, value: Double, unit: Unit) {
        self.name = name; self.value = value; self.unit = unit
    }
}

public final class IOHIDSensors {
    private typealias CreateT   = @convention(c) (CFAllocator?) -> Unmanaged<AnyObject>?
    private typealias SetMatchT = @convention(c) (AnyObject?, CFDictionary?) -> Void
    private typealias CopySvcT  = @convention(c) (AnyObject?) -> Unmanaged<CFArray>?
    private typealias CopyEvtT  = @convention(c) (AnyObject?, Int64, Int32, Int64) -> Unmanaged<AnyObject>?
    private typealias GetFloatT = @convention(c) (AnyObject?, Int64) -> Double
    private typealias CopyPropT = @convention(c) (AnyObject?, CFString?) -> Unmanaged<AnyObject>?

    private static let kTemperature: Int32 = 15   // kIOHIDEventTypeTemperature

    private let client: AnyObject
    private let copySvc: CopySvcT
    private let copyEvt: CopyEvtT
    private let getFloat: GetFloatT
    private let copyProp: CopyPropT
    /// Services with their PRE-COMPUTED labels. The service set and its "Product"
    /// names are stable for a boot, so the pattern-matching/label work runs once at
    /// refresh — not 77 sensors × 11 patterns of string splitting every slow tick.
    /// Numbering from the full service list (not just currently-readable sensors)
    /// also keeps labels stable when a sensor transiently reads 0.
    private var services: [(service: AnyObject, name: String)] = []

    public init?() {
        guard let h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW) else { return nil }
        func sym(_ n: String) -> UnsafeMutableRawPointer? { dlsym(h, n) }
        guard let pCreate = sym("IOHIDEventSystemClientCreate"),
              let pSetM   = sym("IOHIDEventSystemClientSetMatching"),
              let pCopyS  = sym("IOHIDEventSystemClientCopyServices"),
              let pCopyE  = sym("IOHIDServiceClientCopyEvent"),
              let pGetF   = sym("IOHIDEventGetFloatValue"),
              let pCopyP  = sym("IOHIDServiceClientCopyProperty")
        else { return nil }

        let create  = unsafeBitCast(pCreate, to: CreateT.self)
        let setM    = unsafeBitCast(pSetM, to: SetMatchT.self)
        self.copySvc  = unsafeBitCast(pCopyS, to: CopySvcT.self)
        self.copyEvt  = unsafeBitCast(pCopyE, to: CopyEvtT.self)
        self.getFloat = unsafeBitCast(pGetF, to: GetFloatT.self)
        self.copyProp = unsafeBitCast(pCopyP, to: CopyPropT.self)

        guard let cli = create(kCFAllocatorDefault)?.takeRetainedValue() else { return nil }
        self.client = cli
        // page 0xff00 / usage 0x05 = temperature sensors
        let match: [String: Any] = ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 0x05]
        setM(cli, match as CFDictionary)
        refreshServices()
    }

    /// Service list is stable for a boot; cache it (labels included) and refresh
    /// only if empty.
    private func refreshServices() {
        let list = (copySvc(client)?.takeRetainedValue() as? [AnyObject]) ?? []
        var counters = [Int: Int]()   // per-pattern running index for the % placeholder
        services = list.map { s in
            let raw = (copyProp(s, "Product" as CFString)?.takeRetainedValue() as? String) ?? "Sensor"
            return (s, Self.label(raw, counters: &counters))
        }
    }

    /// Snapshot all readable temperature sensors (named, > 0 °C).
    public func read() -> [TempSensor] {
        if services.isEmpty { refreshServices() }
        var out = [TempSensor]()
        out.reserveCapacity(services.count)
        for (s, name) in services {
            guard let ev = copyEvt(s, Int64(Self.kTemperature), 0, 0)?.takeRetainedValue() else { continue }
            let v = getFloat(ev, Int64(Self.kTemperature) << 16)
            guard v > 0, v < 150 else { continue }   // reject bogus/unpopulated
            out.append(TempSensor(name: name, celsius: v))
        }
        return out
    }

    // exelban/Stats `HIDSensorsList` (Modules/Sensors/values.swift): maps the raw
    // IOHIDEventSystem "Product" string to a human label. `%` is replaced by a 1-based
    // running index so the N sensors sharing a pattern (e.g. every "pACC MTR Temp
    // Sensor") read as "CPU performance core 1…N" instead of cryptic raw duplicates.
    // Unmatched names (e.g. the static "PMU tcal" calibration reference) pass through
    // raw — honest, and skipped by the headline auto-pick.
    private static let labelPatterns: [(key: String, name: String)] = [
        ("pACC MTR Temp Sensor%", "CPU performance core %"),
        ("eACC MTR Temp Sensor%", "CPU efficiency core %"),
        ("GPU MTR Temp Sensor%",  "GPU core %"),
        ("SOC MTR Temp Sensor%",  "SOC core %"),
        ("ANE MTR Temp Sensor%",  "Neural engine %"),
        ("ISP MTR Temp Sensor%",  "Image signal processor %"),
        ("PMGR SOC Die Temp Sensor%", "Power manager die %"),
        ("PMU tdev%",             "Power management unit dev %"),
        ("PMU tdie%",             "Power management unit die %"),
        ("gas gauge battery",     "Battery"),
        ("NAND CH% temp",         "Disk %"),
    ]

    /// Map one raw Product name to its friendly label, numbering duplicates 1…N.
    /// `counters` carries the per-pattern index across one full `read()`.
    static func label(_ raw: String, counters: inout [Int: Int]) -> String {
        for (i, p) in labelPatterns.enumerated() {
            let parts = p.key.components(separatedBy: "%")
            // No placeholder → exact match; else match the literal prefix AND suffix
            // around the `%` (handles trailing-% like "PMU tdie%" and mid-% like
            // "NAND CH% temp").
            let matched = parts.count == 1 ? (raw == p.key)
                                           : (raw.hasPrefix(parts[0]) && raw.hasSuffix(parts[1]))
            guard matched else { continue }
            guard p.name.contains("%") else { return p.name }   // single named sensor
            let n = (counters[i] ?? 0) + 1; counters[i] = n
            return p.name.replacingOccurrences(of: "%", with: "\(n)")
        }
        return raw
    }
}
