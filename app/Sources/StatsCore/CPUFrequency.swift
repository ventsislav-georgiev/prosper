// Residency-weighted CPU clock via IOReport "CPU Stats" + pmgr DVFS tables.
//
// Apple Silicon exposes no "current MHz" register. Instead each cluster reports
// time spent in each DVFS performance state ("residency"); the displayed clock
// is the freq table weighted by where the cluster actually sat over the
// interval — the same number Instruments/exelban show.
//
// Two static inputs, read ONCE:
//   • freq tables — voltage-statesN-sram blobs on the `pmgr` node under
//     AppleARMIODevice. Each 8-byte pair: first LE u32 = freq, second = voltage
//     (skipped). Divisor is self-calibrated from magnitude (M4+ stores ~kHz,
//     older stores ~Hz) so no chip-generation table is needed.
//   • channel shape — the bare "ECPU"/"PCPU" channels in the "CPU Stats" group
//     carry one residency per perf state, count == freq-table length (the
//     per-core "ECPU000" variants prepend DOWN/IDLE → longer, skipped here).
//
// Per tick: Δt-independent (residency is already a ratio), delta two samples,
// weight residency × freq, sum. First read seeds → nil.
//
// SAFETY: same load-bearing @convention(c) ABI discipline as IOReportKit —
// validated end-to-end by the cpustats.swift spike before wiring in. All
// failure paths return nil; never crashes.

import Foundation
import CoreFoundation
import IOKit

public final class CPUFrequency {
    private typealias CopyChannelsT = @convention(c)
        (CFString?, CFString?, UInt64) -> Unmanaged<CFMutableDictionary>?
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
    private typealias StateCountT = @convention(c) (CFDictionary?) -> Int32
    private typealias StateResidT = @convention(c) (CFDictionary?, Int32) -> Int64

    private let copyChannels: CopyChannelsT
    private let createSamples: CreateSamplesT
    private let delta: DeltaT
    private let iterate: IterateT
    private let getName: GetNameT
    private let stateCount: StateCountT
    private let stateResid: StateResidT

    private let subscription: AnyObject
    private let channels: CFMutableDictionary
    private var prevSample: CFDictionary?

    private let eFreqs: [Double]   // GHz per E perf state
    private let pFreqs: [Double]   // GHz per P perf state

    // Sampling the whole "CPU Stats" group costs ~7 ms (it spans every per-core
    // channel), so we don't do it on every fast CPU tick. Re-sample at most this
    // often and serve the cached clock between — residency is a ratio over any
    // window, so a wider one is just a smoother average.
    // ponytail: 1.5 s throttle is the cost knob; lower it only if the displayed
    // clock needs to track sub-second bursts (it doesn't — the menu-bar redraws ~1 s).
    private let minInterval: Double
    private let now: () -> Double
    private var lastSampleTime: Double = -.infinity
    private var cached: (e: Double, p: Double) = (.nan, .nan)

    public init?(now: @escaping () -> Double = NetworkReader.monotonicSeconds,
                 minInterval: Double = 1.5) {
        self.now = now
        self.minInterval = minInterval
        // Freq tables first — no point subscribing if the SoC won't decode.
        let (e, p) = Self.readFreqTables()
        guard !e.isEmpty || !p.isEmpty else { return nil }
        self.eFreqs = e
        self.pFreqs = p

        guard let h = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW) else { return nil }
        func sym(_ n: String) -> UnsafeMutableRawPointer? { dlsym(h, n) }
        guard let pCopy = sym("IOReportCopyChannelsInGroup"),
              let pSub  = sym("IOReportCreateSubscription"),
              let pSamp = sym("IOReportCreateSamples"),
              let pDelt = sym("IOReportCreateSamplesDelta"),
              let pIter = sym("IOReportIterate"),
              let pName = sym("IOReportChannelGetChannelName"),
              let pCnt  = sym("IOReportStateGetCount"),
              let pRes  = sym("IOReportStateGetResidency")
        else { return nil }

        self.copyChannels  = unsafeBitCast(pCopy, to: CopyChannelsT.self)
        let createSub      = unsafeBitCast(pSub, to: CreateSubT.self)
        self.createSamples = unsafeBitCast(pSamp, to: CreateSamplesT.self)
        self.delta         = unsafeBitCast(pDelt, to: DeltaT.self)
        self.iterate       = unsafeBitCast(pIter, to: IterateT.self)
        self.getName       = unsafeBitCast(pName, to: GetNameT.self)
        self.stateCount    = unsafeBitCast(pCnt, to: StateCountT.self)
        self.stateResid    = unsafeBitCast(pRes, to: StateResidT.self)

        guard let chans = copyChannels("CPU Stats" as CFString, nil, 0)?.takeRetainedValue() else { return nil }
        self.channels = chans
        var subbed: Unmanaged<CFMutableDictionary>?
        guard let sub = createSub(nil, chans, &subbed, 0, nil)?.takeRetainedValue() else { return nil }
        self.subscription = sub
        _ = subbed?.takeRetainedValue()
    }

    /// One clock reading in GHz per cluster. First call seeds → (NaN, NaN).
    /// Throttled: serves the cached value until `minInterval` has elapsed.
    public func read() -> (e: Double, p: Double) {
        let t = now()
        guard t - lastSampleTime >= minInterval else { return cached }
        lastSampleTime = t
        guard let cur = createSamples(subscription, channels, nil)?.takeRetainedValue() else { return cached }
        defer { prevSample = cur }
        guard let prev = prevSample else { return cached }   // first sample seeds the delta
        guard let d = delta(prev, cur, nil)?.takeRetainedValue() else { return (.nan, .nan) }

        let eFreqs = self.eFreqs, pFreqs = self.pFreqs
        var eGHz = Double.nan, pGHz = Double.nan
        iterate(d) { [getName, stateCount, stateResid] ch in
            guard let ch else { return 0 }
            let name = (getName(ch)?.takeUnretainedValue() as String?) ?? ""
            let n = Int(stateCount(ch))
            // Pure perf-state channel only: count matches the table exactly, so
            // residency index i maps straight to freqs[i]. The per-core variants
            // (ECPU000…) prepend DOWN/IDLE and don't match — they're skipped.
            let freqs: [Double]
            if name.hasPrefix("E") && n == eFreqs.count && n > 0 { freqs = eFreqs }
            else if name.hasPrefix("P") && n == pFreqs.count && n > 0 { freqs = pFreqs }
            else { return 0 }

            var total = 0.0, weighted = 0.0
            for i in 0..<n {
                let r = Double(stateResid(ch, Int32(i)))
                total += r
                weighted += r * freqs[i]
            }
            guard total > 0 else { return 0 }
            let ghz = weighted / total
            if name.hasPrefix("E") { eGHz = ghz } else { pGHz = ghz }
            return 0
        }
        // Carry the last good reading per cluster — a cluster parked the whole
        // window reports no residency (NaN); don't blank a previously-valid clock.
        if !eGHz.isNaN { cached.e = eGHz }
        if !pGHz.isNaN { cached.p = pGHz }
        return cached
    }

    // MARK: - DVFS freq tables (read once)

    /// (E-cluster GHz table, P-cluster GHz table) from the pmgr node. Empty on
    /// failure / non–Apple-Silicon. E = voltage-states1-sram, P = voltage-states5-sram.
    static func readFreqTables() -> (e: [Double], p: [Double]) {
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                IOServiceMatching("AppleARMIODevice"), &iter) == KERN_SUCCESS else { return ([], []) }
        defer { IOObjectRelease(iter) }
        var e = IOIteratorNext(iter)
        while e != 0 {
            defer { IOObjectRelease(e); e = IOIteratorNext(iter) }
            var name = [CChar](repeating: 0, count: 128)
            IORegistryEntryGetName(e, &name)
            guard String(cString: name) == "pmgr" else { continue }
            let eTbl = blob(e, "voltage-states1-sram").map(decode) ?? []
            let pTbl = blob(e, "voltage-states5-sram").map(decode) ?? []
            return (eTbl, pTbl)
        }
        return ([], [])
    }

    private static func blob(_ entry: io_registry_entry_t, _ key: String) -> Data? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Data
    }

    /// Decode a voltage-states blob → GHz. Each 8-byte pair: first LE u32 = freq,
    /// second = voltage (skipped). Divisor self-calibrated from magnitude:
    /// M4+ stores freq in ~kHz (max ~4.5e6), older SoCs in ~Hz (max ~3.2e9).
    /// ponytail: magnitude threshold replaces a chip-generation table — the one
    /// calibration knob; bump only if a future SoC encodes outside both ranges.
    static func decode(_ data: Data) -> [Double] {
        var raws: [UInt32] = []
        data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            var i = 0
            while i + 4 <= buf.count {
                let v = buf.loadUnaligned(fromByteOffset: i, as: UInt32.self)
                if v != 0 { raws.append(v) }
                i += 8
            }
        }
        guard let maxRaw = raws.max() else { return [] }
        let div: Double = maxRaw > 100_000_000 ? 1_000_000_000 : 1_000_000  // → GHz
        return raws.map { Double($0) / div }
    }
}
