import Foundation
import XCTest
@testable import ProsperApp

/// #1990: dch 1.173.0's Codex support as Prosper reads it, from fake dch answers only (no dch runs): --say into a
/// Codex session, the History record's "codex" object, the two new --revive ok details, and the JSON-decoded harness.
final class DchCodexSessionsTests: XCTestCase {
    static let thread = "019a0000-aaaa-bbbb-cccc-0123456789ab"

    // MARK: --say

    /// A Codex session now answers ok (nothing to say); not_claude means neither Claude nor Codex, and says so.
    @MainActor
    func testCodexSayOkSendsAndNotClaudeNamesBothAgents() {
        let ok = #"{"name":"api","result":"ok","reason":"","detail":"sent","session_id":""}"#
        XCTAssertTrue(AgentWindowDriver.sayFailure(AgentWindowDriver.sayReply(ok)) == nil, "a Codex session's ok is a send")
        let skipped = #"{"name":"api","result":"skipped","reason":"not_claude","detail":"no claude runs in the session","session_id":""}"#
        let why = AgentWindowDriver.sayFailure(AgentWindowDriver.sayReply(skipped))
        XCTAssertEqual(why, "No Claude or Codex is running in this session. Open in terminal")
        XCTAssertEqual(why, AgentWindowText.notClaude)
        XCTAssertFalse(AgentWindowText.notClaude.contains("Claude isn't running"), "the 1.172 text named Claude alone")
    }

    // MARK: --history --json "codex"

    /// The "codex" object read leniently: absent, not an object, a non-string or empty thread_id are nil; a missing
    /// or non-string home is "". The rest of each record reads as before.
    @MainActor
    func testHistoryRecordReadsCodexLeniently() {
        let t = Self.thread
        let json = """
        [{"name":"a","cwd":"/Users/example/a","ended":3,"end":"stopped","codex":{"thread_id":"\(t)","home":"/Users/example/.codex"}},
         {"name":"b","ended":2,"end":"stopped","agent":{"kind":"claude","session_id":"sid-b","name":"","cwd":"/b","launch":[]}},
         {"name":"c","codex":"\(t)"},
         {"name":"d","codex":{"thread_id":42,"home":"/h"}},
         {"name":"e","codex":{"thread_id":"\(t)","home":7}},
         {"name":"f","codex":{"thread_id":""}},
         {"name":"g","codex":null},
         {"name":"h","codex":[1,2]}]
        """
        let rows = AgentIsland.parseHistory(Data(json.utf8), dir: "/d")
        XCTAssertEqual(rows.map(\.name), ["a", "b", "c", "d", "e", "f", "g", "h"], "no record dropped by its codex value")
        XCTAssertEqual(rows.map(\.codex), [DchHistoryRecord.Codex(threadID: t, home: "/Users/example/.codex"), nil, nil, nil,
                                           DchHistoryRecord.Codex(threadID: t, home: ""), nil, nil, nil])
        XCTAssertEqual(rows.first?.cwd, "/Users/example/a")
        XCTAssertEqual(rows.dropFirst().first?.agent?.sessionID, "sid-b")
    }

    /// Remove's question names Codex and its by-hand resume for a Codex record; a Claude id still wins.
    @MainActor
    func testRemoveQuestionNamesACodexRecordsThread() {
        var r = DchHistoryRecord(key: AgentSessionKey(dir: "/d", name: "api"), codex: DchHistoryRecord.Codex(threadID: Self.thread))
        XCTAssertEqual(AgentWindowControls.removeQuestion(r),
                       "Remove api from History? Resume won't be able to bring it back. Its Codex conversation stays on disk."
                           + " (codex resume \(Self.thread))")
        r.agent = .init(kind: "claude", sessionID: "sid-api")
        XCTAssertEqual(AgentWindowControls.removeQuestion(r),
                       "Remove api from History? Resume won't be able to bring it back. Its Claude Code conversation stays on disk."
                           + " (claude --resume sid-api)")
    }

    // MARK: --revive

    /// dch 1.173.0's two ok details: codex resumed reads as any Resume; codex NOT resumed keeps dch's words and command.
    @MainActor
    func testCodexReviveDetailsReadFine() throws {
        func line(_ detail: String, as name: String = "api") throws -> DchJSONLine {
            try XCTUnwrap(AgentIsland.jsonLine(#"{"name":"api","result":"ok","reason":"","detail":"\#(detail)","session_id":"\#(Self.thread)","as":"\#(name)"}"#))
        }
        let resumed = try line("revived as api in /Users/example/api, codex resumed \(Self.thread); resume message passed as its prompt")
        XCTAssertEqual(AgentIsland.finalText(resumed, .resume), "Resumed")
        let quiet = try line("revived as api in /Users/example/api, codex resumed \(Self.thread); resume message not sent (--no-message)")
        XCTAssertEqual(AgentIsland.finalText(quiet, .resumeNoMessage), "Resumed without the message")
        let tail = "; codex NOT resumed (not an interactive codex command): codex resume \(Self.thread)"
        let not = try line("revived as api in /Users/example/api" + tail)
        XCTAssertEqual(AgentIsland.finalText(not, .resume), "Resumed" + tail)
        XCTAssertEqual(AgentIsland.finalText(not, .resumeNoMessage), "Resumed without the message" + tail)
        let renamed = try line("revived as api-2 in /Users/example/api" + tail, as: "api-2")
        XCTAssertEqual(AgentIsland.finalText(renamed, .resume), "Resumed as api-2" + tail)
    }

    // MARK: --ls-json harness (#661)

    /// The harness title is a JSON string: escapes decode to the plain title, no quote marks are added, and the
    /// Sidekicks split matches the title itself.
    @MainActor
    func testHarnessIsAPlainDecodedTitle() {
        let json = #"[{"name":"api","alias":"Api","harness":"say \"hi\" web-qa","activity_epoch":1,"state":"idle","agents":0}]"#
        let rows = AgentIsland.list(dirs: ["/d"]) { _, _ in Data(json.utf8) }
        XCTAssertEqual(rows.first?.harness, #"say "hi" web-qa"#)
        XCTAssertEqual(AgentIsland.split(rows, pattern: #"^say "hi" web-qa$"#).firstGroup.map(\.name), ["api"])
        XCTAssertTrue(AgentIsland.split(rows, pattern: #"^"say"#).firstGroup.isEmpty, "no quote mark leads the title")
    }
}
