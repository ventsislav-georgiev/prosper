import XCTest
@testable import ProsperApp

/// #992: Resume interrupted's count asks about the name dch starts (R950-1), and the trailing-slash rows of
/// entry 867 for recordCommand, strippingResume and claudeRuns' env site (rider 3). Pure functions: no dch runs.
final class AgentIslandResumeNameTests: XCTestCase {
    private let now: TimeInterval = 2_000_000_000

    private func rec(_ name: String, dir: String = "/d") -> DchHistoryRecord {
        DchHistoryRecord(key: AgentSessionKey(dir: dir, name: name), started: now - 3600, updated: now - 60, ended: now - 60, end: "signal 9")
    }

    /// R950-1: dch refuses the name it starts. A live name goes to <name>-2, never id-shaped, so an id-shaped
    /// record whose name is live is taken; a dash name is refused either way (-api-2 still starts with '-').
    @MainActor
    func testReviveAllTakesAsksTheNameDchStarts() {
        let id = "m0123456789abcdef"
        XCTAssertFalse(AgentIsland.reviveAllTakes(rec(id), now: now), "free: dch starts the id-shaped name itself")
        XCTAssertFalse(AgentIsland.reviveAllTakes(rec(id), now: now, live: ["api"]), "another name live")
        XCTAssertTrue(AgentIsland.reviveAllTakes(rec(id), now: now, live: [id]), "live: dch starts \(id)-2")
        XCTAssertTrue(AgentIsland.reviveAllTakes(rec(id), now: now, live: ["M0123456789ABCDEF"]), "dch folds case")
        XCTAssertTrue(AgentIsland.reviveAllTakes(rec(" M0123456789ABCDEF "), now: now, live: [" M0123456789ABCDEF "]),
                      "trimmed only for the shape")
        XCTAssertFalse(AgentIsland.reviveAllTakes(rec("-api"), now: now, live: ["-api"]), "dash: -api-2 is refused too")
        XCTAssertTrue(AgentIsland.reviveAllTakes(rec("api"), now: now, live: ["api"]))

        let history = [rec(id), rec(id, dir: "/e")]
        let live: Set<AgentSessionKey> = [AgentSessionKey(dir: "/d", name: id)]
        XCTAssertEqual(AgentIsland.reviveAllTaken(history, now: now, held: nil, endedHolds: false, live: live),
                       [AgentSessionKey(dir: "/d", name: id)], "held nil: only the dir where the name is live")
        XCTAssertEqual(AgentIsland.reviveAllTaken(history, now: now, held: [], endedHolds: true, live: live),
                       [AgentSessionKey(dir: "/d", name: id)], "per dir: only the dir where the name is live")
        XCTAssertTrue(AgentIsland.reviveAllTaken(history, now: now, held: [], endedHolds: true).isEmpty, "nothing live")
    }

    /// Rider 3 (entry 867): dch's basename keeps a trailing "/": a directory named claude/ in the session's argv
    /// is no claude token, so the record's command is agent.launch (RV_SHELL), not the argv.
    func testRecordCommandTakesNoDirectoryNamedClaudeForClaude() {
        var r = rec("api")
        r.argv = ["direnv", "exec", "/Users/example/code/claude/", "zsh"]
        r.agent = DchHistoryRecord.Agent(kind: "claude", launch: ["claude", "--chrome"])
        XCTAssertEqual(AgentIsland.recordCommand(r), ["claude", "--chrome"])
        r.argv = ["direnv", "exec", "/Users/example/code/claude/", "claude"]
        XCTAssertEqual(AgentIsland.recordCommand(r), r.argv, "the real claude word: the argv")
    }

    /// Rider 3: strippingResume's own claude token skips a directory named claude/, so a wrapper's own flag
    /// before the real claude (here --continue) is the wrapper's and stays.
    func testStrippingResumeTakesNoDirectoryNamedClaudeForTheToken() {
        let argv = ["/Users/example/bin/wrap", "--dir", "/Users/example/claude/", "--continue", "claude", "--chrome"]
        XCTAssertEqual(AgentIsland.strippingResume(argv), argv)
        XCTAssertEqual(AgentIsland.strippingResume(argv + ["--continue"]), argv, "claude's own --continue goes")
    }

    /// Rider 3: claudeRuns' env site: a directory named env/ as argv[0] is no env, so claude after it
    /// is not the program run.
    func testClaudeRunsTakesNoDirectoryNamedEnvForEnv() {
        XCTAssertFalse(AgentIsland.claudeRuns(["/Users/example/env/", "FOO=1", "claude"], tok: 2))
        XCTAssertTrue(AgentIsland.claudeRuns(["/usr/bin/env", "FOO=1", "claude"], tok: 2), "the real env")
    }
}
