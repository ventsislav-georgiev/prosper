// CPU load via Mach `host_processor_info(PROCESSOR_CPU_LOAD_INFO)`.
//
// Per-core cumulative tick counters (user/system/idle/nice); load is the delta
// between two reads, so the FIRST read returns zeros (no prior baseline). The
// kernel hands back vm-allocated memory we must vm_deallocate every call.
//
// E/P split: SystemFacts gives the cluster sizes. On Apple Silicon the
// processor list is E-cores first, then P-cores (validated: E+P == logical in
// SystemFactsTests). `eFirst` is the calibration knob if a future SoC reorders.

import Foundation
import Darwin

public struct CPUReader: StatsReader {
    private let facts: SystemFacts
    private let eFirst: Bool
    private var prev: [(user: UInt32, system: UInt32, idle: UInt32, nice: UInt32)] = []

    public init(facts: SystemFacts = .current, eCoresFirst: Bool = true) {
        self.facts = facts
        self.eFirst = eCoresFirst
    }

    public mutating func read() throws -> CPUSample {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let kr = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                                     &cpuCount, &info, &infoCount)
        guard kr == KERN_SUCCESS, let info else { throw StatsError.machCall(kr) }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info),
                          vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride))
        }

        let n = Int(cpuCount)
        let stride = Int(CPU_STATE_MAX)   // 4: user, system, idle, nice
        var cur = [(user: UInt32, system: UInt32, idle: UInt32, nice: UInt32)]()
        cur.reserveCapacity(n)
        info.withMemoryRebound(to: UInt32.self, capacity: n * stride) { p in
            for c in 0..<n {
                let base = c * stride
                cur.append((p[base + Int(CPU_STATE_USER)],
                            p[base + Int(CPU_STATE_SYSTEM)],
                            p[base + Int(CPU_STATE_IDLE)],
                            p[base + Int(CPU_STATE_NICE)]))
            }
        }

        let loadAvg = Self.loadAverage()
        let uptime = Self.uptimeSeconds()

        // First read: store baseline, report idle (no prior delta to rate).
        guard prev.count == n else {
            prev = cur
            return CPUSample(total: 0, performance: 0, efficiency: 0,
                             system: 0, user: 0, idle: 1,
                             perCore: Array(repeating: 0, count: n),
                             loadAverage: loadAvg, uptimeSeconds: uptime)
        }

        var perCore = [Double](repeating: 0, count: n)
        var sumUser = 0.0, sumSys = 0.0, sumIdle = 0.0, sumTotal = 0.0
        for c in 0..<n {
            let du = Double(cur[c].user &- prev[c].user)
            let ds = Double(cur[c].system &- prev[c].system)
            let di = Double(cur[c].idle &- prev[c].idle)
            let dn = Double(cur[c].nice &- prev[c].nice)
            let busy = du + ds + dn
            let tot = busy + di
            perCore[c] = tot > 0 ? busy / tot : 0
            sumUser += du; sumSys += ds; sumIdle += di; sumTotal += tot
        }
        prev = cur

        // Total busy = everything not idle (includes nice), matching Activity Monitor.
        let total = sumTotal > 0 ? (sumTotal - sumIdle) / sumTotal : 0
        let (eLoad, pLoad) = clusterLoads(perCore)
        return CPUSample(
            total: max(0, min(1, total)),
            performance: pLoad,
            efficiency: eLoad,
            system: sumTotal > 0 ? sumSys / sumTotal : 0,
            user: sumTotal > 0 ? sumUser / sumTotal : 0,
            idle: sumTotal > 0 ? sumIdle / sumTotal : 1,
            perCore: perCore,
            loadAverage: loadAvg, uptimeSeconds: uptime)
    }

    /// 1/5/15-minute run-queue load averages via libc `getloadavg`.
    static func loadAverage() -> [Double] {
        var l = [Double](repeating: 0, count: 3)
        return getloadavg(&l, 3) == 3 ? l : []
    }

    /// Seconds since boot from `kern.boottime` (wall-clock delta).
    static func uptimeSeconds() -> Int {
        var bt = timeval(); var size = MemoryLayout<timeval>.stride
        guard sysctlbyname("kern.boottime", &bt, &size, nil, 0) == 0, bt.tv_sec != 0 else { return 0 }
        return max(0, Int(time(nil) - bt.tv_sec))
    }

    /// Average load of the E and P clusters from the per-core array.
    private func clusterLoads(_ perCore: [Double]) -> (efficiency: Double, performance: Double) {
        let e = facts.efficiencyCores, p = facts.performanceCores
        guard e > 0, p > 0, e + p <= perCore.count else { return (.nan, .nan) }
        let eSlice = eFirst ? perCore[0..<e] : perCore[(perCore.count - e)...]
        let pSlice = eFirst ? perCore[e..<(e + p)] : perCore[0..<p]
        func avg(_ s: ArraySlice<Double>) -> Double { s.isEmpty ? 0 : s.reduce(0, +) / Double(s.count) }
        return (avg(eSlice), avg(pSlice))
    }
}
