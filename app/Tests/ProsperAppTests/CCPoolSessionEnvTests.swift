import XCTest
@testable import ProsperApp

/// #871 spec 3.6 + errata C8: the env a new Agent Session gets. Pure; no process is spawned.
final class CCPoolSessionEnvTests: XCTestCase {
    private let base = CCPool.baseURL(port: 41234)
    private let creds = ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN"]

    private func env(_ argv: [String], on: Bool = true, healthy: Bool = true) -> CCPool.EnvDelta {
        CCPool.sessionEnv(command: argv, base: base, on: on, healthy: healthy)
    }

    func testCCPoolSessionEnvTable() {
        XCTAssertEqual(base, "http://127.0.0.1:41234")
        let claude = CCPool.EnvDelta(set: ["ANTHROPIC_BASE_URL": base], remove: creds)
        let headroom = CCPool.EnvDelta(set: ["ANTHROPIC_TARGET_API_URL": base], remove: creds)
        let rows: [(String, [String], Bool, Bool, CCPool.EnvDelta)] = [
            ("claude", ["claude"], true, true, claude),
            ("claude with args", ["claude", "--resume", "x"], true, true, claude),
            ("absolute claude", ["/opt/bin/claude"], true, true, claude),
            ("headroom", ["headroom", "proxy"], true, true, headroom),
            ("absolute headroom", ["/usr/local/bin/headroom"], true, true, headroom),
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
    }

    func testCCPoolSessionEnvAppliedStripsCredentialsOnlyWhenRouting() {
        let parent = ["ANTHROPIC_API_KEY": "dummy-key", "ANTHROPIC_AUTH_TOKEN": "dummy-auth", "PATH": "/usr/bin",
                      "ANTHROPIC_BASE_URL": "http://elsewhere.invalid"]
        let routed = env(["claude"]).applied(to: parent)
        XCTAssertEqual(routed, ["PATH": "/usr/bin", "ANTHROPIC_BASE_URL": base])
        let head = env(["headroom"]).applied(to: parent)
        XCTAssertEqual(head["ANTHROPIC_TARGET_API_URL"], base)
        XCTAssertEqual(head["ANTHROPIC_BASE_URL"], "http://elsewhere.invalid", "headroom keeps its own base URL")
        XCTAssertNil(head["ANTHROPIC_API_KEY"])
        XCTAssertNil(head["ANTHROPIC_AUTH_TOKEN"])
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
}
