import Foundation
import XCTest
@testable import ProsperApp

/// #1839: sessions.say / sessions.interrupt / sessions.prompt. Every row runs on seams: the island store is a test
/// store (AgentWindowD1Tests' fakes), the controller's human-click path is a recorder that runs the window's driver on a
/// fake IO, the screen read is a recorder, the notice goes to a recorder. No dch, no window, no real controller.
final class ControlSessionsTalkTests: XCTestCase {
    let base = AgentWindowD1Tests()

    /// A fake dch for the driver: the screen, the status before and after the say or Esc, and what was sent.
    final class FakeDch: @unchecked Sendable {
        let lock = NSLock()
        var screen = "> "
        var status = "idle"
        var after = "working"
        var said: [String] = []
        var keys: [[String]] = []
        /// dch --say --json's answer.
        var reply = #"{"result":"ok"}"#

        var io: AgentPromptIO {
            AgentPromptIO(read: { _ in self.lock.withLock { self.screen } }, status: { _ in self.lock.withLock { self.status } },
                          send: { _, _ in },
                          keys: { _, k in self.lock.withLock { self.keys.append(k); self.status = self.after } },
                          say: { _, t in
                              self.lock.withLock { self.said.append(t); self.status = self.after }
                              return self.lock.withLock { self.reply }
                          })
        }
    }

    var acted: [String] = []
    var outcomes: [AgentWindowOutcome] = []
    var reads: [AgentSessionKey] = []
    var pendingRead: (@MainActor @Sendable (String) -> Void)?
    var notices: [String] = []
    /// What the human-click path answers: false = held (nothing runs).
    var free = true

    @MainActor
    func withSeams(_ store: AgentIslandStore?, dch: FakeDch = FakeDch(), _ body: (ControlChanges) async throws -> Void) async rethrows {
        let saved = (ControlSessions.model, ControlSessions.islandStore, ControlSessions.showWindow,
                     ControlSessionsTalk.act, ControlSessionsTalk.read, ControlSessionsTalk.bound, ControlSessionsTalk.sleep,
                     ControlSessionsTalk.liveRecords)
        defer {
            (ControlSessions.model, ControlSessions.islandStore, ControlSessions.showWindow) = (saved.0, saved.1, saved.2)
            (ControlSessionsTalk.act, ControlSessionsTalk.read) = (saved.3, saved.4)
            (ControlSessionsTalk.bound, ControlSessionsTalk.sleep, ControlSessionsTalk.liveRecords) = (saved.5, saved.6, saved.7)
        }
        ControlSessionsTalk.liveRecords = { { _ in [] } }
        // #1875: a lost outcome ends a row in seconds (the default sleep is cancelled once an outcome lands).
        ControlSessionsTalk.bound = 2
        ControlSessions.model = { nil }
        ControlSessions.islandStore = { store }
        ControlSessions.showWindow = { nil }
        acted = []; outcomes = []; reads = []; pendingRead = nil; notices = []; free = true
        let io = dch.io
        ControlSessionsTalk.act = { s, run, done in
            self.acted.append(s.name)
            guard self.free else { return false }
            let r = run(io)
            self.outcomes.append(r)
            done(r)
            return true
        }
        ControlSessionsTalk.read = { key, done in self.reads.append(key); self.pendingRead = done }
        let changes = ControlChanges()
        changes.present = { text, _ in self.notices.append(text) }
        try await body(changes)
    }

    func args(_ d: [String: String]) -> [String: ControlJSON] { d.mapValues { .string($0) } }

    @MainActor
    func refused<T>(_ expr: @autoclosure () throws -> T, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try expr(), file: file, line: line) {
            XCTAssertEqual(($0 as? ControlError)?.message, message, file: file, line: line)
        }
    }

    /// `refused` for an awaited call (an autoclosure cannot await).
    @MainActor
    func refusedAsync<T>(_ expr: () async throws -> T, _ message: String, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await expr()
            XCTFail("no error, expected: \(message)", file: file, line: line)
        } catch {
            XCTAssertEqual((error as? ControlError)?.message, message, file: file, line: line)
        }
    }

    func object(_ j: ControlJSON) -> [String: ControlJSON] {
        guard case .object(let o) = j else { return [:] }
        return o
    }

    static let permission = [String(repeating: "─", count: 90), " Bash command", "", "   rm -rf .build", "",
                             " Do you want to proceed?", " ❯ 1. Yes", "   2. No"].joined(separator: "\n")

    // MARK: - text

    /// Agent text is outside text: a control character other than LF and tab, or a text past the composer's cap, is
    /// refused whole; blank is refused; the rest is trimmed as the composer sends it.
    @MainActor
    func testSayTextRefusesControlCharactersAndLongText() throws {
        for bad in ["go\r", "go\u{1B}[201~rm", "go\u{7F}", "go\u{85}", "go\u{00}"] {
            refused(try ControlSessionsTalk.text(["text": .string(bad)]),
                    "text has a control or hidden character: only line breaks (LF) and tabs are allowed")
        }
        for bad in ["a\u{202E}b", "a\u{200B}b", "a\u{2028}b", "\u{2003}/x"] {
            refused(try ControlSessionsTalk.text(["text": .string(bad)]),
                    "text has a control or hidden character: only line breaks (LF) and tabs are allowed")
        }
        for bad in ["/x", "  /x", "\n/x", "\t!x", "!x"] {
            refused(try ControlSessionsTalk.text(["text": .string(bad)]),
                    "a message cannot start with / or !: slash commands and shell mode stay with the person")
        }
        XCTAssertEqual(try ControlSessionsTalk.text(["text": .string("see /tmp/x")]), "see /tmp/x")
        XCTAssertEqual(try ControlSessionsTalk.text(["text": .string("hi!")]), "hi!")
        refused(try ControlSessionsTalk.text(["text": .string(String(repeating: "a", count: ControlSessionsTalk.maxBytes + 1))]),
                "text is longer than \(ControlSessionsTalk.maxBytes) bytes")
        XCTAssertEqual(try ControlSessionsTalk.text(["text": .string(String(repeating: "a", count: ControlSessionsTalk.maxBytes))]).count,
                       ControlSessionsTalk.maxBytes, "the cap itself is allowed")
        refused(try ControlSessionsTalk.text(["text": .string(" \n\t ")]), "argument 'text' is empty")
        XCTAssertEqual(try ControlSessionsTalk.text(["text": .string("  fix the build\n\tthen test \n")]), "fix the build\n\tthen test")
    }

    // MARK: - sessions.say

    /// The composer's send through the human-click path: the driver's say with the text, confirmed by Claude starting
    /// work; #1875: the reply waits for that outcome and says delivered; the change names the session, no undo.
    @MainActor
    func testSayRunsTheDriversSendOnTheHumanPath() async throws {
        let st = base.store([base.session("api", .idle, alias: "API")])
        let dch = FakeDch()
        try await withSeams(st, dch: dch) { changes in
            let c = try await ControlSessionsTalk.say(args(["name": "api", "text": "run the tests"]), changes: changes)
            XCTAssertEqual(acted, ["api"])
            XCTAssertEqual(dch.said, ["run the tests"])
            XCTAssertEqual(outcomes, [.done])
            XCTAssertEqual(c.result, .object(["delivered": .bool(true)]))
            XCTAssertEqual(c.summary, "API: run the tests", "the notice names the session")
            XCTAssertEqual(c.verb, "messaged")
            XCTAssertTrue(c.undo == nil, "no inverse")
            XCTAssertEqual(notices, [], "a sent message adds no failure notice")
        }
    }

    /// #1994: sessions.say on a Codex session (its own record an interactive Codex, no Claude) skips Claude's screen
    /// check: a "❯ 1." caret row in Codex's output goes to --say. The same screen on a Claude session is refused.
    @MainActor
    func testSayToACodexSessionLeavesTheScreenToDch() async throws {
        let st = base.store([base.session("api", .idle, alias: "API"), base.session("api-qa", .idle, alias: "QA")])
        let dch = FakeDch()
        dch.screen = AgentWindowInteractionTests.codexScreen
        var rec = DchHistoryRecord(key: AgentSessionKey(dir: "/tmp/dch-test", name: "api"))
        rec.argv = ["codex"]
        let live = [rec]
        try await withSeams(st, dch: dch) { changes in
            ControlSessionsTalk.liveRecords = { { _ in live } }
            let c = try await ControlSessionsTalk.say(args(["name": "api", "text": "go on"]), changes: changes)
            XCTAssertEqual(c.result, .object(["delivered": .bool(true)]))
            XCTAssertEqual(dch.said, ["go on"])
            dch.status = "idle"
            await refusedAsync({ try await ControlSessionsTalk.say(self.args(["name": "api-qa", "text": "go on"]), changes: changes) },
                               "QA: not delivered: \(AgentWindowText.promptShown)")
            XCTAssertEqual(dch.said, ["go on"], "nothing typed into the Claude session")
        }
    }

    /// #1996: sessions.say on a row whose list says "codex" (a Codex typed at the shell prompt: no Codex record) skips
    /// Claude's screen check and never reads the record.
    @MainActor
    func testSayTakesTheListsAgentAndReadsNoRecord() async throws {
        final class Count: @unchecked Sendable { let lock = NSLock(); var n = 0 }
        var s = base.session("api", .idle, alias: "API")
        s.agent = "codex"
        let st = base.store([s]), dch = FakeDch(), count = Count()
        dch.screen = AgentWindowInteractionTests.codexScreen
        try await withSeams(st, dch: dch) { changes in
            ControlSessionsTalk.liveRecords = { { _ in count.lock.withLock { count.n += 1 }; return [] } }
            let c = try await ControlSessionsTalk.say(args(["name": "api", "text": "go on"]), changes: changes)
            XCTAssertEqual(c.result, .object(["delivered": .bool(true)]))
            XCTAssertEqual(dch.said, ["go on"])
            XCTAssertEqual(count.lock.withLock { count.n }, 0, "the list said: no record read")
        }
    }

    /// #1875: the outcome lands after say awaits (the real path hands it back on main later): the reply waits for it.
    @MainActor
    func testSayWaitsForAnOutcomeThatLandsLater() async throws {
        let st = base.store([base.session("api", .idle, alias: "API")])
        try await withSeams(st) { changes in
            ControlSessionsTalk.sleep = { _ in try? await Task.sleep(nanoseconds: 60_000_000_000) }
            ControlSessionsTalk.act = { _, _, done in Task { @MainActor in done(.done) }; return true }
            let c = try await ControlSessionsTalk.say(args(["name": "api", "text": "go on"]), changes: changes)
            XCTAssertEqual(c.result, .object(["delivered": .bool(true)]))
        }
    }

    /// A failure the driver finds (here a prompt on screen) is an error naming the session, and still a notice.
    @MainActor
    func testSayFailureLaterIsANoticeNamingTheSession() async throws {
        let st = base.store([base.session("api", .done, alias: "API")])
        let dch = FakeDch()
        dch.screen = Self.permission
        try await withSeams(st, dch: dch) { changes in
            do {
                _ = try await ControlSessionsTalk.say(args(["name": "api", "text": "go on"]), changes: changes)
                XCTFail("a prompt on screen is not delivered")
            } catch let e as ControlError {
                XCTAssertTrue(e.message.hasPrefix("API: not delivered: "), e.message)
            }
            XCTAssertEqual(dch.said, [], "nothing typed over a prompt")
            XCTAssertEqual(notices.count, 1)
            XCTAssertEqual(notices.last?.hasPrefix("Agent's message to API failed: "), true, "\(notices)")
        }
    }

    /// #1875 (session-tokens, 2026-11-22): dch --say skips over a composer that already holds a draft; the ctl reply
    /// was ok and nothing showed. Now the reply is an error naming the draft.
    @MainActor
    func testSayOverADraftThrowsTheReason() async throws {
        let st = base.store([base.session("api", .idle, alias: "API")])
        let dch = FakeDch()
        dch.reply = #"{"result":"skipped","reason":"draft"}"#
        await withSeams(st, dch: dch) { changes in
            await refusedAsync({ try await ControlSessionsTalk.say(self.args(["name": "api", "text": "(end of note)"]), changes: changes) },
                               "API: not delivered: \(AgentWindowText.draft)")
            XCTAssertEqual(outcomes, [.failed(AgentWindowText.draft)])
            XCTAssertEqual(notices, ["Agent's message to API failed: \(AgentWindowText.draft)"], "the UI notice stays")
        }
    }

    /// The failure reason is outside text too: a hidden character in it is dropped from the error and the notice.
    @MainActor
    func testSayFailureReasonIsCleaned() async throws {
        let st = base.store([base.session("api", .done, alias: "API")])
        await withSeams(st) { changes in
            ControlSessionsTalk.act = { s, _, done in done(.failed("no\u{202E}pe")); return true }
            await refusedAsync({ try await ControlSessionsTalk.say(self.args(["name": "api", "text": "go on"]), changes: changes) },
                               "API: not delivered: nope")
            XCTAssertEqual(notices, ["Agent's message to API failed: nope"])
        }
    }

    /// #1875: no outcome within the bound is not an error: {"delivered": "unknown", note}.
    @MainActor
    func testSayWithoutOutcomeInTimeIsUnknown() async throws {
        let st = base.store([base.session("api", .idle, alias: "API")])
        try await withSeams(st) { changes in
            ControlSessionsTalk.sleep = { _ in }
            ControlSessionsTalk.act = { _, _, _ in true }
            let c = try await ControlSessionsTalk.say(args(["name": "api", "text": "go on"]), changes: changes)
            XCTAssertEqual(c.result, .object(["delivered": .string("unknown"), "note": .string(ControlSessionsTalk.unknownNote)]))
        }
    }

    /// Blocked, working, a row lock, Claude not in front, a held session and an unknown name are errors; none but the
    /// held one reaches the human-click path, and nothing is typed.
    @MainActor
    func testSayRefusalsTypeNothing() async throws {
        var away = base.session("away", .idle)
        away.claudeForeground = false
        let st = base.store([base.session("ask", .blocked), base.session("busy", .working), base.session("api", .idle), away])
        st.actions[AgentSessionKey(dir: "/tmp/dch-test", name: "api")] = AgentIsland.restartingText
        let dch = FakeDch()
        await withSeams(st, dch: dch) { changes in
            @MainActor func say(_ name: String) async throws { _ = try await ControlSessionsTalk.say(args(["name": name, "text": "hi"]), changes: changes) }
            await refusedAsync({ try await say("ask") }, AgentWindowText.blocked)
            await refusedAsync({ try await say("busy") }, AgentWindowText.working)
            await refusedAsync({ try await say("api") }, AgentWindowControls.lockPlaceholder(AgentIsland.restartingText))
            await refusedAsync({ try await say("away") }, AgentWindowText.notForeground)
            await refusedAsync({ try await say("nope") }, "no live session named nope (sessions.list lists them)")
            XCTAssertEqual(acted, [])
            st.actions = [:]
            free = false
            await refusedAsync({ try await say("api") }, AgentWindowText.busy)
            XCTAssertEqual(acted, ["api"])
            XCTAssertEqual(dch.said, [])
        }
        await withSeams(nil) { changes in
            await refusedAsync({ try await ControlSessionsTalk.say(self.args(["name": "api", "text": "hi"]), changes: changes) },
                               ControlSessions.islandOff)
        }
    }

    // MARK: - sessions.interrupt

    /// Esc only while the list says working, through the driver (which presses it only with no prompt on screen).
    @MainActor
    func testInterruptPressesEscOnlyWhileWorking() async throws {
        let st = base.store([base.session("api", .working), base.session("idle", .idle), base.session("ask", .blocked)])
        let dch = FakeDch()
        dch.status = "working"
        dch.after = "idle"
        try await withSeams(st, dch: dch) { changes in
            refused(try ControlSessionsTalk.interrupt(args(["name": "idle"]), changes: changes), AgentWindowText.notWorking)
            refused(try ControlSessionsTalk.interrupt(args(["name": "ask"]), changes: changes), AgentWindowText.notWorking)
            XCTAssertEqual(acted, [])
            let c = try ControlSessionsTalk.interrupt(args(["name": "api"]), changes: changes)
            XCTAssertEqual(acted, ["api"])
            XCTAssertEqual(dch.keys, [["esc"]])
            XCTAssertEqual(outcomes, [.done])
            XCTAssertEqual(c.verb, "interrupted")
            XCTAssertTrue(c.undo == nil, "no inverse")
        }
    }

    /// #2029: the refusals name the target's agent: a Codex row (the list's `agent`) says Codex, a Claude row keeps
    /// today's words, for say (list busy, and dch busy after an idle list) and for interrupt (list not working, and dch
    /// not working after a working list). Red at base: all four Codex lines say "Claude".
    @MainActor
    func testBusyRefusalsNameCodexOnACodexTarget() async throws {
        func row(_ name: String, _ state: AgentState, codex: Bool) -> AgentSession {
            var s = base.session(name, state)
            s.agent = codex ? "codex" : "claude"
            return s
        }
        let st = base.store([row("cx-busy", .working, codex: true), row("cl-busy", .working, codex: false),
                             row("cx-idle", .idle, codex: true), row("cl-idle", .idle, codex: false),
                             row("cx-late", .idle, codex: true), row("cl-late", .idle, codex: false)])
        let working = "Codex is working. Send when it's done, or interrupt it"
        let notWorking = "Codex isn't working, so there's nothing to interrupt"
        let dch = FakeDch()
        try await withSeams(st, dch: dch) { changes in
            @MainActor func say(_ name: String) async throws { _ = try await ControlSessionsTalk.say(args(["name": name, "text": "hi"]), changes: changes) }
            await refusedAsync({ try await say("cx-busy") }, working)
            await refusedAsync({ try await say("cl-busy") }, AgentWindowText.working)
            refused(try ControlSessionsTalk.interrupt(args(["name": "cx-idle"]), changes: changes), notWorking)
            refused(try ControlSessionsTalk.interrupt(args(["name": "cl-idle"]), changes: changes), AgentWindowText.notWorking)
            XCTAssertEqual(acted, [])
            // The list said idle, dch says working: the driver's refusal reaches the caller in the same words.
            dch.status = "working"
            await refusedAsync({ try await say("cx-late") }, "cx-late: not delivered: " + working)
            dch.status = "working"
            await refusedAsync({ try await say("cl-late") }, "cl-late: not delivered: " + AgentWindowText.working)
        }
        let late = base.store([row("cx", .working, codex: true), row("cl", .working, codex: false)])
        try await withSeams(late, dch: FakeDch()) { changes in
            // The list said working, dch says idle: the driver's refusal is the failure notice.
            for name in ["cx", "cl"] {
                let dch = FakeDch()
                dch.status = "idle"
                ControlSessionsTalk.act = { _, run, done in done(run(dch.io)); return true }
                _ = try ControlSessionsTalk.interrupt(args(["name": name]), changes: changes)
            }
            XCTAssertEqual(notices, ["Agent's interrupt to cx failed: " + notWorking,
                                     "Agent's interrupt to cl failed: " + AgentWindowText.notWorking])
        }
    }

    // MARK: - sessions.prompt

    /// Not blocked: not waiting, no read. Blocked with the island's card: its question and options, no read. Blocked
    /// without one: one read starts (none more while it runs), the reply says reading; once it lands the question is
    /// there; a changed activity reads again.
    @MainActor
    func testPromptReadsTheCardOrOneScreenRead() async throws {
        let dir = "/tmp/dch-test-\(UUID().uuidString)"
        let st = base.store([base.session("api", .idle, dir: dir), base.session("ask", .blocked, dir: dir),
                             base.session("card", .blocked, dir: dir)])
        let p = try XCTUnwrap(AgentPrompt.screen(Self.permission)?.prompt)
        st.cards[AgentSessionKey(dir: dir, name: "card")] = .prompt(p)
        try await withSeams(st) { _ in
            let idle = object(try ControlSessionsTalk.prompt(args(["name": "api"])))
            XCTAssertEqual(idle["waiting"], .bool(false))
            XCTAssertTrue(idle["question"] == nil)
            let card = object(try ControlSessionsTalk.prompt(args(["name": "card"])))
            XCTAssertEqual(card["question"], .string("Do you want to proceed?"))
            guard case .array(let options)? = card["options"] else { return XCTFail("options: \(card)") }
            XCTAssertEqual(options.count, 2)
            XCTAssertEqual(object(options.last ?? .null)["label"], .string("No"))
            XCTAssertEqual(reads, [], "a card needs no read")

            let first = object(try ControlSessionsTalk.prompt(args(["name": "ask"])))
            XCTAssertEqual(first["reading"], .bool(true))
            XCTAssertTrue(first["question"] == nil)
            _ = try ControlSessionsTalk.prompt(args(["name": "ask"]))
            XCTAssertEqual(reads.count, 1, "one read at a time")
            pendingRead?(Self.permission)
            let landed = object(try ControlSessionsTalk.prompt(args(["name": "ask"])))
            XCTAssertEqual(landed["reading"], .bool(false))
            XCTAssertEqual(landed["question"], .string("Do you want to proceed?"))
            XCTAssertEqual(landed["hidden"], .bool(false))
            XCTAssertEqual(reads.count, 1)

            let moved = base.session("ask", .blocked, ago: 5, dir: dir)
            st.sessions = [moved]
            XCTAssertEqual(object(try ControlSessionsTalk.prompt(args(["name": "ask"])))["reading"], .bool(true), "new activity: read again")
            XCTAssertEqual(reads.count, 2)
            pendingRead?("")
        }
    }

    /// Screen text in a reply is outside text: a bidi override in the question is dropped and flagged as hidden.
    @MainActor
    func testPromptStripsHiddenCharacters() async throws {
        let dir = "/tmp/dch-test-\(UUID().uuidString)"
        let st = base.store([base.session("ask", .blocked, dir: dir)])
        try await withSeams(st) { _ in
            _ = try ControlSessionsTalk.prompt(args(["name": "ask"]))
            pendingRead?(Self.permission.replacingOccurrences(of: "Do you want", with: "Do\u{202E} you want"))
            let r = object(try ControlSessionsTalk.prompt(args(["name": "ask"])))
            XCTAssertEqual(r["question"], .string("Do you want to proceed?"))
            XCTAssertEqual(r["hidden"], .bool(true))
        }
    }

    // MARK: - registry

    /// say and interrupt are changes (refused while the switch is off); prompt is a read with no answer verb.
    @MainActor
    func testRegistryDeclaresTwoChangesAndOneRead() {
        var r = ControlRegistry()
        ControlRegistry.registerSessionsTalk(&r)
        XCTAssertEqual(r.commands.keys.sorted(), ["sessions.interrupt", "sessions.prompt", "sessions.say"])
        XCTAssertEqual(r.commands["sessions.say"]?.mutates, true)
        XCTAssertEqual(r.commands["sessions.interrupt"]?.mutates, true)
        XCTAssertEqual(r.commands["sessions.prompt"]?.mutates, false)
        XCTAssertEqual(r.commands["sessions.say"]?.args["text"]?.required, true)
        XCTAssertTrue(r.commands["sessions.say"]?.runAsync != nil, "#1875: say is awaited for its outcome")
    }

    /// #1877 (QA R1875 q1): through reply(to:), say's hand-written record line logs the change once, with its notice.
    @MainActor
    func testSayThroughTheRegistryRecordsTheChange() async {
        let st = base.store([base.session("api", .idle, alias: "API")])
        await withSeams(st) { changes in
            Preferences.defaults.removeObject(forKey: Preferences.agentControlKey)
            var r = ControlRegistry()
            ControlRegistry.registerSessionsTalk(&r)
            r.changes = changes
            let registry = r
            let reply = await registry.reply(to: Data(#"{"cmd":"sessions.say","args":{"name":"api","text":"go on"}}"#.utf8))
            XCTAssertEqual(reply, ControlReply(ok: true, result: .object(["delivered": .bool(true)]), error: nil))
            XCTAssertEqual(changes.entries.map(\.command), ["sessions.say"], "recorded once")
            XCTAssertEqual(changes.entries.last?.summary, "API: go on")
            XCTAssertEqual(notices, ["Agent messaged: API: go on"], "the change's notice, no failure notice")
        }
    }
}
