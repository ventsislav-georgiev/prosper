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
    static let baseURLKey = ClaudeHarness.env.key

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
    /// #1893: Prosper's own ANTHROPIC_BASE_URL; none under XCTest, like the login probe (a test process inherits the agent
    /// shell's value, and any value is foreign to a pool on port 0).
    static func processBaseURL(env: [String: String] = ProcessInfo.processInfo.environment,
                               underXCTest: Bool = NSClassFromString("XCTestCase") != nil) -> String? {
        underXCTest ? nil : env[baseURLKey]
    }

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
    /// pool with no Claude account (QA #739 F1, #2009; `CCPoolStore.hasClaudeAccounts`): no change at all. `claude` gets ANTHROPIC_BASE_URL
    /// only: OQ-132 keeps the person's API key and tokens in the env (the proxy replaces the client's auth header, S10).
    /// `headroom` is not routed in v1 (#1200): it reads its upstream address in its own proxy process, shared by every
    /// headroom session, so it cannot be set per session; the environment stays as it is, credentials kept. Anything else
    /// (a shell, `direnv exec . claude`, a custom wrapper): no change. #1890: `inherited` is the ANTHROPIC_BASE_URL the
    /// session would start with; a foreign one (`foreignBaseURL`) is kept: no change.
    static func sessionEnv(command: [String], base: String, on: Bool, healthy: Bool, hasAccounts: Bool,
                           inherited: String? = nil) -> EnvDelta {
        guard on, healthy, hasAccounts, foreignBaseURL(inherited, base: base) == nil, let first = command.first else { return EnvDelta() }
        // #2004: the harness env rule (claude: ANTHROPIC_BASE_URL); `headroom` and anything else: no change.
        let rule = ClaudeHarness.env
        return rule.programs.contains(programName(first)) ? EnvDelta(set: [rule.key: base]) : EnvDelta()
    }

    /// #2009 (design #2003 section 9): the pool's provider name in Codex's config.
    static let codexProvider = "prosperpool"

    /// #2009: the words a routed `codex` gets after argv[0]: one `-c` per key (dotted path, TOML value), defining a pool
    /// provider over HTTP+SSE (no WebSocket: the proxy answers an upgrade 501), then choosing it. Only the loopback URL and
    /// this pool's port: never a token, an account id or a session id.
    static func codexArgs(port: UInt16) -> [String] {
        let p = "model_providers.\(codexProvider)."
        return ["-c", p + "name=\"Prosper pool\"",
                "-c", p + "base_url=\"\(baseURL(port: port))\(CCPoolCodexHarness.pathPrefix)\"",
                "-c", p + "wire_api=\"responses\"",
                "-c", p + "requires_openai_auth=true",
                "-c", p + "supports_websockets=false",
                "-c", "model_provider=\"\(codexProvider)\""]
    }

    /// #2009: a codex argv the pool leaves alone. Its own provider choice (`--profile`/`-p`, `-c model_provider...`, `-c
    /// model_providers...`, `--oss`) is kept. A `--remote` Codex runs on a server that ignores `-c` ("config overrides were
    /// provided and ignored"), so it is not routed either. A plain `codex` is routed: dch adds `--no-daemon` itself to a
    /// TUI launch (dch README, Codex 0.167 daemon), so `-c` holds without it. Words after `--` are the prompt, not read.
    static func codexKeepsOwn(_ argv: [String]) -> Bool {
        let words = argv.dropFirst().prefix { $0 != "--" }
        var config = false
        for w in words {
            defer { config = w == "-c" || w == "--config" }
            // a `-c`/`--config` value: the next word, `--config=V` or `-cV`
            let value = config ? w : w.hasPrefix("--config=") ? String(w.dropFirst(9)) : w.hasPrefix("-c") ? String(w.dropFirst(2)) : ""
            if value.hasPrefix("model_provider") || value.hasPrefix("profile=") { return true }
            if w == "--profile" || w.hasPrefix("--profile=") || w.hasPrefix("-p") || w == "--oss" || w == "--remote" || w.hasPrefix("--remote=") {
                return true
            }
        }
        return false
    }

    /// #2031: one of the pool's own `-c` values (codexArgs): its provider choice, exactly, or a key of its provider table
    /// (the base_url's port varies). A user's `model_provider="x"` or another table is not.
    static func isCodexPoolWord(_ w: String) -> Bool {
        w == "model_provider=\"\(codexProvider)\"" || w.hasPrefix("model_providers.\(codexProvider).")
    }

    /// #2031: a record argv without the pool's `-c` pairs, so codexKeepsOwn reads only the user's own words.
    static func codexWithoutPoolWords(_ argv: [String]) -> [String] {
        var out: [String] = [], skip = false
        for (i, w) in argv.enumerated() {
            if skip { skip = false; continue }
            if w == "-c", i + 1 < argv.count, isCodexPoolWord(argv[i + 1]) { skip = true; continue }
            out.append(w)
        }
        return out
    }

    /// #2031: the dch 1.189.0 --revive/--restart words for Codex records' argvs (one for a Resume or a row's Restart, the
    /// dir's Codex rows for Restart all), `words` the pool's current codexArgs ([]: routing off or no runtime).
    /// 1. a record that keeps its own provider (after the pool's words are removed): no flags, so dch never strips it;
    ///    for Restart all one such row means none for the whole dir (shortcut: dch takes one set per dir, so the pool rows
    ///    beside it keep their recorded, possibly stale words; upgrade when dch takes the words per record).
    /// 2. a record that carries the pool's provider: the drop (the stale port goes), plus one --codex-config per word.
    /// 3. a plain codex: the drop and the words while routing is on, else nothing (a `headroom wrap codex` is never routed).
    static func codexReviveFlags(_ argvs: [[String]], words: [String]) -> [String] {
        let own = argvs.map(codexWithoutPoolWords)
        if own.contains(where: codexKeepsOwn) { return [] }
        let routed = argvs.contains { a in zip(a, a.dropFirst()).contains { $0 == "-c" && $1 == "model_provider=\"\(codexProvider)\"" } }
        let w = own.allSatisfy({ $0.first.map(programName) == CCPoolCodexHarness.id }) ? words : []
        guard routed || !w.isEmpty else { return [] }
        return ["--codex-drop-provider"] + stride(from: 1, to: w.count, by: 2).flatMap { ["--codex-config", w[$0]] }
    }

    /// #2009: whether routed Codex sessions reach the pool. A routed spawn starts a wait; the next /codex request the proxy
    /// serves ends it. Still waiting 10 minutes after the first routed spawn since the last request: the pane says Codex
    /// is not reaching the pool. A clock is injected; no timer runs (the pane reads it when it redraws).
    /// Isolation: none; the lock guards the fields (spawns on the runner's queue, requests on the proxy's).
    final class CodexReach: @unchecked Sendable {
        static let silentAfter: Double = 600
        private let lock = NSLock()
        private let now: @Sendable () -> Double
        private var waitingSince: Double?, routed_ = 0, lastServed_: Double?
        /// The Codex sessions routed since launch, and when the last /codex request was served.
        var routedCount: Int { lock.withLock { routed_ } }
        var lastServed: Double? { lock.withLock { lastServed_ } }

        init(now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 }) { self.now = now }

        /// A Codex session was routed (the argv contributor, at its spawn).
        func routed() {
            let t = now()
            lock.withLock {
                routed_ += 1
                if waitingSince == nil { waitingSince = t }
            }
        }

        /// The proxy served a /codex request (once per request, never per chunk).
        func served() {
            let t = now()
            lock.withLock {
                lastServed_ = t
                waitingSince = nil
            }
        }

        var silent: Bool {
            let t = now()
            return lock.withLock { waitingSince.map { t - $0 >= Self.silentAfter } ?? false }
        }
    }

    /// spec 3.6 at spawn time: the person's toggle, the proxy's status and the pool's accounts, each read
    /// when a session starts. One value feeds both the spawn env (`contributor`) and the New session form's
    /// "via ccpool" hint (AgentNewSession.poolHint), so the two cannot disagree.
    /// Isolation: none; its closures run on the --spawn runner's queue (DispatchQueue.global) and on main.
    struct Routing: Sendable {
        var on: @Sendable () -> Bool
        var status: @Sendable () -> CCPoolService.Status
        /// Whether the pool lists a Claude account (#2009: CCPoolService passes `CCPoolStore.hasClaudeAccounts`).
        var hasAccounts: @Sendable () -> Bool
        /// #1890: the session's inherited ANTHROPIC_BASE_URL (InheritedBaseURL.read; `wait` only off main); nil: not known.
        var inherited: @Sendable (_ wait: Bool) -> String? = { _ in nil }

        /// #1892: Prosper's own ANTHROPIC_BASE_URL (the source of the spawn env); none by default.
        var own: @Sendable () -> String? = { nil }
        /// #2009: "Start new Codex sessions through the pool", whether the pool lists a Codex account, and where a routed
        /// spawn is counted. Off, none and nil by default.
        var codexOn: @Sendable () -> Bool = { false }
        var hasCodexAccounts: @Sendable () -> Bool = { false }
        var reach: CodexReach?

        /// #2009: the words a codex argv gets after argv[0] ([]: none). The toggle is read first, then the status and the
        /// store, as for Claude. Pure: the form's hint reads it too; the spawn's argvContributor also counts the routing.
        func codexWords(_ argv: [String]) -> [String] {
            guard let first = argv.first, programName(first) == CCPoolCodexHarness.id, codexOn(),
                  case .running(let port) = status(), hasCodexAccounts(), !codexKeepsOwn(argv) else { return [] }
            return codexArgs(port: port)
        }

        /// #2009: the --spawn argv contributor (runs on the runner's queue). A new session only: --revive takes no argv,
        /// and dch's `codex resume` keeps the original's `-c` words (cargv.c dch_codex_resume).
        var argvContributor: SessionArgvContributor {
            { [self] argv in
                let words = codexWords(argv)
                guard let first = argv.first, !words.isEmpty else { return argv }
                reach?.routed()
                return [first] + words + argv.dropFirst()
            }
        }

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

        /// #2031: dch 1.189.0's --revive/--restart words for Codex records (CCPool.codexReviveFlags), with the pool's current
        /// words while routing is on (codexWords of a plain codex). Read on the runner's queue, so at the revive.
        var reviveCodexFlags: CodexReviveFlags { { [self] argvs in codexReviveFlags(argvs, words: codexWords(["codex"])) } }

        /// #1499: the same delta as --revive flags (AgentIslandController.resume, dch 1.94.0); read on the runner's queue too.
        var reviveFlags: ReviveEnvFlags { { [self] argv in delta(argv, wait: true, env: nil).reviveFlags } }
    }
}
