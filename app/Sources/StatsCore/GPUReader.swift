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
    public init(utilization: Double, name: String, usedMemory: UInt64,
                renderUtil: Double = .nan, tilerUtil: Double = .nan, coreCount: Int = 0) {
        self.utilization = utilization; self.name = name; self.usedMemory = usedMemory
        self.renderUtil = renderUtil; self.tilerUtil = tilerUtil; self.coreCount = coreCount
    }
}

public struct GPUReader: StatsReader {
    public init() {}

    public mutating func read() throws -> GPUSample {
        var iter: io_iterator_t = 0
        let match = IOServiceMatching("IOAccelerator")
        guard IOServiceGetMatchingServices(kIOMainPortDefault, match, &iter) == KERN_SUCCESS else {
            throw StatsError.unavailable("IOAccelerator")
        }
        defer { IOObjectRelease(iter) }

        var best = GPUSample(utilization: 0, name: "GPU", usedMemory: 0)
        var found = false
        var entry = IOIteratorNext(iter)
        while entry != 0 {
            defer { IOObjectRelease(entry); entry = IOIteratorNext(iter) }
            var props: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(entry, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let dict = props?.takeRetainedValue() as? [String: Any],
                  let perf = dict["PerformanceStatistics"] as? [String: Any]
            else { continue }

            let util = (perf["Device Utilization %"] as? NSNumber)?.doubleValue
                    ?? (perf["GPU Activity(%)"] as? NSNumber)?.doubleValue ?? 0
            let mem = (perf["In use system memory"] as? NSNumber)?.uint64Value
                   ?? (perf["vramUsedBytes"] as? NSNumber)?.uint64Value ?? 0
            let name = (dict["IOGLBundleName"] as? String)
                    ?? (dict["model"] as? String) ?? "GPU"
            let cores = (dict["gpu-core-count"] as? NSNumber)?.intValue ?? 0
            func frac(_ k: String) -> Double {
                (perf[k] as? NSNumber).map { min(1, max(0, $0.doubleValue / 100)) } ?? .nan
            }
            // Adopt the first nub, then only strictly-busier ones — so an all-idle
            // multi-GPU Mac keeps the first real name/mem instead of flip-flopping.
            if !found || util / 100 > best.utilization {
                best = GPUSample(utilization: min(1, max(0, util / 100)), name: name, usedMemory: mem,
                                 renderUtil: frac("Renderer Utilization %"),
                                 tilerUtil: frac("Tiler Utilization %"), coreCount: cores)
            }
            found = true
        }
        guard found else { throw StatsError.unavailable("IOAccelerator: no nub") }
        return best
    }
}
