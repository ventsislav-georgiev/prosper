import os
import XCTest
@testable import ProsperApp

/// #1135: dch 1.63's `claude_foreground` on an --ls-json row. False (Claude suspended or in the background, a
/// shell reads what is typed) is treated as #935 treats a row naming no Claude Code: Always allow types nothing,
/// and a card click types nothing either. Absent keeps today's rule. Every dch call is a fake recorder: no test
/// reads a real screen, sends a real key or runs dch.
final class AgentIslandForegroundTests: XCTestCase {

    private static func dialog(_ body: String) -> String {
        [String(repeating: "\u{2500}", count: 90), " Bash command", "", "   \(body)", "   Clean the build tree", "",
         " Do you want to proceed?", " \u{276F} 1. Yes", "   2. No, and tell Claude what to do differently (esc)"]
            .joined(separator: "\n")
    }
    private static let screen = dialog("rm -rf .build")
    private static let otherScreen = dialog("swift build")
    private static let sid = "0b7c2f3e-aaaa-bbbb-cccc-0123456789ab"
    private static let dir = "/Users/example/.local/state/dch"
    private let key = AgentSessionKey(dir: AgentIslandForegroundTests.dir, name: "api")

    /// The keystroke recorder: screens read, keys "sent" (recorded only).
    private final class FakeIO: @unchecked Sendable {
        let lock = NSLock()
        var screen: String
        var reads = 0, statuses = 0, sends: [String] = []
        /// The next read waits on this once (a check still on the queue); bounded, so a slip never hangs.
        var gate: DispatchSemaphore?
        init(_ screen: String) { self.screen = screen }
        var io: AgentPromptIO {
            AgentPromptIO(read: { _ in
                _ = self.lock.withLock { () -> DispatchSemaphore? in defer { self.gate = nil }; return self.gate }?
                    .wait(timeout: .now() + 10)
                return self.lock.withLock { self.reads += 1; return self.screen }
            }, status: { _ in self.lock.withLock { self.statuses += 1 }; return "blocked" }, send: { _, d in self.lock.withLock { self.sends.append(d) } })
        }
        var sent: [String] { lock.withLock { sends } }
        var readCount: Int { lock.withLock { reads } }
        var statusCount: Int { lock.withLock { statuses } }
    }

    @MainActor private final class Rec {
        var lists: [[AgentSession]?] = []
        var timers: [@MainActor @Sendable () -> Void] = []
        var lastState: AgentState? { lists.last??.first { $0.name == "api" }?.state }
    }

    @MainActor private func controller(_ f: FakeIO, autoAllow: Bool = true) -> (AgentIslandController, Rec) {
        let c = AgentIslandController(), r = Rec()
        c.io = f.io
        c.showsPanel = false
        c.store = AgentIslandStore(geometry: AgentWindowD1Tests.geometry)
        c.store?.expanded = true
        c.autoAllowOn = { autoAllow }
        c.controlDch = { nil }   // no dch of its own answers: Prosper decides
        c.now = { Date(timeIntervalSince1970: 1_000_000) }
        c.after = { _, fire in r.timers.append(fire) }
        c.onSessions = { r.lists.append($0) }
        return (c, r)
    }

    /// A Claude Code row (its claude_session_id) with dch's `claude_foreground` as given (nil: the key left out).
    private func row(_ fg: Bool?, activity: TimeInterval = 1, allowed: DchAutoAllowed? = nil) -> AgentSession {
        AgentSession(key: key, alias: "", activity: activity, state: .blocked, agents: 0, version: "1.63.0",
                     autoAllowed: allowed, claudeSessionID: Self.sid,
                     transcriptPath: "/Users/example/.claude/projects/p/\(Self.sid).jsonl", claudeForeground: fg)
    }

    @MainActor @discardableResult
    private func tick(_ c: AgentIslandController, _ s: AgentSession) -> AgentState? {
        c.store?.sessions = [s]
        c.checkAutoAllow()
        c.refreshCards()
        return c.published(c.store?.sessions ?? []).first?.state
    }

    @MainActor private func drain(_ c: AgentIslandController) {
        for _ in 0..<2 {
            c.queue.sync {}
            let hopped = expectation(description: "main hops")
            DispatchQueue.main.async { hopped.fulfill() }
            wait(for: [hopped], timeout: 5)
        }
    }

    /// #1291: a Claude row whose transcript_path is null (dch writes claude_foreground all the same), as given.
    private static func nullTranscriptRow(_ fg: String?) -> Data {
        Data((#"[{"name":"api","alias":"","activity_epoch":1,"state":"blocked","version":"1.63.0","agents":0,"#
            + #""claude_session_id":"\#(sid)","transcript_path":null"#
            + (fg.map { #","claude_foreground":\#($0)"# } ?? "") + "}]").utf8)
    }

    private static func listRow(_ fg: String?) -> Data {
        Data((#"[{"name":"api","alias":"","activity_epoch":1,"state":"blocked","version":"1.63.0","agents":0,"#
            + #""claude_session_id":"\#(sid)","transcript_path":"/Users/example/.claude/projects/p/\#(sid).jsonl""#
            + (fg.map { #","claude_foreground":\#($0)"# } ?? "") + "}]").utf8)
    }

    // MARK: - The parser

    func testParserReadsForegroundTrueAndFalse() {
        XCTAssertEqual(AgentTranscriptMapping.foregrounds(Self.listRow("true"))["api"], true)
        XCTAssertEqual(AgentTranscriptMapping.foregrounds(Self.listRow("false"))["api"], false)
        XCTAssertEqual(AgentIsland.list(dirs: [Self.dir]) { _, _ in Self.listRow("false") }.first?.claudeForeground, false,
                       "the list carries it to the session")
    }

    func testParserLeavesAnAbsentForegroundAbsent() {
        let m = AgentTranscriptMapping.parse(Self.listRow(nil))
        XCTAssertEqual(m["api"]?.sessionID, Self.sid, "the row still maps")
        XCTAssertTrue(AgentTranscriptMapping.foregrounds(Self.listRow(nil))["api"] == nil)
    }

    /// A JSON number bridges to Bool through NSNumber (1 would read true): only a JSON boolean counts.
    func testParserReadsANonBooleanAsAbsent() {
        for v in ["1", "0", "\"true\"", "null", "{}", "[true]"] {
            let m = AgentTranscriptMapping.parse(Self.listRow(v))
            XCTAssertEqual(m["api"]?.sessionID, Self.sid, "\(v): the row still maps")
            XCTAssertTrue(AgentTranscriptMapping.foregrounds(Self.listRow(v))["api"] == nil, "\(v): absent")
        }
    }

    /// #1291: no transcript_path on the row: no mapping, but the foreground is still read (boolean only).
    func testForegroundIsReadForARowWithNoTranscriptPath() {
        let d = Self.nullTranscriptRow("false")
        XCTAssertTrue(AgentTranscriptMapping.parse(d)["api"] == nil, "no mapping, as before")
        XCTAssertEqual(AgentTranscriptMapping.foregrounds(d)["api"], false)
        let s = AgentIsland.list(dirs: [Self.dir]) { _, _ in d }.first
        XCTAssertEqual(s?.claudeForeground, false)
        XCTAssertTrue(s?.transcriptPath == nil, "the transcript stays nil")
        XCTAssertEqual(AgentIsland.list(dirs: [Self.dir]) { _, _ in Self.nullTranscriptRow("true") }.first?.claudeForeground, true)
        for v in ["1", "0", "\"false\"", "null"] {
            let n = AgentIsland.list(dirs: [Self.dir]) { _, _ in Self.nullTranscriptRow(v) }.first
            XCTAssertTrue(n != nil && n?.claudeForeground == nil, "\(v): nil, as before")
        }
    }

    /// The relist right before an automatic send (claudeNow) and the newest list's set share this test of a row.
    func testClaudeReadingFollowsTheListedForeground() {
        for (fg, reading) in [("true", true), ("false", false), (nil, true)] as [(String?, Bool)] {
            let s = AgentIsland.list(dirs: [Self.dir]) { _, _ in Self.listRow(fg) }.first
            XCTAssertEqual(s?.claudeReading, reading, "claude_foreground \(fg ?? "absent")")
        }
    }

    // MARK: - Always allow

    /// Way 1 (checkAutoAllow, a row that just went blocked): not answered, never held, its card, as #935 leaves a
    /// row naming no Claude Code.
    @MainActor func testWay1AFreshCheckOfARowNotInFrontIsNotAnswered() throws {
        let f = FakeIO(Self.screen), (c, r) = controller(f)
        XCTAssertEqual(tick(c, row(false)), .blocked, "Needs input goes out at once")
        XCTAssertFalse(c.heldByAutoAllow(key), "no hold")
        drain(c)
        XCTAssertEqual(f.sent, [], "no key")
        XCTAssertEqual(f.statusCount, 0, "no check")
        XCTAssertEqual(f.readCount, 1, "only the card's read")
        XCTAssertEqual(c.store?.cards[key], .prompt(try XCTUnwrap(AgentPrompt.parse(Self.screen))), "its card")
        XCTAssertTrue(r.timers.isEmpty)
    }

    /// True and absent (a client before 1.63.0, or groups it could not read): today's rule, answered.
    @MainActor func testATrueOrAbsentForegroundIsAnswered() {
        for fg in [true, nil] as [Bool?] {
            let f = FakeIO(Self.screen), (c, _) = controller(f)
            XCTAssertEqual(tick(c, row(fg)), .working, "\(String(describing: fg)): held while it is checked")
            drain(c)
            XCTAssertEqual(f.sent, ["1"], "\(String(describing: fg))")
        }
    }

    /// The send: Claude left the front (Ctrl-Z) while the check was on the queue; the newest list decides.
    @MainActor func testARowThatLeftTheFrontBeforeTheSendIsNotAnswered() {
        let f = FakeIO(Self.screen), (c, r) = controller(f)
        let gate = DispatchSemaphore(value: 0)
        f.lock.withLock { f.gate = gate }
        XCTAssertEqual(tick(c, row(true)), .working, "checking")
        tick(c, row(false, activity: 2))
        gate.signal()
        drain(c)
        XCTAssertEqual(f.statusCount, 1, "the send was asked")
        XCTAssertEqual(f.sent, [], "refused at the send")
        XCTAssertEqual(r.lastState, .blocked, "Needs input")
        XCTAssertFalse(c.heldByAutoAllow(key))
    }

    /// Way 2 (#791's re-read): a row left to the human after it left the front prints a different prompt: no check.
    @MainActor func testWay2AReReadOfARowNotInFrontStartsNoCheck() throws {
        let f = FakeIO(Self.screen), (c, r) = controller(f)
        let gate = DispatchSemaphore(value: 0)
        f.lock.withLock { f.gate = gate }
        tick(c, row(true))
        tick(c, row(false, activity: 2))
        gate.signal()
        drain(c)
        XCTAssertEqual(f.statusCount, 1, "the first check's send ask")
        f.lock.withLock { f.screen = Self.otherScreen }
        c.now = { Date(timeIntervalSince1970: 1_000_010) }   // past the poll floor: the print is read at once
        tick(c, row(false, activity: 3))
        drain(c)
        XCTAssertEqual(f.statusCount, 1, "the re-read started no check")
        XCTAssertEqual(f.sent, [])
        XCTAssertFalse(c.heldByAutoAllow(key))
        XCTAssertEqual(r.lastState, .blocked, "Needs input")
        XCTAssertEqual(c.store?.cards[key], .prompt(try XCTUnwrap(AgentPrompt.parse(Self.otherScreen))), "its card")
    }

    /// Way 3 (#755): a check orphaned by an off-toggle and taken back comes back refused: not run again.
    @MainActor func testWay3ATakenBackCheckOfARowNotInFrontIsNotRunAgain() {
        let f = FakeIO(Self.screen), (c, r) = controller(f)
        let on = OSAllocatedUnfairLock(initialState: true)
        c.autoAllowOn = { on.withLock { $0 } }
        let gate = DispatchSemaphore(value: 0)
        f.lock.withLock { f.gate = gate }
        tick(c, row(true))
        on.withLock { $0 = false }
        c.autoAllowChanged()
        on.withLock { $0 = true }
        c.autoAllowChanged()
        XCTAssertTrue(c.heldByAutoAllow(key), "held again")
        tick(c, row(false, activity: 2))
        gate.signal()
        drain(c)
        XCTAssertEqual(f.statusCount, 1, "the orphaned check's send ask only: no re-run")
        XCTAssertEqual(f.sent, [])
        XCTAssertFalse(c.heldByAutoAllow(key))
        XCTAssertEqual(r.lastState, .blocked, "Needs input")
    }

    /// Way 4 (the verify after Prosper's own Yes): it left the front before the verify fires: nothing holds it.
    @MainActor func testWay4TheVerifyOfARowNotInFrontHoldsNothing() {
        let f = FakeIO(Self.screen), (c, r) = controller(f)
        tick(c, row(true))
        drain(c)
        XCTAssertEqual(f.sent, ["1"])
        XCTAssertEqual(r.timers.count, 1, "the verify is armed")
        f.lock.withLock { f.screen = Self.otherScreen }
        tick(c, row(false, activity: 2))
        let t = r.timers
        r.timers = []
        for timer in t { timer() }
        XCTAssertFalse(c.heldByAutoAllow(key), "no check holds it")
        drain(c)
        XCTAssertEqual(f.statusCount, 1, "the first check's send ask only")
        XCTAssertEqual(f.sent, ["1"], "nothing more typed")
        XCTAssertEqual(r.lastState, .blocked, "Needs input")
    }

    /// Way 5 (#792's stand-down): dch answered; when the wait ends the row is not in front: nothing asked again.
    @MainActor func testWay5AStandDownRecheckOfARowNotInFrontHoldsNothing() {
        let f = FakeIO(Self.screen), (c, r) = controller(f)
        let calls = OSAllocatedUnfairLock(initialState: [[String]]())
        c.controlDch = { DchCommand.Binary(path: "/fake/dch", version: [1, 63, 0]) }
        c.runDch = { _, args, _ in
            calls.withLock { $0.append(args) }
            return Data((args == ["--build"] ? "full\n" : "/Users/example/.config/dch/config\nauto_allow = true\n").utf8)
        }
        XCTAssertEqual(tick(c, row(true)), .working)
        drain(c)
        XCTAssertEqual(calls.withLock { $0 }, [["--build"], ["--config"]], "left to dch's own auto-allow")
        XCTAssertEqual(r.timers.count, 1, "the stand-down wait is armed")
        let answered = DchAutoAllowed(at: 1_000_005, title: "Bash command")
        tick(c, row(false, activity: 2, allowed: answered))
        let t = r.timers
        r.timers = []
        for timer in t { timer() }
        XCTAssertFalse(c.heldByAutoAllow(key), "no check holds it")
        XCTAssertEqual(r.lastState, .blocked, "Needs input")
        drain(c)
        XCTAssertEqual(calls.withLock { $0 }, [["--build"], ["--config"]], "dch not asked again")
        XCTAssertEqual(f.statusCount, 0)
        XCTAssertEqual(f.sent, [])
    }

    // MARK: - A card click (the human's)

    /// #1291: the session as listed with a null transcript_path and a false foreground: a click types nothing.
    @MainActor func testACardClickOnAListedRowWithNoTranscriptAndNotInFrontTypesNothing() throws {
        let p = try XCTUnwrap(AgentPrompt.parse(Self.screen))
        for (fg, sent) in [("false", []), ("true", ["1"]), ("1", ["1"])] as [(String, [String])] {
            let f = FakeIO(Self.screen), (c, _) = controller(f, autoAllow: false)
            guard let s = AgentIsland.list(dirs: [Self.dir], run: { _, _ in Self.nullTranscriptRow(fg) }).first else {
                return XCTFail("no row")
            }
            c.store?.sessions = [s]
            c.answer(s, p, p.options[0])
            drain(c)
            XCTAssertEqual(f.sent, sent, "claude_foreground \(fg)")
            if fg == "false" { XCTAssertEqual(c.store?.actions[key], AgentIsland.notInFrontText) }
        }
    }

    /// The digit would go to the shell in front: nothing is typed and the row says why. Absent and true: sent.
    @MainActor func testACardClickOnARowNotInFrontTypesNothing() throws {
        let p = try XCTUnwrap(AgentPrompt.parse(Self.screen))
        for fg in [false, nil, true] as [Bool?] {
            let f = FakeIO(Self.screen), (c, _) = controller(f, autoAllow: false)
            let s = row(fg)
            c.store?.sessions = [s]
            c.answer(s, p, p.options[0])
            drain(c)
            let name = String(describing: fg)
            XCTAssertEqual(f.sent, fg == false ? [] : ["1"], name)
            if fg == false {
                XCTAssertEqual(c.store?.actions[key], AgentIsland.notInFrontText, name)
                XCTAssertFalse(c.heldByAutoAllow(key), "\(name): nothing in flight")
            }
        }
    }

    // MARK: - dch's not_foreground

    /// --stop and the island's Message (--say) failing not_foreground: one plain line, not dch's wrapper hint.
    func testNotForegroundFromStopAndMessageHasItsOwnWords() {
        let detail = "api: claude is not in front: fg it if suspended with Ctrl-Z"
        for verb in [AgentIsland.Verb.stop, .message] {
            XCTAssertEqual(AgentIsland.finalText(DchJSONLine(name: "api", result: "failed", reason: "not_foreground", detail: detail), verb),
                           AgentIsland.notInFrontText, verb.rawValue)
        }
        XCTAssertEqual(AgentIsland.notInFrontText, "Claude is not in front in that session; nothing was typed")
    }
}
