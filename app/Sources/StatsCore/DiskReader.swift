// Disk capacity + throughput via public Foundation and IOKit.
//
// Capacity: `FileManager.mountedVolumeURLs(.skipHiddenVolumes)` filtered to `/`
// and `/Volumes/*`, free space from `volumeAvailableCapacityForImportantUsage`
// (the number Finder shows — larger than `df`, because purgeable space counts).
// Throughput: each volume's BSD device is resolved to its `IOBlockStorageDriver`
// and that node's `"Statistics"` dict carries cumulative `Bytes (Read)` /
// `Bytes (Write)`; the delta over elapsed monotonic time is the rate.
//
// Two tiers, both internal to the reader (no change to StatsPoller's dividers):
// counters every tick, volume re-enumeration + driver re-resolution every 10th
// (`volTick % 10`, the same idiom as `NetworkReader.linkTick`).
//
// Provenance: volume enumeration (`.skipHiddenVolumes` plus the `/`-or-`/Volumes`
// path filter) and the idea of mapping a BSD name to its `IOBlockStorageDriver`
// follow exelban/stats `Modules/Disk/readers.swift` (MIT, © 2019 Serhiy
// Mytrovtsiy); the registry walk here is re-derived — a conformance test capped
// at 12 hops, not exelban's trailing-digit-count heuristic, which mis-hops on
// APFS snapshot BSD names like `disk3s3s1`. The stale-sample gap reset and the
// reset-safe session totals follow vorssaint-utils `DiskSampler.swift` (GPL-3.0).

import Foundation
import IOKit
import os

public struct DiskVolume: Sendable, Equatable {
    public let name: String
    public let mountPath: String        // "/", "/Volumes/Backup"
    public let bsdName: String          // "disk3s3s1"
    public let fileSystem: String       // "apfs"
    public let total: UInt64
    public let free: UInt64
    public let isInternal: Bool
    public let isRemovable: Bool
    public init(name: String, mountPath: String, bsdName: String, fileSystem: String,
                total: UInt64, free: UInt64, isInternal: Bool, isRemovable: Bool) {
        self.name = name; self.mountPath = mountPath; self.bsdName = bsdName
        self.fileSystem = fileSystem; self.total = total; self.free = free
        self.isInternal = isInternal; self.isRemovable = isRemovable
    }
    /// Saturating: a `free` larger than `total` (an over-reported purgeable
    /// estimate) reads as fully free, never as a negative used figure.
    public var used: UInt64 { total &- min(free, total) }
    public var usedFraction: Double { total == 0 ? 0 : Double(used) / Double(total) }
}

public struct DiskSample: Sendable, Equatable {
    public let readBytesPerSec: Double
    public let writeBytesPerSec: Double
    public let totalRead: UInt64        // this session, reset-safe
    public let totalWritten: UInt64
    public let volumes: [DiskVolume]    // boot volume first
    /// Boot-disk NVMe SMART, popover-only. nil on non-NVMe / when not yet sampled.
    public let smart: DiskSMART?
    public init(readBytesPerSec: Double, writeBytesPerSec: Double,
                totalRead: UInt64, totalWritten: UInt64, volumes: [DiskVolume],
                smart: DiskSMART? = nil) {
        self.readBytesPerSec = readBytesPerSec; self.writeBytesPerSec = writeBytesPerSec
        self.totalRead = totalRead; self.totalWritten = totalWritten
        self.volumes = volumes; self.smart = smart
    }
    public var boot: DiskVolume? { volumes.first }
    /// The menu-bar/ring number: boot-volume capacity used.
    public var usedFraction: Double { boot?.usedFraction ?? 0 }
}

/// What `DiskReader` needs from the machine. Two implementations: the real IOKit
/// one below, and a stub in the tests so the rate math is exercised hermetically.
protocol DiskSource: AnyObject {
    var volumes: [DiskVolume] { get }
    /// Re-enumerate volumes and re-resolve their storage drivers.
    func refresh()
    /// Cumulative bytes read/written across every resolved driver.
    func counters() -> (read: UInt64, write: UInt64)
    /// Boot-disk NVMe SMART, refreshed on the same 10-tick tier as `refresh()`.
    var smart: DiskSMART? { get }
}

/// Sources that can't do SMART (test stubs, non-NVMe machines) get nil for free.
extension DiskSource {
    var smart: DiskSMART? { nil }
}

public struct DiskReader: StatsReader {
    /// Longer than this between samples (sleep, a paused debugger) and the rate
    /// would be nonsense — reseed instead of dividing by a huge dt.
    static let maxGap: Double = 15
    /// No Mac storage bus does 25 GB/s; a delta above it is a counter artefact.
    static let maxBytesPerSec: Double = 25_000_000_000

    private let now: () -> Double
    private let source: DiskSource
    private var prevRead: UInt64 = 0
    private var prevWrite: UInt64 = 0
    private var prevTime: Double = 0
    private var seeded = false
    private var cumRead: UInt64 = 0
    private var cumWrite: UInt64 = 0
    private var volTick = 0

    public init(now: @escaping () -> Double = NetworkReader.monotonicSeconds) {
        self.init(now: now, source: IOKitDiskSource())
    }

    init(now: @escaping () -> Double, source: DiskSource) {
        self.now = now
        self.source = source
    }

    public mutating func read() throws -> DiskSample {
        // Capacity moves slowly; re-enumerating (and re-resolving driver handles)
        // every 10th read is ~10 s at the default base interval.
        if volTick % 10 == 0 { source.refresh() }
        volTick += 1

        let (r, w) = source.counters()
        let t = now()
        defer { prevRead = r; prevWrite = w; prevTime = t; seeded = true }

        var readRate = 0.0, writeRate = 0.0
        let dt = t - prevTime
        if seeded, dt > 0, dt <= Self.maxGap {
            let cap = UInt64(Self.maxBytesPerSec * dt)
            // A counter going backwards means the driver set changed under us (eject,
            // re-resolve) — treat it as a reseed, never as a ~2^64 unsigned delta.
            let dR = r >= prevRead && r &- prevRead <= cap ? r - prevRead : 0
            let dW = w >= prevWrite && w &- prevWrite <= cap ? w - prevWrite : 0
            cumRead &+= dR; cumWrite &+= dW
            readRate = Double(dR) / dt; writeRate = Double(dW) / dt
        }

        let vols = source.volumes
        guard !vols.isEmpty else { throw StatsError.unavailable("no mounted volumes") }
        return DiskSample(readBytesPerSec: readRate, writeBytesPerSec: writeRate,
                          totalRead: cumRead, totalWritten: cumWrite, volumes: vols,
                          smart: source.smart)
    }
}

// MARK: - The machine

/// Retained `IOBlockStorageDriver` entries plus the last volume enumeration.
/// Class so `deinit` releases the io_object retains if the reader is torn down.
final class IOKitDiskSource: DiskSource {
    private static let log = Logger(subsystem: "com.prosper.stats", category: "disk")
    private static let resourceKeys: [URLResourceKey] = [
        .volumeNameKey, .volumeTotalCapacityKey,
        .volumeAvailableCapacityForImportantUsageKey,
        .volumeIsInternalKey, .volumeIsRemovableKey,
    ]

    private(set) var volumes: [DiskVolume] = []
    /// Slow tier: the CFPlugIn user-client dance rides the 10-tick `refresh()`, not
    /// every poll. Health %, power-on hours and lifetime writes move on the scale of
    /// hours — a per-second read would be pure waste.
    private(set) var smart: DiskSMART?
    private var drivers: [io_object_t] = []
    private var loggedResolveFailure = false

    deinit { releaseDrivers() }

    func refresh() {
        volumes = Self.enumerateVolumes()
        smart = volumes.first.flatMap { NVMeSMART.read(bsdName: $0.bsdName) }
        releaseDrivers()
        var seen = Set<UInt64>()
        for v in volumes {
            guard let entry = Self.resolveDriver(bsdName: v.bsdName) else {
                if !loggedResolveFailure {
                    loggedResolveFailure = true
                    Self.log.info("no IOBlockStorageDriver for \(v.bsdName, privacy: .public) — throughput reads 0")
                }
                continue
            }
            // Sibling volumes on one physical disk share a driver; counting it twice
            // would double every byte.
            var id: UInt64 = 0
            if IORegistryEntryGetRegistryEntryID(entry, &id) == KERN_SUCCESS, !seen.insert(id).inserted {
                IOObjectRelease(entry)
                continue
            }
            drivers.append(entry)
        }
    }

    func counters() -> (read: UInt64, write: UInt64) {
        var r: UInt64 = 0, w: UInt64 = 0
        for d in drivers {
            // One single-key property copy per physical disk per tick — no full
            // property-dict bridge, no fresh service match.
            guard let stats = IORegistryEntryCreateCFProperty(d, "Statistics" as CFString,
                                                              kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any] else { continue }
            r &+= (stats["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
            w &+= (stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
        }
        return (r, w)
    }

    private func releaseDrivers() {
        for d in drivers { IOObjectRelease(d) }
        drivers = []
    }

    /// Mounted volumes worth showing: the boot volume first, then anything under
    /// `/Volumes`. `.skipHiddenVolumes` already drops the system firmlinks and
    /// cryptexes; the path filter drops simulator/nix images mounted elsewhere.
    static func enumerateVolumes() -> [DiskVolume] {
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: resourceKeys,
                                                         options: [.skipHiddenVolumes]) ?? []
        var out: [DiskVolume] = []
        for url in urls {
            let path = url.path
            guard path == "/" || path.hasPrefix("/Volumes/") else { continue }
            guard let fs = statfsInfo(path) else { continue }
            let rv = try? url.resourceValues(forKeys: Set(resourceKeys))
            let total = (rv?.volumeTotalCapacity).map { UInt64(max(0, $0)) } ?? fs.total
            guard total > 0 else { continue }
            let free = (rv?.volumeAvailableCapacityForImportantUsage).map { UInt64(max(0, $0)) } ?? fs.free
            let v = DiskVolume(name: rv?.volumeName ?? url.lastPathComponent,
                               mountPath: path, bsdName: fs.bsdName, fileSystem: fs.type,
                               total: total, free: free,
                               isInternal: rv?.volumeIsInternal ?? true,
                               isRemovable: rv?.volumeIsRemovable ?? false)
            // Boot volume leads; the popover and the menu-bar percent both read `first`.
            if path == "/" { out.insert(v, at: 0) } else { out.append(v) }
        }
        return out
    }

    /// BSD device name, filesystem type and a capacity fallback for a mount point.
    private static func statfsInfo(_ path: String) -> (bsdName: String, type: String, total: UInt64, free: UInt64)? {
        var st = statfs()
        guard statfs(path, &st) == 0 else { return nil }
        // The two `char[]` fields arrive as fixed-size tuples. Generic, NOT `Any`:
        // an existential would box the 1 KB tuple and we'd read the box, not the chars.
        func str<T>(_ tuple: T) -> String {
            withUnsafeBytes(of: tuple) { raw in
                String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
            }
        }
        let dev = str(st.f_mntfromname)
        let bsd = dev.hasPrefix("/dev/") ? String(dev.dropFirst(5)) : dev
        let block = UInt64(st.f_bsize)
        return (bsd, str(st.f_fstypename), UInt64(st.f_blocks) * block, UInt64(st.f_bfree) * block)
    }

    /// Climb the service plane from the volume's `IOMedia` node until something
    /// conforms to `IOBlockStorageDriver`. On APFS the chain is long — a snapshot
    /// BSD name walks `disk3s3s1 → IOMedia(disk3) → … → IOMedia(disk0) → driver` —
    /// so the cap is depth, not a guess at how many hops the name implies.
    /// Returns a RETAINED entry the caller must release, or nil.
    static func resolveDriver(bsdName: String, maxDepth: Int = 12) -> io_object_t? {
        guard !bsdName.isEmpty,
              let matching = IOBSDNameMatching(kIOMainPortDefault, 0, bsdName) else { return nil }
        // IOServiceGetMatchingService consumes the matching dictionary reference.
        var current = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard current != IO_OBJECT_NULL else { return nil }
        for _ in 0..<maxDepth {
            if IOObjectConformsTo(current, "IOBlockStorageDriver") != 0 { return current }
            var parent: io_registry_entry_t = IO_OBJECT_NULL
            let kr = IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent)
            IOObjectRelease(current)
            guard kr == KERN_SUCCESS, parent != IO_OBJECT_NULL else { return nil }
            current = parent
        }
        IOObjectRelease(current)
        return nil
    }
}
