// Battery via public IOPowerSources + the AppleSmartBattery IORegistry.
//
// IOPowerSources gives charge %, charging state, time-to-empty/full. The
// AppleSmartBattery registry adds cycle count, health, instantaneous
// power (V×A), and battery temperature. Desktops/displays without a battery
// → read() throws .unavailable (caller hides the module).

import Foundation
import IOKit
import IOKit.ps

public struct BatterySample: Sendable, Equatable {
    public let charge: Double          // 0...1
    public let isCharging: Bool
    public let isPluggedIn: Bool
    public let timeToEmpty: Int        // minutes, -1 = calculating
    public let timeToFull: Int         // minutes, -1 = calculating
    public let cycleCount: Int
    public let health: Double           // 0...1 (maxCapacity / designCapacity)
    public let powerWatts: Double       // + charging, − discharging
    public let temperature: Double      // °C (NaN if unknown)
}

public struct BatteryReader: StatsReader {
    public init() {}

    public mutating func read() throws -> BatterySample {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef],
              let src = list.first,
              let desc = IOPSGetPowerSourceDescription(blob, src)?.takeUnretainedValue() as? [String: Any]
        else { throw StatsError.unavailable("no power source (desktop?)") }

        let cur = (desc[kIOPSCurrentCapacityKey] as? Int) ?? 0
        let mx  = (desc[kIOPSMaxCapacityKey] as? Int) ?? 100
        let charge = mx > 0 ? Double(cur) / Double(mx) : 0
        let state = (desc[kIOPSPowerSourceStateKey] as? String) ?? ""
        let pluggedIn = state == kIOPSACPowerValue
        let charging = (desc[kIOPSIsChargingKey] as? Bool) ?? false

        let reg = Self.smartBattery()
        return BatterySample(
            charge: min(1, max(0, charge)),
            isCharging: charging,
            isPluggedIn: pluggedIn,
            timeToEmpty: (desc[kIOPSTimeToEmptyKey] as? Int) ?? -1,
            timeToFull: (desc[kIOPSTimeToFullChargeKey] as? Int) ?? -1,
            cycleCount: reg.cycleCount,
            health: reg.health,
            powerWatts: reg.watts,
            temperature: reg.temperature)
    }

    private struct SmartBattery { var cycleCount = 0; var health = Double.nan; var watts = 0.0; var temperature = Double.nan }

    private static func smartBattery() -> SmartBattery {
        var out = SmartBattery()
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard svc != 0 else { return out }
        defer { IOObjectRelease(svc) }
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(svc, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let d = props?.takeRetainedValue() as? [String: Any] else { return out }

        out.cycleCount = (d["CycleCount"] as? Int) ?? 0
        let design = (d["DesignCapacity"] as? Int) ?? 0
        let maxCap = (d["AppleRawMaxCapacity"] as? Int) ?? (d["MaxCapacity"] as? Int) ?? 0
        if design > 0 { out.health = min(1, Double(maxCap) / Double(design)) }
        // Voltage (mV) × Amperage (mA, signed) → W. Amperage<0 = discharging.
        if let mV = d["Voltage"] as? Int, let mA = d["Amperage"] as? Int {
            out.watts = (Double(mV) / 1000.0) * (Double(mA) / 1000.0)
        }
        if let temp = d["Temperature"] as? Int { out.temperature = Double(temp) / 100.0 } // 1/100 °C
        return out
    }
}
