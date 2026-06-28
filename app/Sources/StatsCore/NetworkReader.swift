// Network throughput via `getifaddrs` AF_LINK byte counters.
//
// Sums in/out bytes across all non-loopback link interfaces, then rates the
// delta over elapsed monotonic time. First read seeds the baseline (0 rate).
// Counters are 32-bit and wrap (~4 GB); wrap-safe `&-` subtraction tolerates
// the occasional glitch sample — exelban/stats accepts the same tradeoff.

import Foundation
import Darwin
import SystemConfiguration
import CoreWLAN

public struct NetworkReader: StatsReader {
    private var prevIn: UInt32 = 0
    private var prevOut: UInt32 = 0
    private var prevTime: Double = 0
    private var seeded = false
    private var cumIn: UInt64 = 0
    private var cumOut: UInt64 = 0
    private let now: () -> Double
    // Held once, not rebuilt each tick: the dynamic-store session and the CoreWLAN
    // client are designed to persist. Link identity (interface/IP/SSID) is resolved
    // on a coarse cadence — it changes on the order of seconds-to-never, not 1 Hz.
    private let scStore: SCDynamicStore?
    private let wifi = CWWiFiClient.shared()
    private var link: (name: String?, ipv4: String?, ssid: String?) = (nil, nil, nil)
    private var linkTick = 0

    public init(now: @escaping () -> Double = NetworkReader.monotonicSeconds) {
        self.now = now
        self.scStore = SCDynamicStoreCreate(nil, "prosper.net" as CFString, nil, nil)
    }

    public static func monotonicSeconds() -> Double {
        var ts = timespec()
        clock_gettime(CLOCK_MONOTONIC, &ts)
        return Double(ts.tv_sec) + Double(ts.tv_nsec) / 1_000_000_000
    }

    public mutating func read() throws -> NetworkSample {
        let (inB, outB) = Self.totals()
        let t = now()

        guard seeded else {
            prevIn = inB; prevOut = outB; prevTime = t; seeded = true
            return NetworkSample(uploadBytesPerSec: 0, downloadBytesPerSec: 0,
                                 totalUploaded: 0, totalDownloaded: 0)
        }
        let dt = max(t - prevTime, 0.0001)
        var dIn = UInt64(inB &- prevIn)     // wrap-safe
        var dOut = UInt64(outB &- prevOut)
        prevIn = inB; prevOut = outB; prevTime = t
        // A 32-bit counter reset (iface down/up, not a true ~4 GB wrap) shows as a
        // near-2^32 delta and `&-` can't tell it from real traffic. Gate on a sane
        // ceiling — 25 GB/s is above any Mac NIC/Thunderbolt link — and drop the
        // glitch so it poisons neither the rate nor the cumulative totals.
        let maxBytes = UInt64(25_000_000_000 * dt)
        if dIn > maxBytes { dIn = 0 }
        if dOut > maxBytes { dOut = 0 }
        cumIn += dIn; cumOut += dOut

        if linkTick % 10 == 0 { link = primaryLink() }   // ~10 s; identity rarely changes
        linkTick += 1
        return NetworkSample(
            uploadBytesPerSec: Double(dOut) / dt,
            downloadBytesPerSec: Double(dIn) / dt,
            totalUploaded: cumOut,
            totalDownloaded: cumIn,
            interfaceName: link.name, ipv4: link.ipv4, ssid: link.ssid)
    }

    /// The default-route interface plus its IPv4 and (if Wi-Fi) SSID. All nil-able:
    /// SSID needs Location authorization on recent macOS and is simply omitted when
    /// unavailable. Uses the held store/client — see the cadence note in read().
    func primaryLink() -> (name: String?, ipv4: String?, ssid: String?) {
        guard let store = scStore,
              let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
              let name = global["PrimaryInterface"] as? String
        else { return (nil, nil, nil) }
        let ssid = wifi.interface(withName: name)?.ssid()
        return (name, Self.ipv4(for: name), ssid)
    }

    /// First AF_INET address bound to `iface`.
    private static func ipv4(for iface: String) -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = ptr {
            defer { ptr = cur.pointee.ifa_next }
            guard let addr = cur.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET),
                  String(cString: cur.pointee.ifa_name) == iface else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count),
                           nil, 0, NI_NUMERICHOST) == 0 {
                return String(cString: host)
            }
        }
        return nil
    }

    /// Aggregate (in, out) bytes across non-loopback link-layer interfaces.
    static func totals() -> (UInt32, UInt32) {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return (0, 0) }
        defer { freeifaddrs(ifaddr) }

        var inSum: UInt32 = 0, outSum: UInt32 = 0
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = ptr {
            defer { ptr = cur.pointee.ifa_next }
            guard let addr = cur.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_LINK) else { continue }
            let name = String(cString: cur.pointee.ifa_name)
            if name.hasPrefix("lo") { continue }   // loopback
            guard let data = cur.pointee.ifa_data else { continue }
            let d = data.assumingMemoryBound(to: if_data.self).pointee
            inSum = inSum &+ d.ifi_ibytes
            outSum = outSum &+ d.ifi_obytes
        }
        return (inSum, outSum)
    }
}
