import XCTest
@testable import ProsperApp

/// #1338: Settings > Agent Island > Pairs, the sidekick suffix field (spec-pairs S6). The commit is driven as a function
/// with a controller of the test's own (no panel, no Settings window shown); Preferences are the XCTest in-memory suite,
/// the key saved and restored per test.
final class AgentIslandSuffixSettingTests: XCTestCase {
    private static let key = "agentIslandSidekickSuffix"
    private static let refusal = "Not saved: 1 to 16 letters, digits, \".\", \"_\" or \"-\", with at least one letter"

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
                           "Not used, pairs are off: 1 to 16 letters, digits, \".\", \"_\" or \"-\", with at least one letter")
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

    /// R1338-s1: the pane's hooks sit on the New session section (Settings scrolls lazily, so hooks on Pairs would
    /// fire as Pairs scrolls); Pairs has only its own suffix commit on leaving. A source pin.
    func testPaneHooksStayOnNewSessionAndPairsCommitsItsOwn() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/ProsperApp/AgentIsland/AgentIslandPane.swift"), encoding: .utf8)
        let newSession = try XCTUnwrap(source.range(of: "NeonSection(\"New session\""))
        let pairs = try XCTUnwrap(source.range(of: "NeonSection(\"Pairs\""))
        XCTAssertTrue(newSession.lowerBound < pairs.lowerBound)
        let first = String(source[newSession.upperBound..<pairs.lowerBound])
        XCTAssertTrue(first.contains(".onAppear {"), "Command inference leaves the New session section")
        XCTAssertTrue(first.contains("Self.commit(command)") && first.contains("Self.commitModel(model)"),
                      "Command and Default model commits leave the New session section")
        XCTAssertFalse(first.contains("commitSuffix"))
        let second = String(source[pairs.upperBound...])
        XCTAssertTrue(second.contains(".onDisappear { if suffix != suffixSaved { _ = Self.commitSuffix(suffix) } }"))
        XCTAssertFalse(second.contains(".onAppear"), "Pairs has no onAppear")
        XCTAssertFalse(second.contains("Self.commit(command)"), "Pairs does not carry the Command commit")
    }

    /// R909-2: the refusal names the letter rule (#909: a suffix with no letter would read every x-N as a sidekick of x).
    @MainActor
    func testSuffixRuleNamesTheLetterR909() {
        XCTAssertEqual(AgentIslandPane.suffixRule, "1 to 16 letters, digits, \".\", \"_\" or \"-\", with at least one letter")
        withIsland { c, _ in
            XCTAssertTrue(AgentIslandPane.commitSuffix("-qa", c) == nil)
            for s in ["-", "-1", "_", ".", "--"] {
                XCTAssertEqual(AgentIslandPane.commitSuffix(s, c), Self.refusal, s.debugDescription)
                XCTAssertEqual(Preferences.agentIslandSidekickSuffix, "-qa", "kept: \(s.debugDescription)")
            }
            XCTAssertTrue(AgentIslandPane.commitSuffix("-qa2", c) == nil, "digits with a letter are fine")
            XCTAssertEqual(AgentIslandPane.suffixHint("-1"),
                           "Not used, pairs are off: 1 to 16 letters, digits, \".\", \"_\" or \"-\", with at least one letter")
        }
    }

    /// #907 (#847 D4.1, D4.2): the Sidekick prompt setting: unset reads the default, stored trimmed, empty removes the
    /// key (the default again), per Mac; the New session footer says what a sidekick is.
    @MainActor
    func testSidekickPromptSettingReadsTheDefaultTrimsAndEmptyRemoves() {
        XCTAssertTrue(Preferences.defaults is XCTestDefaults, "the scratch in-memory suite, never the app's")
        let k = "agentIslandSidekickPrompt", saved = Preferences.defaults.object(forKey: k)
        defer { Preferences.defaults.set(saved, forKey: k) }
        Preferences.defaults.removeObject(forKey: k)
        XCTAssertEqual(Preferences.agentIslandSidekickPrompt, AgentNewSession.sidekickPromptDefault)
        XCTAssertEqual(AgentIslandPane.commitSidekickPrompt("  review $name\n"), "review $name")
        XCTAssertEqual(Preferences.defaults.object(forKey: k) as? String, "review $name", "stored trimmed")
        XCTAssertEqual(AgentIslandPane.commitSidekickPrompt(" \n "), AgentNewSession.sidekickPromptDefault, "empty: the default again")
        XCTAssertTrue(Preferences.defaults.object(forKey: k) == nil, "the key removed")
        XCTAssertFalse(SyncedKeys.isSynced(k), "per Mac")
        XCTAssertEqual(AgentIslandPane.newSessionFooter,
                       "What New session runs in the chosen folder, e.g. claude or headroom wrap claude --chrome. A sidekick runs "
                       + "the same command in the same folder as <name><suffix>, the suffix under Pairs. Its first message is the "
                       + "sidekick prompt, with $name replaced by the main session's name.")
    }
}
