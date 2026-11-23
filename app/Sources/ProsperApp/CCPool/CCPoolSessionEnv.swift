import Foundation

/// #871 spec 3.6 + errata C8: which env a new Agent Session gets when "Start new Claude sessions
/// through the pool" is on. Pure; the spawn path applies the delta (P2b).
enum CCPool {
    /// #871 P2b-2: the --spawn path applies `Routing` (AgentIslandController.sessionEnvContributors), so
    /// the pane shows the "Start new Claude sessions through the pool" row.
    static let routingWired = true

    /// What to change in a spawned session's environment. Empty: leave it as it is.
    struct EnvDelta: Equatable, Sendable {
        var set: [String: String] = [:]
        var remove: [String] = []
        var isEmpty: Bool { self.set.isEmpty && remove.isEmpty }

        func applied(to env: [String: String]) -> [String: String] {
            var out = env
            for k in remove { out.removeValue(forKey: k) }
            out.merge(self.set) { _, new in new }
            return out
        }

        /// #1499: the same change as dch 1.94.0 --revive flags: `--unset K` per removal (in order), then `--env K=V` per set
        /// (by key). Only names and the set values go in argv: the pool's set is its loopback URL, never a credential.
        var reviveFlags: [String] {
            remove.flatMap { ["--unset", $0] } + self.set.sorted { $0.key < $1.key }.flatMap { ["--env", "\($0.key)=\($0.value)"] }
        }
    }

    static func baseURL(port: UInt16) -> String { "http://127.0.0.1:\(port)" }

    /// #1890: the variable a session's own upstream lives in.
    static let baseURLKey = "ANTHROPIC_BASE_URL"

    /// #1890 (operator 2026-11-23): a session whose env already points ANTHROPIC_BASE_URL anywhere other than this pool
    /// is left alone. `inherited` is that value (nil or "": none). Returns it when it is foreign, nil when the pool may
    /// route (none, or this pool's own URL; a trailing "/" is the same URL).
    static func foreignBaseURL(_ inherited: String?, base: String) -> String? {
        guard let inherited, !inherited.isEmpty else { return nil }
        let trim = { (s: String) in String(s.reversed().drop(while: { $0 == "/" }).reversed()) }
        return trim(inherited) == trim(base) ? nil : inherited
    }

    /// #1890: a foreign URL as the pane may draw it: scheme, host and port only, through OutsideText, so a path, query or
    /// user info that could carry a token is never shown. nil when it has no host.
    static func shownBaseURL(_ url: String) -> String? {
        guard let c = URLComponents(string: url), let host = c.host, !host.isEmpty else { return nil }
        return OutsideText.shown((c.scheme.map { "\($0)://" } ?? "") + host + (c.port.map { ":\($0)" } ?? ""), max: 120)
    }

    /// #1890: the ANTHROPIC_BASE_URL a new session really starts with. dch runs the person's login shell for --spawn and
    /// --revive (#1499, AgentIslandController.resume), so an rc file's export wins over Prosper's env, and that shell
    /// inherits Prosper's env, so the login env's value covers both. Probed at most once when it works (one login shell,
    /// bounded by LoginPath.timeout). Isolation: none; the lock guards the two fields.
    final class InheritedBaseURL: @unchecked Sendable {
        /// The login env's value: "" when unset there, nil when the probe failed.
        typealias Probe = @Sendable () -> String?
        /// The production probe; none under XCTest (tests never run a login shell).
        static var live: Probe? {
            let login: Probe = { LoginPath.value(of: CCPool.baseURLKey) }
            return NSClassFromString("XCTestCase") == nil ? login : nil
        }
        private let lock = NSLock()
        private var known: String?
        private var started = false
        private let probe: Probe, process: String?, landed: @Sendable () -> Void

        /// `process`: Prosper's own value, the answer until the probe lands. `landed`: after a background probe that worked.
        init(probe: @escaping Probe, process: String?, landed: @escaping @Sendable () -> Void = {}) {
            self.probe = probe
            self.process = process
            self.landed = landed
        }

        /// `wait` true (the runner's queue only): runs the probe now when nothing is known. false (main: the pane line,
        /// the form's hint) never blocks: the first such read starts one background probe; a failed one is not retried
        /// from here (no login shell per keystroke), only by the next spawn's read.
        func read(wait: Bool) -> String? {
            if let v = lock.withLock({ known }) { return v }
            if wait { return run() ?? process }
            start()
            return process
        }

        /// #1891: the background probe, once (off the caller's thread; a no-op after the first call). CCPoolRuntime.init
        /// calls it so a spawn finds the login env known; read(wait: false) calls it too.
        func start() {
            let first = lock.withLock { () -> Bool in
                defer { started = true }
                return !started
            }
            if first { DispatchQueue.global(qos: .utility).async { [self] in if run() != nil { landed() } } }
        }

        private func run() -> String? {
            guard let v = probe() else { return nil }
            lock.withLock { known = v }
            return v
        }
    }

    /// The program name of a command word the way dch reads it: the text after the last "/", or
    /// the whole word. Not NSString.lastPathComponent, which drops a trailing "/" (QA #726 F1):
    /// "claude/" names no program here.
    static func programName(_ word: String) -> String {
        word.lastIndex(of: "/").map { String(word[word.index(after: $0)...]) } ?? word
    }

    /// `command` is the user's command value (argv) BEFORE any login-shell wrap: the wrapped argv
    /// starts with the shell and would never route (errata C8). Off, the proxy not healthy, or a
    /// pool with no account (QA #739 F1; `CCPoolStore.hasAccounts`): no change at all. `claude` gets ANTHROPIC_BASE_URL
    /// only: OQ-132 keeps the person's API key and tokens in the env (the proxy replaces the client's auth header, S10).
    /// `headroom` is not routed in v1 (#1200): it reads its upstream address in its own proxy process, shared by every
    /// headroom session, so it cannot be set per session; the environment stays as it is, credentials kept. Anything else
    /// (a shell, `direnv exec . claude`, a custom wrapper): no change. #1890: `inherited` is the ANTHROPIC_BASE_URL the
    /// session would start with; a foreign one (`foreignBaseURL`) is kept: no change.
    static func sessionEnv(command: [String], base: String, on: Bool, healthy: Bool, hasAccounts: Bool,
                           inherited: String? = nil) -> EnvDelta {
        guard on, healthy, hasAccounts, foreignBaseURL(inherited, base: base) == nil, let first = command.first else { return EnvDelta() }
        switch programName(first) {
        case "claude": return EnvDelta(set: ["ANTHROPIC_BASE_URL": base])
        case "headroom": return EnvDelta()
        default: return EnvDelta()
        }
    }

    /// spec 3.6 at spawn time: the person's toggle, the proxy's status and the pool's accounts, each read
    /// when a session starts. One value feeds both the spawn env (`contributor`) and the New session form's
    /// "via ccpool" hint (AgentNewSession.poolHint), so the two cannot disagree.
    /// Isolation: none; its closures run on the --spawn runner's queue (DispatchQueue.global) and on main.
    struct Routing: Sendable {
        var on: @Sendable () -> Bool
        var status: @Sendable () -> CCPoolService.Status
        var hasAccounts: @Sendable () -> Bool
        /// #1890: the session's inherited ANTHROPIC_BASE_URL (InheritedBaseURL.read; `wait` only off main); nil: not known.
        var inherited: @Sendable (_ wait: Bool) -> String? = { _ in nil }

        /// #1892: Prosper's own ANTHROPIC_BASE_URL (the source of the spawn env); none by default.
        var own: @Sendable () -> String? = { nil }

        /// The toggle is read first: off, neither the status nor the store is read, so turning it off holds
        /// for the next spawn whatever they would say. Only `.running` routes (stopped, held, failed: no).
        /// Main's form hint: never waits for the login shell.
        /// #1892: checks Prosper's own value too, as the spawn does, so the hint never disagrees with it.
        func delta(_ argv: [String]) -> EnvDelta { delta(argv, wait: false, env: own().map { [baseURLKey: $0] }) }

        /// #1890: `env` is the spawn's own env; #1891: a foreign value in it keeps the session unrouted whatever the login env says.
        func delta(_ argv: [String], wait: Bool, env: [String: String]?) -> EnvDelta {
            guard on(), case .running(let port) = status() else { return EnvDelta() }
            // #1891: foreign if either the login env's value or the spawn env's is foreign (a known login "" never hides one).
            let base = baseURL(port: port)
            let foreign = foreignBaseURL(inherited(wait), base: base) ?? foreignBaseURL(env?[baseURLKey], base: base)
            return sessionEnv(command: argv, base: base, on: true, healthy: true, hasAccounts: hasAccounts(), inherited: foreign)
        }

        /// spec 6.1's ccpool member. Called on the runner's queue, never main. An empty delta returns `env`
        /// unchanged, byte for byte.
        var contributor: SessionEnvContributor { { [self] argv, env in delta(argv, wait: true, env: env).applied(to: env) } }

        /// #1499: the same delta as --revive flags (AgentIslandController.resume, dch 1.94.0); read on the runner's queue too.
        var reviveFlags: ReviveEnvFlags { { [self] argv in delta(argv, wait: true, env: nil).reviveFlags } }
    }
}
