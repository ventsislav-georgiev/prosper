import XCTest
@testable import ProsperApp

/// #2009 (design #2003 phase 6, section 9): a new `codex` session reaches the pool by argv `-c` words, and the pane says
/// when routed Codex sessions never reach it. Pure values, an injected clock and an unstarted service: no process runs,
/// no port is bound or dialled, no ~/.codex is read.
final class CCPoolCodexRoutingTests: XCTestCase {
    private static let port: UInt16 = 41234
    /// A typed --no-daemon (dch adds it itself to a plain `codex`; both route).
    private static let codex = ["codex", "--no-daemon"]

    /// The exact words, in order: one `-c` per key, TOML-quoted strings, the loopback URL with this pool's port only.
    private static let words = [
        "-c", #"model_providers.prosperpool.name="Prosper pool""#,
        "-c", #"model_providers.prosperpool.base_url="http://127.0.0.1:41234/codex""#,
        "-c", #"model_providers.prosperpool.wire_api="responses""#,
        "-c", "model_providers.prosperpool.requires_openai_auth=true",
        "-c", "model_providers.prosperpool.supports_websockets=false",
        "-c", #"model_provider="prosperpool""#,
    ]

    private func routing(codexOn: Bool = true, status: CCPoolService.Status = .running(port: CCPoolCodexRoutingTests.port),
                         codexAccounts: Bool = true, claudeOn: Bool = true, reach: CCPool.CodexReach? = nil) -> CCPool.Routing {
        CCPool.Routing(on: { claudeOn }, status: { status }, hasAccounts: { true },
                       codexOn: { codexOn }, hasCodexAccounts: { codexAccounts }, reach: reach)
    }

    func testCodexArgsAreTheExactWordsInOrder() {
        XCTAssertEqual(CCPool.codexArgs(port: Self.port), Self.words)
        XCTAssertEqual(routing().codexWords(Self.codex), Self.words)
        XCTAssertEqual(routing().argvContributor(Self.codex + ["-m", "gpt-5"]), ["codex"] + Self.words + ["--no-daemon", "-m", "gpt-5"],
                       "the words go right after argv[0]; the rest is kept in order")
        XCTAssertEqual(routing().argvContributor(["/opt/bin/codex", "--no-daemon"]), ["/opt/bin/codex"] + Self.words + ["--no-daemon"])
    }

    /// Only codex gets words; claude keeps its env routing and no argv; anything else: nothing.
    func testOnlyCodexGetsWords() {
        let r = routing()
        let rows: [(String, [String], Bool)] = [
            ("codex", Self.codex, true),
            ("absolute codex", ["/opt/bin/codex", "--no-daemon"], true),
            ("claude", ["claude"], false),
            ("bash", ["/bin/bash", "-l"], false),
            ("shell running codex", ["/bin/zsh", "-lc", "codex --no-daemon"], false),
            ("a prefix", ["xcodex", "--no-daemon"], false),
            ("trailing slash", ["codex/", "--no-daemon"], false),
            ("empty", [], false),
        ]
        for (name, argv, routed) in rows {
            XCTAssertEqual(r.codexWords(argv), routed ? Self.words : [], name)
            XCTAssertEqual(r.argvContributor(argv), routed ? [argv[0]] + Self.words + argv.dropFirst() : argv, name)
        }
        XCTAssertEqual(r.delta(["claude"]), CCPool.EnvDelta(set: ["ANTHROPIC_BASE_URL": "http://127.0.0.1:41234"]), "Claude's env as today")
        XCTAssertTrue(r.delta(Self.codex).isEmpty, "codex gets no env change")
    }

    /// A Codex with its own provider choice keeps it; one that runs --remote is not routed. A plain `codex` (no
    /// --no-daemon: dch adds it at launch, README "Codex 0.167 and later") is routed.
    func testForeignMarkersGetNothing() {
        let r = routing()
        let rows: [(String, [String])] = [
            ("--profile", Self.codex + ["--profile", "work"]),
            ("--profile=", Self.codex + ["--profile=work"]),
            ("-p", Self.codex + ["-p", "work"]),
            ("-c model_provider", Self.codex + ["-c", "model_provider=x"]),
            ("-c model_providers.", Self.codex + ["-c", #"model_providers.x.base_url="http://example.invalid""#]),
            ("--config model_provider", Self.codex + ["--config", "model_provider=x"]),
            ("--config=model_provider", Self.codex + ["--config=model_provider=x"]),
            ("-cmodel_provider", Self.codex + ["-cmodel_provider=x"]),
            ("-c profile=", Self.codex + ["-c", "profile=work"]),
            ("--oss", Self.codex + ["--oss"]),
            ("--remote", Self.codex + ["--remote", "ws://example.invalid:1"]),
            ("--remote=", Self.codex + ["--remote=ws://example.invalid:1"]),
            ("plain codex --remote", ["codex", "--remote", "ws://x"]),
            ("plain codex --remote=", ["codex", "--remote=ws://x"]),
        ]
        for (name, argv) in rows {
            XCTAssertTrue(CCPool.codexKeepsOwn(argv), name)
            XCTAssertEqual(r.codexWords(argv), [], name)
            XCTAssertEqual(r.argvContributor(argv), argv, name)
        }
        // Plain codex, a typed --no-daemon, other -c keys and a marker inside the prompt: routed.
        let routed: [[String]] = [["codex"], ["codex", "--no-daemon"], ["codex", "--", "--no-daemon"], ["codex", "-m", "gpt-5"],
                                  Self.codex + ["-c", "model=\"gpt-5\""], Self.codex + ["-m", "gpt-5"], Self.codex + ["--", "-p", "--remote"]]
        for argv in routed {
            XCTAssertFalse(CCPool.codexKeepsOwn(argv), "\(argv)")
            XCTAssertEqual(r.codexWords(argv), Self.words, "\(argv)")
            XCTAssertEqual(r.argvContributor(argv), [argv[0]] + Self.words + argv.dropFirst(), "\(argv)")
        }
        XCTAssertEqual(r.argvContributor(["codex"]), ["codex"] + Self.words, "plain codex: the words and nothing else")
    }

    func testGatesToggleStatusAndCodexAccounts() {
        XCTAssertEqual(routing(codexOn: false).codexWords(Self.codex), [], "toggle off")
        XCTAssertEqual(routing(status: .stopped).codexWords(Self.codex), [], "pool not running")
        XCTAssertEqual(routing(codexAccounts: false).codexWords(Self.codex), [], "no Codex account")
        XCTAssertEqual(routing(claudeOn: false).codexWords(Self.codex), Self.words, "the Claude toggle is not Codex's")
        XCTAssertEqual(routing(codexOn: false).delta(["claude"]).set["ANTHROPIC_BASE_URL"], "http://127.0.0.1:41234",
                       "the Codex toggle is not Claude's")
        // The default Routing (the Claude rows' own) never routes codex.
        let plain = CCPool.Routing(on: { true }, status: { .running(port: Self.port) }, hasAccounts: { true })
        XCTAssertEqual(plain.codexWords(Self.codex), [])
        // The toggle is stored like Claude's: never set reads on, a stored false stands.
        let d = XCTestDefaults(suiteName: "prosper-ccpool-codexroute-\(UUID().uuidString)")!
        XCTAssertTrue(CCPoolPaneModel.codexRouteValue(in: d))
        d.set(false, forKey: CCPoolPaneModel.codexRouteKey)
        XCTAssertFalse(CCPoolPaneModel.codexRouteValue(in: d))
        XCTAssertTrue(CCPoolPaneModel.routeValue(in: d), "Claude's key is a different one")
    }

    /// The form's hint says "via ccpool" exactly when the spawn would add the words.
    @MainActor
    func testHintFollowsTheWords() {
        let argvs: [[String]] = [Self.codex, ["codex"], Self.codex + ["-p", "x"], ["bash"]]
        for r in [routing(), routing(codexOn: false), routing(status: .stopped), routing(codexAccounts: false)] {
            for argv in argvs {
                XCTAssertEqual(AgentNewSession.poolHint(argv, routing: r) != nil, !r.codexWords(argv).isEmpty, "\(argv)")
            }
        }
        XCTAssertEqual(AgentNewSession.poolHint(Self.codex, routing: routing()), AgentNewSession.viaPoolHint)
        XCTAssertEqual(AgentNewSession.poolHint(["claude"], routing: routing(codexOn: false)), AgentNewSession.viaPoolHint, "Claude's hint as today")
    }

    /// Only the spawn contributor counts a routed session; the hint's read never does.
    func testOnlyTheContributorCountsARoutedSpawn() {
        let reach = CCPool.CodexReach(now: { 0 })
        let r = routing(reach: reach)
        _ = r.codexWords(Self.codex)
        _ = r.argvContributor(["claude"])
        _ = r.argvContributor(Self.codex + ["-p", "x"])
        XCTAssertEqual(reach.routedCount, 0)
        _ = r.argvContributor(Self.codex)
        XCTAssertEqual(reach.routedCount, 1)
    }

    func testDetectorRoutedAndSilentForTenMinutes() {
        let clock = CCPoolTestClock(1_000)
        let reach = CCPool.CodexReach(now: { clock.now })
        XCTAssertFalse(reach.silent, "not routed: no caption")
        clock.advance(3_600)
        XCTAssertFalse(reach.silent, "not routed, however long: no caption")
        reach.routed()
        clock.advance(599)
        XCTAssertFalse(reach.silent, "under 10 minutes")
        clock.advance(1)
        XCTAssertTrue(reach.silent, "routed and no /codex request for 10 minutes")
        reach.served()
        XCTAssertFalse(reach.silent, "a request clears it")
        XCTAssertEqual(reach.lastServed, clock.now)
        // A request then a new routed spawn: the wait counts from the new spawn, not the first.
        reach.routed()
        clock.advance(300)
        reach.routed()
        clock.advance(300)
        XCTAssertTrue(reach.silent, "10 minutes after the first routed spawn since the last request")
        XCTAssertEqual(reach.routedCount, 3)
    }

    /// The pane model's caption reads the service config's reach.
    @MainActor
    func testPaneShowsTheCaptionFromTheServiceReach() {
        let clock = CCPoolTestClock(1_000)
        let dir = tempDir()
        let store = CCPoolStore(directory: dir.appendingPathComponent("ccpool"))
        let secrets = CCPoolMemorySecrets()
        var cfg = CCPoolServiceConfig()
        cfg.port = 0
        cfg.upstream = URL(string: "http://127.0.0.1:9")!
        cfg.codexReach = CCPool.CodexReach(now: { clock.now })
        let service = CCPoolService(config: cfg, store: store, secrets: secrets)
        let model = CCPoolPaneModel(store: store, secrets: secrets, service: service,
                                    defaults: XCTestDefaults(suiteName: "prosper-ccpool-codexreach-\(UUID().uuidString)")!,
                                    probeBase: cfg.upstream, vaultURL: dir.appendingPathComponent("old"), trash: { _ in })
        XCTAssertFalse(model.codexNotReaching)
        service.routing(on: { true }, codexOn: { true }).reach?.routed()
        clock.advance(CCPool.CodexReach.silentAfter)
        XCTAssertTrue(model.codexNotReaching)
        XCTAssertEqual(CCPoolPane.codexSilentLine, "Codex sessions are not reaching the pool")
        cfg.codexReach.served()
        XCTAssertFalse(model.codexNotReaching, "the config copies share one reach")
        XCTAssertFalse(model.hasCodexAccounts, "no Codex account: the Codex toggle row is hidden")
    }

    /// A Codex account of a kind the pool serves counts; a Claude one or another Codex kind does not.
    func testHasCodexAccountsNeedsAServableCodexLogin() throws {
        let store = CCPoolStore(directory: tempDir().appendingPathComponent("ccpool"))
        let secrets = CCPoolMemorySecrets()
        try store.addAccount(label: "one", token: "tok-one", secrets: secrets)
        XCTAssertTrue(store.hasAccounts)
        XCTAssertFalse(store.hasCodexAccounts, "a Claude account only")
        try store.addAccount(label: "cx", token: "item", secrets: secrets)
        store.mutate { $0.accounts["cx"]?.harness = CCPoolCodexHarness.id; $0.accounts["cx"]?.kind = "openai-key" }
        XCTAssertFalse(store.hasCodexAccounts, "a Codex kind the pool does not serve")
        store.mutate { $0.accounts["cx"]?.kind = CCPoolCodexHarness.chatgptKind }
        XCTAssertTrue(store.hasCodexAccounts)
    }

    /// #2009 (design #2003 section 1): Claude sessions route only while the pool lists a Claude account. A pool of Codex
    /// accounts only leaves `claude` alone and the Claude toggle reads as having no account; Codex still routes.
    @MainActor
    func testClaudeRoutingNeedsAClaudeAccount() throws {
        let r = try ccpoolPaneRig()
        guard case .running(let port) = r.service.start() else { return XCTFail("\(r.service.status)") }
        let base = CCPool.baseURL(port: port)
        r.model.routeAgentSessions = true
        try r.add(["cx"])
        r.store.mutate { $0.accounts["cx"]?.harness = CCPoolCodexHarness.id; $0.accounts["cx"]?.kind = CCPoolCodexHarness.chatgptKind }
        XCTAssertTrue(r.store.hasAccounts, "the proxy still has an account to run for")
        XCTAssertTrue(r.store.hasCodexAccounts)
        XCTAssertFalse(r.store.hasClaudeAccounts, "a Codex account only")
        XCTAssertTrue(r.service.sessionEnv(command: ["claude"], on: true).isEmpty, "a Codex-only pool never routes claude")
        XCTAssertTrue(r.service.routing(on: { true }).delta(["claude"]).isEmpty)
        XCTAssertFalse(r.service.routable)
        XCTAssertFalse(r.model.routeToggleShown, "the Claude toggle shows off")
        XCTAssertEqual(r.model.routeDisabledReason, "Add an account first.")
        XCTAssertEqual(r.service.routing(on: { true }, codexOn: { true }).codexWords(["codex"]), CCPool.codexArgs(port: port),
                       "Codex routes on its own account")

        try r.add(["one"])
        XCTAssertTrue(r.store.hasClaudeAccounts)
        XCTAssertEqual(r.service.sessionEnv(command: ["claude"], on: true).set["ANTHROPIC_BASE_URL"], base, "a Claude account: as today")
        XCTAssertTrue(r.service.routable)
        XCTAssertTrue(r.model.routeToggleShown)
        XCTAssertTrue(r.model.routeDisabledReason == nil)
    }
}
