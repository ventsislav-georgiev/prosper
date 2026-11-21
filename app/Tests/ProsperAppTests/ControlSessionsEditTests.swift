import Foundation
import XCTest
@testable import ProsperApp

/// #1842: sessions.rename / sessions.model / sessions.effort on the seams: no dch, no window shown, no terminal typed into.
final class ControlSessionsEditTests: XCTestCase {
    let base = AgentWindowD1Tests()

    func args(_ d: [String: String]) -> [String: ControlJSON] { d.mapValues { .string($0) } }

    @MainActor
    func refused<T>(_ expr: @autoclosure () throws -> T, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try expr(), file: file, line: line) {
            XCTAssertEqual(($0 as? ControlError)?.message, message, file: file, line: line)
        }
    }

    /// The Control seams swapped for the body and put back: the window's model, its show path (never reached), the edit seams.
    @MainActor
    func withSeams(_ m: AgentWindowModel?, store: AgentIslandStore? = nil,
                   rename: @escaping @MainActor (AgentSession, String) -> Bool = { _, _ in true },
                   switchTo: @escaping @MainActor (AgentWindowModel, AgentModelSwitch.Command, AgentSession) -> String? = { _, _, _ in nil },
                   _ body: () throws -> Void) rethrows {
        let saved = (ControlSessions.model, ControlSessions.islandStore, ControlSessions.showWindow,
                     ControlSessionsEdit.rename, ControlSessionsEdit.switchTo)
        defer { (ControlSessions.model, ControlSessions.islandStore, ControlSessions.showWindow,
                 ControlSessionsEdit.rename, ControlSessionsEdit.switchTo) = saved }
        ControlSessions.model = { m }
        ControlSessions.islandStore = { store }
        ControlSessions.showWindow = { nil }
        ControlSessionsEdit.rename = rename
        ControlSessionsEdit.switchTo = switchTo
        try body()
    }

    func claude(_ name: String, _ state: AgentState, alias: String = "", model: String? = nil, effort: String? = nil,
                foreground: Bool? = true) -> AgentSession {
        var s = base.session(name, state, alias: alias)
        s.claudeForeground = foreground
        s.model = model
        s.effort = effort
        return s
    }

    // MARK: - sessions.rename

    /// By name or title; the alias before is what undo sends; no window needed (the island's store alone).
    @MainActor
    func testRenameSendsTheNewTitleAndUndoPutsTheOldOneBack() throws {
        let st = base.store([base.session("api", .idle, alias: "API"), base.session("web", .working)])
        var calls: [String] = []
        try withSeams(nil, store: st, rename: { calls.append("\($0.name)=\($1)"); return true }) {
            let c = try ControlSessionsEdit.renameSession(args(["name": "api", "to": "  Billing  "]))
            XCTAssertEqual(calls, ["api=Billing"], "trimmed, one line")
            XCTAssertEqual(c.verb, "renamed")
            XCTAssertEqual(c.result, .string("api"))
            XCTAssertEqual(c.summary, "API to Billing")
            c.undo?()
            XCTAssertEqual(calls, ["api=Billing", "api=API"])
            let byTitle = try ControlSessionsEdit.renameSession(args(["name": "WEB", "to": "site"]))
            XCTAssertEqual(calls.last, "web=site")
            byTitle.undo?()
            XCTAssertEqual(calls.last, "web=", "no alias before: cleared")
        }
    }

    /// A title is one line of outside text: a control character (ESC, tab, LF) or an unseen scalar is refused whole and
    /// the rename seam is never called; a title may start with / or !.
    @MainActor
    func testRenameRefusesControlAndHiddenCharacters() throws {
        let st = base.store([base.session("api", .idle)])
        var calls: [String] = []
        try withSeams(nil, store: st, rename: { calls.append("\($0.name)=\($1)"); return true }) {
            for bad in ["\u{1B}[2J", "a\u{202E}b", "a\tb", "a\nb", "a\u{200B}b"] {
                refused(try ControlSessionsEdit.renameSession(args(["name": "api", "to": bad])), "to has a control or hidden character")
            }
            XCTAssertEqual(calls, [], "refused whole: nothing renamed")
            _ = try ControlSessionsEdit.renameSession(args(["name": "api", "to": "api 2"]))
            _ = try ControlSessionsEdit.renameSession(args(["name": "api", "to": "/api"]))
            XCTAssertEqual(calls, ["api=api 2", "api=/api"])
        }
    }

    @MainActor
    func testRenameRefusesUnchangedUnknownBusyAndOff() throws {
        let st = base.store([base.session("api", .idle, alias: "API")])
        try withSeams(nil, store: st, rename: { _, _ in false }) {
            refused(try ControlSessionsEdit.renameSession(args(["name": "api", "to": "API"])), "API is already named API")
            refused(try ControlSessionsEdit.renameSession(args(["name": "api", "to": "x"])),
                    "API can't be renamed now: dch is unavailable or the session is busy")
            refused(try ControlSessionsEdit.renameSession(args(["name": "nope", "to": "x"])),
                    "no live session named nope (sessions.list lists them)")
            refused(try ControlSessionsEdit.renameSession(args(["name": "api", "to": "  "])), "argument 'to' is empty")
            st.actions[AgentSessionKey(dir: "/tmp/dch-test", name: "api")] = AgentIsland.renameBusyText
            refused(try ControlSessionsEdit.renameSession(args(["name": "api", "to": "x"])), AgentIsland.renameBusyText)
        }
        try withSeams(nil, store: nil) {
            refused(try ControlSessionsEdit.renameSession(args(["name": "api", "to": "x"])), ControlSessions.islandOff)
        }
    }

    // MARK: - sessions.model / sessions.effort

    @MainActor
    func testModelAndEffortSwitchAndUndoGoBackToTheValueBefore() throws {
        let st = base.store([claude("api", .idle, model: "claude-opus-4-1", effort: "high"), claude("web", .done)])
        let m = base.windowModel(st)
        defer { m.close() }
        var calls: [String] = []
        try withSeams(m, switchTo: { _, c, s in calls.append("\(s.name) \(c.text)"); return nil }) {
            let model = try ControlSessionsEdit.switchSession(args(["name": "api", "model": "sonnet"]), model: true)
            XCTAssertEqual(calls, ["api /model sonnet"])
            XCTAssertEqual(model.verb, "switched")
            XCTAssertEqual(model.result, .string("sonnet"))
            model.undo?()
            XCTAssertEqual(calls.last, "api /model opus")
            let effort = try ControlSessionsEdit.switchSession(args(["name": "api", "effort": "low"]), model: false)
            XCTAssertEqual(calls.last, "api /effort low")
            effort.undo?()
            XCTAssertEqual(calls.last, "api /effort high")
            let unknown = try ControlSessionsEdit.switchSession(args(["name": "web", "effort": "max"]), model: false)
            XCTAssertTrue(unknown.undo == nil, "the row never showed an effort: no inverse")
            XCTAssertEqual(calls.count, 5)
        }
    }

    /// Only idle or done, Claude in front; the window's own refusal is the error and nothing is reported started.
    @MainActor
    func testSwitchRefusesNotIdleNotInFrontAndTheWindowsOwnRefusal() throws {
        let st = base.store([claude("w", .working), claude("b", .blocked), claude("bg", .idle, foreground: false),
                             claude("nf", .idle, foreground: nil), claude("ok", .idle)])
        let m = base.windowModel(st)
        defer { m.close() }
        var calls = 0
        try withSeams(m, switchTo: { _, _, _ in calls += 1; return "Restarting" }) {
            refused(try ControlSessionsEdit.switchSession(args(["name": "w", "effort": "low"]), model: false), AgentModelSwitch.working)
            refused(try ControlSessionsEdit.switchSession(args(["name": "b", "model": "opus"]), model: true), AgentWindowText.blocked)
            refused(try ControlSessionsEdit.switchSession(args(["name": "bg", "model": "opus"]), model: true), AgentWindowText.notForeground)
            refused(try ControlSessionsEdit.switchSession(args(["name": "nf", "model": "opus"]), model: true), AgentWindowText.notForeground)
            XCTAssertEqual(calls, 0, "refused before the window is asked")
            refused(try ControlSessionsEdit.switchSession(args(["name": "ok", "model": "opus"]), model: true), "Restarting")
            XCTAssertEqual(calls, 1)
            refused(try ControlSessionsEdit.switchSession(args(["name": "ok", "model": "gpt"]), model: true), "unknown model gpt")
        }
    }

    /// n133: the agent's switch goes through the window's own path (dch --say, no key, no focus): no row selected, no
    /// session opened in a terminal, no window shown, nothing sent but the one command. The default seam, a fake dch.
    @MainActor
    func testTheSwitchMovesNoFocusAndTypesOnlyTheCommand() throws {
        let sw = AgentModelSwitchTests()
        let st = base.store([claude("s", .idle, model: "claude-opus-4-1")])
        let m = base.windowModel(st)
        defer { m.close() }
        var moved: [String] = []
        m.openSession = { moved.append("open \($0.name)") }
        m.onVisible = { moved.append("visible \($0)") }
        let f = AgentModelSwitchTests.Fake()
        m.interaction.controller = sw.controller(f.io)
        m.interaction.pause = { _ in }
        m.interaction.readQueue = { $0() }
        m.interaction.files = AgentModelSwitchTests.noFiles
        let selected = m.selection, real = ControlSessionsEdit.switchTo
        try withSeams(m) {
            ControlSessionsEdit.switchTo = real
            let c = try ControlSessionsEdit.switchSession(args(["name": "s", "effort": "low"]), model: false)
            XCTAssertEqual(c.verb, "switched")
            sw.until("settled") { !m.interaction.busy }
        }
        XCTAssertEqual(f.lock.withLock { f.says }, ["/effort low"], "only the command, typed by dch --say")
        XCTAssertEqual(moved, [], "no terminal opened, no window shown")
        XCTAssertEqual(m.selection, selected, "no row selected")
    }

    @MainActor
    func testTheThreeCommandsAreRegisteredAsChangesWithTheListsAsEnums() throws {
        var r = ControlRegistry()
        ControlRegistry.registerSessionsEdit(&r)
        XCTAssertEqual(r.commands.keys.sorted(), ["sessions.effort", "sessions.model", "sessions.rename"])
        XCTAssertTrue(r.commands.values.allSatisfy(\.mutates))
        XCTAssertEqual(r.commands["sessions.model"]?.args["model"]?.allowed, AgentModelEffort.aliases)
        XCTAssertEqual(r.commands["sessions.effort"]?.args["effort"]?.allowed, AgentModelEffort.levelOrder)
        XCTAssertThrowsError(try r.commands["sessions.effort"]?.validate(["name": .string("a"), "effort": .string("huge")]))
    }
}
