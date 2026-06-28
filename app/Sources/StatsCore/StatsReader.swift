// Reader protocol + the shared sample value types every module emits.
//
// A reader is a stateless-ish sampler: `read()` returns one snapshot. Delta
// readers (CPU, network) keep the previous raw counters internally and emit a
// rate. The poller calls `read()` on its serial queue at the module's cadence.

import Foundation

public enum StatsError: Error, Equatable {
    case machCall(kern_return_t)   // host_* / task_* failure
    case unavailable(String)       // API/source absent on this machine
}

public protocol StatsReader {
    associatedtype Sample
    /// One snapshot. Throws on a hard failure (API gone); a soft/partial read
    /// returns a Sample with the unavailable fields nil-ed.
    mutating func read() throws -> Sample
}

// MARK: - Sample types (plain values, Sendable for actor hand-off)

public struct CPUSample: Sendable, Equatable {
    public let total: Double          // 0...1 overall load
    public let performance: Double    // 0...1 P-cluster (NaN if unknown)
    public let efficiency: Double     // 0...1 E-cluster (NaN if unknown)
    public let system: Double
    public let user: Double
    public let idle: Double
    public let perCore: [Double]      // 0...1 per logical core
    public let loadAverage: [Double]  // 1/5/15-min run-queue averages (empty if unread)
    public let uptimeSeconds: Int     // since boot; 0 if unknown
    public let freqE: Double          // E-cluster GHz, residency-weighted (NaN if unknown)
    public let freqP: Double          // P-cluster GHz, residency-weighted (NaN if unknown)
    public init(total: Double, performance: Double, efficiency: Double,
                system: Double, user: Double, idle: Double, perCore: [Double],
                loadAverage: [Double] = [], uptimeSeconds: Int = 0,
                freqE: Double = .nan, freqP: Double = .nan) {
        self.total = total; self.performance = performance; self.efficiency = efficiency
        self.system = system; self.user = user; self.idle = idle; self.perCore = perCore
        self.loadAverage = loadAverage; self.uptimeSeconds = uptimeSeconds
        self.freqE = freqE; self.freqP = freqP
    }
}

public struct MemorySample: Sendable, Equatable {
    public let total: UInt64
    public let used: UInt64           // app + wired + compressed (matches Activity Monitor)
    public let app: UInt64
    public let wired: UInt64
    public let compressed: UInt64
    public let cached: UInt64          // purgeable + external (Activity Monitor "Cached Files")
    public let free: UInt64
    public let pressure: Double       // 0...1 (used/total proxy, drives the chart)
    public let swapUsed: UInt64
    public let swapTotal: UInt64
    /// Kernel memory-pressure level from `kern.memorystatus_vm_pressure_level`:
    /// 1=normal, 2=warning, 4=critical (0 if unread). The true signal, unlike the
    /// `pressure` fraction above which is only a used/total approximation.
    public let pressureLevel: Int
    public init(total: UInt64, used: UInt64, app: UInt64, wired: UInt64,
                compressed: UInt64, free: UInt64, pressure: Double, swapUsed: UInt64,
                cached: UInt64 = 0, swapTotal: UInt64 = 0, pressureLevel: Int = 0) {
        self.total = total; self.used = used; self.app = app; self.wired = wired
        self.compressed = compressed; self.cached = cached; self.free = free
        self.pressure = pressure
        self.swapUsed = swapUsed; self.swapTotal = swapTotal; self.pressureLevel = pressureLevel
    }
    public var usedFraction: Double { total == 0 ? 0 : Double(used) / Double(total) }
    /// Human pressure state from the kernel level (falls back to the fraction).
    public var pressureState: String {
        switch pressureLevel {
        case 4: "Critical"; case 2: "Warning"; case 1: "Normal"
        default: pressure > 0.8 ? "High" : "Normal"
        }
    }
}

public struct NetworkSample: Sendable, Equatable {
    public let uploadBytesPerSec: Double
    public let downloadBytesPerSec: Double
    public let totalUploaded: UInt64
    public let totalDownloaded: UInt64
    public let interfaceName: String?   // primary active interface, e.g. "en0"
    public let ipv4: String?            // its IPv4 address
    public let ssid: String?            // Wi-Fi network name, nil on wired/none
    public init(uploadBytesPerSec: Double, downloadBytesPerSec: Double,
                totalUploaded: UInt64, totalDownloaded: UInt64,
                interfaceName: String? = nil, ipv4: String? = nil, ssid: String? = nil) {
        self.uploadBytesPerSec = uploadBytesPerSec
        self.downloadBytesPerSec = downloadBytesPerSec
        self.totalUploaded = totalUploaded
        self.totalDownloaded = totalDownloaded
        self.interfaceName = interfaceName; self.ipv4 = ipv4; self.ssid = ssid
    }
}
