import AppKit
import XCTest
@testable import ProsperApp

/// #1358: "Kill" reads "End" in every user-visible Agent Sessions and Agent Island text, and every item of the Agent
/// Sessions menus has a leading SF Symbol (the same one for the same action). The menus are read as entries lists:
/// no NSMenu is built or popped, no window is shown, no dch runs, no event is posted.
final class AgentEndSymbolTests: XCTestCase {
    static let now: TimeInterval = 1_800_000_000
    static let dir = "/tmp/dch-test"
    static let door = "rectangle.portrait.and.arrow.right"

    func session(_ name: String) -> AgentSession {
        AgentSession(key: AgentSessionKey(dir: Self.dir, name: name), alias: "", activity: Self.now - 60, state: .idle,
                     agents: 0, version: "1.30.0")
    }

    func record(_ name: String, pinned: Bool = false) -> DchHistoryRecord {
        var r = DchHistoryRecord(key: AgentSessionKey(dir: Self.dir, name: name))
        r.cwd = "/Users/example/\(name)"
        r.started = Self.now - 3600
        r.ended = Self.now - 60
        r.updated = Self.now - 60
        r.end = "signal 9"
        r.pinned = pinned
        return r
    }

    @MainActor
    func store(_ sessions: [AgentSession], history: [DchHistoryRecord] = []) -> AgentIslandStore {
        let s = AgentIslandStore(geometry: AgentWindowD1Tests.geometry)
        s.now = { Self.now }
        s.controlDch = DchCommand.Binary(path: "/fake/dch", version: [1, 38, 0])
        s.sessions = sessions
        s.history = history
        return s
    }

    /// "title|symbol" for an item that draws; nil for a divider or a note.
    func pair(_ e: AgentWindowMenuEntry) -> String? {
        let title: String
        switch e {
        case .item(let t, _, _), .pane(let t, _, _), .side(let t, _): title = t
        case .open: title = AgentWindowControls.openLabel
        case .chapters: title = AgentWindowControls.chaptersLabel
        case .xray: title = AgentWindowControls.xrayLabel
        case .divider, .note: return nil
        }
        return "\(title)|\(e.symbol ?? "NO SYMBOL")"
    }

    /// Every item and submenu of a sidebar menu, depth first.
    func flat(_ entries: [AgentSidebarMenuEntry]) -> [String] {
        entries.flatMap { e -> [String] in
            switch e {
            case .item(let t, _, _, _): ["\(t)|\(e.symbol ?? "NO SYMBOL")"]
            case .submenu(let t, _, let items): ["\(t)|\(e.symbol ?? "NO SYMBOL")"] + flat(items)
            case .divider, .note: []
            }
        }
    }

    // MARK: The words

    /// Each renamed label, question and line against a LITERAL expectation (never a loop over the statics under test);
    /// the name set is pinned, and none of the words says kill.
    @MainActor
    func testEveryEndWordIsLiteral() {
        let r = { (status: Int32, out: String, stopped: Bool) in
            AgentIsland.actionResult(status: status, output: Data(out.utf8), stopped: stopped)
        }
        let st = store([session("api")])
        st.confirmingKillAll = true
        let rows: [(String, String, String)] = [
            ("killLabel", AgentIsland.killLabel, "End\u{2026}"),
            ("killingText", AgentIsland.killingText, "Ending session\u{2026}"),
            ("killAllLabel", AgentIsland.killAllLabel(tab: "Sidekicks"), "End all in Sidekicks\u{2026}"),
            ("killAllGlobalLabel", AgentIsland.killAllGlobalLabel, "End all\u{2026}"),
            ("killQuestion", AgentIsland.killQuestion("api"), "End api? No pause message first."),
            ("killAllQuestion", AgentIsland.killAllQuestion(2, skipped: 0, tab: "Sessions"),
             "End 2 sessions in Sessions? No pause message first."),
            ("killAllQuestion1", AgentIsland.killAllQuestion(1, skipped: 0, tab: nil, tabs: false),
             "End 1 session? No pause message first."),
            ("killBusyText", AgentIsland.killBusyText, "End not run: another job is running"),
            ("killedText", AgentIsland.killedText, "Ended"),
            ("killText ok", AgentIsland.killText(r(0, "killed: a\n", false)), "Ended"),
            ("killText cancelled", AgentIsland.killText(r(143, "", true)), "End cancelled: no answer in 5m"),
            ("killText failed", AgentIsland.killText(r(1, "dch: cannot connect\n", false)), "End failed: dch: cannot connect"),
            ("killText failed exit", AgentIsland.killText(r(0, "", false)), "End failed (exit 0)"),
            ("killTally", AgentIsland.killTally(killed: 2, gone: 1, failed: 1, busy: 1), "2 ended, 1 already ended, 1 failed, 1 busy"),
            ("killTally none", AgentIsland.killTally(killed: 0, gone: 0, failed: 0, busy: 0), "nothing ended"),
            ("confirmTitle", AgentWindowControls.confirmTitle(.kill), "End"),
            ("window question", AgentWindowControls.question(.kill, session("api")), "End api? No pause message first."),
            ("store question action", AgentWindowControls.storeQuestion(st)?.action ?? "none", "End"),
            ("pane menu help", AgentSessionMenuButton.help(session("api")),
             "Open in terminal, rename, restart, stop or end this session"),
            ("sidebar menu help", AgentWindowControls.sidebarMenuHelp,
             "New session, restart, stop or end all, History and Agent Island settings"),
        ]
        XCTAssertEqual(Set(rows.map(\.0)), ["killLabel", "killingText", "killAllLabel", "killAllGlobalLabel", "killQuestion",
                                            "killAllQuestion", "killAllQuestion1", "killBusyText", "killedText", "killText ok",
                                            "killText cancelled", "killText failed", "killText failed exit", "killTally",
                                            "killTally none", "confirmTitle", "window question", "store question action",
                                            "pane menu help", "sidebar menu help"])
        for (name, got, want) in rows {
            XCTAssertEqual(got, want, name)
            XCTAssertFalse(got.lowercased().contains("kill"), "\(name) says kill: \(got)")
        }
    }

    /// End's running text is no dch phase word: runningTexts match whole texts, so "Ending session\u{2026}" is not one
    /// ("Ending\u{2026}" is). It locks no input and a busy refusal still writes its own line, as at TIP.
    func testEndRunningTextIsNotARunningText() {
        XCTAssertEqual(AgentIsland.killingText, "Ending session\u{2026}")
        XCTAssertFalse(AgentIsland.runningTexts.contains(AgentIsland.killingText))
        XCTAssertTrue(AgentIsland.runningTexts.contains("Ending\u{2026}"))
        XCTAssertTrue(AgentWindowControls.lock(AgentIsland.killingText) == nil)
        XCTAssertEqual(AgentIsland.killBusyText, "End not run: another job is running")
    }

    /// The dir-wide lines that count a row a Kill ended say ended (the raw dch end "killed" is not shown).
    func testTalliesCountEndedRows() {
        let out = #"{"name":"a","result":"failed","reason":"x","detail":"a: x"}"# + "\n"
        var r = AgentIsland.actionResult(status: 1, output: Data(out.utf8))
        r.killed = ["a"]
        XCTAssertEqual(AgentIsland.tally(r, .stop, title: "Stop all", empty: "none"), "1 ended")
        XCTAssertEqual(AgentIsland.restartAllSummary(r), "1 ended")
        XCTAssertEqual(AgentIsland.rowText(r, name: "a", .stop), "Ended")
    }

    /// The words that live inside SwiftUI bodies and the stale-help strings (not reachable as values): no string literal
    /// of the island's and the window's GUI files holds "kill" in any case (R1358-i1). Comments and identifiers are not
    /// strings. LITERAL allowlist: (file, exact text, why); the text is cut from the line before the scan, and every
    /// entry must still occur (a stale entry fails).
    func testNoKillLiteralInTheGUIFiles() throws {
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let files = ["AgentIsland/AgentIslandActions.swift", "AgentIsland/AgentIslandController.swift",
                     "AgentIsland/AgentIslandView.swift", "AgentWindow/AgentWindowControls.swift",
                     "AgentWindow/AgentWindowModel.swift", "AgentWindow/AgentsWindow.swift"]
        let allowed: [(file: String, text: String, why: String)] = [
            ("AgentIsland/AgentIslandActions.swift", #"case "killed": return "closed""#, "dch's raw end state, shown as closed"),
            ("AgentIsland/AgentIslandActions.swift", #"["exit 0", "killed", "stopped"]"#, "dch's raw end states"),
            ("AgentIsland/AgentIslandActions.swift", #"\(killed)"#, "an identifier in an interpolation (the count)"),
            ("AgentIsland/AgentIslandActions.swift", #"\(killWarning)"#, "an identifier in an interpolation"),
            ("AgentIsland/AgentIslandActions.swift", #"hasPrefix("killed: ")"#, "dch's output line, parsed"),
            ("AgentIsland/AgentIslandActions.swift", #""stop", "kill", "ultrareview""#, "dch's subcommand names"),
        ]
        var used = Set<Int>()
        let literal = try NSRegularExpression(pattern: #""[^"\n]*kill[^"\n]*""#, options: .caseInsensitive)
        for f in files {
            let text = try String(contentsOf: app.appendingPathComponent("Sources/ProsperApp/\(f)"), encoding: .utf8)
            XCTAssertFalse(text.isEmpty, f)
            for (i, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            where !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                var code = line.components(separatedBy: " //")[0]
                for (k, a) in allowed.enumerated() where a.file == f && code.contains(a.text) {
                    used.insert(k)
                    code = code.replacingOccurrences(of: a.text, with: "")
                }
                XCTAssertEqual(literal.numberOfMatches(in: code, range: NSRange(code.startIndex..., in: code)), 0,
                               "\(f):\(i + 1) has a kill string: \(line)")
            }
        }
        XCTAssertEqual(used, Set(allowed.indices), "an allowlist entry no longer occurs: drop it")
    }

    // MARK: The symbols

    /// A live row's pane and row menu: each item with its symbol, literal.
    @MainActor
    func testLiveRowMenuEntriesCarryTheirSymbols() {
        let a = session("api"), st = store([a])
        let entries = AgentWindowControls.rowMenu(a, store: st, splits: true, side: nil)
        XCTAssertEqual(entries.compactMap(pair), [
            "Open in terminal|terminal", "Open to the Side|sidebar.right", "Rename\u{2026}|pencil",
            "Restart agent\u{2026}|arrow.clockwise", "Stop\u{2026}|stop.circle", "End\u{2026}|\(Self.door)",
        ])
        XCTAssertEqual(entries.filter { pair($0) == nil }.count, entries.count - 6, "only dividers and notes have none")
        XCTAssertEqual(entries.filter { if case .divider = $0 { true } else { false } }.count, entries.count - 6)
        let header = AgentWindowControls.sessionMenu(a, store: st, ended: false)
        XCTAssertEqual(header.compactMap(pair).first, "Open in terminal|terminal")
        XCTAssertEqual(AgentWindowControls.sessionMenu(a, store: nil, ended: true).compactMap(pair), ["Open in terminal|terminal"])
    }

    @MainActor
    func testPaneMenuEntriesCarryTheirSymbols() {
        XCTAssertEqual(AgentWindowControls.paneMenu(splits: true, panes: 2, right: nil, down: nil).compactMap(pair), [
            "Split Right|rectangle.split.2x1", "Split Down|rectangle.split.1x2", "Zoom|arrow.up.left.and.arrow.down.right",
            "Equalize|equal.square", "\(AgentWindowControls.closePaneLabel)|xmark.rectangle",
        ])
    }

    @MainActor
    func testHistoryRowMenuEntriesCarryTheirSymbols() {
        let h = record("api"), p = record("api-qa", pinned: true)
        let st = store([], history: [h, p])
        XCTAssertEqual(AgentWindowControls.historyMenu(h, store: st).compactMap(pair), [
            "Resume|play.fill", "Resume (no message)|forward.end", "Pin|pin", "Remove from History\u{2026}|trash",
        ])
        XCTAssertEqual(AgentWindowControls.historyMenu(p, store: st).compactMap(pair), [
            "Resume|play.fill", "Resume (no message)|forward.end", "Unpin|pin.slash",
            "Remove from History (unpin it first)|trash",
        ])
    }

    /// The sidebar "..." : items, submenus and the entries inside them all draw a symbol; the list-wide verbs wear the
    /// symbol of the row verb they run for every session.
    @MainActor
    func testSidebarMenuEntriesCarryTheirSymbols() {
        let st = store([session("api")], history: [record("old")])
        let got = flat(AgentWindowControls.sidebarMenu(store: st, autoAllow: false))
        XCTAssertFalse(got.contains { $0.hasSuffix("|NO SYMBOL") }, "\(got)")
        for want in ["Restart stale agents\u{2026}|arrow.clockwise", "Restart all agents (force)\u{2026}|arrow.clockwise",
                     "Stop all\u{2026}|stop.circle", "End all\u{2026}|\(Self.door)", "Clear unpinned\u{2026}|trash",
                     "Sort|arrow.up.arrow.down", "Last activity|clock", "Name|textformat", "Row details|list.bullet.rectangle",
                     "Always allow permission prompts|checkmark.shield", "Agent Island Settings\u{2026}|gearshape",
                     "Diagnostics\u{2026}|stethoscope", "New session|plus", "Choose folder\u{2026}|folder.badge.plus"] {
            XCTAssertTrue(got.contains(want), "\(want) in \(got)")
        }
        XCTAssertTrue(got.contains { $0.hasPrefix("Resume interrupted") && $0.hasSuffix("|play.fill") }, "\(got)")
    }

    /// One action, one symbol, in every menu that draws it.
    func testTheSameActionKeepsItsSymbolEverywhere() {
        XCTAssertEqual(AgentSidebarVerb.restartAll(force: true).symbol, AgentWindowVerb.restart.symbol)
        XCTAssertEqual(AgentSidebarVerb.restartAll(force: false).symbol, AgentWindowVerb.restart.symbol)
        XCTAssertEqual(AgentSidebarVerb.stopAll.symbol, AgentWindowVerb.stop.symbol)
        XCTAssertEqual(AgentWindowVerb.stopGroup(["a", "b"]).symbol, AgentWindowVerb.stop.symbol)
        XCTAssertEqual(AgentSidebarVerb.killAll.symbol, AgentWindowVerb.kill.symbol)
        XCTAssertEqual(AgentWindowVerb.kill.symbol, Self.door)
        XCTAssertEqual(AgentSidebarVerb.resumeInterrupted(noMessage: false).symbol, AgentWindowVerb.resume.symbol)
        XCTAssertEqual(AgentWindowVerb.resumeGroup.symbol, AgentWindowVerb.resume.symbol)
        XCTAssertEqual(AgentSidebarVerb.resumeInterrupted(noMessage: true).symbol, AgentWindowVerb.resumeNoMessage.symbol)
        XCTAssertEqual(AgentSidebarVerb.clearUnpinned.symbol, AgentWindowVerb.remove.symbol)
        for verb in [AgentLayoutVerb.rename, .duplicate, .delete] {
            let e = AgentLayoutMenuEntry(title: "x", enabled: true, verb: verb)
            XCTAssertEqual(e.symbol, [AgentLayoutVerb.rename: "pencil", .duplicate: "plus.square.on.square", .delete: "trash"][verb])
        }
        XCTAssertEqual(AgentLayoutMenuEntry(title: "x", enabled: true, verb: .rename).symbol, AgentWindowVerb.rename.symbol)
        XCTAssertEqual(AgentLayoutMenuEntry(title: "x", enabled: true, verb: .delete).symbol, AgentWindowVerb.remove.symbol)
        XCTAssertEqual(AgentWindowMenuEntry.item("Pin", enabled: true, verb: .pin).symbol, "pin")
        XCTAssertEqual(AgentWindowMenuEntry.item("Unpin (also 2 older records of this name)", enabled: true, verb: .pin).symbol, "pin.slash")
    }

    /// Every symbol name resolves on this OS (a typo draws nothing). The literal list is pinned to the product's own set.
    func testEverySymbolNameResolves() {
        let names = ["terminal", "pencil", "arrow.clockwise", "stop.circle", Self.door, "play.fill", "forward.end", "pin",
                     "pin.slash", "trash", "plus.square.on.square", "sidebar.right", "list.bullet", "rectangle.split.2x1",
                     "rectangle.split.1x2", "arrow.up.left.and.arrow.down.right", "equal.square", "xmark.rectangle", "plus",
                     "folder", "folder.badge.plus", "arrow.up.arrow.down", "clock", "textformat", "list.bullet.rectangle",
                     "checkmark.shield", "gearshape", "stethoscope", "rectangle.righthalf.inset.filled"]
        XCTAssertEqual(Set(names), AgentMenuSymbol.all)
        for n in names { XCTAssertTrue(NSImage(systemSymbolName: n, accessibilityDescription: nil) != nil, "\(n) does not resolve") }
    }
}
