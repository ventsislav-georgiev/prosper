// Link identity that the throughput reader doesn't carry: hardware (MAC) address,
// Wi-Fi signal strength, and the public IP + country.
//
// MAC and RSSI are cheap local lookups (getifaddrs / CoreWLAN). The public IP is
// a network round-trip, so it's fetched asynchronously at most every 5 minutes
// and served from cache — read() never blocks. The public-IP fetch is an outbound
// request to a third party (api.country.is); it only runs while a Network popup is
// driving reads, never in the background with the app idle.

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
    private let lock = NSLock()
    private var publicIP: String?
    private var country: String?
    private var lastFetch: Double = 0
    private var fetching = false

    public init() {}

    public func read(interface: String?) -> NetLinkInfo {
        maybeFetchPublicIP()
        let mac = interface.flatMap { Self.mac(for: $0) }
        var rssi: Int?
        if let interface, let i = wifi.interface(withName: interface), i.ssid() != nil {
            let v = i.rssiValue()
            rssi = v == 0 ? nil : v
        }
        return lock.withLock { NetLinkInfo(macAddress: mac, rssi: rssi, publicIP: publicIP, countryCode: country) }
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
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
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
