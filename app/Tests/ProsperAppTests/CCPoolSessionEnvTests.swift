import XCTest
@testable import ProsperApp

/// #871 spec 3.6 + errata C8: the env a new Agent Session gets. Pure; no process is spawned.
final class CCPoolSessionEnvTests: XCTestCase {
    private let base = CCPool.baseURL(port: 41234)

    private func env(_ argv: [String], on: Bool = true, healthy: Bool = true, hasAccounts: Bool = true) -> CCPool.EnvDelta {
        CCPool.sessionEnv(command: argv, base: base, on: on, healthy: healthy, hasAccounts: hasAccounts)
    }

    func testCCPoolSessionEnvTable() {
        XCTAssertEqual(base, "http://127.0.0.1:41234")
        // OQ-132: the base URL only; nothing is removed.
        let claude = CCPool.EnvDelta(set: ["ANTHROPIC_BASE_URL": base])
        let rows: [(String, [String], Bool, Bool, CCPool.EnvDelta)] = [
            ("claude", ["claude"], true, true, claude),
            ("claude with args", ["claude", "--resume", "x"], true, true, claude),
            ("absolute claude", ["/opt/bin/claude"], true, true, claude),
            // #1200: headroom's upstream is read in its own shared proxy, so it is never routed.
            ("headroom", ["headroom"], true, true, .init()),
            ("absolute headroom", ["/usr/local/bin/headroom"], true, true, .init()),
            ("headroom wrap claude", ["headroom", "wrap", "claude"], true, true, .init()),
            ("a shell", ["/bin/zsh", "-l"], true, true, .init()),
            ("login-shell wrapped claude", ["/bin/zsh", "-lc", "claude --resume x"], true, true, .init()),
            // argv[0] is direnv: no change (the report says so; P2b documents it in the pane).
            ("direnv exec . claude", ["direnv", "exec", ".", "claude"], true, true, .init()),
            ("trailing slash is not claude", ["claude/"], true, true, .init()),
            ("trailing slash, absolute", ["/opt/bin/claude/"], true, true, .init()),
            ("a longer name", ["claude-code"], true, true, .init()),
            ("a prefix", ["xclaude"], true, true, .init()),
            ("empty command", [], true, true, .init()),
            ("off", ["claude"], false, true, .init()),
            ("proxy down", ["claude"], true, false, .init()),
            ("off and down, headroom", ["headroom"], false, false, .init()),
        ]
        for (name, argv, on, healthy, want) in rows {
            XCTAssertEqual(env(argv, on: on, healthy: healthy), want, name)
        }
        XCTAssertTrue(env(["claude"], on: false).isEmpty)
        // QA #739 F1: an empty pool never routes, whatever else holds.
        for argv in [["claude"], ["headroom"]] {
            XCTAssertTrue(env(argv, hasAccounts: false).isEmpty, "\(argv)")
        }
    }

    /// OQ-132 (#1570): a routed claude keeps the API key, the auth token and the OAuth token; only the base URL changes.
    func testCCPoolSessionEnvAppliedKeepsCredentialsWhenRouting() {
        let parent = ["ANTHROPIC_API_KEY": "dummy-key", "ANTHROPIC_AUTH_TOKEN": "dummy-auth", "PATH": "/usr/bin",
                      "ANTHROPIC_BASE_URL": "http://elsewhere.invalid", "CLAUDE_CODE_OAUTH_TOKEN": "dummy-oauth"]
        let routed = env(["claude"]).applied(to: parent)
        XCTAssertEqual(routed, ["ANTHROPIC_API_KEY": "dummy-key", "ANTHROPIC_AUTH_TOKEN": "dummy-auth", "PATH": "/usr/bin",
                                "ANTHROPIC_BASE_URL": base, "CLAUDE_CODE_OAUTH_TOKEN": "dummy-oauth"])
        XCTAssertEqual(Set(parent.keys.filter { routed[$0] != parent[$0] }), ["ANTHROPIC_BASE_URL"], "only the base URL is touched")
        XCTAssertEqual(env(["claude"]).remove, [], "nothing is removed")
        for argv in [["headroom"], ["/usr/local/bin/headroom"], ["headroom", "wrap", "claude"]] {
            XCTAssertEqual(env(argv).applied(to: parent), parent, "headroom is never routed: credentials kept, \(argv)")
        }
        XCTAssertEqual(env(["claude"], hasAccounts: false).applied(to: parent), parent, "empty pool: nothing changes")
        XCTAssertEqual(env(["claude"], healthy: false).applied(to: parent), parent, "proxy down: nothing changes")
        XCTAssertEqual(env(["bash"]).applied(to: parent), parent, "not claude: nothing changes")
    }

    // Errata C8: the rule reads the user's command value before any wrap. Given the form's command,
    // a session still routes however the final argv is built (dch's --spawn prefix, a login-shell
    // wrap); given the final argv instead, it never would.
    func testCCPoolWrappedSpawnStillRoutes() {
        let command = "claude --resume x"
        let user = AgentNewSession.argv(command, shell: "/bin/zsh")
        XCTAssertEqual(user.first, "claude")
        let delta = env(user)
        XCTAssertEqual(delta.set["ANTHROPIC_BASE_URL"], base, "the user's command routes")

        let dchArgv = AgentIsland.newSessionArgs(folder: "/tmp/p", command: user, taken: [])
        let wrapped = ["/bin/zsh", "-lc", AgentIsland.shellLine(user)]
        XCTAssertTrue(env(dchArgv).isEmpty, "the --spawn argv would never route")
        XCTAssertTrue(env(wrapped).isEmpty, "the wrapped argv would never route")
        // The delta is applied to the spawn env, whatever argv it ends up running.
        XCTAssertEqual(delta.applied(to: AgentIsland.spawnEnv(["PATH": "/usr/bin"]))["ANTHROPIC_BASE_URL"], base)
        XCTAssertTrue(env(AgentNewSession.argv("", shell: "/bin/zsh")).isEmpty, "an empty command is the login shell")
    }

    // P2b-2: CCPool.Routing, the spawn-time reads. Only `.running` routes, on its own port; every other
    // status, the toggle off or an empty pool: no change.
    func testCCPoolRoutingDeltaByStatus() {
        func routing(_ on: Bool, _ status: CCPoolService.Status, _ accounts: Bool) -> CCPool.Routing {
            CCPool.Routing(on: { on }, status: { status }, hasAccounts: { accounts })
        }
        let claude = CCPool.EnvDelta(set: ["ANTHROPIC_BASE_URL": "http://127.0.0.1:41234"])
        XCTAssertEqual(routing(true, .running(port: 41234), true).delta(["claude"]), claude)
        XCTAssertEqual(routing(true, .running(port: 41235), true).delta(["claude"]).set, ["ANTHROPIC_BASE_URL": "http://127.0.0.1:41235"])
        let none: [(String, CCPool.Routing)] = [
            ("off", routing(false, .running(port: 41234), true)),
            ("stopped", routing(true, .stopped, true)),
            ("held by another ccpool", routing(true, .heldByCCPool(pid: 4242), true)),
            ("held by another program", routing(true, .heldByOther, true)),
            ("failed", routing(true, .failed("x"), true)),
            ("no accounts", routing(true, .running(port: 41234), false)),
        ]
        for (name, r) in none {
            XCTAssertEqual(r.delta(["claude"]), CCPool.EnvDelta(), name)
            XCTAssertEqual(r.delta(["headroom"]), CCPool.EnvDelta(), name)
        }
    }

    // MARK: - #1890: a session's own ANTHROPIC_BASE_URL

    /// Mutant foreign-url-routed: a foreign inherited base URL empties the delta for claude; this pool's own URL (with or
    /// without a trailing "/"), none and "" route.
    func testCCPoolForeignBaseURLEmptiesTheDelta() {
        let claude = CCPool.EnvDelta(set: ["ANTHROPIC_BASE_URL": base])
        func delta(_ inherited: String?) -> CCPool.EnvDelta {
            CCPool.sessionEnv(command: ["claude"], base: base, on: true, healthy: true, hasAccounts: true, inherited: inherited)
        }
        XCTAssertEqual(delta("http://127.0.0.1:8787"), CCPool.EnvDelta(), "headroom's port: foreign")
        XCTAssertEqual(delta("https://gateway.example.invalid/v1"), CCPool.EnvDelta(), "a remote gateway: foreign")
        XCTAssertEqual(delta("http://127.0.0.1:41235"), CCPool.EnvDelta(), "another port: foreign")
        XCTAssertEqual(delta(base), claude, "this pool's own URL: routed (a no-op set)")
        XCTAssertEqual(delta(base + "/"), claude, "a trailing slash is the same URL")
        XCTAssertEqual(delta(nil), claude, "none: routed")
        XCTAssertEqual(delta(""), claude, "empty: routed")
        XCTAssertTrue(CCPool.foreignBaseURL("http://127.0.0.1:8787", base: base) == "http://127.0.0.1:8787")
        XCTAssertTrue(CCPool.foreignBaseURL(base, base: base) == nil)

        let foreign = CCPool.Routing(on: { true }, status: { .running(port: 41234) }, hasAccounts: { true })
        let parent = ["PATH": "/usr/bin", "ANTHROPIC_BASE_URL": "http://127.0.0.1:8787", "ANTHROPIC_API_KEY": "dummy-key"]
        XCTAssertEqual(foreign.contributor(["claude"], parent), parent, "the spawn env's own URL: unchanged, byte for byte")
        XCTAssertEqual(foreign.contributor(["claude"], ["PATH": "/usr/bin"])["ANTHROPIC_BASE_URL"], base)
    }

    /// The pane line names the foreign URL by scheme, host and port only: no user info, path or query (a token's places).
    func testCCPoolForeignBaseURLLineShowsHostAndPortOnly() {
        XCTAssertEqual(CCPoolPane.foreignLine("http://127.0.0.1:8787"),
                       "Sessions keep their own ANTHROPIC_BASE_URL (http://127.0.0.1:8787): not routed")
        XCTAssertEqual(CCPoolPane.foreignLine("https://user:secret-token@gateway.example.invalid:8443/v1/key-abc?token=xyz#frag"),
                       "Sessions keep their own ANTHROPIC_BASE_URL (https://gateway.example.invalid:8443): not routed")
        XCTAssertEqual(CCPoolPane.foreignLine("not a url"), "Sessions keep their own ANTHROPIC_BASE_URL: not routed")
    }

    /// The login probe runs once when it works, never on a main read's own thread, and a main read never retries a failed
    /// background probe (no login shell per keystroke); only a spawn's waiting read does. Counts calls, not time.
    func testCCPoolInheritedBaseURLProbesOnceAndNeverPerRead() {
        final class Probe: @unchecked Sendable {
            let lock = NSLock()
            var calls = 0, answer: String?
            let ran = DispatchSemaphore(value: 0)
            func run() -> String? {
                defer { ran.signal() }
                return lock.withLock { calls += 1; return answer }
            }
            var count: Int { lock.withLock { calls } }
        }
        let failing = Probe()
        let landed = DispatchSemaphore(value: 0)
        let f = CCPool.InheritedBaseURL(probe: { failing.run() }, process: "http://process.example.invalid") { landed.signal() }
        XCTAssertEqual(f.read(wait: false), "http://process.example.invalid", "before the probe: Prosper's own value")
        XCTAssertEqual(failing.ran.wait(timeout: .now() + 5), .success)
        for _ in 0..<50 { XCTAssertEqual(f.read(wait: false), "http://process.example.invalid") }
        XCTAssertEqual(failing.count, 1, "a failed background probe is not retried by main reads")
        XCTAssertEqual(landed.wait(timeout: .now() + 0.2), .timedOut, "a failed probe redraws nothing")
        XCTAssertEqual(f.read(wait: true), "http://process.example.invalid")
        XCTAssertEqual(failing.count, 2, "a spawn's read retries")

        let working = Probe()
        working.answer = ""
        let w = CCPool.InheritedBaseURL(probe: { working.run() }, process: "http://process.example.invalid") { landed.signal() }
        _ = w.read(wait: false)
        XCTAssertEqual(landed.wait(timeout: .now() + 5), .success, "a probe that worked redraws")
        for _ in 0..<50 { XCTAssertEqual(w.read(wait: false), "", "the login env says unset") }
        XCTAssertEqual(w.read(wait: true), "")
        XCTAssertEqual(working.count, 1, "probed once")
    }
}
