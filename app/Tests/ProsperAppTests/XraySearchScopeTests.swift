import XCTest
@testable import ProsperApp

/// #1611 (dch #498 `--search --scope`, #501 --search in `--requests`, 1.111.0 first/latest/answer): the Search tab's
/// other-session groups, read from fixtures of dch's sent shapes (Tests/Fixtures/dch-xray-search, fakes only). Fake
/// runs and a fake `--requests` child; no dch, no process, no window shown.
@MainActor
final class XraySearchScopeTests: XCTestCase {
    static let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/dch-xray-search", isDirectory: true)
    static func fixture(_ name: String) throws -> Data { try Data(contentsOf: dir.appendingPathComponent(name)) }
    /// The fixtures' own session's last activity: api-qa's is 2 h before it.
    static let now = Date(timeIntervalSince1970: 1_794_304_860)

    override func tearDown() {
        XrayPanels.probed = nil
        super.tearDown()
    }

    /// 1.110.0's shape: <n>'s group is the hits; the others keep dch's order, an empty group dropped; hits inside a
    /// group in dch's order (Round 4), never re-sorted by time. Red at TIP: parse reads only a top-level "hits" (nil).
    func testScopedAnswerKeepsDchsGroupAndHitOrder() throws {
        let s = try XCTUnwrap(XraySearch.parse(Self.fixture("scoped-1.110.0.json")))
        XCTAssertEqual(s.hits.map(\.snippet), ["see the push retry note"])
        XCTAssertEqual(s.others.map(\.session), ["api-qa", "cli"], "dch's order; api-docs had no hit")
        XCTAssertEqual(s.others.first?.sessionID, "9a2c0d11-7e5b-4f3a-8c21-5d6e7f8a9b01")
        XCTAssertEqual(s.others.first?.hits.map(\.snippet), ["\u{2026} push retry fails on Example Org", "push and retry"],
                       "an older hit first stays first")
        XCTAssertEqual(s.others.last?.more, true)
        XCTAssertFalse(s.more)
        XCTAssertEqual(s.footer, ["the search stopped early: too many sessions"])
        XCTAssertEqual(s.others.first.map { XraySearch.header($0, now: Self.now) }, "also discussed in api-qa, 2h")
        XCTAssertEqual(s.others.last.map { XraySearch.header($0, now: Self.now) }, "also discussed in cli, 1d")
        XCTAssertTrue(s.first == nil && s.latest == nil, "1.110.0 sends no first or latest")
        XCTAssertFalse((s.hits + s.others.flatMap(\.hits)).contains(where: \.answer))
    }

    /// 1.111.0: first and latest as lines, the answer hit marked and spoken. Red at TIP: no first, latest or answer.
    func testFirstLatestAndTheAnswerHit() throws {
        let s = try XCTUnwrap(XraySearch.parse(Self.fixture("scoped-1.111.0.json")))
        XCTAssertEqual(s.moments(now: Self.now), ["first mentioned in api-qa, 4h: push retry fails",
                                                  "latest in api, 1m: see the push retry note"])
        XCTAssertEqual(s.hits.first?.answer, true)
        XCTAssertEqual(s.others.first?.hits.map(\.answer), [false, true])
        let row = try XCTUnwrap(s.hits.first.map { XraySearchRow($0, now: Self.now) })
        XCTAssertTrue(row.answer)
        XCTAssertEqual(row.spoken, "Reply, 1 minute ago, the answer, see the push retry note")
    }

    /// The unscoped shape (before 1.110.0, or no --scope) parses as before: no groups, no moments.
    func testUnscopedAnswerIsAsBefore() throws {
        let s = try XCTUnwrap(XraySearch.parse(XraySearchTabTests.hits(3).out))
        XCTAssertEqual(s.hits.count, 3)
        XCTAssertTrue(s.others.isEmpty && s.first == nil && s.latest == nil)
        XCTAssertTrue(XraySearch.parse(Data(#"{"schema":1,"sessions":"x"}"#.utf8)) == nil, "no hits array anywhere")
    }

    /// --scope project only from dch 1.110.0 on (XraySearch.scoped). Red at TIP: argv never carries --scope.
    func testScopeOnlyFromDch1_110() async {
        for (version, scoped) in [([1, 109, 0], false), ([1, 110, 0], true), ([2, 0, 0], true)] {
            XrayPanels.probed = DchCommand.Binary(path: "/fake/dch", version: version)
            let run = XraySearchTabTests.Run()
            let p = await opened(XraySearchTabTests.local, run.run)
            p.query = "push retry"
            p.runSearch()
            await p.reading?.value
            let scope = scoped ? ["--scope", "project"] : []
            XCTAssertEqual(run.searches, [["--xray", "api", "--search", "-"] + scope + ["--json"]], "\(version)")
        }
    }

    /// #1621: the field's accessibility label says the scope the read uses. Red at TIP: always "Search this session".
    func testSearchFieldLabelFollowsTheScope() async {
        XrayPanels.probed = DchCommand.Binary(path: "/fake/dch", version: [1, 109, 0])
        let p = await opened(XraySearchTabTests.local, XraySearchTabTests.Run().run)
        XCTAssertEqual(p.searchFieldLabel, "Search this session")
        XrayPanels.probed = DchCommand.Binary(path: "/fake/dch", version: [1, 110, 0])
        XCTAssertEqual(p.searchFieldLabel, "Search this project")
        p.unscopedHost = true
        XCTAssertEqual(p.searchFieldLabel, "Search this session", "a host that refused --scope reads the session")
    }

    /// A remote host whose dch refuses --scope (exit 1): one unscoped read follows and the panel stays unscoped; its
    /// hits land. Red under the mutant scope-no-retry (the tab goes, "cannot search").
    func testRemoteHostRefusingScopeRetriesUnscopedOnce() async {
        XrayPanels.probed = DchCommand.Binary(path: "/fake/dch", version: [1, 110, 0])
        let calls = Calls()
        let run: XrayPanels.Run = { _, args, _ in
            calls.add(args)
            if args.contains("--tasks") || args.contains("--memory") { return XraySearchTabTests.ok }
            return args.contains("--scope") ? (1, Data()) : XraySearchTabTests.hits(2)
        }
        let p = await opened(XraySearchTabTests.remote, run)
        p.query = "push retry"
        p.runSearch()
        await p.reading?.value
        let plain = ["--xray", "example-host:api", "--search", "push retry", "--json"]
        XCTAssertEqual(calls.searches, [["--xray", "example-host:api", "--search", "push retry", "--scope", "project", "--json"], plain])
        XCTAssertEqual(p.search?.hits.count, 2)
        XCTAssertTrue(p.searchable)
        p.runSearch()
        await p.reading?.value
        XCTAssertEqual(calls.searches.last, plain, "remembered: no second scoped try")
        XCTAssertEqual(calls.searches.count, 3)
    }

    /// --search goes warm only with `search` (dch 1.110.0): bare or with --scope, --json last. Red at TIP: always nil.
    func testSearchIsARequestFormFrom1_110() {
        func f(_ a: [String], _ on: Bool = true) -> [String]? { XrayRequests.form(["--xray", "box:api"] + a, name: "box:api", search: on) }
        XCTAssertEqual(f(["--search", "x y", "--json"]), ["--search", "x y", "--json"])
        XCTAssertEqual(f(["--search", "x y", "--scope", "project", "--json"]), ["--search", "x y", "--scope", "project", "--json"])
        for a in [["--search", "x", "--json"]] { XCTAssertTrue(f(a, false) == nil, "an older dch: cold") }
        for a in [["--search", "x"], ["--search", "x", "--full", "project", "--json"], ["--search", "x", "--scope", "--json"],
                  ["--search", "--json"]] {
            XCTAssertTrue(f(a) == nil, "\(a)")
        }
    }

    /// A remote scoped search on 1.110.0 goes through the warm connection: no cold run. Red at TIP: it ran cold.
    func testRemoteSearchGoesWarm() async {
        XrayPanels.probed = DchCommand.Binary(path: "/fake/dch", version: [1, 110, 0])
        let spawns = XrayRequestsTests.Spawns { XrayRequestsTests.Child(reply: XrayRequestsTests.echo) }
        let cold = XrayRequestsTests.Cold(), r = XrayRequests()
        r.spawn = spawns.spawn
        let run = r.run(for: XrayRequestsTests.remote, cold: cold.run)
        let a = await run("/fake/dch", ["--xray", "box:api", "--search", "x y", "--scope", "project", "--json"], [:])
        XCTAssertEqual(a.status, 0)
        XCTAssertEqual(cold.calls, [])
        XCTAssertEqual(spawns.children.last?.writes.last?["argv"] as? [String], ["--search", "x y", "--scope", "project", "--json"])
    }

    /// "Open that session": by session_id (live Claude id); with no id, by name; an id that matches no row opens
    /// nothing (dch #493: a reused name is another session). Red under the mutant open-by-name-first.
    func testOpenSessionKeysOnSessionIDThenName() {
        func row(_ name: String, _ sid: String?) -> AgentSidebar.Row {
            var s = AgentSession(key: AgentSessionKey(dir: "/tmp/dch-test", name: name), alias: "", activity: 0, state: .idle, agents: 0)
            s.claudeSessionID = sid
            var r = AgentSidebar.Row(id: .live(s.key), title: name, state: .idle, detail: "", age: "", prs: [])
            r.session = s
            return r
        }
        let rows = [row("api-qa", "11111111-2222-3333-4444-555555555555"), row("api-qa-2", "9a2c")]
        func g(_ name: String, _ id: String?) -> XraySearch.Group { .init(session: name, sessionID: id, lastActive: nil, hits: [], more: false) }
        XCTAssertEqual(XraySearch.row(g("api-qa", "9a2c"), in: rows), rows.last?.id, "the id wins over the name")
        XCTAssertEqual(XraySearch.row(g("api-qa", nil), in: rows), rows.first?.id)
        XCTAssertTrue(XraySearch.row(g("api-qa", "ffff"), in: rows) == nil, "an unknown id never falls back to the name")
    }

    /// As XraySearchTabTests.opened: a shown, live panel on the Search tab, its clock at the fixtures' now.
    func opened(_ target: XrayTarget, _ run: @escaping XrayPanels.Run) async -> XrayPanelModel {
        let p = XrayPanelModel(target: target, tab: .search)
        p.now = { Self.now }
        p.paneState = { (true, true) }
        p.mtime = { _ in Self.now }
        p.searchable = true
        p.read(dch: "/fake/dch", run: run)
        await p.reading?.value
        return p
    }

    final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [[String]] = []
        func add(_ a: [String]) { lock.withLock { _calls.append(a) } }
        var searches: [[String]] { lock.withLock { _calls.filter { $0.contains("--search") } } }
    }
}
