import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #584: the island's Message… on a row and Message all in <tab>… in the "⋯" menu, sent with
/// `dch --say <names…> --json -- <text>` on the long-verb runner; and QA #453 L2/L3's row texts.
/// No test runs dch: the runner's launch is a recorder. No window is shown or made key, no event is
/// posted, no menu is opened: the composer's keys are the controller calls its view makes.
final class AgentIslandMessageTests: XCTestCase {
    private let notched = AgentIslandGeometry.make(
        frame: CGRect(x: 0, y: 0, width: 1512, height: 982), visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 950),
        topLeft: CGRect(x: 0, y: 950, width: 663.5, height: 32), topRight: CGRect(x: 848.5, y: 950, width: 663.5, height: 32),
        safeTop: 32)
    private static let v1230 = DchCommand.Binary(path: "/fake/dch", version: [1, 23, 0])
    private static let v1240 = DchCommand.Binary(path: "/fake/dch", version: [1, 24, 0])

    private func session(_ name: String, dir: String = "/d", alias: String = "") -> AgentSession {
        AgentSession(key: AgentSessionKey(dir: dir, name: name), alias: alias, activity: 0, state: .idle, agents: 0)
    }

    /// The runner's process: records each argv and its DCH_SOCKET_DIR, prints the dir's canned output and
    /// exits with its status; with `hold`, only once it is signalled. Also the controller's screen IO: each
    /// `--read` returns the name's screen (default Claude's idle composer) and is logged in `events` with
    /// the launches, with whether it ran on main and whether the runner held the message's key then.
    private final class Proc: @unchecked Sendable {
        let lock = NSLock()
        var launches: [[String]] = []
        var dirs: [String] = []
        var out: [String: (String, Int32)] = [:]
        var hold: DispatchSemaphore?
        /// #1104: with `readHold`, each `--read` waits on it after it is logged (a held read: no real wait).
        var readHold: DispatchSemaphore?
        var screens: [String: String] = [:]
        var noMirror = false
        var events: [String] = []
        private var made: DchActionRunner?
        func runner() -> DchActionRunner {
            let r = DchActionRunner(launch: { _, args, env, _, onPid, onOutput in
                let dir = env["DCH_SOCKET_DIR"] ?? ""
                let (o, h) = self.lock.withLock { () -> ((String, Int32), DispatchSemaphore?) in
                    self.launches.append(args)
                    self.dirs.append(dir)
                    self.events.append("launch " + args.joined(separator: " "))
                    return (self.out[dir] ?? ("", 0), self.hold)
                }
                onPid(4242)
                h?.wait()
                let d = Data(o.0.utf8)
                onOutput(d)
                return (o.1, d)
            }, signal: { _ in })
            lock.withLock { made = r }
            return r
        }
        var io: AgentPromptIO {
            AgentPromptIO(read: { key in
                let r = self.lock.withLock { self.made }
                let held = r?.isBusy(key) ?? false, main = Thread.isMainThread
                let (screen, h) = self.lock.withLock { () -> (String, DispatchSemaphore?) in
                    self.events.append("read \(key.name) held=\(held) main=\(main)")
                    return (self.screens[key.name] ?? AgentWindowInteractionTests.idleScreen, self.readHold)
                }
                h?.wait()
                return screen
            }, status: { _ in "idle" }, send: { _, _ in }, noMirror: { _ in self.lock.withLock { self.noMirror } })
        }
        var args: [[String]] { lock.withLock { launches } }
        var says: [[String]] { args.filter { $0.first == "--say" } }
        var log: [String] { lock.withLock { events } }
    }

    /// A panel-less, open controller over `sessions`; the control dch is `dch`, the runner a recorder.
    @MainActor
    private func controller(_ p: Proc, _ sessions: [AgentSession], dch: DchCommand.Binary? = v1240,
                            pattern: String = "") -> AgentIslandController {
        let c = AgentIslandController()
        c.showsPanel = false
        c.monitorClicks = { _ in nil }
        c.controlDch = { dch }
        c.controlEnv = { ["DCH_SOCKET_DIR": $0] }
        c.runner = p.runner()
        c.io = p.io
        let store = AgentIslandStore(geometry: notched, sidekickPattern: pattern)
        store.controlDch = dch
        store.sessions = sessions
        store.expanded = true
        c.store = store
        return c
    }

    /// Main's queue until `done` (the runner's results hop to main), with a 5 s deadline.
    @MainActor
    private func settle(_ done: () -> Bool) {
        let end = Date().addingTimeInterval(5)
        while !done() && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    }

    @MainActor
    private func press(_ item: NSMenuItem?) {
        guard let item, let action = item.action else { return XCTFail("no item") }
        _ = (item.target as AnyObject?)?.perform(action, with: item)
    }

    private func result(_ out: String, status: Int32 = 0, stopped: Bool = false) -> DchActionResult {
        AgentIsland.actionResult(status: status, output: Data((out + "\n").utf8), stopped: stopped)
    }

    private static func say(_ name: String, _ result: String, _ reason: String = "", _ detail: String = "") -> String {
        #"{"name":"\#(name)","result":"\#(result)","reason":"\#(reason)","detail":"\#(detail)"}"#
    }

    // MARK: - argv and text

    /// The argv as literal arrays, and the text as one element after "--": CR, LF and controls go, a
    /// leading "--" stays text.
    func testArgsAndTheTextAsOneElement() {
        XCTAssertEqual(AgentIsland.messageArgs(["api"], "hello"), ["--say", "api", "--json", "--", "hello"])
        XCTAssertEqual(AgentIsland.messageArgs(["api", "api-qa"], "hi"), ["--say", "api", "api-qa", "--json", "--", "hi"])
        XCTAssertTrue(AgentIsland.messageArgs(["api", "-kl"], "hi") == nil, "a name dch reads as a flag: nothing runs")
        XCTAssertEqual(AgentIsland.messageText("--force\r\nthen\rtest\nnow"), "--force then test now")
        XCTAssertEqual(AgentIsland.messageText("  fix\u{1B}[201~it\tplease \n"), "fix[201~it\tplease", "the window's sanitizer")
        XCTAssertTrue(AgentIsland.messageText(" \r\n\u{1B}\u{7F} ") == nil, "nothing left: nothing to send")
        XCTAssertTrue(AgentIsland.messageText("") == nil)
    }

    // MARK: - Message…

    /// A row's Message…: the composer names the row, Send runs one `--say` for it with the dir's env,
    /// "Sending…" then "Sent"; the text is in the argv only, never on the row.
    @MainActor
    func testRowMessageSendsOneNameAndShowsSent() throws {
        let p = Proc()
        p.out["/d"] = (Self.say("api", "ok"), 0)
        let c = controller(p, [session("api", alias: "API work"), session("api-qa")])
        let store = try XCTUnwrap(c.store)
        let row = try XCTUnwrap(AgentIslandView(store: store, onMessage: { c.askMessage($0) }).drawn.first { $0.session.name == "api" })
        XCTAssertTrue(row.messageEnabled)
        row.message()
        XCTAssertEqual(store.messageDraft, "")
        XCTAssertEqual(store.messagePrompt, "Message API work")
        XCTAssertTrue(store.showsControlLine)
        store.typeMessage("-- check the\r\nbuild")
        c.sendMessage()
        XCTAssertTrue(store.messageDraft == nil, "Send closes the composer")
        XCTAssertEqual(store.actions[AgentSessionKey(dir: "/d", name: "api")], "Sending…")
        settle { store.actions[AgentSessionKey(dir: "/d", name: "api")] == "Sent" }
        XCTAssertEqual(store.actions[AgentSessionKey(dir: "/d", name: "api")], "Sent")
        XCTAssertEqual(p.says, [["--say", "api", "--json", "--", "-- check the build"]])
        XCTAssertEqual(p.log, ["read api held=true main=false", "launch --say api --json -- -- check the build"],
                       "r2: the screen read, off main under the job's hold, then the say")
        XCTAssertEqual(p.lock.withLock { p.dirs }, ["/d"])
        XCTAssertFalse(store.actions.values.contains { $0.contains("check the") }, "the text is never on a row")
    }

    /// A row's result: "Sent" for ok, else dch's detail; a reply about another name, non-JSON output and a
    /// non-zero exit read failed; the 60 s bound reads cancelled.
    func testRowTextsFromSayReplies() {
        func row(_ out: String, status: Int32 = 0) -> String { AgentIsland.rowText(result(out, status: status), name: "api", .message) }
        XCTAssertEqual(row(Self.say("api", "ok")), "Sent")
        XCTAssertEqual(row(Self.say("api", "skipped", "not_claude", "no claude runs in the session")), "no claude runs in the session")
        XCTAssertEqual(row(Self.say("api", "failed", "no_session", "no such session"), status: 1), "no such session")
        XCTAssertEqual(row(Self.say("api", "failed", "not_submitted", "api: not submitted")), "not submitted", "\"<name>: \" stripped")
        XCTAssertEqual(row(Self.say("api", "skipped", "draft")), "Message skipped (draft)", "no detail: result and reason")
        XCTAssertEqual(row(Self.say("other", "ok")), "Message failed (exit 0)", "a line about another session is no result")
        XCTAssertEqual(row("dch: usage: dch --say <name>... | --all [--json] -- <text...>", status: 1),
                       "Message failed: dch: usage: dch --say <name>... | --all [--json] -- <text...>")
        XCTAssertEqual(row("", status: 1), "Message failed (exit 1)")
        XCTAssertEqual(AgentIsland.rowText(result("", status: 143, stopped: true), name: "api", .message),
                       "Message cancelled: no answer in 1m")
        XCTAssertEqual(DchActionRunner.messageBound, 60)
    }

    // MARK: - Message all

    /// Message all in <tab>…: the shown tab's live rows by name (never --all), one job per dir, a "-" name
    /// skipped; each row's result as it comes, the dir's tally "N sent, K skipped, F failed" over the asked
    /// names: a line about another session is ignored, a missing one counts as failed.
    @MainActor
    func testMessageAllNamesTheShownTabAndTallies() throws {
        let p = Proc()
        p.out["/d"] = ([Self.say("api", "ok"), Self.say("ghost", "ok"), Self.say("-x", "failed", "no_session", "no such session"),
                        Self.say("api-qa", "skipped", "not_claude", "no claude runs in the session")]
                        .joined(separator: "\n"), 0)
        p.out["/e"] = ("dch: lost the master", 1)
        let c = controller(p, [session("api"), session("api-qa"), session("-x"), session("web", dir: "/e"),
                               session("ghost-row", dir: "/d")])
        let store = try XCTUnwrap(c.store)
        let menu = c.makeControlsMenu()
        let item = menu.items.first { $0.title == "Message all in Sessions…" }
        XCTAssertEqual(item?.isEnabled, true)
        press(item)
        XCTAssertEqual(store.messagePrompt, "Message 4 sessions in Sessions")
        // ghost-row ends before Send: it is not asked.
        store.sessions = [session("api"), session("api-qa"), session("-x"), session("web", dir: "/e")]
        XCTAssertEqual(store.messageDraft, "", "a row ending keeps the composer while any is left")
        store.typeMessage("hi")
        c.sendMessage()
        XCTAssertEqual(store.actions[AgentSessionKey(dir: "/d", name: "api")], "Sending…")
        settle { store.actions[AgentSessionKey(dir: "/d", name: "")] != "Sending…" && store.actions[AgentSessionKey(dir: "/e", name: "")] != "Sending…" }
        XCTAssertEqual(p.says.sorted { $0.count > $1.count }, [["--say", "api", "api-qa", "--json", "--", "hi"], ["--say", "web", "--json", "--", "hi"]])
        XCTAssertEqual(store.actions[AgentSessionKey(dir: "/d", name: "")], "1 sent, 1 skipped. 1 skipped: name starts with “-”.",
                       "#1104: the \"-\" row left out is said")
        XCTAssertEqual(store.actions[AgentSessionKey(dir: "/e", name: "")], "1 failed")
        XCTAssertEqual(store.actions[AgentSessionKey(dir: "/d", name: "api")], "Sent")
        XCTAssertEqual(store.actions[AgentSessionKey(dir: "/d", name: "api-qa")], "no claude runs in the session")
        XCTAssertTrue(store.actions[AgentSessionKey(dir: "/e", name: "web")] == nil, "no line for it: the running text goes")
        XCTAssertTrue(store.actions[AgentSessionKey(dir: "/d", name: "-x")] == nil, "never asked: its line is not its")
    }

    /// The tally alone: unknown names ignored, missing ones failed, the bound cancelled.
    func testMessageTally() {
        let out = [Self.say("a", "ok"), Self.say("b", "skipped", "not_claude"), Self.say("zz", "ok"), Self.say("zz", "skipped"),
                   Self.say("c", "failed", "no_session")].joined(separator: "\n")
        XCTAssertEqual(AgentIsland.messageTally(result(out, status: 1), names: ["a", "b", "c", "d"]), "1 sent, 1 skipped, 2 failed")
        XCTAssertEqual(AgentIsland.messageTally(result("not json at all", status: 1), names: ["a", "b"]), "2 failed")
        XCTAssertEqual(AgentIsland.messageTally(result(Self.say("a", "ok") + "\n" + Self.say("a", "ok")), names: ["a"]), "1 sent",
                       "one name, one count")
        XCTAssertEqual(AgentIsland.messageTally(result("", stopped: true), names: ["a"]), "Message all cancelled: no answer in 1m")
        XCTAssertEqual(AgentIsland.messageTally(result(Self.say("a", "ok")), names: ["a"], dashed: 2),
                       "1 sent. 2 skipped: name starts with “-”.", "#1104: the \"-\" names left out")
        XCTAssertEqual(AgentIsland.messageTally(result(Self.say("a", "ok")), names: ["a"], dashed: 0), "1 sent")
    }

    /// Under Sidekicks the item and the names are the sidekicks'; under History, the session tab's (as Stop all).
    @MainActor
    func testMessageAllUnderSidekicksAndHistory() throws {
        let p = Proc()
        let c = controller(p, [session("api"), session("api-qa"), session("web-qa")], pattern: "-qa$")
        let store = try XCTUnwrap(c.store)
        store.sidekickTab = true
        store.history = [DchHistoryRecord(key: AgentSessionKey(dir: "/d", name: "old"), cwd: "/src", updated: 1, ended: 1, end: "exit 0")]
        store.historyTab = true
        let item = c.makeControlsMenu().items.first { $0.title.hasPrefix("Message all") }
        XCTAssertEqual(item?.title, "Message all in Sidekicks…")
        press(item)
        XCTAssertEqual(store.messagePrompt, "Message 2 sessions in Sidekicks")
        store.typeMessage("go")
        c.sendMessage()
        settle { !c.runner.isBusy(AgentSessionKey(dir: "/d", name: "")) && store.actions[AgentSessionKey(dir: "/d", name: "")] != "Sending…" }
        XCTAssertEqual(p.says, [["--say", "api-qa", "web-qa", "--json", "--", "go"]])
    }

    // MARK: - Gate, busy, composer keys

    /// The base gate only: off below 1.24.0 (the row item, the menu item, both calls), on at 1.24.0.
    @MainActor
    func testGateOffBelowTheMinimumAndOnAtIt() throws {
        let p = Proc()
        let c = controller(p, [session("api")], dch: Self.v1230)
        let store = try XCTUnwrap(c.store)
        XCTAssertEqual(AgentIslandView(store: store).drawn.map(\.messageEnabled), [false])
        XCTAssertEqual(c.makeControlsMenu().items.first { $0.title == "Message all in Sessions…" }?.isEnabled, false)
        c.askMessage(session("api"))
        c.askMessageAll()
        XCTAssertTrue(store.messageDraft == nil)
        store.controlDch = Self.v1240
        XCTAssertEqual(AgentIslandView(store: store).drawn.map(\.messageEnabled), [true])
        XCTAssertEqual(c.makeControlsMenu().items.first { $0.title == "Message all in Sessions…" }?.isEnabled, true)
        c.askMessage(session("api"))
        XCTAssertEqual(store.messageDraft, "")
        store.controlDch = Self.v1230
        store.typeMessage("hi")
        c.sendMessage()
        XCTAssertEqual(p.says, [], "the gate is checked again at Send")
        XCTAssertTrue(store.messageDraft == nil, "r2: a fallen gate closes the composer")
        XCTAssertEqual(store.actions[AgentSessionKey(dir: "/d", name: "api")], "Controls needs dch 1.24.0", "and says why")
        XCTAssertEqual(AgentIslandView(store: store).drawn.map(\.messageEnabled), [false])
        let dash = controller(Proc(), [session("-x")])
        XCTAssertEqual(AgentIslandView(store: try XCTUnwrap(dash.store)).drawn.map(\.messageEnabled), [false], "a \"-\" name")
    }

    /// A busy row refuses at Message… (nothing typed for nothing) and at Send; Message all refuses a busy dir
    /// whole and runs the others.
    @MainActor
    func testBusyRowAndDirRefuse() throws {
        let p = Proc(), gate = DispatchSemaphore(value: 0)
        p.hold = gate
        let c = controller(p, [session("api"), session("web", dir: "/e")])
        let store = try XCTUnwrap(c.store)
        let api = AgentSessionKey(dir: "/d", name: "api")
        defer { for _ in 0..<4 { gate.signal() } }
        XCTAssertTrue(c.runner.start(api, path: "/fake/dch", args: ["--stop", "api", "--json"], env: { ["DCH_SOCKET_DIR": "/d"] }, done: { _ in }))
        c.askMessage(session("api"))
        XCTAssertTrue(store.messageDraft == nil, "a busy row opens no composer")
        XCTAssertEqual(store.actions[api], AgentIsland.messageBusyText)
        store.actions[api] = nil
        c.askMessageAll()
        store.typeMessage("hi")
        c.sendMessage()
        XCTAssertEqual(store.actions[AgentSessionKey(dir: "/d", name: "")], "Message not sent: another job is running")
        XCTAssertEqual(store.actions[AgentSessionKey(dir: "/e", name: "web")], "Sending…")
        settle { p.says.count == 1 }
        XCTAssertEqual(p.says, [["--say", "web", "--json", "--", "hi"]])
        // Send on a row that became busy after Message… opened. Two jobs wait: the --stop and web's --say.
        p.lock.withLock { p.hold = nil }
        gate.signal()
        gate.signal()
        settle { !c.runner.isBusy(api) && !c.runner.isBusy(AgentSessionKey(dir: "/e", name: "")) }
        c.askMessage(session("api"))
        XCTAssertEqual(store.messageDraft, "")
        p.lock.withLock { p.hold = gate }
        XCTAssertTrue(c.runner.start(api, path: "/fake/dch", args: ["--stop", "api", "--json"], env: { [:] }, done: { _ in }))
        store.typeMessage("hi")
        store.actions[api] = nil
        c.sendMessage()
        XCTAssertEqual(store.actions[api], AgentIsland.messageBusyText)
        XCTAssertEqual(p.says, [["--say", "web", "--json", "--", "hi"]], "nothing more typed")
    }

    /// Enter on an empty (or control-only) draft sends nothing and keeps the composer; Esc and Cancel close it
    /// and drop the draft; the panel's Esc collapses only with no composer; collapsing drops the draft; a late
    /// field write never reopens it; the composer opens only on an open island (the panel is key then).
    @MainActor
    func testComposerEnterEscEmptyAndCollapse() throws {
        let p = Proc()
        let c = controller(p, [session("api")])
        let store = try XCTUnwrap(c.store)
        c.askMessage(session("api"))
        c.sendMessage()
        store.typeMessage("  \r\n\u{1B} ")
        c.sendMessage()
        XCTAssertEqual(store.messageDraft, "  \r\n\u{1B} ", "empty as sent: nothing goes, the composer stays")
        XCTAssertEqual(p.args, [])
        c.escape()
        XCTAssertTrue(store.messageDraft == nil, "Esc closes the composer")
        XCTAssertTrue(store.expanded, "and leaves the island open")
        store.typeMessage("late")
        XCTAssertTrue(store.messageDraft == nil, "a late field write never reopens it")
        c.askMessage(session("api"))
        store.typeMessage("draft")
        c.cancelMessage()
        XCTAssertTrue(store.messageDraft == nil, "Cancel")
        c.askMessage(session("api"))
        store.typeMessage("secret plan")
        c.setExpanded(false)
        XCTAssertTrue(store.messageDraft == nil, "collapse closes it")
        c.askMessage(session("api"))
        c.askMessageAll()
        XCTAssertTrue(store.messageDraft == nil, "collapsed: no composer (the panel is not key)")
        store.expanded = true
        c.askMessage(session("api"))
        XCTAssertEqual(store.messageDraft, "", "the draft did not survive the collapse")
        c.cancelMessage()
        c.escape()
        XCTAssertFalse(store.expanded, "no composer: Esc collapses as before")
        XCTAssertEqual(p.args, [])
    }

    /// The one row asked about ends: the composer goes with it.
    @MainActor
    func testComposerGoesWhenItsRowEnds() throws {
        let c = controller(Proc(), [session("api"), session("web")])
        let store = try XCTUnwrap(c.store)
        c.askMessage(session("api"))
        store.typeMessage("hi")
        store.sessions = [session("web")]
        XCTAssertTrue(store.messageDraft == nil)
        XCTAssertFalse(store.showsControlLine)
    }

    // MARK: - r2: the window's screen guard, and a spawn that fails

    private typealias T = AgentWindowInteractionTests

    /// #820 and QA #651 F1's screens, as the window refuses them: a plan approval with no footer (no parsed
    /// prompt), its caret row alone, a parsed permission prompt (a row the island shows a card for), an empty
    /// read (fails closed) and an empty read on a dch with no mirror. A row's Message reads the screen in the
    /// job, says nothing to dch, and the row reads the window's words.
    @MainActor
    func testRowMessageRefusedWhereTheWindowRefuses() throws {
        let plan = T.planScreen(caret: 1, footer: nil)
        let caretRow = plan.replacingOccurrences(of: "Claude has written up a plan and is ready to execute. ", with: "")
        let cases: [(String, String, Bool, String)] = [
            ("plan-no-footer", plan, false, "Claude is showing a prompt. Open in terminal to answer it"),
            ("caret-row", caretRow, false, "Claude is showing a prompt. Open in terminal to answer it"),
            ("permission", T.permission(), false, "Claude is showing a prompt. Open in terminal to answer it"),
            ("empty-read", "", false, "Couldn't confirm. Open in terminal"),
            ("no-mirror", "", true, "This dch can't confirm a message. Open in terminal"),
        ]
        for (name, screen, lite, text) in cases {
            let p = Proc()
            p.screens["api"] = screen
            p.noMirror = lite
            p.out["/d"] = (Self.say("api", "ok"), 0)
            let c = controller(p, [session("api")])
            let store = try XCTUnwrap(c.store)
            let api = AgentSessionKey(dir: "/d", name: "api")
            c.askMessage(session("api"))
            store.typeMessage("1")
            c.sendMessage()
            settle { store.actions[api] != "Sending…" }
            XCTAssertEqual(store.actions[api], text, name)
            XCTAssertEqual(p.args, [], "\(name): nothing reached dch")
            XCTAssertEqual(p.log, ["read api held=true main=false"], name)
        }
    }

    /// Message all over three sessions, one on a plan approval with no footer: exactly the other two names go
    /// to `--say`, the refused row reads the window's words, and the dir line counts it as skipped.
    @MainActor
    func testMessageAllLeavesTheRefusedSessionOut() throws {
        let p = Proc()
        p.screens["b"] = T.planScreen(caret: 1, footer: nil)
        p.out["/d"] = ([Self.say("a", "ok"), Self.say("c", "ok")].joined(separator: "\n"), 0)
        let c = controller(p, [session("a"), session("b"), session("c")])
        let store = try XCTUnwrap(c.store)
        c.askMessageAll()
        store.typeMessage("1")
        c.sendMessage()
        let dir = AgentSessionKey(dir: "/d", name: "")
        settle { store.actions[dir] != "Sending…" }
        XCTAssertEqual(p.says, [["--say", "a", "c", "--json", "--", "1"]])
        XCTAssertEqual(store.actions[dir], "2 sent, 1 skipped")
        XCTAssertEqual(store.actions[AgentSessionKey(dir: "/d", name: "b")], "Claude is showing a prompt. Open in terminal to answer it")
        XCTAssertEqual(store.actions[AgentSessionKey(dir: "/d", name: "a")], "Sent")
        XCTAssertEqual(p.log, ["read a held=true main=false", "read b held=true main=false", "read c held=true main=false",
                               "launch --say a c --json -- 1"])
        // Every screen refused (here: empty reads): no say at all, every name skipped.
        let q = Proc()
        q.screens = ["a": "", "b": ""]
        let d = controller(q, [session("a"), session("b")])
        let ds = try XCTUnwrap(d.store)
        d.askMessageAll()
        ds.typeMessage("hi")
        d.sendMessage()
        settle { ds.actions[dir] != "Sending…" }
        XCTAssertEqual(q.args, [])
        XCTAssertEqual(ds.actions[dir], "2 skipped")
        XCTAssertEqual(ds.actions[AgentSessionKey(dir: "/d", name: "a")], "Couldn't confirm. Open in terminal")
    }

    /// #1104 (QA #836 INFO-5): a text past 256 KB (UTF-8 bytes) is never spawned: its argv would pass ARG_MAX and
    /// read "Message failed (exit -1)". The composer closes and the row, or Message all's dir line, says why; at the
    /// cap it goes, one argv element, whole.
    @MainActor
    func testTextPastTheCapIsRefusedWithItsReason() throws {
        let p = Proc()
        p.out["/d"] = (Self.say("a", "ok"), 0)
        let c = controller(p, [session("a"), session("b")])
        let store = try XCTUnwrap(c.store)
        let a = AgentSessionKey(dir: "/d", name: "a"), dir = AgentSessionKey(dir: "/d", name: "")
        c.askMessage(session("a"))
        store.typeMessage(String(repeating: "x", count: AgentIsland.messageCap + 1))
        c.sendMessage()
        XCTAssertTrue(store.messageDraft == nil, "the composer closes")
        XCTAssertEqual(store.actions[a], "Message not sent: longer than 256 KB")
        XCTAssertEqual(p.args, [], "nothing spawned")
        c.askMessageAll()
        store.typeMessage(String(repeating: "\u{E9}", count: AgentIsland.messageCap / 2 + 1))   // bytes, not characters
        c.sendMessage()
        XCTAssertEqual(store.actions[dir], AgentIsland.messageTooLongText)
        XCTAssertEqual(p.args, [])
        c.askMessage(session("a"))
        store.typeMessage(String(repeating: "x", count: AgentIsland.messageCap))
        c.sendMessage()
        settle { store.actions[a] != "Sending\u{2026}" }
        XCTAssertEqual(store.actions[a], "Sent")
        XCTAssertEqual(p.says.first?.last?.utf8.count, AgentIsland.messageCap, "at the cap: one argv element, whole")
    }

    // MARK: - #1104: the 584 review's follow-ups

    /// Item 1: a Message all cancelled while its first screen read is held (DchActionRunner.cancel, what the 60 s idle
    /// bound calls, here with no 60 s wait) launches no say once the reads end, and its dir line reads cancelled.
    @MainActor
    func testMessageAllCancelledDuringItsReadsLaunchesNothing() throws {
        let p = Proc(), reads = DispatchSemaphore(value: 0)
        p.readHold = reads
        let c = controller(p, [session("a"), session("b")])
        let store = try XCTUnwrap(c.store)
        let dir = AgentSessionKey(dir: "/d", name: "")
        defer {
            p.lock.withLock { p.readHold = nil }
            reads.signal()
        }
        c.askMessageAll()
        store.typeMessage("hi")
        c.sendMessage()
        settle { p.log.count == 1 }
        XCTAssertEqual(p.log, ["read a held=true main=false"], "the first read is held")
        c.runner.cancel(dir)
        p.lock.withLock { p.readHold = nil }
        reads.signal()
        settle { store.actions[dir] != "Sending\u{2026}" }
        XCTAssertEqual(p.args, [], "nothing launched after the reads")
        XCTAssertEqual(store.actions[dir], "Message all cancelled: no answer in 1m")
        XCTAssertFalse(c.runner.isBusy(dir), "reaped")
    }

    /// The screen reads' clock and log: each read costs `cost[name]` seconds of the fake clock and returns the
    /// name's next screen (the last one stays; none: Claude's idle composer).
    private final class Reads: @unchecked Sendable {
        let lock = NSLock()
        var t: TimeInterval = 0
        var log: [String] = []
        var cost: [String: TimeInterval] = [:]
        var screens: [String: [String]] = [:]
        var io: AgentPromptIO {
            AgentPromptIO(read: { key in
                self.lock.withLock {
                    self.log.append(key.name)
                    self.t += self.cost[key.name] ?? 0
                    var s = self.screens[key.name] ?? []
                    let shown = s.count > 1 ? s.removeFirst() : s.first ?? AgentWindowInteractionTests.idleScreen
                    self.screens[key.name] = s
                    return shown
                }
            }, status: { _ in "idle" }, send: { _, _ in })
        }
        func clock() -> TimeInterval { lock.withLock { t } }
    }

    private func skips(_ out: Data) -> [String] {
        AgentIsland.actionResult(status: 0, output: out).json.map { "\($0.name): \($0.detail ?? "")" }
    }

    /// Items 2 and 4 (QA #836 INFO-4): a pass of reads slower than 2 s (a stuck session's 8 s timeout) is read once
    /// more over the names it cleared, so a prompt that came up meanwhile is refused; a fast pass is read once; the
    /// first pass starts no read at 20 s, the re-read none at 40 s, so the reads end inside the 60 s bound (fake clock).
    func testScreenReadsReReadASlowPassAndStopInTime() {
        let slow = Reads()
        slow.cost = ["b": 8]
        slow.screens = ["a": [T.idleScreen, T.planScreen(caret: 1, footer: nil)], "b": [""]]
        let g = AgentIsland.messageScreens(slow.io, dir: "/d", names: ["a", "b", "c"], clock: slow.clock)
        XCTAssertEqual(g.names, ["c"], "a showed a prompt by the re-read")
        XCTAssertEqual(slow.log, ["a", "b", "c", "a", "c"])
        XCTAssertEqual(skips(g.out), ["b: \(AgentWindowText.unconfirmed)", "a: \(AgentWindowText.promptShown)"])
        let fast = Reads()
        let f = AgentIsland.messageScreens(fast.io, dir: "/d", names: ["a", "b"], clock: fast.clock)
        XCTAssertEqual(f.names, ["a", "b"])
        XCTAssertEqual(fast.log, ["a", "b"], "a fast pass is read once")
        let stuck = Reads()
        stuck.cost = ["n1": 8, "n2": 8, "n3": 8, "n4": 8]
        let s = AgentIsland.messageScreens(stuck.io, dir: "/d", names: ["n1", "n2", "n3", "n4"], clock: stuck.clock)
        XCTAssertEqual(stuck.log, ["n1", "n2", "n3", "n1", "n2"], "no read starts at 20 s, nor a re-read at 40 s")
        XCTAssertEqual(s.names, ["n1", "n2"])
        XCTAssertEqual(skips(s.out), ["n4: \(AgentWindowText.unconfirmed)", "n3: \(AgentWindowText.unconfirmed)"])
        XCTAssertLessThan(AgentIsland.messageRereadBy + 16, DchActionRunner.messageBound, "a last read and its probe end in the bound")
    }

    /// Item 3 (QA: cannot happen): every refused control gate names the dch it needs, so the fallen-gate line is
    /// never a bare "Controls ".
    func testARefusedGateAlwaysNamesTheDchItNeeds() {
        let cases: [(DchCommand.Binary?, [String])] = [(nil, []), (Self.v1230, []), (Self.v1240, ["1.30.0"]), (Self.v1240, ["x"])]
        for (dch, masters) in cases {
            let gate = DchCommand.gate(dch, masters: masters, minimum: AgentIsland.controlMinimum)
            XCTAssertTrue(gate.refusal?.hasPrefix("needs dch 1.") ?? gate.isOK, "\(String(describing: dch?.version)) \(masters)")
        }
        XCTAssertFalse(DchCommand.gate(Self.v1240, masters: ["1.30.0"], minimum: AgentIsland.controlMinimum).isOK)
    }

    /// Item 5 (QA #836 INFO-2): a window action, then a card click (its screen read held), in flight on a row: Message…
    /// refuses with the busy text, and Message all refuses that row's dir whole and sends to the others.
    @MainActor
    func testBusyWhileAWindowActionOrACardClickIsInFlight() throws {
        let p = Proc(), gate = DispatchSemaphore(value: 0), reads = DispatchSemaphore(value: 0)
        let c = controller(p, [session("api"), session("web", dir: "/e")])
        let store = try XCTUnwrap(c.store)
        let api = AgentSessionKey(dir: "/d", name: "api")
        defer {
            gate.signal()
            p.lock.withLock { p.readHold = nil }
            reads.signal()
        }
        XCTAssertTrue(c.humanAction(session("api"), prompt: nil, run: { _ in gate.wait() }) { _ in })
        c.askMessage(session("api"))
        XCTAssertTrue(store.messageDraft == nil, "a window action holds the row: no composer")
        XCTAssertEqual(store.actions[api], AgentIsland.messageBusyText)
        store.actions[api] = nil
        c.askMessageAll()
        store.typeMessage("hi")
        c.sendMessage()
        XCTAssertEqual(store.actions[AgentSessionKey(dir: "/d", name: "")], AgentIsland.messageBusyText, "its dir, whole")
        settle { p.says.count == 1 }
        XCTAssertEqual(p.says, [["--say", "web", "--json", "--", "hi"]])
        gate.signal()
        settle { !c.heldByAutoAllow(api) }
        XCTAssertFalse(c.heldByAutoAllow(api))
        p.lock.withLock { p.readHold = reads }
        let prompt = try XCTUnwrap(AgentPrompt.parse(T.permission()))
        let option = try XCTUnwrap(prompt.options.first)
        store.actions[api] = nil
        c.answer(session("api"), prompt, option)
        XCTAssertTrue(c.heldByAutoAllow(api), "the click is in flight")
        c.askMessage(session("api"))
        XCTAssertTrue(store.messageDraft == nil, "a card click holds the row too")
        XCTAssertEqual(store.actions[api], AgentIsland.messageBusyText)
        p.lock.withLock { p.readHold = nil }
        reads.signal()
        settle { !c.heldByAutoAllow(api) }
    }

    /// Item 6 (QA #836 INFO-3): Message all refused by Stop all running on the dir leaves "Stopping\u{2026}" up.
    @MainActor
    func testMessageAllRefusalNeverOverwritesARunningText() throws {
        let p = Proc(), gate = DispatchSemaphore(value: 0)
        p.hold = gate
        let c = controller(p, [session("api")])
        let store = try XCTUnwrap(c.store)
        let dir = AgentSessionKey(dir: "/d", name: "")
        defer { gate.signal() }
        XCTAssertTrue(c.runner.start(dir, path: "/fake/dch", args: ["--stop", "api", "--json"], env: { ["DCH_SOCKET_DIR": "/d"] }, done: { _ in }))
        store.actions[dir] = AgentIsland.stoppingText
        c.askMessageAll()
        store.typeMessage("hi")
        c.sendMessage()
        XCTAssertEqual(store.actions[dir], AgentIsland.stoppingText, "Stop all's running text stays")
        XCTAssertEqual(p.says, [])
    }

    // MARK: - QA #453 L2, L3

    /// L2: a failed master pass reads dch's "dch: " line; L3: a Resume that did not start reads its exec line.
    func testRestartMasterFailureAndResumeExecLine() {
        let master = #"{"name":"a","phase":"master","result":"failed","reason":"x","detail":"not restarted (see stderr)","session_id":""}"#
        XCTAssertEqual(AgentIsland.rowText(result(master + "\ndch: a: master is gone", status: 1), name: "a", .restart),
                       "Restart failed: dch: a: master is gone")
        XCTAssertEqual(AgentIsland.rowText(result(master, status: 1), name: "a", .restart), "not restarted (see stderr)",
                       "no dch line: the detail")
        let notStarted = #"{"name":"s3","as":"s3-2","result":"failed","reason":"not_started","detail":"NOT revived — the session did not start","session_id":""}"#
        XCTAssertEqual(AgentIsland.rowText(result(notStarted + "\ndch: s3-2: /src/prog: No such file or directory\ndch: failed to spawn session",
                                                  status: 1), name: "s3", .resume),
                       "Resume failed: dch: s3-2: /src/prog: No such file or directory", "the line of the name it started")
        XCTAssertEqual(AgentIsland.rowText(result(notStarted + "\ndch: failed to spawn session", status: 1), name: "s3", .resume),
                       "NOT revived — the session did not start", "no exec line: the detail")
        let dash = #"{"name":"-x","as":"-x","result":"failed","reason":"not_started","detail":"NOT revived — the session did not start","session_id":""}"#
        XCTAssertEqual(AgentIsland.rowText(result(dash + "\ndch: -x: refused", status: 1), name: "-x", .resume),
                       AgentIsland.dashRefusedText, "#878's words stay")
    }

    /// Item 9 (QA #836 INFO-6): the phone's Resume and Restart get the same L2/L3 words in their error frame (0x13
    /// {"message"}, which the phone shows as written: docs/protocol/remote-frames.md), "<name>: " first.
    func testPhoneErrorFrameCarriesTheDchLine() {
        func message(_ frame: Data) -> String? {
            XCTAssertEqual(frame.first, DchFrame.error)
            let json = (try? JSONSerialization.jsonObject(with: Data(frame.dropFirst(5)))) as? [String: Any]
            return json?["message"] as? String
        }
        let notStarted = #"{"name":"s3","as":"s3-2","result":"failed","reason":"not_started","detail":"NOT revived — the session did not start","session_id":""}"#
        let resume = result(notStarted + "\ndch: s3-2: /src/prog: No such file or directory\ndch: failed to spawn session", status: 1)
        XCTAssertEqual(message(DchControlOps.answer(named: [("s3", resume)], .resume)),
                       "s3: Resume failed: dch: s3-2: /src/prog: No such file or directory")
        let master = #"{"name":"a","phase":"master","result":"failed","reason":"x","detail":"not restarted (see stderr)","session_id":""}"#
        XCTAssertEqual(message(DchControlOps.answer(named: [("a", result(master + "\ndch: a: master is gone", status: 1))], .restart)),
                       "a: Restart failed: dch: a: master is gone")
    }

    // MARK: - Offscreen: accessibility tree and UI scale

    /// The composer's field and both buttons by name, read off the real accessibility tree of a never-shown
    /// window (#887's technique): both attributes are put back after. Named to run first in this class.
    @MainActor
    func testAAccessibilityTreeReadsTheComposerByName() throws {
        let restoreAX = AXTreeSupport.axOn()
        defer { restoreAX() }
        let c = controller(Proc(), [session("api")])
        let store = try XCTUnwrap(c.store)
        c.askMessage(session("api"))
        store.typeMessage("hi")
        let (win, host) = AXTreeSupport.hosted(AgentIslandView(store: store), store.size)
        defer { win.close() }
        func named(_ t: [AXTreeNode], _ role: String, _ name: String) -> Bool {
            t.contains { $0.role == role && ($0.label == name || $0.title == name) }
        }
        let tree = AXTreeSupport.poll(host) { named($0, "AXTextField", "Message api") && named($0, "AXButton", "Send message") }
        print("#584 a11y tree:\n" + tree.map { "  \($0.role) label=\($0.label) title=\($0.title)" }.joined(separator: "\n"))
        XCTAssertEqual(tree.filter { $0.role == "AXTextField" }.map(\.label), ["Message api"])
        XCTAssertTrue(named(tree, "AXButton", "Send message"), "Send")
        XCTAssertTrue(named(tree, "AXButton", "Cancel message"), "Cancel")
        XCTAssertFalse(win.isVisible, "never on screen")
    }

    /// The composer at UI scale 1.0, 0.85 and 0.7: its natural width (buttons fixedSize, the field's
    /// placeholder) and height fit the control line; PNGs of the island with it open, for review.
    @MainActor
    func testComposerFitsTheLineAtEveryScale() throws {
        let saved = ThemeRuntime.scale
        defer { ThemeRuntime.scale = saved }
        let out = tempDir()
        let extra = ProcessInfo.processInfo.environment["PROSPER_RENDER_DIR"].map { URL(fileURLWithPath: $0) }
        let line = AgentIslandGeometry.expandedWidth - 2 * AgentIslandGeometry.listInset - 2 * AgentIslandGeometry.rowLead
        for scale: CGFloat in [1.0, 0.85, 0.7] {
            ThemeRuntime.scale = scale
            let c = controller(Proc(), [session("api"), session("api-qa"), session("web")])
            let store = try XCTUnwrap(c.store)
            c.askMessageAll()
            store.typeMessage("please rebase on main and rerun the failing tests")
            let fit = NSHostingView(rootView: AgentIslandComposer(store: store, onSend: {}, onCancel: {})
                .font(.system(size: 11)).fixedSize()).fittingSize
            XCTAssertLessThanOrEqual(fit.width, line, "scale \(scale): natural width \(fit.width) fits \(line)")
            XCTAssertLessThanOrEqual(fit.height, AgentIslandGeometry.historyHeaderHeight, "scale \(scale)")
            for title in ["Send", "Cancel"] {
                let w = NSHostingView(rootView: AgentIslandView.lineButton(title) {}.fixedSize()).fittingSize.width
                XCTAssertGreaterThan(w, 20, "\(title) keeps its natural width")
            }
            let size = store.size
            let h = NSHostingView(rootView: AgentIslandView(store: store).padding(20).background(Color(white: 0.75)))
            h.frame = CGRect(origin: .zero, size: CGSize(width: size.width + 40, height: size.height + 40))
            h.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            h.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(h.bitmapImageRepForCachingDisplay(in: h.bounds))
            h.cacheDisplay(in: h.bounds, to: rep)
            let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            let name = "agent-island-composer-\(Int(scale * 100)).png"
            try png.write(to: out.appendingPathComponent(name))
            if let extra { try png.write(to: extra.appendingPathComponent(name)) }
        }
    }
}
