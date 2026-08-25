// NVMe SMART health for the boot disk: wear level, temperature, lifetime writes.
//
// No public API exposes NVMe SMART. The path is the IOKit CFPlugIn dance:
// `IOCreatePlugInInterfaceForService(device, kIONVMeSMARTUserClientTypeID, …)`
// → `QueryInterface(kIONVMeSMARTInterfaceID)` → `SMARTReadData(&buffer)`, which
// fills the 512-byte NVMe "SMART / Health Information" log page (NVMe 1.4 §5.14.1.2).
//
// NVMe only. ATA SMART is exelban's own default-off path and no Apple Silicon
// internal needs it.
//
// CRITICAL: the `@convention(c)` signatures below are load-bearing — a wrong one
// faults at call time, not link time (same warning `IOHIDSensors.swift:12` carries).
// The log page is read into a raw 512-byte buffer and decoded by documented byte
// offset rather than a hand-tupled Swift struct: `SMARTReadData` only ever sees a
// pointer, so the ABI is identical, and the decode becomes pure and unit-testable.
//
// ── Attribution ────────────────────────────────────────────────────────────────
// The two CFUUID literals and the `IONVMeSMARTInterface` layout below are lifted
// close to verbatim from exelban/stats (`Modules/Disk/readers.swift`,
// `Modules/Disk/header.h`).
//
// MIT License
//
// Copyright (c) 2019 Serhiy Mytrovtsiy
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.
// ───────────────────────────────────────────────────────────────────────────────

import Foundation
import IOKit
import IOKit.storage
import os

/// Decoded NVMe SMART / Health Information log page. Popover-only.
public struct DiskSMART: Sendable, Equatable {
    /// 100 − `percent_used`. Clamped to 0…100: the spec lets `percent_used`
    /// exceed 100 once the drive is past its rated endurance.
    public let healthPercent: Int
    /// Composite temperature. `nil` when the drive reports 0 K (field unsupported).
    public let celsius: Double?
    /// Lifetime bytes, `data_units_read/written × 512 000` (NVMe unit = 1000 × 512 B).
    public let totalRead: UInt64
    public let totalWritten: UInt64
    public let powerCycles: UInt32
    public let powerOnHours: UInt32
    public let unsafeShutdowns: UInt32
    public let mediaErrors: UInt32

    public init(healthPercent: Int, celsius: Double?, totalRead: UInt64, totalWritten: UInt64,
                powerCycles: UInt32, powerOnHours: UInt32, unsafeShutdowns: UInt32,
                mediaErrors: UInt32) {
        self.healthPercent = healthPercent; self.celsius = celsius
        self.totalRead = totalRead; self.totalWritten = totalWritten
        self.powerCycles = powerCycles; self.powerOnHours = powerOnHours
        self.unsafeShutdowns = unsafeShutdowns; self.mediaErrors = mediaErrors
    }
}

// MARK: - Log page decode (pure)

extension DiskSMART {
    /// Byte size of the SMART / Health Information log page.
    static let logPageSize = 512

    /// `nvme_smart_log`, by offset. Every field is little-endian (NVMe 1.4 §5.14.1.2);
    /// the 128-bit counters are read as their low 64 bits, which no consumer drive
    /// will overflow (2^64 data units ≈ 9 ZB).
    ///
    ///     0     critical_warning      u8
    ///     1     temperature           u16   composite, kelvin
    ///     3     avail_spare           u8
    ///     4     spare_thresh          u8
    ///     5     percent_used          u8
    ///     6     rsvd6                 [26]
    ///     32    data_units_read       u128
    ///     48    data_units_written    u128
    ///     64    host_reads            u128
    ///     80    host_writes           u128
    ///     96    ctrl_busy_time        u128
    ///     112   power_cycles          u128
    ///     128   power_on_hours        u128
    ///     144   unsafe_shutdowns      u128
    ///     160   media_errors          u128
    ///     176   num_err_log_entries   u128
    ///     …     (thermal counters, reserved to 512)
    ///
    /// Returns nil if the buffer is short — a truncated page would decode as garbage.
    public static func decode(logPage p: [UInt8]) -> DiskSMART? {
        guard p.count >= logPageSize else { return nil }
        func u16(_ o: Int) -> UInt16 { UInt16(p[o]) | UInt16(p[o + 1]) << 8 }
        func u32(_ o: Int) -> UInt32 {
            (0..<4).reduce(UInt32(0)) { $0 | UInt32(p[o + $1]) << (8 * UInt32($1)) }
        }
        func u64(_ o: Int) -> UInt64 {
            (0..<8).reduce(UInt64(0)) { $0 | UInt64(p[o + $1]) << (8 * UInt64($1)) }
        }

        let kelvin = u16(1)
        let bytesPerDataUnit: UInt64 = 512_000
        // Multiply saturating: a corrupt 2^63 data-unit count must not trap.
        func bytes(_ units: UInt64) -> UInt64 {
            units.multipliedReportingOverflow(by: bytesPerDataUnit).overflow
                ? UInt64.max : units * bytesPerDataUnit
        }

        return DiskSMART(
            healthPercent: max(0, 100 - Int(p[5])),
            celsius: kelvin == 0 ? nil : Double(Int(kelvin) - 273),
            totalRead: bytes(u64(32)),
            totalWritten: bytes(u64(48)),
            powerCycles: u32(112),
            powerOnHours: u32(128),
            unsafeShutdowns: u32(144),
            mediaErrors: u32(160)
        )
    }
}

// MARK: - The machine

/// `IUNKNOWN_C_GUTS` + the one NVMe entry point we call. Layout must match
/// `IONVMeSMARTInterface` in exelban/stats' `Modules/Disk/header.h` exactly.
private struct IONVMeSMARTInterface {
    var _reserved: UnsafeMutableRawPointer?
    var QueryInterface: (@convention(c) (UnsafeMutableRawPointer?, CFUUIDBytes,
                                         UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> HRESULT)?
    var AddRef: (@convention(c) (UnsafeMutableRawPointer?) -> ULONG)?
    var Release: (@convention(c) (UnsafeMutableRawPointer?) -> ULONG)?
    var version: UInt16
    var revision: UInt16
    /// `IOReturn (*SMARTReadData)(void *interface, struct nvme_smart_log *)`
    var SMARTReadData: (@convention(c) (UnsafeMutableRawPointer?,
                                        UnsafeMutableRawPointer?) -> IOReturn)?
}

public enum NVMeSMART {
    private static let log = Logger(subsystem: "com.prosper.stats", category: "disk")

    private static var userClientTypeID: CFUUID? { CFUUIDGetConstantUUIDWithBytes(nil,
        0xAA, 0x0F, 0xA6, 0xF9,
        0xC2, 0xD6, 0x45, 0x7F,
        0xB1, 0x0B, 0x59, 0xA1,
        0x32, 0x53, 0x29, 0x2F
    ) }
    private static var interfaceID: CFUUID? { CFUUIDGetConstantUUIDWithBytes(nil,
        0xCC, 0xD1, 0xDB, 0x19,
        0xFD, 0x9A, 0x4D, 0xAF,
        0xBF, 0x95, 0x12, 0x45,
        0x4B, 0x23, 0x0A, 0xB6
    ) }
    private static var plugInInterfaceID: CFUUID? { CFUUIDGetConstantUUIDWithBytes(nil,
        0xC2, 0x44, 0xE8, 0x58,
        0x10, 0x9C, 0x11, 0xD4,
        0x91, 0xD4, 0x00, 0x50,
        0xE4, 0xC6, 0x42, 0x6F
    ) }

    /// SMART for the physical device backing `bsdName` (e.g. "disk3s3s1"). nil on
    /// anything that isn't an NVMe drive advertising `"NVMe SMART Capable"`.
    public static func read(bsdName: String) -> DiskSMART? {
        guard let device = blockStorageDevice(bsdName: bsdName) else { return nil }
        defer { IOObjectRelease(device) }
        guard let raw = IORegistryEntryCreateCFProperty(device, "NVMe SMART Capable" as CFString,
                                                        kCFAllocatorDefault, 0),
              let capable = raw.takeRetainedValue() as? Bool, capable else { return nil }
        return readData(device: device)
    }

    /// Climb the service plane from the volume's `IOMedia` node to the
    /// `IOBlockStorageDevice` that owns it — the node the SMART user client
    /// attaches to. Depth-capped like `IOKitDiskSource.resolveDriver`.
    private static func blockStorageDevice(bsdName: String, maxDepth: Int = 12) -> io_object_t? {
        guard !bsdName.isEmpty,
              let matching = IOBSDNameMatching(kIOMainPortDefault, 0, bsdName) else { return nil }
        var node = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard node != IO_OBJECT_NULL else { return nil }
        for _ in 0..<maxDepth {
            if IOObjectConformsTo(node, kIOBlockStorageDeviceClass) != 0 { return node }
            var parent: io_registry_entry_t = IO_OBJECT_NULL
            guard IORegistryEntryGetParentEntry(node, kIOServicePlane, &parent) == KERN_SUCCESS,
                  parent != IO_OBJECT_NULL else { break }
            IOObjectRelease(node)
            node = parent
        }
        IOObjectRelease(node)
        return nil
    }

    private static func readData(device: io_object_t) -> DiskSMART? {
        var plugIn: UnsafeMutablePointer<UnsafeMutablePointer<IOCFPlugInInterface>?>?
        var score: Int32 = 0
        guard IOCreatePlugInInterfaceForService(device, userClientTypeID, plugInInterfaceID,
                                                &plugIn, &score) == kIOReturnSuccess,
              let plugIn else { return nil }
        defer { IODestroyPlugInInterface(plugIn) }

        var smart: UnsafeMutablePointer<UnsafeMutablePointer<IONVMeSMARTInterface>?>?
        let queried = withUnsafeMutablePointer(to: &smart) {
            $0.withMemoryRebound(to: UnsafeMutableRawPointer?.self, capacity: 1) {
                plugIn.pointee?.pointee.QueryInterface(plugIn, CFUUIDGetUUIDBytes(interfaceID), $0)
                    ?? KERN_NOT_FOUND
            }
        }
        guard queried == S_OK, let iface = smart?.pointee else { return nil }
        defer { _ = iface.pointee.Release?(smart) }

        // Raw buffer, not a hand-tupled struct: SMARTReadData writes 512 bytes
        // through a pointer either way, and this keeps the layout in the decoder
        // where it can be tested.
        var page = [UInt8](repeating: 0, count: DiskSMART.logPageSize)
        let ok = page.withUnsafeMutableBytes { buf in
            iface.pointee.SMARTReadData?(smart, buf.baseAddress) ?? KERN_NOT_FOUND
        }
        guard ok == kIOReturnSuccess else {
            log.info("NVMe SMARTReadData failed: \(ok, privacy: .public)")
            return nil
        }
        return DiskSMART.decode(logPage: page)
    }
}
