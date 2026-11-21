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

        var io: AgentPromptIO {
            AgentPromptIO(read: { _ in self.lock.withLock { self.screen } }, status: { _ in self.lock.withLock { self.status } },
                          send: { _, _ in },
                          keys: { _, k in self.lock.withLock { self.keys.append(k); self.status = self.after } },
                          say: { _, t in
                              self.lock.withLock { self.said.append(t); self.status = self.after }
                              return #"{"result":"ok"}"#
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
    func withSeams(_ store: AgentIslandStore?, dch: FakeDch = FakeDch(), _ body: (ControlChanges) throws -> Void) rethrows {
        let saved = (ControlSessions.model, ControlSessions.islandStore, ControlSessions.showWindow,
                     ControlSessionsTalk.act, ControlSessionsTalk.read)
        defer {
            (ControlSessions.model, ControlSessions.islandStore, ControlSessions.showWindow) = (saved.0, saved.1, saved.2)
            (ControlSessionsTalk.act, ControlSessionsTalk.read) = (saved.3, saved.4)
        }
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
        try body(changes)
    }

    func args(_ d: [String: String]) -> [String: ControlJSON] { d.mapValues { .string($0) } }

    @MainActor
    func refused<T>(_ expr: @autoclosure () throws -> T, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try expr(), file: file, line: line) {
            XCTAssertEqual(($0 as? ControlError)?.message, message, file: file, line: line)
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
    /// work; the change names the session and has no undo.
    @MainActor
    func testSayRunsTheDriversSendOnTheHumanPath() throws {
        let st = base.store([base.session("api", .idle, alias: "API")])
        let dch = FakeDch()
        try withSeams(st, dch: dch) { changes in
            let c = try ControlSessionsTalk.say(args(["name": "api", "text": "run the tests"]), changes: changes)
            XCTAssertEqual(acted, ["api"])
            XCTAssertEqual(dch.said, ["run the tests"])
            XCTAssertEqual(outcomes, [.done])
            XCTAssertEqual(c.result, .string("api"))
            XCTAssertEqual(c.summary, "API: run the tests", "the notice names the session")
            XCTAssertEqual(c.verb, "messaged")
            XCTAssertTrue(c.undo == nil, "no inverse")
            XCTAssertEqual(notices, [], "a sent message adds no failure notice")
        }
    }

    /// A failure the driver finds after the reply (here a prompt on screen) is a notice naming the session.
    @MainActor
    func testSayFailureLaterIsANoticeNamingTheSession() throws {
        let st = base.store([base.session("api", .done, alias: "API")])
        let dch = FakeDch()
        dch.screen = Self.permission
        try withSeams(st, dch: dch) { changes in
            _ = try ControlSessionsTalk.say(args(["name": "api", "text": "go on"]), changes: changes)
            XCTAssertEqual(dch.said, [], "nothing typed over a prompt")
            XCTAssertEqual(notices.count, 1)
            XCTAssertEqual(notices.last?.hasPrefix("Agent's message to API failed: "), true, "\(notices)")
        }
    }

    /// The late-failure reason is outside text too: a hidden character in it is dropped from the notice.
    @MainActor
    func testSayFailureReasonIsCleaned() throws {
        let st = base.store([base.session("api", .done, alias: "API")])
        try withSeams(st) { changes in
            ControlSessionsTalk.act = { s, _, done in done(.failed("no\u{202E}pe")); return true }
            _ = try ControlSessionsTalk.say(args(["name": "api", "text": "go on"]), changes: changes)
            XCTAssertEqual(notices, ["Agent's message to API failed: nope"])
        }
    }

    /// Blocked, working, a row lock, Claude not in front, a held session and an unknown name are errors; none but the
    /// held one reaches the human-click path, and nothing is typed.
    @MainActor
    func testSayRefusalsTypeNothing() throws {
        var away = base.session("away", .idle)
        away.claudeForeground = false
        let st = base.store([base.session("ask", .blocked), base.session("busy", .working), base.session("api", .idle), away])
        st.actions[AgentSessionKey(dir: "/tmp/dch-test", name: "api")] = AgentIsland.restartingText
        let dch = FakeDch()
        try withSeams(st, dch: dch) { changes in
            @MainActor func say(_ name: String) throws { _ = try ControlSessionsTalk.say(args(["name": name, "text": "hi"]), changes: changes) }
            refused(try say("ask"), AgentWindowText.blocked)
            refused(try say("busy"), AgentWindowText.working)
            refused(try say("api"), AgentWindowControls.lockPlaceholder(AgentIsland.restartingText))
            refused(try say("away"), AgentWindowText.notForeground)
            refused(try say("nope"), "no live session named nope (sessions.list lists them)")
            XCTAssertEqual(acted, [])
            st.actions = [:]
            free = false
            refused(try say("api"), AgentWindowText.busy)
            XCTAssertEqual(acted, ["api"])
            XCTAssertEqual(dch.said, [])
        }
        try withSeams(nil) { changes in
            refused(try ControlSessionsTalk.say(args(["name": "api", "text": "hi"]), changes: changes), ControlSessions.islandOff)
        }
    }

    // MARK: - sessions.interrupt

    /// Esc only while the list says working, through the driver (which presses it only with no prompt on screen).
    @MainActor
    func testInterruptPressesEscOnlyWhileWorking() throws {
        let st = base.store([base.session("api", .working), base.session("idle", .idle), base.session("ask", .blocked)])
        let dch = FakeDch()
        dch.status = "working"
        dch.after = "idle"
        try withSeams(st, dch: dch) { changes in
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

    // MARK: - sessions.prompt

    /// Not blocked: not waiting, no read. Blocked with the island's card: its question and options, no read. Blocked
    /// without one: one read starts (none more while it runs), the reply says reading; once it lands the question is
    /// there; a changed activity reads again.
    @MainActor
    func testPromptReadsTheCardOrOneScreenRead() throws {
        let dir = "/tmp/dch-test-\(UUID().uuidString)"
        let st = base.store([base.session("api", .idle, dir: dir), base.session("ask", .blocked, dir: dir),
                             base.session("card", .blocked, dir: dir)])
        let p = try XCTUnwrap(AgentPrompt.screen(Self.permission)?.prompt)
        st.cards[AgentSessionKey(dir: dir, name: "card")] = .prompt(p)
        try withSeams(st) { _ in
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
    func testPromptStripsHiddenCharacters() throws {
        let dir = "/tmp/dch-test-\(UUID().uuidString)"
        let st = base.store([base.session("ask", .blocked, dir: dir)])
        try withSeams(st) { _ in
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
    }
}
