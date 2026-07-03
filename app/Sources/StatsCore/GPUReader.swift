// GPU utilization via the IOAccelerator registry — PUBLIC IOKit, no dlopen.
//
// Each accelerator nub publishes a "PerformanceStatistics" dict; "Device
// Utilization %" is the integer 0–100 busy figure Activity Monitor shows. Works
// on Apple Silicon (unified memory) and discrete GPUs alike. We pick the entry
// with the highest utilization (the active GPU on multi-GPU Intel Macs).

import Foundation
import IOKit

public struct GPUSample: Sendable, Equatable {
    public let utilization: Double      // 0...1
    public let name: String
    public let usedMemory: UInt64       // bytes, 0 if unreported
    public let renderUtil: Double       // 0...1 renderer (NaN if unreported)
    public let tilerUtil: Double        // 0...1 tiler (NaN if unreported)
    public let coreCount: Int           // GPU cores, 0 if unreported
    public let fps: Double              // presented frames/sec (NaN if unreported)
    public init(utilization: Double, name: String, usedMemory: UInt64,
                renderUtil: Double = .nan, tilerUtil: Double = .nan, coreCount: Int = 0,
                fps: Double = .nan) {
        self.utilization = utilization; self.name = name; self.usedMemory = usedMemory
        self.renderUtil = renderUtil; self.tilerUtil = tilerUtil; self.coreCount = coreCount
        self.fps = fps
    }
}

public struct GPUReader: StatsReader {
    // Reference type: presented-frame counters persist across reads. nil when the
    // DCP IOReport group is unavailable → fps stays NaN.
    private let frameRate: GPUFrameRate?
    // Reference type: retained IOAccelerator registry entries + their static
    // identity props, matched once — the nub set is stable for a boot, so the
    // per-tick work is ONE single-key property copy per nub, not a fresh service
    // match + full property-dict bridge every second.
    private let nubs = GPUNubCache()

    public init(frameRate: Bool = true) {
        self.frameRate = frameRate ? GPUFrameRate() : nil
    }

    public mutating func read() throws -> GPUSample {
        if nubs.entries.isEmpty { nubs.match() }
        guard !nubs.entries.isEmpty else { throw StatsError.unavailable("IOAccelerator") }

        var best = GPUSample(utilization: 0, name: "GPU", usedMemory: 0)
        var found = false
        for attempt in 0..<2 {
            for nub in nubs.entries {
                guard let perf = nub.performanceStatistics() else { continue }
                let util = (perf["Device Utilization %"] as? NSNumber)?.doubleValue
                        ?? (perf["GPU Activity(%)"] as? NSNumber)?.doubleValue ?? 0
                let mem = (perf["In use system memory"] as? NSNumber)?.uint64Value
                       ?? (perf["vramUsedBytes"] as? NSNumber)?.uint64Value ?? 0
                func frac(_ k: String) -> Double {
                    (perf[k] as? NSNumber).map { min(1, max(0, $0.doubleValue / 100)) } ?? .nan
                }
                // Adopt the first nub, then only strictly-busier ones — so an all-idle
                // multi-GPU Mac keeps the first real name/mem instead of flip-flopping.
                if !found || util / 100 > best.utilization {
                    best = GPUSample(utilization: min(1, max(0, util / 100)), name: nub.name,
                                     usedMemory: mem,
                                     renderUtil: frac("Renderer Utilization %"),
                                     tilerUtil: frac("Tiler Utilization %"), coreCount: nub.cores)
                }
                found = true
            }
            if found { break }
            // Every cached entry failed to answer — the nub set changed under us
            // (eGPU unplug, driver reload). Re-match once and retry this tick.
            guard attempt == 0 else { break }
            nubs.match()
        }
        guard found else { throw StatsError.unavailable("IOAccelerator: no nub") }
        // FPS spans all displays, not a single nub — read once and stamp it on.
        let fps = frameRate?.read() ?? .nan
        return GPUSample(utilization: best.utilization, name: best.name, usedMemory: best.usedMemory,
                         renderUtil: best.renderUtil, tilerUtil: best.tilerUtil,
                         coreCount: best.coreCount, fps: fps)
    }
}

/// Retained IOAccelerator registry entries with their boot-static identity props.
/// Class so `deinit` releases the io_object retains if the reader is torn down.
private final class GPUNubCache {
    struct Nub {
        let entry: io_registry_entry_t
        let name: String
        let cores: Int
        /// The one per-tick read: a single-key property copy, no full-dict bridge.
        func performanceStatistics() -> [String: Any]? {
            IORegistryEntryCreateCFProperty(entry, "PerformanceStatistics" as CFString,
                                            kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any]
        }
    }
    private(set) var entries: [Nub] = []

    func match() {
        releaseAll()
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("IOAccelerator"),
                                           &iter) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iter) }
        var entry = IOIteratorNext(iter)
        while entry != 0 {
            // Full property bridge ONCE per boot-stable nub for the identity fields.
            var props: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(entry, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let dict = props?.takeRetainedValue() as? [String: Any] {
                let name = (dict["IOGLBundleName"] as? String)
                        ?? (dict["model"] as? String) ?? "GPU"
                let cores = (dict["gpu-core-count"] as? NSNumber)?.intValue ?? 0
                entries.append(Nub(entry: entry, name: name, cores: cores))  // keeps the retain
            } else {
                IOObjectRelease(entry)
            }
            entry = IOIteratorNext(iter)
        }
    }

    private func releaseAll() {
        for n in entries { IOObjectRelease(n.entry) }
        entries = []
    }
    deinit { releaseAll() }
}
