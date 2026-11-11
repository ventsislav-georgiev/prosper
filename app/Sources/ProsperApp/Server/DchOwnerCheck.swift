import Darwin
import Foundation
import os

/// One Tailscale node as whois or status describes it. The owner is decided on `userID` alone
/// (remote-frames.md, Decided defaults); `nodeID` (the stable node id) only spots this Mac's own
/// node; `login` and `name` are display only.
struct TailscaleNode: Equatable, Sendable {
    var userID: Int64
    var nodeID = ""
    var login = ""
    var name = ""
    var tagged = false
}

/// One whois round: this Mac's own node and the peer's (nil: Tailscale doesn't know the address).
struct TailscaleWhois: Equatable, Sendable {
    var host: TailscaleNode
    var peer: TailscaleNode?
}

/// Tailscale isn't answering: no CLI, it can't start, it times out, or `tailscale status` fails.
/// The only failure "Allow when Tailscale isn't answering" relaxes. `cause` is user copy.
struct WhoisUnavailable: Error, Equatable {
    let cause: String
}

/// Tailscale answers but can't vouch for the peer: whois fails while status works, either answer
/// can't be read, the host isn't Running, or whois doesn't finish once status answered. Always
/// refused (dch serve's G_NOTNODE/G_BADWHOIS). `cause` is user copy. `askAgain`: not remembered
/// for the TTL (a host still Starting, a whois that timed out), so the next connection asks again.
struct WhoisUnusable: Error, Equatable {
    let cause: String
    var askAgain = false
}

/// One finished `tailscale` call (nil where one is expected: it timed out and was killed).
/// `exit` is -1 when it couldn't start.
struct TailscaleCLIOutput: Equatable, Sendable {
    var exit: Int32
    var out = Data()
    var err = ""
}

/// #777: the owner check. Every connection that passed the address gate is let in only when
/// Tailscale whois says its node belongs to this Mac's own Tailscale user (`UserProfile.ID ==
/// Self.UserID`). This Mac's own addresses and node, tagged peers, other users and addresses
/// Tailscale doesn't know are refused, and so is a peer whois can't vouch for. When Tailscale
/// isn't answering at all the peer is refused too, unless "Allow when Tailscale isn't answering"
/// is on. dch serve's gate (v1.33.1, serve.c `serve_gate`) is the reference for the cases.
/// `DchSessionServer` calls `check` before it starts the connection, so a refused peer is closed
/// with no byte read. A refusal is one log line per cause and a status line in Remote Terminal's
/// settings.
final class DchOwnerCheck: ObservableObject, @unchecked Sendable {
    enum Verdict: Equatable, Sendable {
        case owner
        /// Tailscale not answering, let in because the relax setting is on.
        case unverified(String)
        /// One of this Mac's own addresses, or its own node: any local user or app could be it.
        case thisMac
        case otherUser(TailscaleNode)
        case taggedPeer(TailscaleNode)
        case unknownPeer
        /// This Mac is a tagged node: no user owns it, so no peer can match (see `decide`).
        case taggedHost
        /// Tailscale answered but can't vouch for the peer. Never relaxed.
        case unusable(String)
        /// Tailscale isn't answering. Relaxed by the setting.
        case unavailable(String)

        var allowed: Bool {
            switch self {
            case .owner, .unverified: true
            default: false
            }
        }

        /// Everything Tailscale answered is cached (dch serve caches its refusals the same 30 s);
        /// "not answering" is asked again, so a Tailscale that comes back is seen at once.
        /// So are a timeout and a host not Running yet (`check` passes them uncached).
        var cacheable: Bool {
            switch self {
            case .unavailable, .unverified, .thisMac: false
            default: true
            }
        }
    }

    static let shared = DchOwnerCheck()

    /// A phone opens a burst of connections (0x08 handshake, watch, attach), so one lookup
    /// covers the burst, and a refused peer that keeps reconnecting forks no CLI for 30 s
    /// (dch serve's NEG_MS). Tailscale addresses are fixed per node, so a stale answer only
    /// matters when a node changes owner or gets tagged inside those 30 s.
    static let ttl: TimeInterval = 30
    /// The whole decision waits at most this; whois answers in ~50 ms when Tailscale is up.
    static let timeout: TimeInterval = 2

    /// `whois(ip, statusAnswered)`: production calls `statusAnswered` once `tailscale status`
    /// answered, so a timeout after it is "unusable", never relaxed (QA #635 F2).
    typealias Lookup = @Sendable (_ ip: String, _ statusAnswered: @Sendable () -> Void) throws -> TailscaleWhois

    private let whois: Lookup
    private let allowWhenDown: @Sendable () -> Bool
    private let isLocalAddress: @Sendable (String) -> Bool
    private let timeout: TimeInterval
    private let ttl: TimeInterval
    private let now: @Sendable () -> Date
    /// Test seam: runs after the verdict timer did its work.
    private let timerFired: @Sendable () -> Void
    private let log = Logger(subsystem: "com.prosper.app", category: "DchServer")
    private let lock = NSLock()
    private var cache: [String: (verdict: Verdict, until: Date)] = [:]
    /// Who waits on the check in flight per address (QA #635 INFO 4).
    private var waiting: [String: [@Sendable (Verdict) -> Void]] = [:]
    /// QA #635 r2 N2: the timeout verdict of an address whose lookup outlived its bound, until
    /// that lookup returns. A peer reconnecting meanwhile gets it at once and forks no CLI, so
    /// a hung Tailscale never stacks lookups per address.
    private var outlived: [String: Verdict] = [:]
    private var lastLogged: String?

    /// Why the last device was refused, or let in unverified; nil once an owner's device
    /// connects. Main thread only; Remote Terminal's settings show it.
    @Published private(set) var status: String?

    init(whois: @escaping Lookup = { try DchOwnerCheck.tailscaleWhois($0, statusAnswered: $1) },
         allowWhenDown: @escaping @Sendable () -> Bool = { Preferences.remoteAllowWhenTailscaleDown },
         isLocalAddress: @escaping @Sendable (String) -> Bool = { DchOwnerCheck.isLocalAddress($0) },
         timeout: TimeInterval = DchOwnerCheck.timeout,
         ttl: TimeInterval = DchOwnerCheck.ttl,
         now: @escaping @Sendable () -> Date = { Date() },
         timerFired: @escaping @Sendable () -> Void = {}) {
        self.whois = whois
        self.allowWhenDown = allowWhenDown
        self.isLocalAddress = isLocalAddress
        self.timeout = timeout
        self.ttl = ttl
        self.now = now
        self.timerFired = timerFired
    }

    /// Decides `ip` off the caller's queue and calls `done` exactly once, within `timeout`.
    /// A whois that answers later is ignored. The production lookup ends within its status calls'
    /// share of the bound (at least `minStatusBound` each) plus whois's bound, and `outlived`
    /// covers that tail.
    func check(_ ip: String, done: @escaping @Sendable (Verdict) -> Void) {
        // This Mac's own addresses: a process of any local user can connect from them, and whois
        // would name this Mac, so its owner. Decided with no whois. Loopback is the address gate's:
        // it is never a tailnet peer, so production refuses it before this, and a test lets it
        // through `allowPeer` to be checked like a tailnet peer (dch serve's test-only bypass).
        let own = !ip.hasPrefix("127.") && isLocalAddress(ip)
        enum Start { case known(Verdict), joined, ask }
        let start: Start = lock.withLock {
            if let c = cache[ip] {
                if c.until > now() { return .known(c.verdict) }
                cache[ip] = nil
            }
            if own { return .known(.thisMac) }
            if let v = outlived[ip] { return .known(v) }
            // A phone's burst (handshake, watch, attach) asks once: later connections from an
            // address being checked wait for that check.
            // ponytail: per address only, no global cap: N new addresses at once fork N CLIs;
            // gate `ask` with a semaphore if a tailnet ever connects from many at once.
            if waiting[ip] != nil {
                waiting[ip]?.append(done)
                return .joined
            }
            waiting[ip] = [done]
            return .ask
        }
        switch start {
        case .joined:
            return
        case .known(let v):
            DispatchQueue.global(qos: .userInitiated).async { self.finish(ip, v, cache: false, only: done) }
            return
        case .ask:
            break
        }
        let claimed = OSAllocatedUnfairLock(initialState: false)
        let once: @Sendable (Verdict, Bool) -> Void = { v, keep in
            if claimed.withLock({ let first = !$0; $0 = true; return first }) { self.finish(ip, v, cache: keep, only: nil) }
        }
        // All guarded by `lock`: whether `tailscale status` answered, and whether the lookup
        // returned, so whether `outlived` is ours.
        final class Ran: @unchecked Sendable { var answered = false, returned = false }
        let lookup = Ran()
        let whois = whois, late = Verdict.unusable(Self.lateCause(timeout))
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result {
                try whois(ip) {
                    self.lock.withLock {
                        lookup.answered = true
                        // QA #640 F1: Tailscale is answering after all, so reconnects served the
                        // timer's relaxable verdict now get the refusal. Set only while this
                        // lookup runs, so it's ours.
                        if self.outlived[ip] != nil { self.outlived[ip] = late }
                    }
                }
            }
            let answered: Bool = self.lock.withLock {
                lookup.returned = true
                self.outlived[ip] = nil
                return lookup.answered
            }
            do {
                once(Self.decide(try result.get()), true)
            } catch let e as WhoisUnavailable {
                // Once status answered, Tailscale is answering: nothing after it is relaxed.
                once(answered ? .unusable(e.cause) : .unavailable(e.cause), false)
            } catch let e as WhoisUnusable {
                once(.unusable(e.cause), !e.askAgain)
            } catch {
                once(.unusable(String(describing: error)), true)
            }
        }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout) {
            // QA #635 F2: only a timeout before `tailscale status` answered is "not answering".
            // Read under the same lock as the `outlived` write (QA #640 F1).
            let v: Verdict = self.lock.withLock {
                let v = lookup.answered ? late : .unavailable(Self.timeoutCause(self.timeout))
                if !lookup.returned { self.outlived[ip] = v }
                return v
            }
            once(v, false)
            self.timerFired()
        }
    }

    /// The policy, in dch serve's order. A tagged host comes first: its Self.UserID is the shared
    /// tagged-devices identity, which every tagged peer also carries, so comparing ids there would
    /// admit them. A tagged peer is refused even when its id matches: some Tailscale versions
    /// report the tagging user's profile for a tagged node. This Mac's own node is refused before
    /// the id compare, which it would pass.
    static func decide(_ w: TailscaleWhois) -> Verdict {
        if w.host.tagged { return .taggedHost }
        guard let peer = w.peer else { return .unknownPeer }
        if peer.tagged { return .taggedPeer(peer) }
        // dch serve's rule: once this Mac's node id is known, a peer without one can't be told
        // apart from this Mac's own node.
        if !w.host.nodeID.isEmpty, peer.nodeID.isEmpty { return .unusable("Tailscale's whois answer has no device id") }
        if !peer.nodeID.isEmpty, peer.nodeID == w.host.nodeID { return .thisMac }
        // dch serve (serve.c serve_gate: `self_uid >= 0 && uid == self_uid`, else not_allowed):
        // a negative host id is no owner, so no peer matches it, a peer with the same id included.
        // A 0 id is a valid owner. A negative peer id can't equal a host id that passed this.
        guard w.host.userID >= 0 else { return .unusable("Tailscale gives this Mac no valid user id (\(w.host.userID))") }
        return peer.userID == w.host.userID ? .owner : .otherUser(peer)
    }

    /// `only`: the one caller of a cache hit; nil: everyone waiting on this address's check.
    private func finish(_ ip: String, _ decided: Verdict, cache keep: Bool, only: (@Sendable (Verdict) -> Void)?) {
        var v = decided
        if case .unavailable(let cause) = v, allowWhenDown() { v = .unverified(cause) }
        let text = Self.statusText(ip: ip, v)
        let (fresh, callers): (Bool, [@Sendable (Verdict) -> Void]) = lock.withLock {
            if keep, v.cacheable { cache[ip] = (v, now() + ttl) }
            defer { lastLogged = text }
            return (text != lastLogged, only.map { [$0] } ?? waiting.removeValue(forKey: ip) ?? [])
        }
        if fresh, let text {
            if v.allowed {
                log.info("dch server: \(text, privacy: .public)")
            } else {
                log.error("dch server: \(text, privacy: .public)")
            }
        }
        DispatchQueue.main.async { if self.status != text { self.status = text } }
        callers.forEach { $0(v) }
    }

    /// Seconds for user copy, at most one decimal: "0.7", not "0.666667".
    static func seconds(_ t: TimeInterval) -> String { String(format: "%g", (t * 10).rounded() / 10) }

    static func timeoutCause(_ t: TimeInterval) -> String {
        "Tailscale didn't answer within \(seconds(t)) s"
    }

    /// The bound passed after `tailscale status` answered: Tailscale is up, whois didn't finish.
    static func lateCause(_ t: TimeInterval) -> String {
        "Tailscale answered but didn't finish within \(seconds(t)) s"
    }

    /// The settings status line (and the log line) for a verdict; nil for the owner.
    static func statusText(ip: String, _ v: Verdict) -> String? {
        func who(_ n: TailscaleNode) -> String { n.name.isEmpty ? ip : "\(n.name) (\(ip))" }
        switch v {
        case .owner:
            return nil
        case .unverified(let cause):
            return "Let in \(ip) without verifying it: \(cause)."
        case .thisMac:
            return "Refused \(ip): it's this Mac's own address, which any app or user on this Mac can use."
        case .otherUser(let n):
            let login = n.login.isEmpty ? "" : ", \(n.login)"
            return "Refused \(who(n)): it belongs to another Tailscale user\(login)."
        case .taggedPeer(let n):
            return "Refused \(who(n)): tagged Tailscale devices aren't allowed."
        case .unknownPeer:
            return "Refused \(ip): Tailscale doesn't know this device."
        case .taggedHost:
            return "Refused \(ip): this Mac is a tagged Tailscale device, so no user owns it. "
                + "Log this Mac in to Tailscale as yourself."
        case .unavailable(let cause):
            return "Couldn't verify \(ip): \(cause). Turning on \"Allow when Tailscale isn't answering\" would let it in."
        case .unusable(let cause):
            // QA #635 r2 N4: no "Tailscale is answering" here, it read as contradicting a cause
            // like "Tailscale on this Mac is Stopped".
            return "Couldn't verify \(ip): \(cause). Refused; \"Allow when Tailscale isn't answering\" doesn't cover this."
        }
    }

    /// Whether `ip` is an IPv4 address on one of this Mac's interfaces.
    static func isLocalAddress(_ ip: String) -> Bool {
        var want = in_addr()
        guard inet_pton(AF_INET, ip, &want) == 1 else { return false }
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return false }
        defer { freeifaddrs(ifap) }
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = ptr {
            defer { ptr = cur.pointee.ifa_next }
            guard let sa = cur.pointee.ifa_addr, sa.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            let addr = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            if addr.s_addr == want.s_addr { return true }
        }
        return false
    }

    // MARK: - Production whois: the Tailscale CLI

    /// The App Store and standalone apps both ship the CLI as the app binary; Homebrew's and
    /// MacPorts' tailscale (open-source tailscaled) install it under their prefix. Not $PATH: an
    /// app's PATH has none of these. The CLI finds each variant's LocalAPI itself.
    static let cliCandidates = [
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
        "/opt/homebrew/bin/tailscale",
        "/usr/local/bin/tailscale",
        "/opt/local/bin/tailscale",
    ]

    /// The least a status call gets when the CLIs split the bound: a cold CLI launch needs it.
    static let minStatusBound: TimeInterval = 1

    /// Status, then whois, through the first CLI whose `tailscale status` answers Running (QA #635
    /// INFO 6: the App Store app can be installed with its daemon off while a Homebrew tailscaled
    /// runs). A CLI that isn't answering, or answers not Running, hands over to the next one. When
    /// none is Running: a not-Running answer wins (Tailscale is answering, never relaxed), else
    /// the first "not answering". QA #635 r2 N1: the installed CLIs split `bound` for their status
    /// calls (never under `minStatusBound`), so a hung first one still leaves a later Running one
    /// time to answer; whois gets the whole `bound`. `run(cli, args, bound)`, `isExecutable`
    /// and `bound` are the tests' seams.
    static func tailscaleWhois(_ ip: String, statusAnswered: () -> Void = {},
                               candidates: [String] = cliCandidates,
                               isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
                               bound: TimeInterval = timeout,
                               run: (String, [String], TimeInterval) -> TailscaleCLIOutput? = { runCLI($0, $1, bound: $2) }) throws -> TailscaleWhois {
        var notAnswering: WhoisUnavailable?, notRunning: WhoisUnusable?
        let installed = candidates.filter(isExecutable)
        // ponytail: worst case is now N x minStatusBound + bound when every CLI hangs.
        let statusBound = max(bound / Double(max(installed.count, 1)), min(bound, minStatusBound))
        for cli in installed {
            let host: TailscaleNode
            do {
                host = try Self.host(fromStatus: run(cli, ["status", "--json", "--peers=false"], statusBound), bound: statusBound)
            } catch let e as WhoisUnavailable {
                notAnswering = notAnswering ?? e
                continue
            } catch let e as WhoisUnusable where e.askAgain {
                statusAnswered()
                notRunning = notRunning ?? e
                continue
            }
            statusAnswered()
            return TailscaleWhois(host: host, peer: try peer(fromWhois: run(cli, ["whois", "--json", ip], bound), bound: bound))
        }
        throw notRunning ?? notAnswering ?? WhoisUnavailable(cause: "Tailscale isn't installed")
    }

    /// `tailscale status --json --peers=false` (nil: timed out). Anything short of an answer is
    /// "not answering"; `--json` exits 0 in every backend state, so a non-zero exit means the CLI
    /// couldn't reach tailscaled.
    static func host(fromStatus r: TailscaleCLIOutput?, bound: TimeInterval = timeout) throws -> TailscaleNode {
        guard let r else { throw WhoisUnavailable(cause: timeoutCause(bound)) }
        guard r.exit != -1 else { throw WhoisUnavailable(cause: "the Tailscale command couldn't start") }
        guard r.exit == 0 else { throw WhoisUnavailable(cause: "Tailscale isn't answering (\(firstLine(r.err)))") }
        return try parseHost(r.out)
    }

    /// `tailscale whois --json <ip>` once status answered (nil: timed out); nil for a peer
    /// Tailscale doesn't know. Every failure here is "unusable": Tailscale is answering.
    static func peer(fromWhois r: TailscaleCLIOutput?, bound: TimeInterval = timeout) throws -> TailscaleNode? {
        guard let r else { throw WhoisUnusable(cause: "tailscale whois didn't answer within \(seconds(bound)) s", askAgain: true) }
        guard r.exit != -1 else { throw WhoisUnusable(cause: "tailscale whois couldn't start", askAgain: true) }
        if r.exit == 0 { return try parsePeer(r.out) }
        if r.err.contains("peer not found") { return nil }
        throw WhoisUnusable(cause: "tailscale whois failed (\(firstLine(r.err)))")
    }

    private struct Status: Decodable {
        struct Node: Decodable {
            var ID: String?
            var UserID: Int64?
            var Tags: [String]?
            var HostName: String?
        }
        struct Profile: Decodable {
            var LoginName: String?
        }
        var BackendState: String?
        var me: Node?
        var User: [String: Profile]?
        enum CodingKeys: String, CodingKey { case BackendState, me = "Self", User }
    }

    private struct Whois: Decodable {
        struct PeerNode: Decodable {
            var StableID: String?
            var Name: String?
            var ComputedName: String?
            var Tags: [String]?
        }
        struct Profile: Decodable {
            var ID: Int64?
            var LoginName: String?
        }
        var Node: PeerNode?
        var UserProfile: Profile?
    }

    /// The shared identity tagged nodes report as their user.
    private static let taggedDevices = "tagged-devices"

    /// `tailscale status --json --peers=false`: the host must be Running with a user id. Not
    /// Running yet (Starting after wake, NeedsLogin, Stopped) is refused but not remembered, so
    /// the phone gets in as soon as Tailscale is up (QA #635 INFO 3).
    static func parseHost(_ data: Data) throws -> TailscaleNode {
        guard let s = try? JSONDecoder().decode(Status.self, from: data) else {
            throw WhoisUnusable(cause: "Tailscale's status couldn't be read")
        }
        guard s.BackendState == "Running" else {
            throw WhoisUnusable(cause: "Tailscale on this Mac is \(s.BackendState ?? "in no state"), not connected", askAgain: true)
        }
        guard let me = s.me, let id = me.UserID else {
            throw WhoisUnusable(cause: "Tailscale's status has no user for this Mac")
        }
        let login = s.User?[String(id)]?.LoginName ?? ""
        return TailscaleNode(userID: id, nodeID: me.ID ?? "", login: login, name: me.HostName ?? "",
                             tagged: !(me.Tags ?? []).isEmpty || login == taggedDevices)
    }

    /// `tailscale whois --json <ip>`: a user id and a Node (dch serve refuses either missing).
    static func parsePeer(_ data: Data) throws -> TailscaleNode {
        guard let w = try? JSONDecoder().decode(Whois.self, from: data), let id = w.UserProfile?.ID else {
            throw WhoisUnusable(cause: "Tailscale's whois answer couldn't be read")
        }
        guard let node = w.Node else { throw WhoisUnusable(cause: "Tailscale's whois answer names no device") }
        let login = w.UserProfile?.LoginName ?? ""
        return TailscaleNode(userID: id, nodeID: node.StableID ?? "", login: login,
                             name: node.ComputedName ?? node.Name ?? "",
                             tagged: !(node.Tags ?? []).isEmpty || login == taggedDevices)
    }

    private static func firstLine(_ s: String) -> String {
        let line = s.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return line.isEmpty ? "no message" : String(line.prefix(120))
    }

    private final class Exit: @unchecked Sendable {
        var err = ""
        var status: Int32 = -1
    }

    /// One CLI call, killed by its pid after `bound` (DchCommand.bounded); nil when it was.
    static func runCLI(_ cli: String, _ args: [String], bound: TimeInterval = timeout) -> TailscaleCLIOutput? {
        var vars = ProcessInfo.processInfo.environment
        vars["TAILSCALE_BE_CLI"] = "1"   // the app binary acts as the CLI, never the GUI
        let env = vars, exit = Exit()
        guard let out = DchCommand.bounded(bound, { onPid in
            let r = DchCommand.runCapturingBoth(args: args, env: env, path: cli, onPid: onPid)
            exit.err = r.err
            exit.status = r.status
            return r.out
        }) else { return nil }
        return TailscaleCLIOutput(exit: exit.status, out: out, err: exit.err)
    }
}
