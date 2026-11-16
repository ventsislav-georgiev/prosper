import XCTest
@testable import ProsperApp

/// #1338: Settings > Agent Island > Pairs, the sidekick suffix field (spec-pairs S6). The commit is driven as a function
/// with a controller of the test's own (no panel, no Settings window shown); Preferences are the XCTest in-memory suite,
/// the key saved and restored per test.
final class AgentIslandSuffixSettingTests: XCTestCase {
    private static let key = "agentIslandSidekickSuffix"
    private static let refusal = "Not saved: 1 to 16 letters, digits, \".\", \"_\" or \"-\""

    private let geometry = AgentIslandGeometry.make(
        frame: CGRect(x: 0, y: 0, width: 1512, height: 982), visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 950),
        topLeft: CGRect(x: 0, y: 950, width: 663.5, height: 32), topRight: CGRect(x: 848.5, y: 950, width: 663.5, height: 32),
        safeTop: 32)

    private func session(_ name: String) -> AgentSession {
        AgentSession(key: AgentSessionKey(dir: "/d", name: name), alias: "", activity: 0, state: .idle, agents: 0)
    }

    /// The key saved and restored; a controller with no panel and a store listing api, api-rev and api-qa.
    @MainActor
    private func withIsland(_ body: (AgentIslandController, AgentIslandStore) throws -> Void) rethrows {
        XCTAssertTrue(Preferences.defaults is XCTestDefaults, "the scratch in-memory suite, never the app's")
        let saved = Preferences.defaults.object(forKey: Self.key)
        defer { Preferences.defaults.set(saved, forKey: Self.key) }
        let c = AgentIslandController()
        c.showsPanel = false
        let store = AgentIslandStore(geometry: geometry)
        store.sessions = [session("api"), session("api-rev"), session("api-qa")]
        c.store = store
        try body(c, store)
    }

    @MainActor
    func testValidSuffixIsStoredTrimmedAndTheIslandRegroupsAtOnce() {
        withIsland { c, store in
            XCTAssertTrue(store.groups.isEmpty, "a store built outright reads no suffix yet")
            XCTAssertTrue(AgentIslandPane.commitSuffix(" -rev\n", c) == nil)
            XCTAssertEqual(Preferences.defaults.object(forKey: Self.key) as? String, "-rev", "stored trimmed")
            XCTAssertEqual(store.pairSuffix, "-rev", "pushed to the open island by the commit")
            XCTAssertEqual(store.groups, [AgentGroup(dir: "/d", stem: "api", mains: ["api"], sidekicks: ["api-rev"])])
            XCTAssertTrue(AgentIslandPane.commitSuffix("-qa", c) == nil)
            XCTAssertEqual(store.groups, [AgentGroup(dir: "/d", stem: "api", mains: ["api"], sidekicks: ["api-qa"])])
            let sixteen = String(repeating: "a", count: 16)
            XCTAssertTrue(AgentIslandPane.commitSuffix(sixteen, c) == nil, "16 bytes is the cap, kept")
            XCTAssertEqual(Preferences.agentIslandSidekickSuffix, sixteen)
        }
    }

    @MainActor
    func testInvalidSuffixIsRefusedWithWhyAndTheOldOneStays() {
        withIsland { c, store in
            XCTAssertTrue(AgentIslandPane.commitSuffix("-qa", c) == nil)
            let refused = [String(repeating: "a", count: 17), "-q a", "-q\u{E4}", "\u{E4}", "a/b", "-q\u{0}"]
            for s in refused {
                XCTAssertEqual(AgentIslandPane.commitSuffix(s, c), Self.refusal, s.debugDescription)
                XCTAssertEqual(Preferences.defaults.object(forKey: Self.key) as? String, "-qa", "kept: \(s.debugDescription)")
                XCTAssertEqual(store.pairSuffix, "-qa", s.debugDescription)
            }
            XCTAssertEqual(store.groups.count, 1, "still paired by the old suffix")
            Preferences.agentIslandSidekickSuffix = "a/b"   // written from outside: shown, never rewritten
            XCTAssertEqual(AgentIslandPane.suffixHint(Preferences.agentIslandSidekickSuffix),
                           "Not used, pairs are off: 1 to 16 letters, digits, \".\", \"_\" or \"-\"")
            XCTAssertEqual(Preferences.agentIslandSidekickSuffix, "a/b")
        }
    }

    @MainActor
    func testEmptyIsStoredAsEmptyAndTurnsPairsOff() {
        withIsland { c, store in
            XCTAssertTrue(AgentIslandPane.commitSuffix("-qa", c) == nil)
            XCTAssertEqual(store.groups.count, 1)
            XCTAssertTrue(AgentIslandPane.commitSuffix("  \n", c) == nil, "empty is a value, not a refusal")
            XCTAssertEqual(Preferences.defaults.object(forKey: Self.key) as? String, "", "kept as \"\", the key stays")
            XCTAssertEqual(Preferences.agentIslandSidekickSuffix, "", "reads back \"\", not -qa")
            XCTAssertEqual(store.pairSuffix, "")
            XCTAssertTrue(store.groups.isEmpty, "pairs by name are off")
            XCTAssertEqual(AgentIslandPane.suffixHint(""), "Off: no pairs by name. Type a suffix to turn pairs on")
        }
    }

    @MainActor
    func testAbsentKeyReadsTheDefaultAndTheLineSaysWhatItDoes() {
        withIsland { _, _ in
            Preferences.defaults.removeObject(forKey: Self.key)
            XCTAssertEqual(Preferences.agentIslandSidekickSuffix, "-qa")
            XCTAssertEqual(AgentIslandPane.suffixHint(Preferences.agentIslandSidekickSuffix),
                           "<name> and <name>-qa act as a pair: Stop both, Resume both. Empty turns pairs off")
        }
    }
}
