import XCTest
@testable import ProsperApp

/// #847 P1e "Pairs", step A: the pure pairing, its texts and the suffix setting. No dch, no
/// view, no window; the setting goes through Preferences' in-memory XCTest store.
final class AgentIslandPairsTests: XCTestCase {
    private func key(_ name: String, _ dir: String = "/d") -> AgentSessionKey { AgentSessionKey(dir: dir, name: name) }

    private func line(_ name: String, _ result: String, reason: String? = nil, detail: String? = nil) -> DchJSONLine {
        DchJSONLine(name: name, result: result, reason: reason, detail: detail)
    }

    // T8; R909-2: a suffix needs a letter.
    func testSuffixOK() {
        for s in ["-qa", "_r", ".x", "Q", "-qa2", "1a", String(repeating: "a", count: 16)] { XCTAssertTrue(AgentIsland.suffixOK(s), s) }
        for s in ["", " ", "a/b", "q a", "\u{E9}", "\u{0}", String(repeating: "a", count: 17), "-", "_", ".", "1", "-2", "--", "-.-_"] {
            XCTAssertFalse(AgentIsland.suffixOK(s), s)
        }
    }

    // R909-2: with "-" (or digits alone) every numbered name read as a sidekick: such a suffix is off, as "" is.
    func testASuffixWithNoLetterGroupsNothing() {
        let keys = [key("feat"), key("feat-1"), key("feat-2"), key("feat-qa")]
        XCTAssertEqual(AgentIsland.groups(keys, suffix: "-"), [], "not feat with sidekicks feat-1, feat-2")
        XCTAssertEqual(AgentIsland.groups(keys, suffix: "-1"), [])
        XCTAssertEqual(AgentIsland.groups(keys, suffix: " - "), [], "trimmed first")
        XCTAssertEqual(AgentIsland.groups(keys, suffix: "-qa"),
                       [AgentGroup(dir: "/d", stem: "feat", mains: ["feat", "feat-1", "feat-2"], sidekicks: ["feat-qa"])],
                       "a suffix with a letter groups as before")
    }

    // T9 for groups (R909-1, the size row pairs() had): 2000 keys, every group found, none doubled; no timing assert.
    func testTwoThousandKeysGroup() {
        let keys = (0..<1000).flatMap { [key("s\($0)"), key("s\($0)-qa")] }.shuffled()
        let g = AgentIsland.groups(keys, suffix: "-qa")
        XCTAssertEqual(g.count, 1000)
        let members = g.flatMap { $0.mains + $0.sidekicks }
        XCTAssertEqual(members.count, 2000)
        XCTAssertEqual(Set(members).count, 2000, "none doubled")
        let byStem = Dictionary(g.map { ($0.stem, $0) }, uniquingKeysWith: { a, _ in a })
        for i in 0..<1000 where byStem["s\(i)"] != AgentGroup(dir: "/d", stem: "s\(i)", mains: ["s\(i)"], sidekicks: ["s\(i)-qa"]) {
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

    // #908 rider p5 and the Step A INFO: a bound (stopped) result never reads "had already ended", and
    // neither does a revive's line; only dch --stop's no_session does.
    func testOnlyAFinishedStopReadsAlreadyEnded() {
        let gone = [line("api-qa", "failed", reason: "no_session", detail: "no such session")]
        let ok = AgentPairOutcome.result(DchActionResult(status: 0, json: [line("api", "ok")]))
        XCTAssertEqual(AgentIsland.pairLine(.stop, [("api", ok), ("api-qa", .result(DchActionResult(status: 1, json: gone, stopped: true)))]),
                       "Stop both: api stopped, api-qa: Stop cancelled: no answer in 15m", "p5: a stopped job is no ended session")
        XCTAssertFalse(AgentIsland.pairLine(.resume, [("api", ok), ("api-qa", .result(DchActionResult(status: 1, json: gone)))])
            .contains("had already ended"), "a revive never reads as ended")
    }

    // #908 riders p6 and QA 791 (3): a link across two dirs pairs nothing, even with both names in each dir;
    // QA 791 (1): a self link pairs nothing. groups() alike.
    func testLinksNeverCrossDirsAndNeverPairANameWithItself() {
        let keys = [key("api"), key("api-rev"), key("api", "/e"), key("api-rev", "/e")]
        let across = [(main: key("api"), sidekick: key("api-rev", "/e"))]
        XCTAssertTrue(AgentIsland.groups(keys, suffix: "", links: across).isEmpty, "p6")
        XCTAssertEqual(AgentIsland.groups(keys, suffix: "", links: [(main: key("api"), sidekick: key("api-rev"))]),
                       [AgentGroup(dir: "/d", stem: "api", mains: ["api"], sidekicks: ["api-rev"])], "the same link in one dir groups")
        let me = [(main: key("api"), sidekick: key("API"))]
        XCTAssertTrue(AgentIsland.groups([key("api")], suffix: "", links: me).isEmpty, "QA 791 (1): a self link, any case")
    }

    // #908 QA 791 (2): a join given one name twice still ends, once.
    @MainActor
    func testJoinWithOneNameTwiceStillEnds() {
        var lines: [String] = []
        let j = AgentPairJoin(.stop, main: "api", sidekick: "api") { lines.append($0) }
        j.fill("api", .notListed)
        j.fill("api", .refused)
        XCTAssertEqual(lines, ["Stop both: api is not listed any more"])
    }

    // #908: a group of more than two reads "all N"; a group of two keeps "both".
    @MainActor
    func testGroupTextsCountTheMembers() {
        typealias A = AgentIsland
        XCTAssertEqual(A.groupLabel(.stop, others: ["feat-2", "feat-qa"]), "Stop all 3 (with feat-2, feat-qa)")
        XCTAssertEqual(A.groupLabel(.resume, others: ["feat-2", "feat-qa"]), "Resume all 3 (with feat-2, feat-qa)")
        XCTAssertEqual(A.groupLabel(.stop, others: ["api-qa"]), A.stopBothLabel(partner: "api-qa"))
        XCTAssertEqual(A.pairNotRun(.stop, "feat-2 is busy", count: 3), "Stop all 3 not run: feat-2 is busy")
        XCTAssertEqual(A.pairFirstText(["feat-1", "feat-2", "feat-qa"]), "Resume all 3: feat-1 first, then feat-2, feat-qa\u{2026}")
        var lines: [String] = []
        let j = AgentPairJoin(.stop, names: ["feat-1", "feat-2", "feat-qa"]) { lines.append($0) }
        j.fill("feat-qa", .notListed)
        j.fill("feat-1", .result(DchActionResult(status: 0, json: [line("feat-1", "ok")])))
        XCTAssertTrue(lines.isEmpty, "two of three")
        j.fill("feat-2", .result(DchActionResult(status: 0, json: [line("feat-2", "ok")])))
        XCTAssertEqual(lines, ["Stop all 3: feat-1 stopped, feat-2 stopped, feat-qa is not listed any more"])
    }
}
