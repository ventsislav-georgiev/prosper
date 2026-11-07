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
    /// Leeway granted to the keep-awake tick timer.
    static let tickLeewaySeconds = 1
    /// Window each tick actually scans: tick + leeway, so a tick firing up to
    /// `tickLeewaySeconds` late still sees activity from just after the previous tick.
    static let tickActivityWindowSeconds = activeWindowSeconds + tickLeewaySeconds
    /// Consecutive idle ticks (each `tickSeconds` ≈ this many seconds) before
    /// releasing the hold — a ~60s grace covering a brief reconnect or output lull.
    static let graceTicks = 6
    /// Once the daemon has CONFIRMED the hold, refresh it every this many ticks
    /// (30 s) instead of every tick (#767). The tick itself stays 10 s for the
    /// activity window. 4 beats fit in the daemon's 120 s TTL, so two missed or
    /// late beats (plus tick leeway) still land before it expires, and the TTL
    /// still releases the hold within 2 min of Prosper dying.
    static let heartbeatTicks = 3
    static let heartbeatSeconds = heartbeatTicks * activeWindowSeconds

    /// One holding tick: send the keep-awake XPC now? `confirmed` = the daemon
    /// acknowledged the last hold. Unconfirmed beats every tick, as before #767.
    /// "Unconfirmed" is only learned from a reply: a refused beat (lid open,
    /// sleep requested), a failed or timed-out XPC. A drop the server never hears
    /// of — the helper restarting and reclaiming, or the lid-open hard release —
    /// stays "confirmed" until the next beat, which re-asserts it, so the hold is
    /// back within one beat (30 s); from then on a failing reply beats every tick.
    static func beat(confirmed: Bool, ticksSinceBeat: Int) -> (send: Bool, ticksSinceBeat: Int) {
        let n = ticksSinceBeat + 1
        if !confirmed || n >= heartbeatTicks { return (true, 0) }
        return (false, n)
    }

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

    /// Post-release watch mode: the hold was released (grace elapsed) but detached
    /// sessions may still exist — a long-running command with a quiet phase (>grace
    /// of silence, then output resumes) must RE-ACQUIRE the hold, or the Mac sleeps
    /// mid-build. So after a release the tick keeps running, deciding per tick:
    enum WatchAction: Equatable {
        case rehold        // activity resumed → hold again
        case keepWatching  // sessions exist but quiet → keep ticking, no hold
        case stop          // no sessions at all → nothing left to watch, stop the timer
    }

    static func watch(clientConnected: Bool, sessionActive: Bool, sessionsExist: Bool) -> WatchAction {
        if clientConnected || sessionActive { return .rehold }
        return sessionsExist ? .keepWatching : .stop
    }
}

final class DchSessionServer: @unchecked Sendable {
    static let shared = DchSessionServer()

    /// Fixed port so the app connects deterministically (no discovery step).
    /// ponytail: hard-coded; advertise via Bonjour/MagicDNS SRV if it ever clashes.
    static let port: UInt16 = 8771

    private let log = Logger(subsystem: "com.prosper.app", category: "DchServer")
    /// Connections, keep-awake and everything they touch. It runs dch forks with no
    /// timeout, so main must never wait on it.
    let queue = DispatchQueue(label: "com.prosper.dchserver")
    /// Owns `listener`, `wanted`, `retry` and `retryAttempt`, and runs the listener's
    /// handlers. Only short work runs here, so start()/stop()/isRunning may sync on it
    /// from main (QA #532 F1: syncing on `queue` froze main behind a hung dch call).
    let lifecycle = DispatchQueue(label: "com.prosper.dchserver.listener")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: DchConnection] = [:]
    /// #765: the island's list for the phone and the watch streams. On `queue`.
    private(set) lazy var watch = DchWatchHub(schedule: DchWatchHub.schedule(on: queue))

    // Bind recovery (#715). `wanted` = start() was asked and stop() was not; while it
    // holds, a failed bind (EADDRINUSE) or a missing Tailscale address retries after
    // `retryDelay`. All touched only on `lifecycle`.
    // ponytail: timer backoff only; a network-path-change retry would bring the server
    // up sooner when Tailscale connects, add it if the 60 s cap proves too slow.
    private var wanted = false
    private(set) var retry: DispatchWorkItem?
    private var retryAttempt = 0

    // Seams (tests bind loopback on their own port and never sweep real dch clients).
    private let bindHost: @Sendable () -> String?
    private let bindPort: UInt16
    private let retryBase: Double
    private let onReady: @Sendable () -> Void

    // Keep-awake: while any client is attached — OR a detached session is still
    // producing output — the Mac must not sleep mid-command. A single repeating
    // tick re-evaluates and heartbeats the daemon's remote-session hold (TTL ~120s).
    // When nothing wants it awake for `graceTicks` consecutive ticks, we release.
    // All touched only on `queue`.
    private var keepAwakeActive = false
    private var holdTimer: DispatchSourceTimer?
    private var idleTicks = 0
    /// The daemon acknowledged the last hold (set from the XPC result) and ticks
    /// since that send: a confirmed hold is refreshed every `heartbeatTicks` only.
    private var holdConfirmed = false
    private var ticksSinceBeat = 0
    /// Tick cadence; the hold heartbeat is every `KeepAwakePolicy.heartbeatTicks`
    /// ticks once confirmed (30 s, inside the daemon's 120s TTL).
    /// Kept equal to `activeWindowSeconds` so the "silent >10s ⇒ inactive" rule
    /// actually holds — a coarser tick would mis-read a session that prints between
    /// ticks as idle. Each tick re-evaluates; `beat` decides whether it refreshes the TTL.
    private static let tickSeconds = KeepAwakePolicy.activeWindowSeconds

    init(bindHost: @escaping @Sendable () -> String? = { DchSessionServer.tailscaleIPv4() },
         port: UInt16 = DchSessionServer.port,
         retryBase: Double = 2,
         // Detach any dch client left behind by a previous Prosper (crash / force quit).
         // Those clients still hold a pty and keep reporting ITS window size to the
         // master, which narrows the session for whoever attaches next.
         onReady: @escaping @Sendable () -> Void = { DchCommand.sweepOrphanedClients() }) {
        self.bindHost = bindHost
        self.bindPort = port
        self.retryBase = retryBase
        self.onReady = onReady
    }

    /// Never call from `lifecycle`.
    var isRunning: Bool { lifecycle.sync { listener != nil } }

    /// 2, 4, 8 … seconds (for base 2), capped at 60.
    static func retryDelay(attempt: Int, base: Double = 2) -> Double {
        min(base * Double(1 << min(attempt, 6)), 60)
    }

    // MARK: - Lifecycle

    /// Bind to the Tailscale interface and accept connections. Idempotent. Throws
    /// `ServerError.noTailscale` when no Tailscale address exists — we never fall
    /// back to a wider bind. Either failure (no address, failed bind) retries with
    /// backoff until `stop()`. Waits up to 5 s for the first bind result.
    func start() throws {
        let sem = DispatchSemaphore(value: 0)
        let bound: Bool = try lifecycle.sync {
            wanted = true
            if listener != nil { return false }
            retry?.cancel(); retry = nil
            retryAttempt = 0
            try bind(signal: sem)
            return true
        }
        if bound { _ = sem.wait(timeout: .now() + 5) }
    }

    /// On `lifecycle`. Creates and starts a listener, or schedules a retry and rethrows.
    private func bind(signal sem: DispatchSemaphore?) throws {
        do {
            guard let host = bindHost() else {
                logFailure("dch server: no Tailscale address — refusing to bind")
                throw ServerError.noTailscale
            }
            let listener = try makeListener(host: host)
            self.listener = listener
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                guard let self, let listener else { return }
                self.listenerStateChanged(state, of: listener, signal: sem)
            }
            listener.newConnectionHandler = { [weak self, weak listener] conn in
                guard let self, let listener, self.listener === listener else { conn.cancel(); return }
                self.queue.async { self.accept(conn) }
            }
            listener.start(queue: lifecycle)
        } catch {
            scheduleRetry()
            throw error
        }
    }

    private func makeListener(host: String) throws -> NWListener {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        // A phone that leaves the network (sleep, tunnel switch, no signal) never sends
        // FIN. Without keepalive the connection sits in `.ready` forever, so `close()`
        // never runs and its dch client — plus that client's pty — leaks. 44 of them
        // had piled up over one day, all still attached to their sessions.
        if let tcp = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            Self.configureKeepalive(tcp)
        }
        // Port MUST stay `.any` here. Listener params are inherited by every accepted
        // connection, so a port in requiredLocalEndpoint makes each accepted socket try to
        // bind the port the listener already holds: connectx fails EADDRINUSE and the
        // connection dies before the handshake. allowLocalEndpointReuse is SO_REUSEADDR,
        // which does not cover an actively LISTENing port. The listening port goes in `on:`.
        params.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host), port: .any)
        return try NWListener(using: params, on: NWEndpoint.Port(rawValue: bindPort)!)
    }

    /// Idle 120 s (#767; was 30 s): each probe wakes the phone's radio, so an idle
    /// attached connection now costs 0.5 probes/min instead of 2. A dead link is
    /// noticed in ~160 s (was ~70 s); a reconnect never waits on it, because
    /// `retireOlderClients` drops the old client on the new attach.
    static let keepaliveIdle = 120
    static func configureKeepalive(_ tcp: NWProtocolTCP.Options) {
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = keepaliveIdle
        tcp.keepaliveInterval = 10
        tcp.keepaliveCount = 4   // dead link noticed in ~160s
    }

    /// On `lifecycle`. A `.failed` clears the listener — only if it is still the current one,
    /// so a stale handler never clears a newer listener — and schedules a retry.
    func listenerStateChanged(_ state: NWListener.State, of l: NWListener, signal sem: DispatchSemaphore?) {
        dispatchPrecondition(condition: .onQueue(lifecycle))
        switch state {
        case .ready:
            sem?.signal()
            guard listener === l else { return }
            log.info("dch server ready on port \(self.bindPort)")
            retryAttempt = 0
            queue.async(execute: onReady)   // the sweep runs ps + a 0.3 s sleep: not here
        case .failed(let e):
            logFailure("dch server failed on port \(bindPort): \(String(describing: e))")
            l.cancel()
            if listener === l {
                listener = nil
                scheduleRetry()
            }
            sem?.signal()
        default: break
        }
    }

    /// First failure of a streak at error, repeats at debug: a Tailscale that never comes
    /// up would otherwise log twice a minute forever (QA #532 F3). On `lifecycle`.
    private func logFailure(_ message: String) {
        if retryAttempt == 0 {
            log.error("\(message, privacy: .public)")
        } else {
            log.debug("\(message, privacy: .public)")
        }
    }

    /// On `lifecycle`. One pending retry at most; none once stop() cleared `wanted`.
    private func scheduleRetry() {
        guard wanted, retry == nil else { return }
        let delay = Self.retryDelay(attempt: retryAttempt, base: retryBase)
        if retryAttempt == 0 {
            log.info("dch server: retrying bind in \(delay, privacy: .public) s")
        } else {
            log.debug("dch server: retrying bind in \(delay, privacy: .public) s")
        }
        retryAttempt += 1
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.retry = nil
            guard self.wanted, self.listener == nil else { return }
            try? self.bind(signal: nil)
        }
        retry = item
        lifecycle.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// Frees the port before returning, even while `queue` is stuck in a dch call.
    func stop() {
        lifecycle.sync {
            wanted = false
            retry?.cancel(); retry = nil
            listener?.cancel()
            listener = nil
        }
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

    /// #765: AgentIslandController.onSessions, on main: the rows for Remote Terminal's dir
    /// (nil once the island stops or lists other dirs), cached for the list frame and pushed
    /// to the watch streams. No dch fork: these are the island poller's own sessions.
    @MainActor func islandSessions(_ sessions: [AgentSession]?) {
        let cache = DchWatchHub.cache(island: sessions, dirs: sessions == nil ? [] : AgentIsland.liveSocketDirs(),
                                      remote: DchCommand.remoteSocketDir())
        queue.async { self.watch.island(cache) }
    }

    /// #765: AgentIslandController.onRowDetails (the sidekick pattern may have changed).
    func sidekickChanged() {
        queue.async { self.watch.sidekickChanged() }
    }

    private func accept(_ conn: NWConnection) {
        // Belt-and-suspenders source-IP gate (the bind already restricts us).
        if !Self.isTailscalePeer(conn) {
            log.error("dch server: rejecting non-Tailscale peer")
            conn.cancel()
            return
        }
        let handler = DchConnection(
            conn: conn, queue: queue, log: log,
            onClose: { [weak self] id in
                self?.connections.removeValue(forKey: id)
                // No immediate release: the tick re-evaluates and the grace covers a
                // detached session still working or a quick reconnect.
            },
            onAttach: { [weak self] id, name in self?.retireOlderClients(of: name, keep: id) })
        handler.watch = watch
        connections[ObjectIdentifier(handler)] = handler
        handler.start()
        // QA #606 INFO-2: a watch stream takes this ~60 s hold too (no frame says "watch" yet),
        // as the phone's 0x08 handshake connection just before it does; the tick never counts it.
        startKeepAwake()
    }

    /// One phone, one client per session. A reconnect (backgrounded app, tunnel switch,
    /// no signal) opens a new connection while the old one still looks `.ready`; without
    /// this the old client lingers until TCP keepalive notices, ~160s during which the
    /// master takes ITS window size and the phone sees a narrow, garbled screen. So the
    /// newest attach retires the older clients for that session immediately.
    /// Runs on `queue`, called from the connection that just attached.
    private func retireOlderClients(of name: String, keep: ObjectIdentifier) {
        for (id, c) in connections where id != keep && c.attachedSession == name {
            log.info("dch server: retiring stale client for \(name, privacy: .public)")
            c.close()
            connections.removeValue(forKey: id)
        }
    }

    // MARK: - Keep-awake (drives the daemon's remote-session hold)

    /// A client attached (or watched activity resumed): ensure the hold is held now
    /// and the tick is running. The tick is what later releases it once neither a
    /// client nor an active detached session wants the Mac awake.
    private func startKeepAwake() {
        idleTicks = 0
        keepAwakeActive = true
        holdConfirmed = false
        ticksSinceBeat = 0
        sendKeepAwake(true)
        if holdTimer != nil { return }   // already ticking (hold or watch mode)
        let t = DispatchSource.makeTimerSource(queue: queue)
        // 1 s leeway (10 %): a late tick only delays the hold release by that much;
        // `tickActivityWindowSeconds` widens the scan by the same amount.
        t.schedule(deadline: .now() + .seconds(Self.tickSeconds), repeating: .seconds(Self.tickSeconds),
                   leeway: .seconds(KeepAwakePolicy.tickLeewaySeconds))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        holdTimer = t
    }

    /// One evaluation, delegating the branching to the pure `KeepAwakePolicy`. The
    /// `||` short-circuits so the sidecar scan runs only while no client is attached.
    private func tick() {
        // No transport → no remote session, whatever the sockets and the (still open,
        // keepalive-pending) NWConnections claim. See `DchCommand.transportUp`: on a
        // network drop this used to renew the hold forever for a session nothing
        // could reach, so the Mac never slept.
        let up = DchCommand.transportUp
        let n = Self.keepAwakeClients(connections.values)
        let clients = up && n > 0
        let active = up && !clients
            && DchCommand.anySessionActive(within: KeepAwakePolicy.tickActivityWindowSeconds)
        guard keepAwakeActive else {
            // Watch mode: the hold was released after the idle grace, but detached
            // sessions may still exist. A resumed session (long quiet phase, then
            // output) re-acquires the hold; the timer stops only once nothing is
            // left to watch. Without this, a build that goes quiet >grace and then
            // resumes printing would sleep the Mac mid-work.
            // `sessionsExist` stays transport-UNgated on purpose: with no transport,
            // `active` is false so nothing re-holds, but the watch timer must keep
            // ticking so a session that resumes printing after the network returns
            // re-acquires the hold. Gating it would .stop the timer on a drop and
            // never watch again until a client reconnects.
            switch KeepAwakePolicy.watch(clientConnected: clients,
                                         sessionActive: active,
                                         sessionsExist: DchCommand.anySessionExists()) {
            case .rehold:
                TraceLog.emit("keepAwake watch: activity resumed → re-hold")
                startKeepAwake()
            case .keepWatching:
                break
            case .stop:
                holdTimer?.cancel(); holdTimer = nil
            }
            return
        }
        let step = KeepAwakePolicy.step(
            clientConnected: clients, sessionActive: active, idleTicks: idleTicks)
        TraceLog.emit("keepAwake tick: clients=\(n) transport=\(up) activeSession=\(active) "
            + "idleTicks=\(idleTicks)→\(step.idleTicks) hold=\(step.hold) release=\(step.release)")
        idleTicks = step.idleTicks
        if step.release {
            // Release the hold but KEEP the timer — drop to watch mode; the watch
            // branch above stops it once no sessions remain.
            keepAwakeActive = false
            idleTicks = 0
            sendKeepAwake(false)
        } else if step.hold {
            // hold / refresh the TTL (incl. grace window), every 3rd tick once confirmed
            let beat = KeepAwakePolicy.beat(confirmed: holdConfirmed, ticksSinceBeat: ticksSinceBeat)
            ticksSinceBeat = beat.ticksSinceBeat
            if beat.send { sendKeepAwake(true) }
        }
    }

    /// #765: a watch stream is no client: it stays open while the phone app is suspended,
    /// and would hold the Mac awake for as long as it does. On `queue`.
    static func keepAwakeClients(_ connections: some Collection<DchConnection>) -> Int {
        connections.count { !$0.watching }
    }

    /// Full stop (server stop): release the hold AND the timer.
    private func stopKeepAwake() {
        holdTimer?.cancel(); holdTimer = nil
        guard keepAwakeActive else { return }
        keepAwakeActive = false
        idleTicks = 0
        sendKeepAwake(false)
    }

    /// Stop re-asserting the remote-session keep-awake hold so the Mac can sleep now
    /// even while a session is technically "active". Cancels the heartbeat tick
    /// (it only restarts when a new client connects via `accept`); the daemon hold
    /// itself is released — in order, before the sleep — by `SleepControl`, so we do
    /// NOT `sendKeepAwake(false)` here and risk reordering against that chain.
    func releaseForSleep() {
        queue.async { [weak self] in
            guard let self else { return }
            self.holdTimer?.cancel(); self.holdTimer = nil
            self.keepAwakeActive = false
            self.idleTicks = 0
        }
    }

    private func sendKeepAwake(_ on: Bool) {
        // Route through LidSleepHelper's order-preserving apply chain (NOT a bare
        // Task) so a true/false heartbeat pair can't reorder on the MainActor, and so
        // a heartbeat can't invalidate the shared XPC connection out from under an
        // in-flight lid / remote-wake op between its awaits. enqueueApply appends
        // synchronously on this queue thread; the op crosses to @MainActor itself.
        // The result feeds `holdConfirmed`; the chain is FIFO and so is `queue`, so
        // the last send's result is the one that sticks.
        LidSleepHelper.enqueueApply { [weak self] in
            let ok = await LidSleepHelper.setRemoteSessionActive(on)
            guard let self else { return }
            self.queue.async { self.holdConfirmed = on && ok }
        }
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
            return String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
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
