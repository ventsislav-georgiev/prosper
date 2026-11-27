import XCTest
@testable import ProsperApp

/// #2002: the window and island name Codex on a Codex row (dch's `agent`): the row marker, the Stop/Restart confirms,
/// the conversation pane's reason, the composer notices and the recent folders. A Claude row and a shell row keep
/// today's words.
final class AgentCodexWindowTests: XCTestCase {
    static let key = AgentSessionKey(dir: "/tmp/dch-test", name: "api")

    func session(_ agent: String?, claudeID: String? = nil, state: AgentState = .idle) -> AgentSession {
        var s = AgentSession(key: Self.key, alias: "", activity: 1, state: state, agents: 0)
        s.agent = agent
        s.claudeSessionID = claudeID
        return s
    }

    /// Gap 3: a Codex row carries the Codex marker, a Claude row the Claude marker, a shell row none; a row without
    /// `agent` (an older dch) is Claude by its session id, else none. The island's row and both labels read the name.
    /// Red at base: Row has no agentKind.
    @MainActor
    func testRowsCarryTheirAgentsMarker() {
        let codex = AgentSidebar.row(session("codex"), details: .all, now: 2)
        XCTAssertEqual(codex.agentKind, .codex)
        XCTAssertEqual(AgentSidebar.row(session("claude"), details: .all, now: 2).agentKind, .claude)
        XCTAssertTrue(AgentSidebar.row(session(""), details: .all, now: 2).agentKind == nil, "a shell: no marker")
        XCTAssertEqual(AgentSidebar.row(session(nil, claudeID: "0b7c2f3e"), details: .all, now: 2).agentKind, .claude)
        XCTAssertTrue(AgentSidebar.row(session(nil), details: .all, now: 2).agentKind == nil, "an older dch, no Claude id")
        XCTAssertNotEqual(AgentSidebar.AgentKind.codex.symbol, AgentSidebar.AgentKind.claude.symbol)
        XCTAssertEqual(AgentIslandRow.sidebarRow(session("codex"), show: .all, now: 2, notice: "Attach command copied").agentKind,
                       .codex, "the island's row with a notice keeps the marker")
        XCTAssertTrue(AgentSidebarRowView(row: codex, selected: false).accessibilityWords.contains("Codex"))
        XCTAssertTrue(AgentIslandRow.accessibilityLabel(session("claude"), now: 2, show: .all).contains("Claude Code"))
        XCTAssertFalse(AgentIslandRow.accessibilityLabel(session(""), now: 2, show: .all).contains("Claude Code"))
    }

    /// Gap 5: Stop and Restart name Codex and warn that a daemon-attached Codex is skipped; Claude and a shell keep
    /// today's text. Red at base: the Codex row says "Claude Code".
    func testStopAndRestartNameTheRunningAgent() {
        let claude = "Restart api? Claude Code is paused, then relaunched on the same conversation. This can take minutes."
        XCTAssertEqual(AgentWindowControls.question(.restart, session("claude")), claude)
        XCTAssertEqual(AgentWindowControls.question(.restart, session("")), claude, "a shell keeps today's text")
        XCTAssertEqual(AgentWindowControls.question(.restart, session("codex")),
                       "Restart api? Codex is paused, then relaunched on the same conversation. This can take minutes."
                       + AgentWindowControls.codexDaemonSentence)
        XCTAssertEqual(AgentWindowControls.question(.stop, session("claude")),
                       "Stop api? Claude Code is paused and the session ends. Resume it later from History.")
        XCTAssertEqual(AgentWindowControls.question(.stop, session("codex", state: .blocked)),
                       "Stop api? Codex is paused and the session ends. Resume it later from History."
                       + AgentWindowControls.codexDaemonSentence + AgentWindowControls.blockedSentence)
    }

    /// Gap 6: a Codex session's pane says why there is no transcript and points at X-ray. Red at base: the source has
    /// no `codex` and the pane says "No transcript matched this session".
    func testCodexPaneSaysItHasNoTranscriptView() {
        let codex = AgentSidebar.source(session("codex"))
        XCTAssertTrue(codex.codex)
        XCTAssertFalse(AgentSidebar.source(session("claude")).codex)
        func mode(_ s: AgentTranscriptSource) -> AgentWindowMode {
            AgentTranscriptModel.mode(source: s, hasView: false, nullSince: Date(timeIntervalSince1970: 0), missing: false,
                                      live: TierCounts(), lastGrowth: nil, toolPending: false, now: Date(timeIntervalSince1970: 100))
        }
        var c = codex
        c.dchVersion = "1.30.0"
        XCTAssertEqual(mode(c), .terminalFirst("Codex sessions have no transcript view here; open X-ray for its chapters"))
        c.codex = false
        XCTAssertEqual(mode(c), .terminalFirst("No transcript matched this session"))
    }

    /// Gap 7: the composer's notices name Codex on a Codex row and keep Claude's words elsewhere. Red at base: no
    /// AgentWindowText.named.
    @MainActor
    func testComposerNoticesNameCodex() {
        XCTAssertEqual(AgentWindowText.named(AgentWindowText.working, codex: true),
                       "Codex is working. Send when it's done, or interrupt it")
        XCTAssertEqual(AgentWindowText.named(AgentWindowText.working, codex: false), AgentWindowText.working)
        XCTAssertEqual(AgentWindowText.named(AgentWindowText.notWorking, codex: true),
                       "Codex isn't working, so there's nothing to interrupt")
        XCTAssertEqual(AgentWindowText.named(AgentWindowText.blocked, codex: true), AgentWindowText.blocked, "agent-neutral")
        for t in [AgentWindowText.draft, AgentWindowText.shellMode, AgentWindowText.notSubmitted, AgentWindowText.shellNotRun,
                  AgentWindowText.shellLeft, AgentWindowText.draftLeft] {
            XCTAssertFalse(AgentWindowText.named(t, codex: true).contains("Claude"), t)
        }
        // The window's Run pill: a working Codex row says Codex.
        let i = AgentWindowInteraction()
        XCTAssertEqual(i.runOff(session("codex", state: .working)), "Codex is working. Send when it's done, or interrupt it")
        XCTAssertEqual(i.runOff(session("claude", state: .working)), AgentWindowText.working)
    }

    /// Gap 9: a folder used only with Codex is a recent folder. Red at base: `r.agent != nil` skips the Codex record.
    func testRecentFoldersIncludeCodexRecords() {
        var cx = DchHistoryRecord(key: AgentSessionKey(dir: "/d", name: "cx"), cwd: "/Users/example/codex-only")
        cx.codex = .init(threadID: "019a0000-0000-7000-8000-000000000001", home: "/Users/example/.codex")
        let plain = DchHistoryRecord(key: AgentSessionKey(dir: "/d", name: "sh"), cwd: "/Users/example/shell")
        XCTAssertEqual(AgentIsland.recentFolders([cx, plain], exists: { _ in true }), ["/Users/example/codex-only"])
    }
}
