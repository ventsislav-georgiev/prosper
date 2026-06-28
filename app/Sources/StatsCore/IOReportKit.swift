// Power telemetry via the private IOReport framework — CPU / GPU / ANE Watts.
//
// IOReport exposes an "Energy Model" channel group whose per-channel values are
// energy (millijoules) accumulated over a sample interval; power = ΔmJ / Δt.
// Resolved by dlsym from /usr/lib/libIOReport.dylib so nothing private is
// linked at build time. Prosper is not sandboxed, so the dylib loads.
//
// SAFETY: every @convention(c) signature here is load-bearing — a wrong arity
// or type segfaults at CALL time, not link time. These match the canonical
// reverse-engineered IOReport ABI (same as exelban/stats Energy.swift). The
// `IOReportIterate` block is @convention(block). Validated by ioreport2_probe
// before being wired into the app. Any failure path returns nil, never crashes.

import Foundation
import CoreFoundation

public struct PowerSample: Sendable, Equatable {
    public let cpuWatts: Double
    public let gpuWatts: Double
    public let aneWatts: Double      // Apple Neural Engine
    public let dramWatts: Double     // DRAM (0 if the SoC doesn't report it)
    public let totalWatts: Double
    public init(cpuWatts: Double, gpuWatts: Double, aneWatts: Double,
                dramWatts: Double = 0, totalWatts: Double) {
        self.cpuWatts = cpuWatts; self.gpuWatts = gpuWatts
        self.aneWatts = aneWatts; self.dramWatts = dramWatts; self.totalWatts = totalWatts
    }
}

public final class IOReportKit {
    // Opaque handles are raw pointers.
    private typealias CopyChannelsT = @convention(c)
        (CFString?, CFString?, UInt64) -> Unmanaged<CFMutableDictionary>?
    private typealias MergeT = @convention(c)
        (CFMutableDictionary?, CFMutableDictionary?) -> Void
    private typealias CreateSubT = @convention(c)
        (UnsafeMutableRawPointer?, CFMutableDictionary?,
         UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>?, UInt64, CFTypeRef?) -> Unmanaged<AnyObject>?
    private typealias CreateSamplesT = @convention(c)
        (AnyObject?, CFMutableDictionary?, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias DeltaT = @convention(c)
        (CFDictionary?, CFDictionary?, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias IterateT = @convention(c)
        (CFDictionary?, @convention(block) (CFDictionary?) -> Int32) -> Void
    private typealias GetNameT = @convention(c) (CFDictionary?) -> Unmanaged<CFString>?
    private typealias GetIntT = @convention(c) (CFDictionary?, Int32) -> Int64
    private typealias GetUnitT = @convention(c) (CFDictionary?) -> Unmanaged<CFString>?

    private let copyChannels: CopyChannelsT
    private let createSub: CreateSubT
    private let createSamples: CreateSamplesT
    private let delta: DeltaT
    private let iterate: IterateT
    private let getName: GetNameT
    private let getInt: GetIntT
    private let getUnit: GetUnitT

    private let subscription: AnyObject
    private let channels: CFMutableDictionary
    private var prevSample: CFDictionary?
    private var prevTime: Double = 0
    private let now: () -> Double

    public init?(now: @escaping () -> Double = NetworkReader.monotonicSeconds) {
        self.now = now
        guard let h = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW) else { return nil }
        func sym(_ n: String) -> UnsafeMutableRawPointer? { dlsym(h, n) }
        guard let pCopy = sym("IOReportCopyChannelsInGroup"),
              let pSub  = sym("IOReportCreateSubscription"),
              let pSamp = sym("IOReportCreateSamples"),
              let pDelt = sym("IOReportCreateSamplesDelta"),
              let pIter = sym("IOReportIterate"),
              let pName = sym("IOReportChannelGetChannelName"),
              let pInt  = sym("IOReportSimpleGetIntegerValue"),
              let pUnit = sym("IOReportChannelGetUnitLabel")
        else { return nil }

        self.copyChannels  = unsafeBitCast(pCopy, to: CopyChannelsT.self)
        self.createSub     = unsafeBitCast(pSub, to: CreateSubT.self)
        self.createSamples = unsafeBitCast(pSamp, to: CreateSamplesT.self)
        self.delta         = unsafeBitCast(pDelt, to: DeltaT.self)
        self.iterate       = unsafeBitCast(pIter, to: IterateT.self)
        self.getName       = unsafeBitCast(pName, to: GetNameT.self)
        self.getInt        = unsafeBitCast(pInt, to: GetIntT.self)
        self.getUnit       = unsafeBitCast(pUnit, to: GetUnitT.self)

        guard let chans = copyChannels("Energy Model" as CFString, nil, 0)?.takeRetainedValue() else { return nil }
        self.channels = chans
        var subbed: Unmanaged<CFMutableDictionary>?
        guard let sub = createSub(nil, chans, &subbed, 0, nil)?.takeRetainedValue() else { return nil }
        self.subscription = sub
        _ = subbed?.takeRetainedValue()   // balance the +1 from the out-param
    }

    /// One power reading. First call seeds the baseline → returns zeros.
    public func read() -> PowerSample? {
        guard let cur = createSamples(subscription, channels, nil)?.takeRetainedValue() else { return nil }
        let t = now()
        defer { prevSample = cur; prevTime = t }
        guard let prev = prevSample else { return PowerSample(cpuWatts: 0, gpuWatts: 0, aneWatts: 0, totalWatts: 0) }   // seed
        let dt = max(t - prevTime, 0.0001)
        guard let d = delta(prev, cur, nil)?.takeRetainedValue() else { return nil }

        // Match the authoritative AGGREGATE channels by exact name (summing
        // substrings double-counts: "GPU Energy" duplicates "GPU", and per-core
        // EACC_/PACC_ channels roll up into "CPU Energy"). Scale per-channel by
        // its unit label — the Energy Model mixes mJ / µJ / nJ.
        var energyJ: [String: Double] = [:]   // domain → Joules over the interval
        iterate(d) { [getName, getInt, getUnit] ch in
            guard let ch else { return 0 }
            // Get-rule (+0): use takeUnretainedValue, NOT takeRetainedValue —
            // the latter over-releases the CFString and segfaults under load.
            let name = (getName(ch)?.takeUnretainedValue() as String?) ?? ""
            let unit = (getUnit(ch)?.takeUnretainedValue() as String?) ?? "mJ"
            let scale: Double = unit == "nJ" ? 1e9 : (unit == "uJ" || unit == "µJ" ? 1e6 : 1e3)
            let joules = Double(getInt(ch, 0)) / scale
            switch name {
            case "CPU Energy":               energyJ["cpu", default: 0] += joules
            case "GPU Energy":               energyJ["gpu", default: 0] += joules
            case "ANE", "ANE Energy":        energyJ["ane", default: 0] += joules
            case "DRAM", "DRAM Energy":      energyJ["dram", default: 0] += joules
            default: break
            }
            return 0
        }
        let cpu = (energyJ["cpu"] ?? 0) / dt
        let gpu = (energyJ["gpu"] ?? 0) / dt
        let ane = (energyJ["ane"] ?? 0) / dt
        let dram = (energyJ["dram"] ?? 0) / dt
        return PowerSample(cpuWatts: cpu, gpuWatts: gpu, aneWatts: ane,
                           dramWatts: dram, totalWatts: cpu + gpu + ane + dram)
    }
}
