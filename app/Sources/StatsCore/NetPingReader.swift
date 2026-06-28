// Latency / jitter / reachability via unprivileged ICMP echo.
//
// macOS lets a process open SOCK_DGRAM/IPPROTO_ICMP without root (the same path
// the `ping` tool and Apple's SimplePing use), so we can measure round-trip time
// to a public anycast resolver with no entitlement. Pinging blocks up to the
// timeout, so this runs on its OWN background thread and the poller only ever
// reads the cached latest value + a reachability history ring — the poll queue
// never blocks.

import Foundation
import Darwin

public struct NetLatency: Sendable, Equatable {
    public let latencyMs: Double    // NaN if the last ping failed
    public let jitterMs: Double     // mean abs successive RTT diff; NaN if <2 samples
    public let reachable: Bool
    public init(latencyMs: Double, jitterMs: Double, reachable: Bool) {
        self.latencyMs = latencyMs; self.jitterMs = jitterMs; self.reachable = reachable
    }
}

public final class NetPingReader {
    private let host: String
    private let lock = NSLock()
    private var _latency = NetLatency(latencyMs: .nan, jitterMs: .nan, reachable: false)
    private var rtts: [Double] = []      // recent RTTs (ms) for the jitter window
    private var reach: [Bool] = []       // connectivity history (oldest→newest)
    private let reachCap: Int
    private var thread: Thread?
    private var running = false

    public init(host: String = "1.1.1.1", historyLength: Int = 120) {
        self.host = host; self.reachCap = historyLength
    }

    public func start() {
        guard thread == nil else { return }
        running = true
        let t = Thread { [weak self] in self?.loop() }
        t.stackSize = 256 * 1024
        t.qualityOfService = .background
        thread = t
        t.start()
    }

    public func stop() { running = false; thread = nil }

    public func latest() -> NetLatency { lock.withLock { _latency } }
    public func connectivity() -> [Bool] { lock.withLock { reach } }

    private func loop() {
        var seq: UInt16 = 0
        while running {
            let rtt = Self.ping(host: host, seq: seq, timeout: 1.0)
            seq &+= 1
            lock.withLock {
                let ok = rtt != nil
                reach.append(ok)
                if reach.count > reachCap { reach.removeFirst(reach.count - reachCap) }
                if let r = rtt {
                    rtts.append(r)
                    if rtts.count > 20 { rtts.removeFirst(rtts.count - 20) }
                }
                var jitter = Double.nan
                if rtts.count >= 2 {
                    var s = 0.0
                    for i in 1..<rtts.count { s += abs(rtts[i] - rtts[i - 1]) }
                    jitter = s / Double(rtts.count - 1)
                }
                _latency = NetLatency(latencyMs: rtt ?? .nan, jitterMs: jitter, reachable: ok)
            }
            Thread.sleep(forTimeInterval: 1.0)   // ~1 s between pings (plus the timeout above)
        }
    }

    /// One ICMP echo round-trip in milliseconds, or nil on timeout/error.
    static func ping(host: String, seq: UInt16, timeout: Double) -> Double? {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr(host)
        guard addr.sin_addr.s_addr != INADDR_NONE else { return nil }

        // ICMP echo request: type(8) code(0) checksum id seq + 8-byte payload.
        var packet = [UInt8](repeating: 0, count: 16)
        packet[0] = 8
        let id = UInt16(truncatingIfNeeded: getpid())
        packet[4] = UInt8(id >> 8); packet[5] = UInt8(id & 0xff)
        packet[6] = UInt8(seq >> 8); packet[7] = UInt8(seq & 0xff)
        let csum = checksum(packet)
        packet[2] = UInt8(csum >> 8); packet[3] = UInt8(csum & 0xff)

        let start = NetworkReader.monotonicSeconds()
        let sent = packet.withUnsafeBytes { buf in
            withUnsafePointer(to: &addr) { ap in
                ap.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    sendto(fd, buf.baseAddress, buf.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard sent > 0 else { return nil }

        var recvBuf = [UInt8](repeating: 0, count: 128)
        let n = recv(fd, &recvBuf, recvBuf.count, 0)
        guard n > 0 else { return nil }   // timeout → recv returns -1 (EAGAIN)
        return (NetworkReader.monotonicSeconds() - start) * 1000
    }

    /// Internet checksum (RFC 1071). The kernel recomputes it for DGRAM sockets,
    /// but a correct one keeps the packet valid on any path.
    static func checksum(_ data: [UInt8]) -> UInt16 {
        var sum: UInt32 = 0
        var i = 0
        while i + 1 < data.count { sum += UInt32(data[i]) << 8 | UInt32(data[i + 1]); i += 2 }
        if i < data.count { sum += UInt32(data[i]) << 8 }
        while sum >> 16 != 0 { sum = (sum & 0xffff) + (sum >> 16) }
        return UInt16(truncatingIfNeeded: ~sum)
    }
}
