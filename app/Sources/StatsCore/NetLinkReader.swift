// Link identity that the throughput reader doesn't carry: hardware (MAC) address,
// Wi-Fi signal strength, and the public IP + country.
//
// MAC (getifaddrs) and RSSI (CoreWLAN) are local lookups, but CoreWLAN's RSSI can
// block on IPC to airportd for tens of ms — too long for the shared serial poll
// queue, where it would stall every other module's tick. So the whole read runs on
// a private queue, coalesced, and the poller reads a cached value (one tick of lag,
// never a stall). The public IP is a third-party round-trip (api.country.is), fetched
// at most every 5 minutes and only while a Network popup is driving refreshes — never
// in the background with the app idle.

import Foundation
import Darwin
import CoreWLAN

public struct NetLinkInfo: Sendable, Equatable {
    public let macAddress: String?
    public let rssi: Int?           // dBm, nil if not on Wi-Fi
    public let publicIP: String?
    public let countryCode: String? // ISO 3166-1 alpha-2
    public init(macAddress: String?, rssi: Int?, publicIP: String?, countryCode: String?) {
        self.macAddress = macAddress; self.rssi = rssi
        self.publicIP = publicIP; self.countryCode = countryCode
    }
}

public final class NetLinkReader {
    private let wifi = CWWiFiClient.shared()
    private let queue = DispatchQueue(label: "com.prosper.stats.netlink", qos: .utility)
    private let lock = NSLock()
    private var cached = NetLinkInfo(macAddress: nil, rssi: nil, publicIP: nil, countryCode: nil)
    private var refreshing = false
    private var publicIP: String?
    private var country: String?
    private var lastFetch: Double = 0
    private var fetching = false

    public init() {}

    /// Last computed link info — non-blocking, safe on the poll queue.
    public func latest() -> NetLinkInfo { lock.withLock { cached } }

    /// Recompute MAC + RSSI on a private queue (coalesced) and kick the public-IP
    /// fetch. Returns immediately; the result lands in `latest()` a tick later.
    public func refresh(interface: String?) {
        let go: Bool = lock.withLock { if refreshing { return false }; refreshing = true; return true }
        guard go else { return }
        queue.async { [weak self] in
            guard let self else { return }
            self.maybeFetchPublicIP()
            let mac = interface.flatMap { Self.mac(for: $0) }
            var rssi: Int?
            if let interface, let i = self.wifi.interface(withName: interface), i.ssid() != nil {
                let v = i.rssiValue()
                rssi = v == 0 ? nil : v
            }
            self.lock.withLock {
                self.cached = NetLinkInfo(macAddress: mac, rssi: rssi,
                                          publicIP: self.publicIP, countryCode: self.country)
                self.refreshing = false
            }
        }
    }

    private func maybeFetchPublicIP() {
        let now = NetworkReader.monotonicSeconds()
        let go: Bool = lock.withLock {
            guard !fetching, publicIP == nil || now - lastFetch > 300 else { return false }
            fetching = true; lastFetch = now
            return true
        }
        guard go, let url = URL(string: "https://api.country.is/") else {
            if go { lock.withLock { fetching = false } }
            return
        }
        // Short timeout so a captive portal / slow endpoint can't pin `fetching` for
        // URLSession's default 60 s.
        var req = URLRequest(url: url)
        req.timeoutInterval = 5
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let self else { return }
            defer { self.lock.withLock { self.fetching = false } }
            guard let data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            self.lock.withLock {
                self.publicIP = obj["ip"] as? String
                self.country = (obj["country"] as? String)?.uppercased()
            }
        }.resume()
    }

    /// The hardware MAC of `iface`, formatted aa:bb:cc:dd:ee:ff.
    static func mac(for iface: String) -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = ptr {
            defer { ptr = cur.pointee.ifa_next }
            guard let addr = cur.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_LINK),
                  String(cString: cur.pointee.ifa_name) == iface else { continue }
            let sdl = addr.withMemoryRebound(to: sockaddr_dl.self, capacity: 1) { $0.pointee }
            guard sdl.sdl_alen == 6 else { continue }
            let base = Int(sdl.sdl_nlen)   // MAC bytes follow the interface name in sdl_data
            var bytes = [UInt8](repeating: 0, count: 6)
            let ok = withUnsafeBytes(of: sdl.sdl_data) { raw -> Bool in
                guard base + 6 <= raw.count else { return false }
                for i in 0..<6 { bytes[i] = raw[base + i] }
                return true
            }
            guard ok else { return nil }
            return bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
        }
        return nil
    }
}
