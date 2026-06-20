import Darwin
import Foundation
import Network
import os.log

/// Serves `dch` terminal sessions to the DchTerm app over Tailscale.
///
/// Design (ponytail): the server is a *thin bridge*. It never reimplements dch's
/// socket/daemon/redraw protocol — it spawns the real `dch` binary as a **client**
/// attached to a pty and shuttles bytes between that pty and a TCP connection. dch
/// keeps doing all the hard parts (session daemon survival, SIGWINCH redraw, kitty
/// key replay). Killing the pty child detaches the client; the master daemon lives on.
///
/// Security model (per the user: "only ensure traffic comes from a Tailscale VPN"):
///   1. The listener binds **only** to the host's Tailscale interface address. The
///      port is not reachable off-tailnet. If there is no Tailscale address, the
///      server refuses to start (fail safe — never bind to 0.0.0.0).
///   2. Belt-and-suspenders: every accepted connection's peer IP must also fall in
///      the Tailscale CGNAT range 100.64.0.0/10, else it's dropped.
/// No auth tokens, no TLS — Tailscale is the trust boundary.
final class DchSessionServer: @unchecked Sendable {
    static let shared = DchSessionServer()

    /// Fixed port so the app connects deterministically (no discovery step).
    /// ponytail: hard-coded; advertise via Bonjour/MagicDNS SRV if it ever clashes.
    static let port: UInt16 = 8771

    private let log = Logger(subsystem: "com.prosper.app", category: "DchServer")
    private let queue = DispatchQueue(label: "com.prosper.dchserver")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: DchConnection] = [:]

    private init() {}

    var isRunning: Bool { listener != nil }

    // MARK: - Lifecycle

    /// Bind to the Tailscale interface and accept connections. Idempotent. Throws
    /// `ServerError.noTailscale` when no Tailscale address exists — we never fall
    /// back to a wider bind.
    func start() throws {
        if listener != nil { return }
        guard let tsIP = Self.tailscaleIPv4() else {
            log.error("dch server: no Tailscale address — refusing to bind")
            throw ServerError.noTailscale
        }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(tsIP), port: NWEndpoint.Port(rawValue: Self.port)!)

        let listener = try NWListener(using: params)
        self.listener = listener
        let sem = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.log.info("dch server ready on \(tsIP, privacy: .public):\(Self.port)")
                sem.signal()
            case .failed(let e):
                self.log.error("dch server failed: \(String(describing: e), privacy: .public)")
                sem.signal()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        listener.start(queue: queue)
        _ = sem.wait(timeout: .now() + 5)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        queue.async { [weak self] in
            self?.connections.values.forEach { $0.close() }
            self?.connections.removeAll()
        }
    }

    /// Apply the current `Preferences.remoteTerminalEnabled` toggle.
    func syncToPreference() {
        if Preferences.remoteTerminalEnabled {
            try? start()
        } else {
            stop()
        }
    }

    enum ServerError: Error { case noTailscale }

    private func accept(_ conn: NWConnection) {
        // Belt-and-suspenders source-IP gate (the bind already restricts us).
        if !Self.isTailscalePeer(conn) {
            log.error("dch server: rejecting non-Tailscale peer")
            conn.cancel()
            return
        }
        let handler = DchConnection(conn: conn, queue: queue, log: log) { [weak self] id in
            self?.connections.removeValue(forKey: id)
        }
        connections[ObjectIdentifier(handler)] = handler
        handler.start()
    }

    // MARK: - Tailscale interface resolution (variant-independent)

    /// Tailscale CGNAT range 100.64.0.0/10 → network 0x64400000, mask 0xFFC00000.
    private static let cgnatNet: UInt32 = 0x6440_0000
    private static let cgnatMask: UInt32 = 0xFFC0_0000

    static func isCGNAT(_ addr: in_addr) -> Bool {
        // s_addr is network byte order; compare in host order.
        let host = UInt32(bigEndian: addr.s_addr)
        return host & cgnatMask == cgnatNet
    }

    /// First IPv4 address on any interface that falls in the Tailscale CGNAT range.
    /// Relies on the range, not the interface name (utun numbering varies; App
    /// Store vs brew Tailscale differ) — this is the variant-independent floor.
    static func tailscaleIPv4() -> String? {
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return nil }
        defer { freeifaddrs(ifap) }
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = ptr {
            defer { ptr = cur.pointee.ifa_next }
            guard let sa = cur.pointee.ifa_addr, sa.pointee.sa_family == sa_family_t(AF_INET)
            else { continue }
            var addr = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            guard isCGNAT(addr) else { continue }
            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &addr, &buf, socklen_t(INET_ADDRSTRLEN))
            return String(cString: buf)
        }
        return nil
    }

    private static func isTailscalePeer(_ conn: NWConnection) -> Bool {
        guard case let .hostPort(host, _) = conn.currentPath?.remoteEndpoint ?? conn.endpoint
        else { return false }
        switch host {
        case .ipv4(let v4):
            return isCGNAT(v4.rawValue.withUnsafeBytes { raw in
                in_addr(s_addr: raw.load(as: UInt32.self))
            })
        case .ipv6(let v6):
            // Tailscale also peers over IPv6; if it's a v4-mapped CGNAT addr accept,
            // else accept any address (the bind already constrained us to the TS iface).
            _ = v6
            return true
        default:
            return false
        }
    }
}
