// Presented-frame rate via IOReport DCP ("Display Co-Processor") channels.
//
// The display pipeline reports per-frame "swap" events — a frame handed to the
// display. Summing the swap subframe histogram over an interval and dividing by
// elapsed time gives presented FPS: workload-driven (≈0 on a static desktop,
// climbing toward the refresh rate under animation), the same number exelban
// surfaces. Distinct from "frame_count", which tracks the fixed scanout/refresh
// rate regardless of workload.
//
// External displays land in DCPEXT0…3 groups; we merge them into the DCP
// subscription so the figure covers every attached panel.
//
// SAFETY: same load-bearing @convention(c) ABI as IOReportKit/CPUFrequency,
// validated end-to-end by the gpufps spike. Failure paths return NaN.

import Foundation
import CoreFoundation

public final class GPUFrameRate {
    private typealias CopyChannelsT = @convention(c)
        (CFString?, CFString?, UInt64) -> Unmanaged<CFMutableDictionary>?
    private typealias MergeT = @convention(c) (CFMutableDictionary?, CFMutableDictionary?) -> Void
    private typealias CreateSubT = @convention(c)
        (UnsafeMutableRawPointer?, CFMutableDictionary?,
         UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>?, UInt64, CFTypeRef?) -> Unmanaged<AnyObject>?
    private typealias CreateSamplesT = @convention(c)
        (AnyObject?, CFMutableDictionary?, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias DeltaT = @convention(c)
        (CFDictionary?, CFDictionary?, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias IterateT = @convention(c)
        (CFDictionary?, @convention(block) (CFDictionary?) -> Int32) -> Void
    private typealias GetStrT = @convention(c) (CFDictionary?) -> Unmanaged<CFString>?
    private typealias GetIntT = @convention(c) (CFDictionary?, Int32) -> Int64

    private let copyChannels: CopyChannelsT
    private let createSamples: CreateSamplesT
    private let delta: DeltaT
    private let iterate: IterateT
    private let getGroup: GetStrT
    private let getSubGroup: GetStrT
    private let getName: GetStrT
    private let getInt: GetIntT

    private let subscription: AnyObject
    private let channels: CFMutableDictionary
    private var prevSample: CFDictionary?
    private var prevTime: Double = 0
    private let now: () -> Double

    // The DCP group is small enough to sample cheaply, but FPS is a rate over an
    // interval — sampling faster than this just shrinks the window and adds noise.
    // ponytail: 1.0 s window matches the menu-bar redraw cadence.
    private let minInterval: Double
    private var lastSampleTime: Double = -.infinity
    private var cached: Double = .nan

    public init?(now: @escaping () -> Double = NetworkReader.monotonicSeconds,
                 minInterval: Double = 1.0) {
        self.now = now
        self.minInterval = minInterval
        guard let h = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW) else { return nil }
        func sym(_ n: String) -> UnsafeMutableRawPointer? { dlsym(h, n) }
        guard let pCopy = sym("IOReportCopyChannelsInGroup"),
              let pMerge = sym("IOReportMergeChannels"),
              let pSub  = sym("IOReportCreateSubscription"),
              let pSamp = sym("IOReportCreateSamples"),
              let pDelt = sym("IOReportCreateSamplesDelta"),
              let pIter = sym("IOReportIterate"),
              let pGrp  = sym("IOReportChannelGetGroup"),
              let pSubg = sym("IOReportChannelGetSubGroup"),
              let pName = sym("IOReportChannelGetChannelName"),
              let pInt  = sym("IOReportSimpleGetIntegerValue")
        else { return nil }

        self.copyChannels  = unsafeBitCast(pCopy, to: CopyChannelsT.self)
        let mergeChannels  = unsafeBitCast(pMerge, to: MergeT.self)
        let createSub      = unsafeBitCast(pSub, to: CreateSubT.self)
        self.createSamples = unsafeBitCast(pSamp, to: CreateSamplesT.self)
        self.delta         = unsafeBitCast(pDelt, to: DeltaT.self)
        self.iterate       = unsafeBitCast(pIter, to: IterateT.self)
        self.getGroup      = unsafeBitCast(pGrp, to: GetStrT.self)
        self.getSubGroup   = unsafeBitCast(pSubg, to: GetStrT.self)
        self.getName       = unsafeBitCast(pName, to: GetStrT.self)
        self.getInt        = unsafeBitCast(pInt, to: GetIntT.self)

        guard let chans = copyChannels("DCP" as CFString, nil, 0)?.takeRetainedValue() else { return nil }
        // Fold in external displays. Absent groups just return nil → skipped.
        for g in ["DCPEXT0", "DCPEXT1", "DCPEXT2", "DCPEXT3"] {
            if let ext = copyChannels(g as CFString, nil, 0)?.takeRetainedValue() {
                mergeChannels(chans, ext)
            }
        }
        self.channels = chans
        var subbed: Unmanaged<CFMutableDictionary>?
        guard let sub = createSub(nil, chans, &subbed, 0, nil)?.takeRetainedValue() else { return nil }
        self.subscription = sub
        _ = subbed?.takeRetainedValue()
    }

    /// Presented frames per second across all attached displays. First call
    /// seeds → NaN. Throttled: serves the cached rate until `minInterval` elapses.
    public func read() -> Double {
        let t = now()
        guard t - lastSampleTime >= minInterval else { return cached }
        guard let cur = createSamples(subscription, channels, nil)?.takeRetainedValue() else { return cached }
        let prevT = lastSampleTime
        lastSampleTime = t
        defer { prevSample = cur; prevTime = t }
        guard let prev = prevSample, prevT.isFinite else { return cached }
        let dt = max(t - prevTime, 0.0001)
        guard let d = delta(prev, cur, nil)?.takeRetainedValue() else { return cached }

        var frames = 0.0
        iterate(d) { [getGroup, getSubGroup, getName, getInt] ch in
            guard let ch else { return 0 }
            let group = (getGroup(ch)?.takeUnretainedValue() as String?) ?? ""
            guard group.hasPrefix("DCP") else { return 0 }
            let sub = (getSubGroup(ch)?.takeUnretainedValue() as String?) ?? ""
            let name = (getName(ch)?.takeUnretainedValue() as String?) ?? ""
            // "swap" subframe buckets = frames presented (workload-driven).
            if sub == "swap" && name.hasPrefix("subframes") { frames += Double(getInt(ch, 0)) }
            return 0
        }
        cached = frames / dt
        return cached
    }
}
