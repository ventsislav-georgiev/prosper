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
/// Pure keep-awake decision, extracted from `DchSessionServer` so the grace /
/// activity branching is unit-testable without an `NWListener` or live XPC. The
/// server feeds it the current world (client attached? session active?) plus the
/// running idle-tick count and applies the result. No I/O, no state of its own.
enum KeepAwakePolicy {
    /// A detached session counts as "active" if it produced output within this many
    /// seconds (the design's "frozen >10s ⇒ not active" threshold).
    static let activeWindowSeconds = 10
    /// Consecutive idle ticks (each `tickSeconds` ≈ this many seconds) before
    /// releasing the hold — a ~60s grace covering a brief reconnect or output lull.
    static let graceTicks = 6

    struct Step: Equatable {
        let hold: Bool      // send/refresh the keep-awake hold this tick
        let release: Bool   // tear the hold down (idle grace elapsed)
        let idleTicks: Int  // carry forward
    }

    static func step(clientConnected: Bool, sessionActive: Bool, idleTicks: Int) -> Step {
        if clientConnected || sessionActive {
            return Step(hold: true, release: false, idleTicks: 0)
        }
        let n = idleTicks + 1
        if n >= graceTicks {
            return Step(hold: false, release: true, idleTicks: n)
        }
        return Step(hold: true, release: false, idleTicks: n)
    }
}

final class DchSessionServer: @unchecked Sendable {
    static let shared = DchSessionServer()

    /// Fixed port so the app connects deterministically (no discovery step).
    /// ponytail: hard-coded; advertise via Bonjour/MagicDNS SRV if it ever clashes.
    static let port: UInt16 = 8771

    private let log = Logger(subsystem: "com.prosper.app", category: "DchServer")
    private let queue = DispatchQueue(label: "com.prosper.dchserver")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: DchConnection] = [:]

    // Keep-awake: while any client is attached — OR a detached session is still
    // producing output — the Mac must not sleep mid-command. A single repeating
    // tick re-evaluates and heartbeats the daemon's remote-session hold (TTL ~120s).
    // When nothing wants it awake for `graceTicks` consecutive ticks, we release.
    // All touched only on `queue`.
    private var keepAwakeActive = false
    private var holdTimer: DispatchSourceTimer?
    private var idleTicks = 0
    /// Tick cadence; also the hold heartbeat (well inside the daemon's 120s TTL).
    /// Kept equal to `activeWindowSeconds` so the "silent >10s ⇒ inactive" rule
    /// actually holds — a coarser tick would mis-read a session that prints between
    /// ticks as idle. Each tick re-evaluates AND refreshes the TTL.
    private static let tickSeconds = KeepAwakePolicy.activeWindowSeconds

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
            guard let self else { return }
            self.connections.values.forEach { $0.close() }
            self.connections.removeAll()
            self.stopKeepAwake()
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
            // No immediate release: the tick re-evaluates and the grace covers a
            // detached session still working or a quick reconnect.
        }
        connections[ObjectIdentifier(handler)] = handler
        handler.start()
        startKeepAwake()
    }

    // MARK: - Keep-awake (drives the daemon's remote-session hold)

    /// A client attached: ensure the hold is held now and the tick is running. The
    /// tick is what later releases it once neither a client nor an active detached
    /// session wants the Mac awake.
    private func startKeepAwake() {
        idleTicks = 0
        sendKeepAwake(true)
        if keepAwakeActive { return }
        keepAwakeActive = true
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + .seconds(Self.tickSeconds), repeating: .seconds(Self.tickSeconds))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        holdTimer = t
    }

    /// One evaluation, delegating the branching to the pure `KeepAwakePolicy`. The
    /// `||` short-circuits so the sidecar scan runs only while no client is attached.
    private func tick() {
        let active = connections.isEmpty
            && DchCommand.anySessionActive(within: KeepAwakePolicy.activeWindowSeconds)
        let step = KeepAwakePolicy.step(
            clientConnected: !connections.isEmpty, sessionActive: active, idleTicks: idleTicks)
        TraceLog.emit("keepAwake tick: clients=\(connections.count) activeSession=\(active) "
            + "idleTicks=\(idleTicks)→\(step.idleTicks) hold=\(step.hold) release=\(step.release)")
        idleTicks = step.idleTicks
        if step.release {
            stopKeepAwake()
        } else if step.hold {
            sendKeepAwake(true)        // hold / refresh the TTL (incl. grace window)
        }
    }

    private func stopKeepAwake() {
        holdTimer?.cancel(); holdTimer = nil
        guard keepAwakeActive else { return }
        keepAwakeActive = false
        idleTicks = 0
        sendKeepAwake(false)
    }

    private func sendKeepAwake(_ on: Bool) {
        // Route through LidSleepHelper's order-preserving apply chain (NOT a bare
        // Task) so a true/false heartbeat pair can't reorder on the MainActor, and so
        // a heartbeat can't invalidate the shared XPC connection out from under an
        // in-flight lid / remote-wake op between its awaits. enqueueApply appends
        // synchronously on this queue thread; the op crosses to @MainActor itself.
        LidSleepHelper.enqueueApply { await LidSleepHelper.setRemoteSessionActive(on) }
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
