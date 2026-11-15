import XCTest
@testable import ProsperApp

/// #1266: sessions Prosper starts say the terminal draws 24-bit colour. Pure rule on literal dictionaries.
final class DchColourEnvTests: XCTestCase {
    private let others = ["PATH": "/usr/bin", "TERM": "xterm-256color", "HOME": "/Users/example"]

    func testAbsentGivesTruecolor() {
        let out = DchCommand.withColour(others)
        XCTAssertEqual(out["COLORTERM"], "truecolor")
        XCTAssertEqual(Set(out.keys), Set(others.keys).union(["COLORTERM"]))
    }

    func testEmptyGivesTruecolor() {
        let out = DchCommand.withColour(others.merging(["COLORTERM": ""]) { $1 })
        XCTAssertEqual(out["COLORTERM"], "truecolor")
    }

    func testAPresentValueIsKept() {
        for v in ["truecolor", "24bit", "x"] {
            XCTAssertEqual(DchCommand.withColour(others.merging(["COLORTERM": v]) { $1 })["COLORTERM"], v, v)
        }
    }

    func testEveryOtherKeyIsUnchanged() {
        let out = DchCommand.withColour(others)
        for (k, v) in others { XCTAssertEqual(out[k], v, k) }
        XCTAssertEqual(out["TERM"], "xterm-256color")
    }

    func testTheSpawnPathCarriesAndKeepsColorterm() {
        let base = ["PATH": "/usr/bin", "HOME": "/Users/example", "CLAUDECODE": "1"]
        let added = AgentIsland.spawnEnv(AgentIsland.controlEnv(dir: "/d", login: nil, base: base))
        XCTAssertEqual(added["COLORTERM"], "truecolor")
        XCTAssertTrue(added["CLAUDECODE"] == nil, "the Claude Code strip still applies")
        let kept = AgentIsland.spawnEnv(AgentIsland.controlEnv(dir: "/d", login: nil, base: base.merging(["COLORTERM": "24bit"]) { $1 }))
        XCTAssertEqual(kept["COLORTERM"], "24bit")
    }
}
