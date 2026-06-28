// Static machine facts — read ONCE at startup, never on the hot path.
//
// Core topology (E/P split), page size, physical memory, model identifier.
// Readers that need these (CPU % per cluster, RAM totals) capture a snapshot
// rather than re-querying sysctl every tick.

import Foundation

public struct SystemFacts: Sendable {
    public let physicalCores: Int
    public let logicalCores: Int
    public let efficiencyCores: Int     // 0 on Intel / unknown
    public let performanceCores: Int    // 0 on Intel / unknown
    public let pageSize: Int
    public let physicalMemory: UInt64   // bytes
    public let modelIdentifier: String
    public let isAppleSilicon: Bool

    public static let current = SystemFacts()

    public init() {
        self.physicalCores  = Self.sysctlInt("hw.physicalcpu") ?? 1
        self.logicalCores   = Self.sysctlInt("hw.logicalcpu") ?? 1
        // perflevel0 = P-cores, perflevel1 = E-cores on Apple Silicon.
        // Absent on Intel → 0.
        self.performanceCores = Self.sysctlInt("hw.perflevel0.logicalcpu") ?? 0
        self.efficiencyCores  = Self.sysctlInt("hw.perflevel1.logicalcpu") ?? 0
        self.pageSize       = Self.sysctlInt("hw.pagesize") ?? 16384
        self.physicalMemory = UInt64(Self.sysctlInt64("hw.memsize") ?? 0)
        self.modelIdentifier = Self.sysctlString("hw.model") ?? "unknown"
        #if arch(arm64)
        self.isAppleSilicon = true
        #else
        self.isAppleSilicon = false
        #endif
    }

    // MARK: sysctl helpers

    static func sysctlInt(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return Int(value)
    }

    static func sysctlInt64(_ name: String) -> Int64? {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        if let nul = buf.firstIndex(of: 0) { buf.removeSubrange(nul...) }
        return String(decoding: buf, as: UTF8.self)
    }
}
