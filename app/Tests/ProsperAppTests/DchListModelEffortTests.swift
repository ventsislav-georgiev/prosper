import XCTest
@testable import ProsperApp

/// #1519 (P4 of #1192): the phone list row's "model" and "effort" (only where the Mac's badges would show them:
/// AgentIslandRowDetails.modelEffort against Preferences' Default model and effort) and "activity" (epoch seconds
/// the Mac's age slot is computed from). Fakes only; no defaults are read.
final class DchListModelEffortTests: XCTestCase {
    private static let dir = "/Users/example/dch"

    private func session(model: String?, effort: String?, claude: Bool = true, activity: TimeInterval = 1_799_999_940) -> AgentSession {
        var s = AgentSession(key: AgentSessionKey(dir: Self.dir, name: "api"), alias: "", activity: activity, state: .idle, agents: 0,
                             transcriptPath: claude ? "/Users/example/api.jsonl" : nil)
        s.model = model; s.effort = effort
        return s
    }

    /// The listPayload text of one session through DchWatchHub.cache.
    private func wire(_ s: AgentSession, defaultModel: String = "", defaultEffort: String = "") throws -> String {
        let cache = try XCTUnwrap(DchWatchHub.cache(island: [s], dirs: [Self.dir], remote: Self.dir,
                                                    defaultModel: defaultModel, defaultEffort: defaultEffort))
        return String(decoding: DchFrame.listPayload(cache.rows), as: UTF8.self)
    }

    /// Literal table: present when it differs from the Default, absent when equal, unknown, or not a Claude row.
    func testModelAndEffortAreSentOnlyWhereTheyDifferFromTheDefault() throws {
        let opus = "claude-opus-4-7", sonnet = "claude-sonnet-4-6"
        let a = #""activity":1799999940"#
        let table: [(String, AgentSession, String, String, String)] = [
            ("no default", session(model: opus, effort: "high"), "", "", #"[{\#(a),"effort":"high","model":"Opus 4.7","name":"api","state":"idle"}]"#),
            ("both equal", session(model: opus, effort: "high"), opus, "high", #"[{\#(a),"name":"api","state":"idle"}]"#),
            ("both differ", session(model: sonnet, effort: "medium"), opus, "high",
             #"[{\#(a),"effort":"medium","model":"Sonnet 4.6","name":"api","state":"idle"}]"#),
            ("effort only", session(model: opus, effort: "max"), opus, "high", #"[{\#(a),"effort":"max","name":"api","state":"idle"}]"#),
            ("model only", session(model: sonnet, effort: "high"), opus, "high", #"[{\#(a),"model":"Sonnet 4.6","name":"api","state":"idle"}]"#),
            ("family alias default", session(model: opus, effort: nil), "opus", "", #"[{\#(a),"name":"api","state":"idle"}]"#),
            ("unknown model", session(model: nil, effort: "high"), "", "", #"[{\#(a),"name":"api","state":"idle"}]"#),
            ("not a Claude row", session(model: opus, effort: "high", claude: false), "", "", #"[{\#(a),"name":"api","state":"idle"}]"#),
            ("unknown effort", session(model: opus, effort: nil), "", "", #"[{\#(a),"model":"Opus 4.7","name":"api","state":"idle"}]"#),
        ]
        for (label, s, dm, de, expected) in table {
            XCTAssertEqual(try wire(s, defaultModel: dm, defaultEffort: de), expected, label)
        }
    }

    /// The age's epoch goes as a JSON integer (not a string or a float), and is absent when unknown (0).
    func testActivityIsAnIntegerOfEpochSecondsAndAbsentWhenUnknown() throws {
        let s = session(model: nil, effort: nil, activity: 1_799_999_940.9)
        let text = try wire(s)
        XCTAssertTrue(text.contains(#""activity":1799999940,"#), text)
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]])
        let n = try XCTUnwrap(rows.first?["activity"] as? NSNumber)
        XCTAssertFalse(CFNumberIsFloatType(n), "an integer, not a float")
        XCTAssertEqual(n.intValue, 1_799_999_940)
        XCTAssertTrue(try wire(session(model: nil, effort: nil, activity: 0)) == #"[{"name":"api","state":"idle"}]"#)
    }

    /// The epoch is floored to the minute (a multiple of 60) before it goes into the row.
    func testActivityIsFlooredToTheMinute() throws {
        XCTAssertTrue(try wire(session(model: nil, effort: nil, activity: 1_799_999_999)).contains(#""activity":1799999940,"#))
        XCTAssertTrue(try wire(session(model: nil, effort: nil, activity: 59)) == #"[{"name":"api","state":"idle"}]"#, "minute 0: unknown")
    }

    /// #2001: the phone row carries `agent` as dch serve does (serve.c:371-382@v1.186.0): "claude" or "codex", else the
    /// key left out (dch's null, an older dch's none, any other word). Red at base: no "agent" key at all.
    func testAgentIsSentAsDchServeSendsIt() throws {
        func with(_ a: String?) -> AgentSession { var s = session(model: nil, effort: nil, claude: false, activity: 0); s.agent = a; return s }
        XCTAssertEqual(try wire(with("codex")), #"[{"agent":"codex","name":"api","state":"idle"}]"#)
        XCTAssertEqual(try wire(with("claude")), #"[{"agent":"claude","name":"api","state":"idle"}]"#)
        XCTAssertEqual(try wire(with("")), #"[{"name":"api","state":"idle"}]"#, "a shell: dch's null, no key")
        XCTAssertEqual(try wire(with(nil)), #"[{"name":"api","state":"idle"}]"#, "an older dch: no key")
        let odd = DchListRow(name: "a", alias: "", activityEpoch: 0, state: "", agents: 0, agent: "gemini")
        XCTAssertEqual(String(decoding: DchFrame.listPayload([odd]), as: UTF8.self), #"[{"name":"a"}]"#)
    }

    /// The caps: a model over AgentModelEffort.maxModelLength bytes and an effort that is no level are left out.
    func testOutsideValuesAreCapped() {
        func payload(_ model: String, _ effort: String) -> String {
            String(decoding: DchFrame.listPayload([DchListRow(name: "a", alias: "", activityEpoch: 0, state: "", agents: 0,
                                                              model: model, effort: effort)]), as: UTF8.self)
        }
        let atCap = String(repeating: "m", count: DchListRow.maxModelBytes)
        XCTAssertEqual(DchListRow.maxModelBytes, 128)
        XCTAssertEqual(payload(atCap, "xhigh"), #"[{"effort":"xhigh","model":""# + atCap + #"","name":"a"}]"#)
        XCTAssertEqual(payload(atCap + "m", "bogus"), #"[{"name":"a"}]"#)
        XCTAssertEqual(payload("", ""), #"[{"name":"a"}]"#)
    }
}
