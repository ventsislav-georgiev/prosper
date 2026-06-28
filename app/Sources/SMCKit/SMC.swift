// SMCKit — System Management Controller read/write over IOKit.
//
// Shared by ProsperApp (read: fans/temps/power) and ProsperHelper (write:
// fan control, root-only). IOKit public API only — no private symbols.
//
// ABI validated on a real M4 Pro (macOS 26.5.1): FNum=2, F{i}Mn/Mx as `flt `,
// mode key `F0Md` uppercase, `Ftst` present (M1–M4 layered-unlock path).
// MUST use MemoryLayout.stride (not .size) for the struct call — a classic bug.
//
// Thread-safety: an `SMC` instance is NOT thread-safe; the firmware mailbox is
// a single shared resource. Callers serialize (StatsPoller uses one queue; the
// helper uses a dedicated fan queue). Reads check `output.result == 0` because
// IOKit can return success while the SMC firmware rejects the request.

import Foundation
import IOKit

// MARK: - Kernel ABI (byte-exact; field order is load-bearing)

struct SMCVersion {
    var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0, reserved: UInt8 = 0
    var release: UInt16 = 0
}
struct SMCPLimitData {
    var version: UInt16 = 0, length: UInt16 = 0
    var cpuPLimit: UInt32 = 0, gpuPLimit: UInt32 = 0, memPLimit: UInt32 = 0
}
struct SMCKeyInfoData {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
}
/// 32-byte payload region.
typealias SMCBytes32 = (
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
)
struct SMCParamStruct {
    var key: UInt32 = 0
    var vers = SMCVersion()
    var pLimitData = SMCPLimitData()
    var keyInfo = SMCKeyInfoData()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: SMCBytes32 = (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
}

private let kSMCKernelIndex: UInt32 = 2
private enum SMCCmd: UInt8 { case read = 5, write = 6, getKeyFromIndex = 8, getKeyInfo = 9 }

// MARK: - FourCC helpers

@inline(__always) func smcFourCC(_ s: String) -> UInt32 {
    var r: UInt32 = 0
    for b in s.utf8.prefix(4) { r = (r << 8) | UInt32(b) }
    return r
}
@inline(__always) func smcKeyString(_ v: UInt32) -> String {
    let cs: [UInt8] = [UInt8((v >> 24) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)]
    return String(bytes: cs, encoding: .ascii) ?? "????"
}

// MARK: - Errors

public enum SMCError: Error, Equatable {
    case notOpen
    case ioReturn(kern_return_t)
    case firmwareReject(UInt8)        // output.result != 0
    case keyNotFound(String)
    case writeNotAllowed(String)      // key not in whitelist
    case clampUnsafe(String)          // bounds unreadable/degenerate — fail closed
}

// MARK: - Decoded value

public struct SMCValue {
    public let key: String
    public let type: String           // 4-char type code, e.g. "flt ", "ui16"
    public let bytes: [UInt8]
    public let double: Double         // decoded scalar (NaN if undecodable)
}

// MARK: - SMC connection

public final class SMC {
    private var conn: io_connect_t = 0
    private var keyInfoCache: [UInt32: SMCKeyInfoData] = [:]

    public init() throws {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard svc != 0 else { throw SMCError.ioReturn(KERN_FAILURE) }
        defer { IOObjectRelease(svc) }
        let r = IOServiceOpen(svc, mach_task_self_, 0, &conn)
        guard r == kIOReturnSuccess else { throw SMCError.ioReturn(r) }
    }
    deinit { if conn != 0 { IOServiceClose(conn) } }

    private func callStruct(_ input: inout SMCParamStruct) throws -> SMCParamStruct {
        guard conn != 0 else { throw SMCError.notOpen }
        var output = SMCParamStruct()
        var outSize = MemoryLayout<SMCParamStruct>.stride           // stride, NOT size
        let r = withUnsafePointer(to: &input) { ip in
            IOConnectCallStructMethod(conn, kSMCKernelIndex, ip,
                                      MemoryLayout<SMCParamStruct>.stride, &output, &outSize)
        }
        guard r == kIOReturnSuccess else { throw SMCError.ioReturn(r) }
        guard output.result == 0 else { throw SMCError.firmwareReject(output.result) }
        return output
    }

    private func keyInfo(_ key: UInt32) throws -> SMCKeyInfoData {
        if let cached = keyInfoCache[key] { return cached }
        var input = SMCParamStruct()
        input.key = key
        input.data8 = SMCCmd.getKeyInfo.rawValue
        let out = try callStruct(&input)
        keyInfoCache[key] = out.keyInfo
        return out.keyInfo
    }

    /// Raw read: key bytes + type. Throws keyNotFound on firmware reject.
    public func readRaw(_ keyStr: String) throws -> (bytes: [UInt8], type: UInt32) {
        let key = smcFourCC(keyStr)
        let info: SMCKeyInfoData
        do { info = try keyInfo(key) }
        catch { throw SMCError.keyNotFound(keyStr) }
        var input = SMCParamStruct()
        input.key = key
        input.keyInfo = info
        input.data8 = SMCCmd.read.rawValue
        let out = try callStruct(&input)
        let n = Int(info.dataSize)
        let bytes = withUnsafeBytes(of: out.bytes) { Array($0.prefix(n)) }
        return (bytes, info.dataType)
    }

    /// Whether a key exists (getKeyInfo succeeds). Used for mode-key form probing.
    public func exists(_ keyStr: String) -> Bool {
        (try? keyInfo(smcFourCC(keyStr))) != nil
    }

    /// Decoded scalar read. Returns nil if the key is absent.
    public func read(_ keyStr: String) -> SMCValue? {
        guard let (bytes, type) = try? readRaw(keyStr) else { return nil }
        return SMCValue(key: keyStr, type: smcKeyString(type), bytes: bytes,
                        double: SMCDecode.scalar(bytes, type: type))
    }

    // MARK: Write (root-only; guarded — see SMCWrite.swift)

    /// Low-level write primitive. Internal: the ONLY sanctioned caller is
    /// `SMCFanController.guardedWrite`, which enforces the key whitelist AND
    /// re-clamps any RPM target to the absolute rails. This is the single
    /// chokepoint to IOConnect selector `write`.
    func writeRawUnchecked(_ keyStr: String, _ bytes: [UInt8]) throws {
        let key = smcFourCC(keyStr)
        let info = try keyInfo(key)
        var input = SMCParamStruct()
        input.key = key
        input.keyInfo = info
        input.data8 = SMCCmd.write.rawValue
        // Pack bytes into the 32-byte tuple region.
        withUnsafeMutableBytes(of: &input.bytes) { raw in
            for (i, b) in bytes.prefix(Int(info.dataSize)).enumerated() { raw[i] = b }
        }
        _ = try callStruct(&input)   // throws firmwareReject if result != 0
    }
}

// MARK: - Decoders (validated against M4 Pro: all fan/sensor values are `flt `)

public enum SMCDecode {
    /// Decode the common SMC scalar types to a Double. NaN if unknown.
    public static func scalar(_ b: [UInt8], type: UInt32) -> Double {
        switch smcKeyString(type) {
        case "flt ":                                   // little-endian IEEE-754 (no swap)
            guard b.count >= 4 else { return .nan }
            return Double(b.withUnsafeBytes { $0.loadUnaligned(as: Float.self) })
        case "ui8 ":  return b.count >= 1 ? Double(b[0]) : .nan
        case "ui16":  return b.count >= 2 ? Double(UInt16(b[0]) << 8 | UInt16(b[1])) : .nan
        case "ui32":  return b.count >= 4 ? Double(UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3])) : .nan
        case "si8 ":  return b.count >= 1 ? Double(Int8(bitPattern: b[0])) : .nan
        case "si16":  return b.count >= 2 ? Double(Int16(bitPattern: UInt16(b[0]) << 8 | UInt16(b[1]))) : .nan
        case "sp78":  return b.count >= 2 ? Double(Int16(bitPattern: UInt16(b[0]) << 8 | UInt16(b[1]))) / 256.0 : .nan
        case "fpe2":  return b.count >= 2 ? Double(UInt16(b[0]) << 6 | UInt16(b[1]) >> 2) : .nan
        case "fp1f":  return b.count >= 2 ? Double(UInt16(b[0]) << 8 | UInt16(b[1])) / 32768.0 : .nan
        case "fp4c":  return b.count >= 2 ? Double(UInt16(b[0]) << 8 | UInt16(b[1])) / 4096.0 : .nan
        case "fp5b":  return b.count >= 2 ? Double(UInt16(b[0]) << 8 | UInt16(b[1])) / 2048.0 : .nan
        case "fp6a":  return b.count >= 2 ? Double(UInt16(b[0]) << 8 | UInt16(b[1])) / 1024.0 : .nan
        case "fp79":  return b.count >= 2 ? Double(UInt16(b[0]) << 8 | UInt16(b[1])) / 512.0 : .nan
        case "fp88":  return b.count >= 2 ? Double(UInt16(b[0]) << 8 | UInt16(b[1])) / 256.0 : .nan
        default:
            // sp__ family: spXY → fractional bits = 16 - (hex Y nibble + ...). Fallback: big-endian /256.
            return b.count >= 2 ? Double(UInt16(b[0]) << 8 | UInt16(b[1])) / 256.0 : .nan
        }
    }

    /// Encode an RPM target as `flt ` (Apple Silicon fan target encoding, LE Float32).
    public static func encodeFloatLE(_ value: Float) -> [UInt8] {
        withUnsafeBytes(of: value) { Array($0) }     // little-endian on arm64/x86_64
    }
    /// Encode an RPM target as `fpe2` (Intel fan target encoding): 14.2 fixed
    /// point stored big-endian, i.e. (rpm << 2) as a UInt16. Inverse of the
    /// `fpe2` decoder above: `(b0 << 6) | (b1 >> 2)`.
    public static func encodeFPE2(_ rpm: Int) -> [UInt8] {
        // NOTE: fpe2 saturates at 0x3fff = 16383 rpm, BELOW SMCFanController's
        // absoluteCeilRPM (20000). Harmless — capping high is thermally safe and no
        // real Mac fan exceeds 16k — but the Intel encoder and the AS ceiling
        // disagree, so don't assume 20000 is reachable on Intel if bounds ever change.
        let v = UInt16(max(0, min(rpm, 0x3fff))) << 2
        return [UInt8(v >> 8), UInt8(v & 0xff)]
    }

    /// Inverse of `encodeFloatLE` — decode a `flt ` RPM target. NaN if short.
    public static func decodeFloatLE(_ b: [UInt8]) -> Float {
        guard b.count >= 4 else { return .nan }
        return b.withUnsafeBytes { $0.loadUnaligned(as: Float.self) }
    }
    /// Inverse of `encodeFPE2` — decode an `fpe2` RPM target.
    public static func decodeFPE2(_ b: [UInt8]) -> Int {
        guard b.count >= 2 else { return 0 }
        return Int(UInt16(b[0]) << 6 | UInt16(b[1]) >> 2)
    }
}
