// Temperature sensors via the private IOHIDEventSystem API.
//
// No public temperature API exists on Apple Silicon (SMC temp keys are sparse
// and unlabeled). exelban/stats and every Mac monitor use this same private
// path: match HID services on page 0xff00 / usage 0x05, pull a Temperature
// event, read its float. Resolved by dlsym from the IOKit framework so the app
// links no private symbol at build time.
//
// Validated on M4 Pro (spike): 6 symbols resolve, 77 temp services, die temps
// 36–38°C. Prosper is NOT sandboxed, so the client creates successfully.
//
// CRITICAL: the @convention(c) signatures below are load-bearing — a wrong one
// segfaults at call time, not link time. Keep them exact.

import Foundation
import CoreFoundation

public struct TempSensor: Sendable, Equatable {
    public let name: String
    public let celsius: Double
}

public final class IOHIDSensors {
    private typealias CreateT   = @convention(c) (CFAllocator?) -> Unmanaged<AnyObject>?
    private typealias SetMatchT = @convention(c) (AnyObject?, CFDictionary?) -> Void
    private typealias CopySvcT  = @convention(c) (AnyObject?) -> Unmanaged<CFArray>?
    private typealias CopyEvtT  = @convention(c) (AnyObject?, Int64, Int32, Int64) -> Unmanaged<AnyObject>?
    private typealias GetFloatT = @convention(c) (AnyObject?, Int64) -> Double
    private typealias CopyPropT = @convention(c) (AnyObject?, CFString?) -> Unmanaged<AnyObject>?

    private static let kTemperature: Int32 = 15   // kIOHIDEventTypeTemperature

    private let client: AnyObject
    private let copySvc: CopySvcT
    private let copyEvt: CopyEvtT
    private let getFloat: GetFloatT
    private let copyProp: CopyPropT
    private var services: [AnyObject] = []

    public init?() {
        guard let h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW) else { return nil }
        func sym(_ n: String) -> UnsafeMutableRawPointer? { dlsym(h, n) }
        guard let pCreate = sym("IOHIDEventSystemClientCreate"),
              let pSetM   = sym("IOHIDEventSystemClientSetMatching"),
              let pCopyS  = sym("IOHIDEventSystemClientCopyServices"),
              let pCopyE  = sym("IOHIDServiceClientCopyEvent"),
              let pGetF   = sym("IOHIDEventGetFloatValue"),
              let pCopyP  = sym("IOHIDServiceClientCopyProperty")
        else { return nil }

        let create  = unsafeBitCast(pCreate, to: CreateT.self)
        let setM    = unsafeBitCast(pSetM, to: SetMatchT.self)
        self.copySvc  = unsafeBitCast(pCopyS, to: CopySvcT.self)
        self.copyEvt  = unsafeBitCast(pCopyE, to: CopyEvtT.self)
        self.getFloat = unsafeBitCast(pGetF, to: GetFloatT.self)
        self.copyProp = unsafeBitCast(pCopyP, to: CopyPropT.self)

        guard let cli = create(kCFAllocatorDefault)?.takeRetainedValue() else { return nil }
        self.client = cli
        // page 0xff00 / usage 0x05 = temperature sensors
        let match: [String: Any] = ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 0x05]
        setM(cli, match as CFDictionary)
        refreshServices()
    }

    /// Service list is stable for a boot; cache it and refresh only if empty.
    private func refreshServices() {
        services = (copySvc(client)?.takeRetainedValue() as? [AnyObject]) ?? []
    }

    /// Snapshot all readable temperature sensors (named, > 0 °C).
    public func read() -> [TempSensor] {
        if services.isEmpty { refreshServices() }
        var out = [TempSensor]()
        out.reserveCapacity(services.count)
        for s in services {
            guard let ev = copyEvt(s, Int64(Self.kTemperature), 0, 0)?.takeRetainedValue() else { continue }
            let v = getFloat(ev, Int64(Self.kTemperature) << 16)
            guard v > 0, v < 150 else { continue }   // reject bogus/unpopulated
            let name = (copyProp(s, "Product" as CFString)?.takeRetainedValue() as? String) ?? "Sensor"
            out.append(TempSensor(name: name, celsius: v))
        }
        return out
    }
}
