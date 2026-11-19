import Foundation
import Network

struct CCPoolServiceConfig: Sendable {
    var port: UInt16 = CCPoolService.defaultPort
    /// Upstream base (Python `CCPOOL_UPSTREAM`), a test seam only.
    var upstream: URL = CCPoolService.productionUpstream
    /// Request bodies up to this are buffered and can be replayed on another account; larger ones
    /// are streamed upstream once (errata C1).
    var replayCap: Int = 32 << 20
    var timeout: TimeInterval = 900
    var exhaustedThreshold: Double = CCPoolCore.exhaustedDefault
    /// How long the start-up probe of an occupied port waits for an answer.
    var probeTimeout: TimeInterval = 2
    /// The start-up port probe, a test seam: a bound socket that is not listening makes the real
    /// probe wait for it, so only an injected "free" can stage the bind race start(bindRetry:) retries.
    var portProbe: @Sendable (_ port: UInt16, _ timeout: TimeInterval) -> CCPoolPortProbe.Result = CCPoolPortProbe.probe
    /// Test seam (QA follow-up A6): runs on start()'s thread after the listener said .ready and
    /// before it is published, so a test can deliver a state change into that window. nil in production.
    var afterReady: (@Sendable (CCPoolListener) -> Void)? = nil
    /// #1660: the one place a signal is sent ("Stop ccpool and start"); tests inject a recorder. The
    /// default refuses under XCTest, so no test signals a real process even without a fake.
    var signal: @Sendable (_ pid: pid_t, _ sig: Int32) -> Bool = { pid, sig in
        NSClassFromString("XCTestCase") == nil && kill(pid, sig) == 0
    }
    /// #1660: whether `pid` runs as this user (a seam: tests name fake pids).
    var ownedByUser: @Sendable (_ pid: pid_t) -> Bool = CCPoolService.runsAsCurrentUser
    /// #1660: whether `pid` itself holds a listening TCP socket on 127.0.0.1:`port` (a seam: tests
    /// name fake pids). The pid the probe reports comes from the holder's own health answer; this
    /// ties it to the socket. The default only reads (libproc).
    var listensOn: @Sendable (_ pid: pid_t, _ port: UInt16) -> Bool = CCPoolService.listensOnLoopback
    /// #1660/#1665: how long a signalled ccpool gets to close its listening socket (a Python proxy drains its open
    /// streams first), and how often listensOn is asked meanwhile. 600 s because a draining
    /// proxy finishes long streams (minutes); giving up early leaves the port empty (an outage).
    var takeOverCeiling: TimeInterval = 600
    var takeOverPoll: TimeInterval = 0.25
    /// #1665: this user's pids, scanned for the port's listener when the health answer names none. Empty under
    /// XCTest, so no test reads a real process's argv.
    var userPids: @Sendable () -> [pid_t] = { NSClassFromString("XCTestCase") == nil ? CCPoolService.currentUserPids() : [] }
    /// #1665: a pid's argv (never its environment), its executable path and its parent (seams: tests name fake pids).
    var argv: @Sendable (_ pid: pid_t) -> [String] = CCPoolService.processArgv
    var executable: @Sendable (_ pid: pid_t) -> String? = CCPoolService.executablePath
    var parentPid: @Sendable (_ pid: pid_t) -> pid_t? = CCPoolService.parentOf
}

/// #871: the in-process ccpool proxy. HTTP/1.1 on a BSD loopback socket (#1675; Network.framework before), loopback only. Clients point
/// `ANTHROPIC_BASE_URL` at it; every request is relayed upstream under the pool's current account,
/// and a quota 429 benches that account and replays the request on the next one before any byte
/// reaches the client. Nothing in the app starts it in P1.
///
/// Isolation: not actor-isolated. Listener callbacks run on `queue`, each connection on its own
/// serial queue, URLSession callbacks on per-session delegate queues; shared state is behind locks
/// (`CCPoolStore`, `lock` here). No closure handed to Network or URLSession comes from @MainActor code.
final class CCPoolService: @unchecked Sendable {
    static let defaultPort: UInt16 = 8790
    static let productionUpstream = URL(string: "https://api.anthropic.com")!
    static let healthPath = "/ccpool/health"
    static let serviceName = "ccpool-proxy"
    /// First token of the `Server` header: how a probe tells a ccpool proxy from anything else.
    static let serverHeader = "ccpool"

    enum Status: Equatable, Sendable {
        case stopped
        case running(port: UInt16)
        /// Another ccpool proxy (the Python one, or another Prosper) holds the port. Signalled only
        /// by takeOver(pid:), the pane's "Stop ccpool and start" (#1660).
        case heldByCCPool(pid: Int?)
        /// Something that is not ccpool holds the port.
        case heldByOther
        case failed(String)
    }

    let config: CCPoolServiceConfig
    let store: CCPoolStore
    let secrets: CCPoolSecrets
    let logger: CCPoolLogger
    let upstream = CCPoolUpstream()
    /// #1482: the usage record writer, owned here and stopped (flushed) with the service.
    let usageRecord: CCPoolUsageRecord
    /// #1667: the event record writer, in its own "events" folder beside usage/, stopped (flushed) with the service.
    let eventRecord: CCPoolEventRecord
    private let queue = DispatchQueue(label: "com.prosper.ccpool.listener")
    private let lock = NSLock()
    private var listener: CCPoolListener?
    private var connections: [ObjectIdentifier: CCPoolConnection] = [:]
    private var _status: Status = .stopped
    private var _onStatusChange: (@Sendable () -> Void)?
    /// The last start() failed at bind time after the probe found the port free (TIME_WAIT, a
    /// socket bound but not listening): the case a brief retry can win.
    private var bindRaced = false
    /// #1665: the last start()'s bind error word (EADDRINUSE ...), logged once per start(bindRetry:).
    private var bindError: String?

    /// Fixed reasons a `.failed` status carries (QA #739 INFO-11): never a raw system error text.
    static let reasonCreate = "the listener could not be created"
    static let reasonBind = "the port could not be bound"
    static let reasonTimeout = "the bind timed out"
    static let reasonLost = "the listener stopped after it started"

    init(config: CCPoolServiceConfig, store: CCPoolStore, secrets: CCPoolSecrets, logger: CCPoolLogger = CCPoolOSLog()) {
        self.config = config
        self.store = store
        self.secrets = secrets
        self.logger = logger
        usageRecord = CCPoolUsageRecord(directory: store.usageDirectory, logger: logger)
        eventRecord = CCPoolEventRecord(directory: store.directory.appendingPathComponent("events", isDirectory: true), logger: logger)
    }

    var status: Status { lock.withLock { _status } }

    /// #1219 (R1205-3): called after a status change no caller asked for (a listener lost after its start), on the
    /// thread that saw it (the listener's queue) and outside the lock. Start, stop and restart are not reported here:
    /// their callers (the pane model's proxy jobs) publish. The pane model sets its republisher (formed nonisolated).
    var onStatusChange: (@Sendable () -> Void)? {
        get { lock.withLock { _onStatusChange } }
        set { lock.withLock { _onStatusChange = newValue } }
    }

    /// The published listener (tests deliver its state changes through its own handler, A6).
    var currentListener: CCPoolListener? { lock.withLock { listener } }

    /// QA #739 F1: new sessions route only while the listener runs AND the pool lists an account.
    var routable: Bool {
        guard case .running = status else { return false }
        return store.hasAccounts
    }

    /// The env delta for a new Agent Session (P2b's one call): base URL, health and accounts all
    /// come from this service, so no caller can route to a stopped proxy or an empty pool.
    func sessionEnv(command: [String], on: Bool) -> CCPool.EnvDelta {
        routing(on: { on }).delta(command)
    }

    /// P2b-2: this service's status and accounts, read at each call, behind the person's toggle `on`.
    func routing(on: @escaping @Sendable () -> Bool) -> CCPool.Routing {
        CCPool.Routing(on: on, status: { [self] in status }, hasAccounts: { [self] in store.hasAccounts })
    }

    /// Under XCTest the proxy never binds the production port and never dials the production
    /// upstream: the operator's own proxy may be on that port, and tests never reach the network.
    static func refusalUnderTest(_ config: CCPoolServiceConfig) -> String? {
        guard NSClassFromString("XCTestCase") != nil else { return nil }
        if config.port == defaultPort { return "ccpool: refusing the production port under XCTest" }
        if refusesUnderTest(config.upstream) { return "ccpool: refusing the production upstream under XCTest" }
        return nil
    }

    /// True under XCTest for the production upstream host: tests never dial it.
    static func refusesUnderTest(_ url: URL) -> Bool {
        NSClassFromString("XCTestCase") != nil && url.host?.lowercased() == productionUpstream.host
    }

    /// Bind and serve. Blocks up to a few seconds (port probe + bind): call it off the main thread.
    @discardableResult
    func start() -> Status {
        if case .running = status { return status }
        if let why = Self.refusalUnderTest(config) { return finishStart(.failed(why), note: why) }
        if config.port != 0 {
            switch probeHolder() {
            case .free: break
            case .ccpool(let pid, _):
                return finishStart(.heldByCCPool(pid: pid), note: "port held by another ccpool proxy; not binding")
            case .other:
                return finishStart(.heldByOther, note: "port held by another program; not binding")
            }
        }
        // #1675: a BSD socket on 127.0.0.1 with SO_REUSEADDR (CCPoolListener.open): past TIME_WAIT at once, never beside a live listener.
        switch CCPoolListener.open(port: config.port) {
        case .success(let l): return serve(l)
        case .failure(.create(let c)):
            return finishStart(.failed(Self.reasonCreate), note: "listener could not be created", detail: " \(Self.errorWord(.posix(c)))")
        case .failure(.bind(let c)):
            lock.withLock { bindRaced = c == .EADDRINUSE; bindError = Self.errorWord(.posix(c)) }
            return finishStart(c == .EADDRINUSE ? .heldByOther : .failed(Self.reasonBind), note: "listener did not start")
        }
    }

    /// #1675 (for #1676): serve a listening socket made elsewhere (the port keeper's), with no probe and no bind. Fails
    /// with reasonCreate, the fd left to its owner, unless it is an IPv4 socket bound to 127.0.0.1 and listening.
    @discardableResult
    func start(listening fd: Int32) -> Status {
        if case .running = status { return status }
        guard let l = CCPoolListener(adopting: fd) else {
            return finishStart(.failed(Self.reasonCreate), note: "listener could not be adopted")
        }
        var bound = config
        bound.port = l.port?.rawValue ?? 0
        // The fd stays its owner's: a listener that was never started or cancelled does not close it.
        if let why = Self.refusalUnderTest(bound) { return finishStart(.failed(why), note: why) }
        return serve(l)
    }

    /// Publish a bound, listening socket and accept on `queue`.
    private func serve(_ l: CCPoolListener) -> Status {
        final class Outcome: @unchecked Sendable {
            /// A6 (b): a state change after the bind that came before start() published the listener.
            var lost = false
        }
        let outcome = Outcome()
        let port = l.port?.rawValue ?? 0
        // After the bind every state but .ready/.setup means the listener no longer serves (A6): .waiting, .failed,
        // .cancelled. Before start() published it, `lost` tells start(); after, listenerLost() finds it by identity.
        l.stateUpdateHandler = { [weak self, weak l] state in
            // A freed listener is never the published one (the service holds that); and a nil `from` would mean
            // "the current listener" to listenerLost.
            guard let l else { return }
            switch state {
            case .waiting(let e), .failed(let e):
                outcome.lost = true
                self?.listenerLost(e, from: l)
            case .cancelled:
                outcome.lost = true
                self?.listenerLost(nil, from: l)
            default: break
            }
        }
        config.afterReady?(l)
        // A6 (b): decided on the listener's own queue, so a state change after the bind was either seen above
        // (`lost`) or runs after `listener = l` and is matched by identity.
        let published: Bool = queue.sync {
            guard !outcome.lost else { return false }
            lock.withLock { listener = l }
            // Accepted connections carry the bound port for the Host check.
            l.start(queue: queue, accept: { [weak self] fd in self?.accept(fd, port: port) },
                    exhausted: { [logger] in logger.note(nil, "accept paused: out of file descriptors") })
            return true
        }
        guard published else {
            l.stateUpdateHandler = nil
            l.cancel()
            lock.withLock { bindRaced = false; bindError = nil }
            return finishStart(.failed(Self.reasonLost), note: "listener did not start")
        }
        return finishStart(.running(port: port), note: "proxy listening on loopback")
    }

    /// #1665: how long a bind that loses to a free-probing port keeps retrying. #1675: SO_REUSEADDR binds past
    /// TIME_WAIT at once, so this is a backstop (a socket bound but not yet listening); a live holder is never retried.
    static let timeWaitRetry: TimeInterval = 35

    /// P2a (d): start, and while the bind itself loses to a port the probe found free (P1 note 5:
    /// stop() then start() can meet TIME_WAIT; endpoint reuse stays off), retry for up to
    /// `bindRetry` seconds. A port held by a live listener is never retried. Blocks: off main only.
    @discardableResult
    func start(bindRetry: TimeInterval) -> Status {
        let deadline = Date().addingTimeInterval(bindRetry)
        while true {
            lock.withLock { bindRaced = false; bindError = nil }
            let s = start()
            guard case .heldByOther = s, lock.withLock({ bindRaced }), Date() < deadline else {
                // #1665: the reason, once per start, not once per retry tick.
                if let why = lock.withLock({ bindError }) { logger.note(nil, "bind failed: \(why)") }
                return s
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
    }

    /// #1665: the NWError's code word for the log (EADDRINUSE, dns -65554), never a system message text.
    static func errorWord(_ e: NWError) -> String {
        switch e {
        case .posix(let c):
            switch c {
            case .EADDRINUSE: return "EADDRINUSE"
            case .EADDRNOTAVAIL: return "EADDRNOTAVAIL"
            case .EACCES: return "EACCES"
            case .EPERM: return "EPERM"
            default: return "errno \(c.rawValue)"
            }
        case .dns(let c): return "dns \(c)"
        case .tls(let c): return "tls \(c)"
        @unknown default: return "unknown"
        }
    }

    enum TakeOver: Equatable, Sendable {
        /// The port was re-probed (and freed when it held `pid`), then start(bindRetry:) ran; or at the
        /// ceiling `pid` no longer held the port and the status names the holder the last probe found.
        case started(Status)
        /// `pid` got SIGTERM and still held the port at the ceiling. No second signal is sent.
        case didNotStop(pid: Int)
        /// `pid` still holds the port but is never signalled: pid 1 or lower, this process, out of
        /// pid_t range, another user's, without a listening socket on the port, or the signal was refused.
        case refused(pid: Int)
    }

    /// #1660 "Stop ccpool and start": SIGTERM to the ccpool proxy the probe names at `pid` (nil: whichever
    /// ccpool holds the port now, prosper://ccpool/takeover), wait until it no longer listens on the port,
    /// then the normal start. The port is re-probed first: a holder that changed (free, another pid, not
    /// ccpool) is never signalled and the normal start reports it. Signalled only when the holder itself
    /// listens on the port (config.listensOn). #1665: its respawn loop (a shell parent running
    /// ccpool_proxy.py) gets SIGTERM first. Never SIGKILL, never by name. Blocks up to probe + ceiling +
    /// start: off main only.
    func takeOver(pid wanted: Int?, bindRetry: TimeInterval = timeWaitRetry, stillWanted: @Sendable () -> Bool = { true }) -> TakeOver {
        if case .running = status { return .started(status) }
        guard config.port != 0, Self.refusalUnderTest(config) == nil,
              case .ccpool(let pid?, _) = probeHolder(), wanted == nil || pid == wanted else {
            return .started(start(bindRetry: bindRetry))
        }
        guard pid > 1, pid != Int(getpid()), let p = pid_t(exactly: pid), config.ownedByUser(p),
              config.listensOn(p, config.port) else {
            _ = finishStart(.heldByCCPool(pid: pid), note: "port held by another ccpool proxy; not signalled")
            return .refused(pid: pid)
        }
        // #1665: the loop first, or it respawns the proxy within seconds and the new one takes the port.
        if let loop = respawnLoop(of: p), config.signal(loop, SIGTERM) {
            logger.note(nil, "sent SIGTERM to the ccpool proxy's restart loop")
        }
        guard config.signal(p, SIGTERM) else {
            _ = finishStart(.heldByCCPool(pid: pid), note: "port held by another ccpool proxy; not signalled")
            return .refused(pid: pid)
        }
        logger.note(nil, "sent SIGTERM to the ccpool proxy holding the port")
        // #1665: wait on the socket, not the health answer: a draining proxy stops answering but keeps its LISTEN socket.
        let deadline = Date().addingTimeInterval(config.takeOverCeiling)
        while config.listensOn(p, config.port) {
            // The wait holds the life cycle's queue: a toggle-off or Restart behind it must not end in a bind.
            guard stillWanted() else { return abandoned() }
            guard Date() < deadline else {
                _ = finishStart(.heldByCCPool(pid: pid), note: "the signalled ccpool proxy did not free the port")
                return .didNotStop(pid: pid)
            }
            Thread.sleep(forTimeInterval: config.takeOverPoll)
        }
        guard stillWanted() else { return abandoned() }
        // A new holder (another ccpool, another program) is reported by start()'s own probe.
        return .started(start(bindRetry: bindRetry))
    }

    private func abandoned() -> TakeOver {
        logger.note(nil, "takeover abandoned: the proxy should no longer run")
        return .started(status)
    }

    /// #1665: the health probe, and when it names no ccpool pid (no answer while draining, an answer without a pid),
    /// the port's listener among this user's pids, recognized as ccpool by its argv. Reads only.
    func probeHolder() -> CCPoolPortProbe.Result {
        let r = config.portProbe(config.port, config.probeTimeout)
        switch r {
        case .free, .ccpool(_?, _): return r
        case .ccpool(nil, _), .other:
            guard let p = config.userPids().first(where: { $0 > 1 && $0 != getpid() && config.listensOn($0, config.port) })
            else { return r }
            if case .ccpool(_, let impl) = r { return .ccpool(pid: Int(p), impl: impl) }
            return Self.isCCPoolArgv(config.argv(p)) ? .ccpool(pid: Int(p), impl: nil) : r
        }
    }

    /// #1665: the Python proxy (`python3 .../ccpool_proxy.py 8790`) or the program ccpool (`ccpool ...`, a path
    /// ending in /ccpool, also under an interpreter). A bare "ccpool" word after argv[0] (`grep ccpool`) is not.
    static func isCCPoolArgv(_ argv: [String]) -> Bool {
        argv.first == "ccpool" || argv.contains { $0.hasSuffix("ccpool_proxy.py") || $0.hasSuffix("/ccpool") }
    }

    static let loopShells: Set<String> = ["zsh", "bash", "sh", "dash"]

    /// #1665: `p`'s parent when it is this user's shell running a ccpool_proxy.py loop
    /// (`zsh -c 'while true; do python3 .../ccpool_proxy.py ...'`); never launchd, this process or its parent.
    func respawnLoop(of p: pid_t) -> pid_t? {
        guard let pp = config.parentPid(p), pp > 1, pp != getpid(), pp != getppid(), config.ownedByUser(pp),
              let exe = config.executable(pp), Self.loopShells.contains((exe as NSString).lastPathComponent),
              config.argv(pp).contains(where: { $0.contains("ccpool_proxy.py") }) else { return nil }
        return pp
    }

    /// True when `pid` has a TCP socket in LISTEN on `port` whose local address accepts 127.0.0.1
    /// (127.0.0.1 or 0.0.0.0, or :: for IPv6). Reads only: proc_pidinfo(PROC_PIDLISTFDS), then
    /// proc_pidfdinfo(PROC_PIDFDSOCKETINFO) per socket fd. False when the pid is gone or unreadable.
    static func listensOnLoopback(_ pid: pid_t, _ port: UInt16) -> Bool {
        let need = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard need > 0 else { return false }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(need) / stride + 16)
        let got = fds.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
        guard got > 0 else { return false }
        let size = Int32(MemoryLayout<socket_fdinfo>.size)
        for fd in fds.prefix(min(Int(got) / stride, fds.count)) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var si = socket_fdinfo()
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &si, size) == size,
                  si.psi.soi_kind == Int32(SOCKINFO_TCP) else { continue }
            let tcp = si.psi.soi_proto.pri_tcp
            let ini = tcp.tcpsi_ini
            guard tcp.tcpsi_state == TSI_S_LISTEN,
                  UInt16(bigEndian: UInt16(truncatingIfNeeded: ini.insi_lport)) == port else { continue }
            if ini.insi_vflag & UInt8(INI_IPV4) != 0 {
                let a = ini.insi_laddr.ina_46.i46a_addr4.s_addr
                if a == 0 || a == UInt32(0x7f00_0001).bigEndian { return true }
            } else if ini.insi_vflag & UInt8(INI_IPV6) != 0 {
                if withUnsafeBytes(of: ini.insi_laddr.ina_6, { $0.allSatisfy { $0 == 0 } }) { return true }
            }
        }
        return false
    }

    /// The process's real uid is this user's (sysctl; false when the pid is gone).
    static func runsAsCurrentUser(_ pid: pid_t) -> Bool {
        kinfo(pid)?.kp_eproc.e_pcred.p_ruid == getuid()
    }

    /// #1665: the parent pid (sysctl; nil when the pid is gone).
    static func parentOf(_ pid: pid_t) -> pid_t? { kinfo(pid)?.kp_eproc.e_ppid }

    private static func kinfo(_ pid: pid_t) -> kinfo_proc? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info
    }

    /// #1665: this user's pids (proc_listpids PROC_UID_ONLY). Reads only.
    static func currentUserPids() -> [pid_t] {
        let need = proc_listpids(UInt32(PROC_UID_ONLY), getuid(), nil, 0)
        guard need > 0 else { return [] }
        let stride = MemoryLayout<pid_t>.stride
        var pids = [pid_t](repeating: 0, count: Int(need) / stride + 32)
        let got = pids.withUnsafeMutableBytes { proc_listpids(UInt32(PROC_UID_ONLY), getuid(), $0.baseAddress, Int32($0.count)) }
        guard got > 0 else { return [] }
        return pids.prefix(min(Int(got) / stride, pids.count)).filter { $0 > 0 }
    }

    /// #1665: the executable's path (proc_pidpath; nil when the pid is gone or unreadable).
    static func executablePath(_ pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        guard n > 0, Int(n) <= buf.count else { return nil }
        return String(decoding: buf.prefix(Int(n)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// #1665: a process's argv from KERN_PROCARGS2 (argc, the exec path, then argc strings). Only the argc
    /// strings are decoded: the environment that follows them in the buffer is never read. [] when unreadable.
    static func processArgv(_ pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        let head = MemoryLayout<Int32>.size
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > head, size <= 16 << 20 else { return [] }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > head, size <= buf.count else { return [] }
        let argc = buf.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc > 0, argc <= 4096 else { return [] }
        var i = head
        while i < size, buf[i] != 0 { i += 1 }   // the exec path
        while i < size, buf[i] == 0 { i += 1 }   // its padding
        var args: [String] = []
        while args.count < Int(argc), i < size {
            let from = i
            while i < size, buf[i] != 0 { i += 1 }
            args.append(String(decoding: buf[from..<i], as: UTF8.self))
            i += 1
        }
        return args
    }

    /// The Settings "Restart proxy": a listener restart (B25). Blocks: off main only.
    @discardableResult
    func restart(bindRetry: TimeInterval = 3) -> Status {
        // Wait for the old listener to be gone: a probe racing its cancel would be answered by it
        // (and read as "another ccpool holds the port") or reset (read as "something else").
        let gone = DispatchSemaphore(value: 0)
        let old = lock.withLock { listener }
        old?.stateUpdateHandler = { if case .cancelled = $0 { gone.signal() } }
        stop()
        if old != nil { _ = gone.wait(timeout: .now() + 2) }
        return start(bindRetry: bindRetry)
    }

    /// Remove an account and drop its upstream URLSession with it (P2a follow-up e). False when the
    /// account is gone but its Keychain item could not be deleted (the caller says so).
    @discardableResult
    func removeAccount(label: String) throws -> Bool {
        let (id, deleted) = try store.removeAccount(label: label, secrets: secrets)
        upstream.drop(accountID: id)
        return deleted
    }

    /// QA #734 / A6: the running listener stopped serving (`from` nil means the current one; `error`
    /// nil for a cancel nobody asked for). The status says so and the listener is dropped, so the
    /// pane offers Start again and no session routes to it.
    func listenerLost(_ error: NWError?, from failed: CCPoolListener? = nil) {
        let (lost, hook) = lock.withLock { () -> (CCPoolListener?, (@Sendable () -> Void)?) in
            guard let l = listener, failed == nil || failed === l else { return (nil, nil) }
            listener = nil
            _status = .failed(Self.reasonLost)
            return (l, _onStatusChange)
        }
        guard let lost else { return }
        lost.stateUpdateHandler = nil
        lost.cancel()
        logger.note(nil, "listener stopped after start: \(error.map { "\($0)" } ?? "cancelled")")
        hook?()
    }

    private func finishStart(_ s: Status, note: String, detail: String = "") -> Status {
        lock.withLock { _status = s }
        if detail.isEmpty { logger.note(nil, note) } else { logger.note(nil, note, private: detail) }
        return s
    }

    deinit { listener?.cancel() }

    func stop() {
        let (l, conns) = lock.withLock { () -> (CCPoolListener?, [CCPoolConnection]) in
            defer { listener = nil; connections.removeAll(); _status = .stopped }
            return (listener, Array(connections.values))
        }
        l?.cancel()
        conns.forEach { c in c.queue.async { c.close() } }
        upstream.invalidateAll()
        usageRecord.stop()
        eventRecord.stop()
    }

    private func accept(_ fd: Int32, port: UInt16) {
        let c = CCPoolConnection(conn: CCPoolFDTransport(fd: fd), config: config, store: store, secrets: secrets, logger: logger,
                                 upstream: upstream, boundPort: port, record: usageRecord,
                                 events: eventRecord) { [weak self] id in
            self?.lock.withLock { _ = self?.connections.removeValue(forKey: id) }
        }
        lock.withLock { connections[ObjectIdentifier(c)] = c }
        c.start()
    }

    /// The local health answer: names the proxy, never relayed upstream (B9). `current` is a label,
    /// returned to loopback only (errata C6).
    func healthBody() -> Data { Self.healthBody(store: store) }

    static func healthBody(store: CCPoolStore) -> Data {
        var obj: [String: Any] = ["service": Self.serviceName, "pid": Int(getpid()), "impl": "prosper"]
        obj["current"] = store.snapshot.current.map { $0 as Any } ?? NSNull()
        return (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data()
    }
}

/// What holds a loopback port (Python `ccpool_proxy.probe`): nothing, a ccpool proxy (first
/// `Server` header token "ccpool"; pid from its health answer when it has one), or anything else.
enum CCPoolPortProbe {
    enum Result: Equatable, Sendable {
        case free
        case ccpool(pid: Int?, impl: String?)
        case other
    }

    static func probe(port: UInt16, timeout: TimeInterval) -> Result {
        guard let p = NWEndpoint.Port(rawValue: port) else { return .other }
        let q = DispatchQueue(label: "com.prosper.ccpool.probe")
        let conn = NWConnection(host: .ipv4(.loopback), port: p, using: .tcp)
        final class Box: @unchecked Sendable {
            var data = Data()
            var result: Result?
            let sem = DispatchSemaphore(value: 0)
        }
        let box = Box()
        @Sendable func finish(_ r: Result) {
            guard box.result == nil else { return }
            box.result = r
            conn.cancel()
            box.sem.signal()
        }
        @Sendable func read() {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { d, _, done, err in
                if let d { box.data.append(d) }
                if let r = parse(box.data, complete: done || err != nil || box.data.count > 1 << 16) { finish(r) } else { read() }
            }
        }
        conn.stateUpdateHandler = { state in
            switch state {
            case .ready:
                let req = "GET \(CCPoolService.healthPath) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nConnection: close\r\n\r\n"
                conn.send(content: Data(req.utf8), completion: .contentProcessed { _ in })
                read()
            case .waiting(let e), .failed(let e):
                if case .posix(.ECONNREFUSED) = e { finish(.free) } else { finish(.other) }
            default: break
            }
        }
        conn.start(queue: q)
        q.asyncAfter(deadline: .now() + timeout) { finish(.other) }
        box.sem.wait()
        return q.sync { box.result ?? .other }
    }

    /// nil while more bytes are needed.
    static func parse(_ data: Data, complete: Bool) -> Result? {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return complete ? .other : nil }
        let head = String(decoding: data[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let fields = head.dropFirst().compactMap { line -> (String, String)? in
            guard let c = line.firstIndex(of: ":") else { return nil }
            return (line[..<c].lowercased(), line[line.index(after: c)...].trimmingCharacters(in: .whitespaces))
        }
        let server = fields.first { $0.0 == "server" }?.1 ?? ""
        guard server.split(separator: " ").first.map(String.init) == CCPoolService.serverHeader else { return .other }
        let body = data[end.upperBound...]
        if !complete, let len = fields.first(where: { $0.0 == "content-length" }).flatMap({ Int($0.1) }), body.count < len { return nil }
        if !complete, fields.first(where: { $0.0 == "content-length" }) == nil { return nil }
        let ok = head.first?.split(separator: " ").dropFirst().first == "200"
        guard ok, let obj = try? JSONSerialization.jsonObject(with: Data(body)) as? [String: Any] else { return .ccpool(pid: nil, impl: nil) }
        return .ccpool(pid: obj["pid"] as? Int, impl: obj["impl"] as? String)
    }
}
