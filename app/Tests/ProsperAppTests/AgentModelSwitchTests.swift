import AppKit
import XCTest
@testable import ProsperApp

/// #1469 (spec #1192 P3): a session's model and effort switched from the Agent Sessions menus. dch is a fake only (the
/// AgentPromptIO seam and AgentPromptIO.live's recorder); no menu is shown (AgentModelSwitch.menus is a value).
final class AgentModelSwitchTests: XCTestCase {
    static let key = AgentSessionKey(dir: "/tmp/dch-test", name: "s")
    static let rule = String(repeating: "\u{2500}", count: 40)
    static let idle = "\u{23FA} Done.\n\n" + rule + "\n\u{276F} \n" + rule + "\n  ? for shortcuts"
    static let ok = #"{"name":"s","result":"ok","reason":"","detail":""}"#

    /// The screen after `typed` ran: its echo, then Claude Code's answer line.
    static func answered(_ typed: String, _ answer: String) -> String {
        "\u{23FA} Done.\n> " + typed + "\n  \u{23BF}  " + answer + "\n" + rule + "\n\u{276F} \n" + rule
    }

    final class Fake: @unchecked Sendable {
        let lock = NSLock()
        var statuses: [String]
        var screens: [String]
        var reply: String
        var says: [String] = []
        init(statuses: [String] = ["idle"], screens: [String] = [AgentModelSwitchTests.idle], reply: String = AgentModelSwitchTests.ok) {
            (self.statuses, self.screens, self.reply) = (statuses, screens, reply)
        }
        private func next(_ a: inout [String]) -> String { a.count > 1 ? a.removeFirst() : (a.first ?? "") }
        var io: AgentPromptIO {
            AgentPromptIO(read: { _ in self.lock.withLock { self.next(&self.screens) } },
                          status: { _ in self.lock.withLock { self.next(&self.statuses) } },
                          send: { _, _ in XCTFail("a switch never goes through --send") },
                          keys: { _, _ in XCTFail("a switch never sends keys") },
                          say: { _, t in self.lock.withLock { self.says.append(t); return self.reply } })
        }
    }

    /// A transcript seen through AgentModelEffort.IO: `before` bytes at the send, then `lines` appended.
    final class Files: @unchecked Sendable {
        let lock = NSLock()
        var data = Data(repeating: 0x20, count: 99) + Data([0x0A])
        var grown: Data?
        var io: AgentModelEffort.IO {
            AgentModelEffort.IO(size: { _ in self.lock.withLock {
                let d = self.data
                if let g = self.grown { self.data = g; self.grown = nil }   // grows right after the size at the send
                return UInt64(d.count)
            } }, read: { _, offset, length in self.lock.withLock {
                guard offset <= UInt64(self.data.count), Int(offset) + length <= self.data.count else { return nil }
                return self.data.subdata(in: Int(offset)..<(Int(offset) + length))
            } })
        }
        func append(_ objects: [[String: Any]]) {
            var g = data
            for o in objects { g += (try? JSONSerialization.data(withJSONObject: o)) ?? Data(); g.append(0x0A) }
            grown = g
        }
    }

    static func localCommand(_ content: String, sidechain: Bool = false) -> [String: Any] {
        ["type": "system", "subtype": "local_command", "content": content, "isSidechain": sidechain]
    }

    func driver(_ io: AgentPromptIO) -> AgentWindowDriver {
        AgentWindowDriver(key: Self.key, io: io, pause: { _ in })
    }

    static let noFiles = AgentModelEffort.IO(size: { _ in nil }, read: { _, _, _ in nil })

    func session(_ state: AgentState, foreground: Bool? = true) -> AgentSession {
        var s = AgentSession(key: Self.key, alias: "", activity: 1, state: state, agents: 0)
        s.claudeForeground = foreground
        return s
    }

    // MARK: - The one list and the exact argv (dch #444)

    func testTheSentArgvIsExactlyTheCommandFromTheOneListForEveryItem() throws {
        XCTAssertEqual(AgentModelEffort.aliases, ["default", "opus", "sonnet", "haiku", "opusplan"])
        XCTAssertEqual(AgentModelEffort.levelOrder, ["low", "medium", "high", "xhigh", "max"])
        XCTAssertEqual(AgentModelEffort.levels, Set(AgentModelEffort.levelOrder), "one list")
        final class Rec: @unchecked Sendable { let lock = NSLock(); var calls: [[String]] = []; var typed: String? }
        let r = Rec()
        let io = AgentPromptIO.live(run: { args, _ in
            r.lock.withLock {
                r.calls.append(args)
                if args.first == "--status" { return Data("idle".utf8) }
                guard args.first == "--read", let t = r.typed else { return Data(AgentModelSwitchTests.idle.utf8) }
                let answer = t.hasPrefix("/model ") ? "Set model to " + t.dropFirst(7) : "Set effort level to " + t.dropFirst(8)
                return Data(AgentModelSwitchTests.answered(t, answer).utf8)
            }
        }, say: { args, _ in
            r.lock.withLock { r.calls.append(args); r.typed = args.last }
            return Data(AgentModelSwitchTests.ok.utf8)
        }, noMirror: { _, _ in false }, send: { args, _ in r.lock.withLock { r.calls.append(args) }; return ("", 0) })
        let commands = AgentModelEffort.aliases.compactMap(AgentModelSwitch.Command.model)
            + AgentModelEffort.levelOrder.compactMap(AgentModelSwitch.Command.effort)
        XCTAssertEqual(commands.count, 10)
        for c in commands {
            r.lock.withLock { r.calls = []; r.typed = nil }
            let out = driver(io).switchTo(c, transcript: nil, files: Self.noFiles)
            if case .answered = out {} else { XCTFail("\(c.text): \(out)") }
            let calls = r.lock.withLock { r.calls }
            XCTAssertEqual(calls.filter { $0.first == "--say" }, [["--say", "s", "--json", "--", c.text]])
            XCTAssertTrue(c.text == "/model " + c.value || c.text == "/effort " + c.value)
            XCTAssertFalse(calls.contains { $0.contains("--run") || $0.first == "--send" || $0.first == "--keys" }, "never --run")
        }
        // No other text can reach it: the only constructors take a list item and nothing else.
        for bad in ["opus ", "Opus", "opus\n/exit", "claude-opus-4-1", "", "/model", "opus; x", "[1m]"] {
            XCTAssertTrue(AgentModelSwitch.Command.model(bad) == nil, bad)
            XCTAssertTrue(AgentModelSwitch.Command.effort(bad) == nil, bad)
        }
        XCTAssertTrue(AgentModelSwitch.Command.effort("ultra") == nil)
        XCTAssertTrue(AgentModelSwitch.Command.model("high") == nil, "a level is not an alias")
    }

    // MARK: - Refusals

    func testDriverRefusesWhileWorkingBlockedOrOverAPromptAndTypesNothing() throws {
        let c = try XCTUnwrap(AgentModelSwitch.Command.model("opus"))
        let w = Fake(statuses: ["working"])
        XCTAssertEqual(driver(w.io).switchTo(c, transcript: nil, files: Self.noFiles), .failed(AgentModelSwitch.working))
        XCTAssertEqual(AgentModelSwitch.working, "Claude is working. Switch when it's done")
        let b = Fake(statuses: ["blocked"])
        XCTAssertEqual(driver(b.io).switchTo(c, transcript: nil, files: Self.noFiles), .failed(AgentWindowText.blocked))
        let p = Fake(screens: ["Claude has written up a plan and is ready to execute. Would you like to proceed?\n\u{276F} 1. Yes"])
        if case .failed = driver(p.io).switchTo(c, transcript: nil, files: Self.noFiles) {} else { XCTFail("a prompt on screen") }
        XCTAssertEqual(w.says + b.says + p.says, [], "nothing typed")
    }

    @MainActor
    func testWindowRefusesWhileWorkingBlockedNotForegroundOrLockHeld() throws {
        let c = try XCTUnwrap(AgentModelSwitch.Command.effort("high"))
        func run(_ s: AgentSession, rowText: String? = nil) -> (said: [String], told: [String]) {
            let f = Fake()
            let i = interaction(controller(f.io))
            if let rowText { i.rowText = { _ in rowText } }
            var told: [String] = []
            i.switchTo(c, s) { told.append($0) }
            until("settled") { !i.busy }
            return (f.lock.withLock { f.says }, told)
        }
        XCTAssertEqual(run(session(.working)).told, [AgentModelSwitch.working])
        XCTAssertEqual(run(session(.blocked)).told, [AgentWindowText.blocked])
        XCTAssertEqual(run(session(.idle, foreground: false)).told, [AgentWindowText.notForeground])
        XCTAssertEqual(run(session(.idle, foreground: nil)).told, [AgentWindowText.notForeground], "claude_foreground must be true")
        let locked = run(session(.idle), rowText: AgentIsland.restartingText)
        XCTAssertEqual(locked.told, [AgentWindowControls.lockPlaceholder(AgentIsland.restartingText)])
        XCTAssertEqual(locked.said, [], "the Restart/Stop lock holds the switch")
        for s in [session(.working), session(.blocked), session(.idle, foreground: false)] { XCTAssertEqual(run(s).said, []) }
    }

    // MARK: - dch results

    func testEachDchResultMapsToItsNotice() throws {
        let c = try XCTUnwrap(AgentModelSwitch.Command.model("sonnet"))
        func reply(_ result: String, _ reason: String) -> String {
            #"{"name":"s","result":""# + result + #"","reason":""# + reason + #"","detail":""}"#
        }
        let cases: [(String, AgentWindowOutcome)] = [
            (reply("skipped", "not_claude"), .failed(AgentWindowText.notClaude)),
            (reply("skipped", "prompt"), .failed(AgentWindowText.blocked)),
            (reply("skipped", "draft"), .failed(AgentWindowText.draft)),
            (reply("failed", "not_foreground"), .failed(AgentWindowText.notForeground)),
            ("", .failed(AgentWindowText.unconfirmed)),
        ]
        for (r, want) in cases {
            let f = Fake(reply: r)
            XCTAssertEqual(driver(f.io).switchTo(c, transcript: nil, files: Self.noFiles), want, r)
            XCTAssertEqual(f.says, ["/model sonnet"])
        }
        let ok = Fake(screens: [Self.idle, Self.answered("/model sonnet", "Set model to sonnet (claude-sonnet-4-5)")])
        XCTAssertEqual(driver(ok.io).switchTo(c, transcript: nil, files: Self.noFiles),
                       .answered(AgentModelSwitch.switched("Set model to sonnet (claude-sonnet-4-5)")), "ok: the screen's answer")
    }

    // MARK: - Confirm

    func testModelConfirmedByALocalCommandLineAfterTheSend() throws {
        let c = try XCTUnwrap(AgentModelSwitch.Command.model("opus"))
        let files = Files()
        files.append([
            ["type": "system", "subtype": "local_command",
             "content": "<command-name>/model</command-name>\n<command-args>opus</command-args>"],
            Self.localCommand("<local-command-stdout>Set model to sonnet</local-command-stdout>", sidechain: true),
            Self.localCommand("<local-command-stdout>Set model to \u{1B}[1mopus (claude-opus-4-1)\u{1B}[22m</local-command-stdout>"),
        ])
        let f = Fake()   // the screen never shows it: the transcript line decides
        XCTAssertEqual(driver(f.io).switchTo(c, transcript: "/Users/example/t.jsonl", files: files.io),
                       .answered(AgentModelSwitch.switched("Set model to opus (claude-opus-4-1)")))
        XCTAssertEqual(f.says, ["/model opus"])
        // Bytes before the send are never read as the answer.
        let old = Files()
        old.data = (try JSONSerialization.data(withJSONObject: Self.localCommand(
            "<local-command-stdout>Set model to opus</local-command-stdout>"))) + Data([0x0A])
        XCTAssertEqual(driver(Fake().io).switchTo(c, transcript: "/Users/example/t.jsonl", files: old.io),
                       .failed(AgentModelSwitch.unconfirmed))
    }

    func testUnconfirmedOrRefusedSwitchSaysOpenInTerminalOrClaudeCodesText() throws {
        let c = try XCTUnwrap(AgentModelSwitch.Command.model("haiku"))
        let none = Fake()
        let out = driver(none.io).switchTo(c, transcript: nil, files: Self.noFiles)
        XCTAssertEqual(out, .failed(AgentModelSwitch.unconfirmed))
        XCTAssertTrue(AgentModelSwitch.unconfirmed.hasSuffix(AgentWindowControls.openLabel))
        let refused = Fake(screens: [Self.idle, Self.answered("/model haiku", "Model 'haiku' is not available for your plan")])
        XCTAssertEqual(driver(refused.io).switchTo(c, transcript: nil, files: Self.noFiles),
                       .failed(AgentModelSwitch.refused("Model 'haiku' is not available for your plan")))
        // An echo already on screen before the send is not the answer.
        let stale = Self.answered("/model haiku", "Set model to haiku")
        XCTAssertEqual(driver(Fake(screens: [stale]).io).switchTo(c, transcript: nil, files: Self.noFiles),
                       .failed(AgentModelSwitch.unconfirmed))
        // Outside text is cleaned before it reaches a notice.
        XCTAssertEqual(AgentModelEffort.clean("a\u{1B}[31m\u{202E}b\u{0}\n c"), "a b c")
        XCTAssertTrue(AgentModelEffort.clean(" \u{1B}[0m ") == nil)
        XCTAssertEqual(AgentModelEffort.clean(String(repeating: "x", count: 900))?.count, AgentModelEffort.maxAnswer)
    }

    // MARK: - Effort

    @MainActor
    func testEffortIsRequestedThenNotTakenSaysMayOverride() throws {
        let c = try XCTUnwrap(AgentModelSwitch.Command.effort("high"))
        let f = Fake(screens: [Self.idle, Self.answered("/effort high", "Set effort level to high")])
        XCTAssertEqual(driver(f.io).switchTo(c, transcript: nil, files: Self.noFiles),
                       .answered(AgentModelSwitch.requestedText("high") + ". " + AgentModelSwitch.switched("Set effort level to high")))
        XCTAssertEqual(AgentModelSwitch.requestedText("high"), "Requested: high (from the next message)")
        // Through the window: the request waits for the next answer.
        let g = Fake()
        let i = interaction(controller(g.io))
        var told: [String] = []
        i.switchTo(c, session(.idle)) { told.append($0) }
        until("answered") { !told.isEmpty }
        XCTAssertEqual(told, [AgentModelSwitch.requestedText("high")])
        XCTAssertEqual(i.requested[Self.key], AgentModelSwitch.Pending(level: "high"))
        func row(_ state: AgentState, _ effort: String) -> AgentSession { var r = session(state); r.effort = effort; return r }
        XCTAssertEqual(i.effortLanded([row(.idle, "medium")]), [:], "the old answer: not the next one")
        XCTAssertEqual(i.effortLanded([row(.working, "medium")]), [:])
        XCTAssertEqual(i.effortLanded([row(.done, "medium")]), [Self.key: AgentModelSwitch.kept("medium")])
        XCTAssertTrue(AgentModelSwitch.kept("medium").contains("CLAUDE_CODE_EFFORT_LEVEL) or the model may override it"))
        XCTAssertEqual(i.requested, [:])
        // Taken: no notice; the row gone: dropped.
        let taken = AgentModelSwitch.landed(AgentModelSwitch.Pending(level: "high", sawWorking: true), row(.idle, "high"))
        XCTAssertTrue(taken.pending == nil && taken.notice == nil)
        let gone = AgentModelSwitch.landed(AgentModelSwitch.Pending(level: "high"), nil)
        XCTAssertTrue(gone.pending == nil && gone.notice == nil)
        // A refusal on screen is Claude Code's own text.
        let no = Fake(screens: [Self.idle, Self.answered("/effort max", "Effort max is not supported by this model")])
        XCTAssertEqual(driver(no.io).switchTo(try XCTUnwrap(AgentModelSwitch.Command.effort("max")), transcript: nil, files: Self.noFiles),
                       .failed(AgentModelSwitch.refused("Effort max is not supported by this model")))
    }

    // MARK: - Menus (a value; no NSMenu is shown)

    func testMenusComeFromThePureFunction() {
        var s = session(.idle)
        s.model = "claude-opus-4-1-20250805"
        s.effort = "xhigh"
        let m = AgentModelSwitch.menus(s)
        XCTAssertEqual(m.map(\.title), ["Model", "Effort"])
        XCTAssertEqual(m.first?.items.map(\.title), AgentModelEffort.aliases)
        XCTAssertEqual(m.last?.items.map(\.title), AgentModelEffort.levelOrder)
        XCTAssertEqual(m.first?.items.filter(\.checked).map(\.title), ["opus"])
        XCTAssertEqual(m.last?.items.filter(\.checked).map(\.title), ["xhigh"])
        XCTAssertEqual(m.first?.notes, ["Also becomes your default for new sessions"])
        XCTAssertEqual(m.last?.notes, ["Also becomes your default for new sessions", "max: This session only"])
        XCTAssertEqual(m.first?.items.map(\.command.text), AgentModelEffort.aliases.map { "/model " + $0 })
        XCTAssertEqual(AgentModelSwitch.menus(s, requested: "low").last?.notes.last, "Requested: low (from the next message)")
        let none = AgentModelSwitch.menus(session(.idle))
        XCTAssertEqual(none.flatMap(\.items).filter(\.checked).count, 0, "unknown: nothing checked")
        let opus = m.first?.items.first { $0.title == "opus" }
        XCTAssertEqual(opus.map { AgentWindowVerb.switchTo($0.command).symbol }, AgentMenuSymbol.model)
        for n in [AgentMenuSymbol.model, AgentMenuSymbol.effort] {
            XCTAssertTrue(NSImage(systemSymbolName: n, accessibilityDescription: nil) != nil, n)
        }
    }

    // MARK: - Helpers

    @MainActor
    func controller(_ io: AgentPromptIO) -> AgentIslandController {
        let c = AgentIslandController()
        c.io = io
        c.showsPanel = false
        c.store = AgentIslandStore(geometry: AgentWindowD1Tests.geometry)
        c.autoAllowOn = { false }
        c.after = { _, _ in }
        c.onSessions = { _ in }
        return c
    }

    @MainActor
    func interaction(_ c: AgentIslandController) -> AgentWindowInteraction {
        let i = AgentWindowInteraction()
        i.controller = c
        i.pause = { _ in }
        i.readQueue = { $0() }
        i.files = Self.noFiles
        return i
    }

    @MainActor
    func until(_ what: String, _ cond: () -> Bool) {
        let deadline = Date().addingTimeInterval(5)
        while !cond(), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertTrue(cond(), what)
    }
}
