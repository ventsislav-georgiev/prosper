import XCTest
@testable import ProsperApp

/// #847 P1e "Pairs", step A: the pure pairing, its texts and the suffix setting. No dch, no
/// view, no window; the setting goes through Preferences' in-memory XCTest store.
final class AgentIslandPairsTests: XCTestCase {
    private func key(_ name: String, _ dir: String = "/d") -> AgentSessionKey { AgentSessionKey(dir: dir, name: name) }

    private func pair(_ p: [AgentSessionKey: AgentPair], _ name: String, _ dir: String = "/d") -> AgentPair? {
        p[key(name.lowercased(), dir)]
    }

    private func line(_ name: String, _ result: String, reason: String? = nil, detail: String? = nil) -> DchJSONLine {
        DchJSONLine(name: name, result: result, reason: reason, detail: detail)
    }

    private func session(_ name: String, dir: String = "/d", alias: String = "") -> AgentSession {
        AgentSession(key: key(name, dir), alias: alias, activity: 0, state: .idle, agents: 0)
    }

    private func record(_ name: String, dir: String = "/d", alias: String = "", ended: TimeInterval = 100) -> DchHistoryRecord {
        DchHistoryRecord(key: key(name, dir), alias: alias, cwd: "/Users/example/x", updated: ended, ended: ended, end: "stopped")
    }

    private let geometry = AgentIslandGeometry.make(
        frame: CGRect(x: 0, y: 0, width: 1512, height: 982), visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 950),
        topLeft: CGRect(x: 0, y: 950, width: 663.5, height: 32), topRight: CGRect(x: 848.5, y: 950, width: 663.5, height: 32),
        safeTop: 32)

    // T1
    @MainActor
    func testPairsByNameOnlyNeverByAlias() {
        let p = AgentIsland.pairs([key("api"), key("api-qa")], suffix: "-qa")
        XCTAssertEqual(pair(p, "api"), AgentPair(dir: "/d", main: "api", sidekick: "api-qa"))
        XCTAssertEqual(pair(p, "api-qa"), pair(p, "api"))
        XCTAssertEqual(p.count, 2)
        // Aliases are never read: a record aliased "x-qa" beside a live "x" alias pairs nothing.
        let store = AgentIslandStore(geometry: geometry)
        store.sessions = [session("one", alias: "x")]
        store.history = [record("two", alias: "x-qa")]
        XCTAssertTrue(store.pairs(suffix: "-qa").isEmpty)
    }

    // T2
    @MainActor
    func testPairsFoldCaseAcrossLiveAndHistory() {
        let store = AgentIslandStore(geometry: geometry)
        store.sessions = [session("API")]
        store.history = [record("api-QA")]
        let p = store.pairs(suffix: "-qa")
        XCTAssertEqual(pair(p, "API"), AgentPair(dir: "/d", main: "api", sidekick: "api-qa"))
        XCTAssertEqual(pair(p, "Api-Qa"), pair(p, "api"), "any spelling finds it")
        XCTAssertEqual(store.historyPartner(store.history.first ?? record("none"), pairs: p)?.name, nil,
                       "the main has no record: the sidekick record's History partner is none")
        XCTAssertEqual(store.livePartner(store.sessions.first ?? session("none"), pairs: p)?.name, nil,
                       "api-QA is not live")
        store.sessions = [session("API"), session("api-QA")]
        XCTAssertEqual(store.livePartner(session("api"), pairs: p)?.name, "api-QA")
        XCTAssertEqual(store.livePartner(session("API-qa"), pairs: p)?.name, "API")
        store.history = [record("api", ended: 300), record("api-qa", ended: 200), record("api", ended: 100)]
        XCTAssertEqual(store.historyPartner(record("API-QA"), pairs: p)?.ended, 300, "the newest record of the main")
        XCTAssertTrue(p[key("api", "/e")] == nil)
        XCTAssertEqual(p.first?.value.isMain("API"), true)
        XCTAssertEqual(p.first?.value.isMain("api-qa"), false)
    }

    // T3
    func testSuffixChangeRepairs() {
        let keys = [key("api"), key("api-qa"), key("api-rev")]
        XCTAssertEqual(pair(AgentIsland.pairs(keys, suffix: "-qa"), "api")?.sidekick, "api-qa")
        XCTAssertEqual(pair(AgentIsland.pairs(keys, suffix: "-rev"), "api")?.sidekick, "api-rev")
        XCTAssertTrue(AgentIsland.pairs([key("api"), key("api-qa")], suffix: "-rev").isEmpty)
        XCTAssertTrue(AgentIsland.pairs(keys, suffix: "").isEmpty, "empty: off")
        XCTAssertTrue(AgentIsland.pairs(keys, suffix: "   ").isEmpty, "blank: off")
        XCTAssertEqual(pair(AgentIsland.pairs(keys, suffix: " -QA "), "api")?.sidekick, "api-qa", "trimmed, folded")
        XCTAssertTrue(AgentIsland.pairs([key("api"), key("api-q/a")], suffix: "-q/a").isEmpty, "unusable: off")
    }

    // T4
    func testPairsNeverCrossDirs() {
        XCTAssertTrue(AgentIsland.pairs([key("api", "/d"), key("api-qa", "/e")], suffix: "-qa").isEmpty)
        let p = AgentIsland.pairs([key("api", "/d"), key("api-qa", "/d"), key("api-qa", "/e")], suffix: "-qa")
        XCTAssertEqual(pair(p, "api-qa", "/d"), AgentPair(dir: "/d", main: "api", sidekick: "api-qa"))
        XCTAssertTrue(pair(p, "api-qa", "/e") == nil)
        XCTAssertEqual(p.count, 2)
        let both = AgentIsland.pairs([key("api", "/d"), key("api-qa", "/d"), key("api", "/e"), key("api-qa", "/e")], suffix: "-qa")
        XCTAssertEqual(pair(both, "api", "/e")?.dir, "/e")
        XCTAssertEqual(both.count, 4)
    }

    // T5
    func testStoredLinksWinOverInference() {
        let keys = [key("api"), key("api-qa"), key("api-rev")]
        let p = AgentIsland.pairs(keys, suffix: "-qa", links: [(main: key("api"), sidekick: key("API-rev"))])
        XCTAssertEqual(pair(p, "api"), AgentPair(dir: "/d", main: "api", sidekick: "api-rev"))
        XCTAssertTrue(pair(p, "api-qa") == nil, "the link took api")
        let absent = AgentIsland.pairs(keys, suffix: "-qa", links: [(main: key("api"), sidekick: key("api-gone"))])
        XCTAssertEqual(pair(absent, "api")?.sidekick, "api-qa", "a link with an absent member pairs nothing")
        let off = AgentIsland.pairs(keys, suffix: "", links: [(main: key("api"), sidekick: key("api-rev"))])
        XCTAssertEqual(pair(off, "api-rev")?.main, "api", "links apply with the suffix off")
        XCTAssertEqual(off.count, 2)
        let cross = AgentIsland.pairs([key("api", "/d"), key("api-rev", "/e")], suffix: "",
                                      links: [(main: key("api", "/d"), sidekick: key("api-rev", "/e"))])
        XCTAssertTrue(cross.isEmpty, "a link never crosses dirs")
        let twice = AgentIsland.pairs(keys, suffix: "", links: [(main: key("api"), sidekick: key("api-rev")),
                                                                (main: key("api-qa"), sidekick: key("api"))])
        XCTAssertEqual(pair(twice, "api")?.sidekick, "api-rev", "one partner each, the first link wins")
        XCTAssertTrue(pair(twice, "api-qa") == nil)
    }

    // T6
    func testNeverChains() {
        let p = AgentIsland.pairs([key("api-qa-qa"), key("api-qa"), key("api")], suffix: "-qa")
        XCTAssertEqual(pair(p, "api")?.sidekick, "api-qa")
        XCTAssertEqual(pair(p, "api-qa")?.main, "api")
        XCTAssertTrue(pair(p, "api-qa-qa") == nil)
        XCTAssertEqual(p.count, 2)
        let alone = AgentIsland.pairs([key("api-qa"), key("api-qa-qa")], suffix: "-qa")
        XCTAssertEqual(pair(alone, "api-qa-qa"), AgentPair(dir: "/d", main: "api-qa", sidekick: "api-qa-qa"))
    }

    // T7
    func testEdges() {
        XCTAssertTrue(AgentIsland.pairs([key("qa"), key("")], suffix: "qa").isEmpty, "the suffix alone has no main")
        XCTAssertTrue(AgentIsland.pairs([key("-qa"), key("")], suffix: "-qa").isEmpty, "\"-qa\" is not passable")
        XCTAssertTrue(AgentIsland.pairs([key("--x"), key("--x-qa")], suffix: "-qa").isEmpty, "not passable")
        let p = AgentIsland.pairs([key("api"), key("api-qa"), key("API-QA"), key("api-qa")], suffix: "-qa")
        XCTAssertEqual(p.count, 2, "live and History of one name are one entry")
        XCTAssertEqual(pair(p, "api")?.sidekick, "api-qa")
    }

    // T8
    func testSuffixOK() {
        for s in ["-qa", "_r", ".x", "Q", String(repeating: "a", count: 16)] { XCTAssertTrue(AgentIsland.suffixOK(s), s) }
        for s in ["", " ", "a/b", "q a", "é", "\u{0}", String(repeating: "a", count: 17)] {
            XCTAssertFalse(AgentIsland.suffixOK(s), s)
        }
    }

    // T9: correctness at size; no timing assertion (timing tests flake on this machine).
    func testTwoThousandKeys() {
        let keys = (0..<1000).flatMap { [key("s\($0)"), key("s\($0)-qa")] }.shuffled()
        let p = AgentIsland.pairs(keys, suffix: "-qa")
        XCTAssertEqual(p.count, 2000)
        XCTAssertEqual(Set(p.values).count, 1000, "none doubled")
        for i in 0..<1000 where pair(p, "s\(i)") != AgentPair(dir: "/d", main: "s\(i)", sidekick: "s\(i)-qa") {
            XCTFail("s\(i)")
        }
    }

    // T10
    func testPairLinesAndRevivedOrLive() {
        typealias A = AgentIsland
        XCTAssertEqual(A.stopBothLabel(partner: "api-qa"), "Stop both (with api-qa)")
        XCTAssertEqual(A.resumeBothLabel(partner: "api-qa"), "Resume both (with api-qa)")
        let ok = { (n: String) in AgentPairOutcome.result(DchActionResult(status: 0, json: [self.line(n, "ok")])) }
        // Stop both (S4 step 5, A1).
        XCTAssertEqual(A.pairLine(.stop, [("api", ok("api")), ("api-qa", ok("api-qa"))]), "Stop both: api stopped, api-qa stopped")
        let gone = AgentPairOutcome.result(DchActionResult(status: 1, json: [line("api-qa", "failed", reason: "no_session",
                                                                                 detail: "no such session")]))
        XCTAssertEqual(A.pairLine(.stop, [("api", ok("api")), ("api-qa", gone)]), "Stop both: api stopped, api-qa had already ended")
        let pending = AgentPairOutcome.result(DchActionResult(status: 0, json: [line("api-qa", "skipped", reason: "respawn_pending",
                                                                                    detail: "api-qa: a respawn is pending")]))
        XCTAssertEqual(A.pairLine(.stop, [("api", ok("api")), ("api-qa", pending)]), "Stop both: api stopped, api-qa: a respawn is pending")
        XCTAssertEqual(A.pairLine(.stop, [("api", ok("api")), ("api-qa", .notListed)]),
                       "Stop both: api stopped, api-qa is not listed any more")
        XCTAssertEqual(A.pairLine(.stop, [("api", ok("api")), ("api-qa", .refused)]),
                       "Stop both: api stopped, api-qa: Stop not run: another job is running")
        let bound = AgentPairOutcome.result(DchActionResult(status: 0, json: [line("api", "ok")], stopped: true))
        XCTAssertEqual(A.pairLine(.stop, [("api", bound), ("api-qa", ok("api-qa"))]),
                       "Stop both: api: Stop cancelled: no answer in 15m, api-qa stopped")
        XCTAssertEqual(A.pairNotRun(.stop, "api-qa is busy"), "Stop both not run: api-qa is busy")
        XCTAssertEqual(A.pairNotRun(.stop, "api-qa (restart this session first)"),
                       "Stop both not run: api-qa (restart this session first)")
        // Resume both (S5 steps 1, 2, 5, 6).
        XCTAssertEqual(A.pairLine(.resume, [("api", ok("api")), ("api-qa", ok("api-qa"))]), "Resume both: api resumed, api-qa resumed")
        let cwd = DchActionResult(status: 1, json: [line("api", "failed", reason: "cwd_gone",
                                                         detail: "api: NOT revived — its directory /Users/example/x is gone")])
        XCTAssertEqual(A.pairLine(.resume, [("api", .result(cwd)), ("api-qa", .notStarted)]),
                       "Resume both: api: NOT revived — its directory /Users/example/x is gone; api-qa not started")
        XCTAssertEqual(A.pairLine(.resume, [("api", ok("api")), ("api-qa", .running)]), "Resume both: api resumed, api-qa is running")
        XCTAssertEqual(A.pairLine(.resume, [("api", ok("api")), ("api-qa", .noRecord)]),
                       "Resume both: api resumed, api-qa has no record left")
        XCTAssertEqual(A.pairNotRun(.resume, "api-qa is running"), "Resume both not run: api-qa is running")
        XCTAssertEqual(A.pairFirstText(main: "api", sidekick: "api-qa"), "Resume both: api first, then api-qa…")
        // revivedOrLive (S5 step 4).
        for (result, reason) in [("ok", nil), ("failed", "withdrawn"), ("failed", "draft_left"), ("failed", "live")] as [(String, String?)] {
            XCTAssertTrue(A.revivedOrLive(DchActionResult(status: 0, json: [line("api", result, reason: reason)]), name: "api"),
                          reason ?? result)
        }
        for reason in ["cwd_gone", "no_history", "live_sid", "not_started", "launch_unknown", "relaunch_failed", "ambiguous"] {
            XCTAssertFalse(A.revivedOrLive(DchActionResult(status: 1, json: [line("api", "failed", reason: reason)]), name: "api"), reason)
        }
        XCTAssertFalse(A.revivedOrLive(DchActionResult(status: 1, json: [line("api", "interrupted", reason: "signal")]), name: "api"))
        XCTAssertFalse(A.revivedOrLive(DchActionResult(status: 1), name: "api"), "no final line")
        XCTAssertFalse(A.revivedOrLive(DchActionResult(status: 0, json: [line("api-qa", "ok")]), name: "api"), "another name's line")
        XCTAssertFalse(A.revivedOrLive(DchActionResult(status: 0, json: [line("api", "ok")], stopped: true), name: "api"), "the bound")
    }

    // T10: the join fires once, main first, whichever member ends first.
    @MainActor
    func testJoinFiresOnceWithBoth() {
        var lines: [String] = []
        let j = AgentPairJoin(.stop, main: "api", sidekick: "api-qa") { lines.append($0) }
        j.fill("api-qa", .notListed)
        j.fill("other", .refused)
        XCTAssertTrue(lines.isEmpty)
        j.fill("api", .result(DchActionResult(status: 0, json: [line("api", "ok")])))
        j.fill("api", .refused)
        XCTAssertEqual(lines, ["Stop both: api stopped, api-qa is not listed any more"])
    }

    // T11, the accessor half: unset reads "-qa"; trimmed; "" kept (off), never the default.
    func testSuffixPreference() {
        let k = "agentIslandSidekickSuffix", saved = Preferences.defaults.object(forKey: k)
        defer { Preferences.defaults.set(saved, forKey: k) }
        Preferences.defaults.removeObject(forKey: k)
        XCTAssertEqual(Preferences.agentIslandSidekickSuffix, "-qa", "unset")
        Preferences.agentIslandSidekickSuffix = " -rev "
        XCTAssertEqual(Preferences.defaults.string(forKey: k), "-rev")
        XCTAssertEqual(Preferences.agentIslandSidekickSuffix, "-rev")
        Preferences.agentIslandSidekickSuffix = ""
        XCTAssertEqual(Preferences.defaults.string(forKey: k), "", "empty is kept")
        XCTAssertEqual(Preferences.agentIslandSidekickSuffix, "")
        Preferences.agentIslandSidekickSuffix = "a/b"
        XCTAssertEqual(Preferences.agentIslandSidekickSuffix, "a/b", "an unusable value reads as is, never rewritten")
        XCTAssertFalse(SyncedKeys.isSynced(k), "per Mac")
    }
}
