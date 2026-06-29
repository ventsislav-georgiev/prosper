// Top processes by CPU and memory via libproc — popup tables only, NOT a
// menu-bar hot path. Enumerates pids, reads per-process rusage (phys footprint
// + cpu time), and rates CPU as the time delta between samples (first sample
// has no CPU rate). Sampling every pid is ~1-2ms, so the poller runs this on a
// slow tier and only while a popup is open.

import Foundation
import Darwin

public struct ProcInfo: Sendable, Equatable {
    public let pid: Int32
    public let name: String
    public let cpu: Double          // 0...1 of one core-second per wall-second
    public let memory: UInt64       // phys_footprint bytes
    public var power: Double = 0     // top's relative energy-impact score (Activity Monitor "Energy")
}

public struct ProcSampler {
    // pid → (cumulative cpu nanoseconds, wall time of that reading)
    private var prevCPU: [Int32: (ns: UInt64, t: Double)] = [:]
    private let now: () -> Double

    // proc_pid_rusage reports ri_user_time/ri_system_time in MACH time units, not
    // nanoseconds — on Apple Silicon a tick is 125/3 ≈ 41.67 ns, so treating the raw
    // value as ns undercounts CPU ~42×. Convert with the machine's timebase (numer/
    // denom == 1 on Intel, so this is a no-op there).
    static let machToNS: Double = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return tb.denom == 0 ? 1 : Double(tb.numer) / Double(tb.denom)
    }()

    /// CPU-time delta (mach ticks) over a wall interval → core-seconds per wall-second.
    /// Pure so a test can pin the timebase conversion (one busy core for `dt` ⇒ ~1.0).
    static func cpuRate(deltaTicks: UInt64, seconds dt: Double) -> Double {
        guard dt > 0 else { return 0 }
        return (Double(deltaTicks) * machToNS / 1_000_000_000) / dt
    }

    public init(now: @escaping () -> Double = NetworkReader.monotonicSeconds) {
        self.now = now
    }

    /// Top `limit` by memory and by CPU. One enumeration feeds both.
    public mutating func sample(limit: Int = 5) -> (byCPU: [ProcInfo], byMemory: [ProcInfo]) {
        let t = now()
        let pids = Self.allPIDs()
        var infos = [ProcInfo]()
        infos.reserveCapacity(pids.count)
        var live = Set<Int32>()

        for pid in pids where pid > 0 {
            guard let ru = Self.rusage(pid) else { continue }
            live.insert(pid)
            let cpuNS = ru.ri_user_time &+ ru.ri_system_time
            var cpu = 0.0
            if let prev = prevCPU[pid], t > prev.t {
                cpu = Self.cpuRate(deltaTicks: cpuNS &- prev.ns, seconds: t - prev.t)
            }
            prevCPU[pid] = (cpuNS, t)
            infos.append(ProcInfo(pid: pid, name: Self.name(pid),
                                  cpu: max(0, cpu), memory: ru.ri_phys_footprint))
        }
        // Drop dead pids so the map doesn't grow unbounded.
        prevCPU = prevCPU.filter { live.contains($0.key) }

        let byMem = Array(infos.sorted { $0.memory > $1.memory }.prefix(limit))
        let byCPU = Array(infos.sorted { $0.cpu > $1.cpu }.prefix(limit))
        return (byCPU, byMem)
    }

    // MARK: libproc

    static func allPIDs() -> [Int32] {
        let cap = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard cap > 0 else { return [] }
        let count = Int(cap) / MemoryLayout<Int32>.stride
        var buf = [Int32](repeating: 0, count: count)
        let n = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &buf, cap)
        guard n > 0 else { return [] }
        let actual = Int(n) / MemoryLayout<Int32>.stride
        return Array(buf.prefix(actual))
    }

    static func rusage(_ pid: Int32) -> rusage_info_v4? {
        // proc_pid_rusage writes the whole rusage_info_v4 into the storage the
        // buffer points at — so it must point at `info`, NOT at a pointer slot.
        // (Passing &someRawPointer smashes the stack: ~200 bytes into 8.)
        var info = rusage_info_v4()
        let rc = withUnsafeMutablePointer(to: &info) { p in
            p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        return rc == 0 ? info : nil
    }

    static func name(_ pid: Int32) -> String {
        var buf = [UInt8](repeating: 0, count: 256)   // 2*MAXCOMLEN-ish
        let n = buf.withUnsafeMutableBytes { proc_name(pid, $0.baseAddress, UInt32($0.count)) }
        guard n > 0 else { return "pid \(pid)" }
        if let nul = buf.firstIndex(of: 0) { buf.removeSubrange(nul...) }
        return String(decoding: buf, as: UTF8.self)
    }
}
