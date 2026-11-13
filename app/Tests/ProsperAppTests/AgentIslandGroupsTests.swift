import XCTest
@testable import ProsperApp

/// #1116 session groups: AgentIsland.groups, names in, groups out. Pure: no dch, no view, no defaults.
/// Every expectation is written out; a group reads "<dir> <stem>: <mains> | <sidekicks>".
final class AgentIslandGroupsTests: XCTestCase {
    private func key(_ name: String, _ dir: String = "/d") -> AgentSessionKey { AgentSessionKey(dir: dir, name: name) }

    private func show(_ groups: [AgentGroup]) -> [String] {
        groups.map { "\($0.dir) \($0.stem): \($0.mains.joined(separator: " ")) | \($0.sidekicks.joined(separator: " "))" }
    }

    private func groups(_ names: [String], suffix: String = "-qa") -> [String] {
        show(AgentIsland.groups(names.map { key($0) }, suffix: suffix))
    }

    func testTableByName() {
        let n400 = String(repeating: "9", count: 400)
        let rows: [(label: String, names: [String], suffix: String, want: [String])] = [
            ("1 no sidekick: no groups", ["api", "web", "ios-17", "ios-18", "feat-1", "feat-2", "v2", "17"], "-qa", []),
            ("2 suffix off", ["api", "api-qa"], "", []),
            ("2 suffix blank", ["api", "api-qa"], "   ", []),
            ("2 suffix unusable", ["x", "x-q a"], "-q a", []),
            ("3 standard", ["feat", "feat-qa"], "-qa", ["/d feat: feat | feat-qa"]),
            ("4 two numbered mains", ["feat-1", "feat-2", "feat-qa"], "-qa", ["/d feat: feat-1 feat-2 | feat-qa"]),
            ("5 two sidekicks", ["feat", "feat-qa", "feat-qa2"], "-qa", ["/d feat: feat | feat-qa feat-qa2"]),
            ("6 three and two", ["feat-qa2", "feat-3", "feat-1", "feat-qa1", "feat-2"], "-qa",
             ["/d feat: feat-1 feat-2 feat-3 | feat-qa1 feat-qa2"]),
            ("7 unrelated numbered projects", ["ios-17", "ios-18"], "-qa", []),
            ("8 one has a sidekick", ["ios-17", "ios-18", "ios-17-qa"], "-qa", ["/d ios-17: ios-17 | ios-17-qa"]),
            ("9 exact stem wins", ["ios-17", "ios-18", "ios-17-qa", "ios-qa"], "-qa",
             ["/d ios: ios-18 | ios-qa", "/d ios-17: ios-17 | ios-17-qa"]),
            ("10 a name that is a number", ["17", "18", "17-qa"], "-qa", ["/d 17: 17 | 17-qa"]),
            ("11 a version", ["v2", "v2-qa"], "-qa", ["/d v2: v2 | v2-qa"]),
            ("12 worker number without a dash", ["v1", "v2", "v-qa"], "-qa", ["/d v: v1 v2 | v-qa"]),
            ("13 api-2-qa is api-2's", ["api", "api-2", "api-2-qa"], "-qa", ["/d api-2: api-2 | api-2-qa"]),
            ("14 api-2-qa never api's", ["api", "api-2-qa"], "-qa", []),
            ("15 case folded", ["Feat", "FEAT-QA2"], "-QA", ["/d feat: feat | feat-qa2"]),
            ("17 dash number", ["feat", "feat-qa-2", "feat-qa-x"], "-qa", ["/d feat: feat | feat-qa-2"]),
            ("18 suffix ends in a digit", ["feat", "feat-r2", "feat-r23", "feat-r2-3"], "-r2", ["/d feat: feat | feat-r2 feat-r2-3"]),
            ("19 empty stem", ["", "qa", "qa2"], "qa", []),
            ("20 the suffix as a stem", ["qa", "qa-qa"], "-qa", ["/d qa: qa | qa-qa"]),
            ("21 sidekick of a sidekick", ["api", "api-qa", "api-qa-qa"], "-qa", ["/d api: api | api-qa"]),
            ("22 no main", ["api-qa", "api-qa-qa"], "-qa", []),
            ("23 by number, not text", ["feat-qa10", "feat-10", "feat-qa", "feat-2", "feat-qa2", "feat"], "-qa",
             ["/d feat: feat feat-2 feat-10 | feat-qa feat-qa2 feat-qa10"]),
            ("24 400 digits", ["feat-qa\(n400)", "feat-\(n400)", "feat-qa1"], "-qa",
             ["/d feat: feat-\(n400) | feat-qa1 feat-qa\(n400)"]),
            ("25 freeName copies", ["api-qa-2", "api", "api-2", "api-qa"], "-qa", ["/d api: api api-2 | api-qa api-qa-2"]),
            ("26 not passable", ["--x", "--x-qa"], "-qa", []),
            ("27 live and History spellings once", ["api", "api-qa", "API-QA", "api-qa"], "-qa", ["/d api: api | api-qa"]),
        ]
        for r in rows { XCTAssertEqual(groups(r.names, suffix: r.suffix), r.want, r.label) }
    }

    // Row 16: aliases are no input; a session aliased "one-qa" groups nothing.
    func testAliasNeverRead() {
        let s = [("one", ""), ("two", "one-qa")].map {
            AgentSession(key: key($0.0), alias: $0.1, activity: 0, state: .idle, agents: 0)
        }
        XCTAssertEqual(show(AgentIsland.groups(s.map(\.key), suffix: "-qa")), [])
    }

    func testNeverAcrossDirs() {
        XCTAssertEqual(show(AgentIsland.groups([key("feat", "/d"), key("feat-qa", "/e")], suffix: "-qa")), [], "28")
        XCTAssertEqual(show(AgentIsland.groups([key("feat-qa2", "/e"), key("feat", "/d"), key("feat", "/e"), key("feat-qa", "/d")],
                                               suffix: "-qa")),
                       ["/d feat: feat | feat-qa", "/e feat: feat | feat-qa2"], "29")
    }

    func testLinks() {
        func g(_ names: [String], _ links: [(String, String)], suffix: String = "-qa") -> [String] {
            show(AgentIsland.groups(names.map { key($0) }, suffix: suffix, links: links.map { (main: key($0.0), sidekick: key($0.1)) }))
        }
        XCTAssertEqual(g(["api", "api-qa", "web", "web-qa"], [("api", "WEB-QA")]), ["/d api: api | api-qa web-qa"], "30 across stems")
        XCTAssertEqual(g(["api", "api-qa"], [("api", "gone-qa")]), ["/d api: api | api-qa"], "31 absent member")
        XCTAssertEqual(g(["api", "rev"], [("api", "rev")], suffix: ""), ["/d api: api | rev"], "32 links with the suffix off")
        XCTAssertEqual(g(["api", "x", "y"], [("api", "x"), ("y", "x")]), ["/d api: api | x"], "34 first link wins")
        XCTAssertEqual(g(["api-qa", "x"], [("api-qa", "x")]), ["/d api-qa: api-qa | x"], "35 link roles win")
        XCTAssertEqual(g(["api", "api-qa"], [("api", "api")]), ["/d api: api | api-qa"], "a self link is ignored")
        XCTAssertEqual(g(["api", "x", "y", "y-qa"], [("api", "x"), ("x", "y-qa")]), ["/d api: api | x", "/d y: y | y-qa"],
                       "a linked sidekick is never a linked main")
        XCTAssertEqual(g(["api", "x", "y"], [("x", "y"), ("api", "x")]), ["/d x: x | y"], "a linked main is never a linked sidekick")
        let cross = AgentIsland.groups([key("api", "/d"), key("rev", "/e")], suffix: "",
                                       links: [(main: key("api", "/d"), sidekick: key("rev", "/e"))])
        XCTAssertEqual(show(cross), [], "33 never across dirs")
    }

    // The parse on its own, for the review: stem and number as text.
    func testSidekickTail() {
        let rows: [(String, String, String?)] = [("feat-qa", "feat", nil), ("feat-qa2", "feat", "2"), ("feat-qa-2", "feat", "2"),
                                                 ("feat-qa007", "feat", "007")]
        for (n, stem, num) in rows {
            let t = AgentIsland.sidekickTail(n, "-qa")
            XCTAssertEqual(t?.stem, stem, n)
            XCTAssertEqual(t?.num, num, n)
        }
        for n in ["feat", "-qa", "feat-qa-x", "feat-qa--2", "feat-q2", "feat2"] {
            XCTAssertTrue(AgentIsland.sidekickTail(n, "-qa") == nil, n)
        }
    }
}
