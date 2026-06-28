// Memory via Mach `host_statistics64(HOST_VM_INFO64)` + swap via sysctl.
//
// "Used" follows Activity Monitor: App + Wired + Compressed, where
// App = internal − purgeable. Pressure is a used/total proxy (the kernel's
// real pressure level is a 3-state enum, not a fraction) — calibrate against
// `kern.memorystatus_vm_pressure_level` if a truer signal is ever needed.

import Foundation
import Darwin

public struct MemoryReader: StatsReader {
    private let facts: SystemFacts
    public init(facts: SystemFacts = .current) { self.facts = facts }

    public mutating func read() throws -> MemorySample {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { throw StatsError.machCall(kr) }

        let pg = UInt64(facts.pageSize)
        let wired      = UInt64(stats.wire_count) * pg
        let compressed = UInt64(stats.compressor_page_count) * pg
        let purgeable  = UInt64(stats.purgeable_count) * pg
        let internalB  = UInt64(stats.internal_page_count) * pg
        let app        = internalB > purgeable ? internalB - purgeable : 0
        let used       = app + wired + compressed
        let total      = facts.physicalMemory
        let free       = total > used ? total - used : 0

        let swap = Self.swapUsed()
        return MemorySample(
            total: total, used: used, app: app, wired: wired,
            compressed: compressed, free: free,
            pressure: total > 0 ? min(1, Double(used) / Double(total)) : 0,
            swapUsed: swap)
    }

    static func swapUsed() -> UInt64 {
        var xsw = xsw_usage()
        var size = MemoryLayout<xsw_usage>.stride
        guard sysctlbyname("vm.swapusage", &xsw, &size, nil, 0) == 0 else { return 0 }
        return xsw.xsu_used
    }
}
