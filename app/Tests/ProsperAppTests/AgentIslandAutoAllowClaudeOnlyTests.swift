import os
import XCTest
@testable import ProsperApp

/// #935: Always allow types its "Yes" only into a session dch names a live Claude Code in (the
/// `claude_session_id` of its `--ls-json` row, the Agents window's transcript mapping). Any other
/// session keeps its card and its Needs input, as with the setting off. Every dch call is a fake
/// recorder: no test reads a real screen, sends a real key or runs dch.
final class AgentIslandAutoAllowClaudeOnlyTests: XCTestCase {

    private static func dialog(_ body: String) -> String {
        [String(repeating: "─", count: 90), " Bash command", "", "   \(body)", "   Clean the build tree", "",
         " Do you want to proceed?", " ❯ 1. Yes", "   2. No, and tell Claude what to do differently (esc)"]
            .joined(separator: "\n")
    }
    private static let screen = dialog("rm -rf .build")
    private static let otherScreen = dialog("swift build")
    private static let sid = "0b7c2f3e-aaaa-bbbb-cccc-0123456789ab"
    private static let dir = "/Users/example/.local/state/dch"
    private let key = AgentSessionKey(dir: AgentIslandAutoAllowClaudeOnlyTests.dir, name: "api")

    /// The keystroke recorder: screens read, keys "sent" (recorded only).
    private final class FakeIO: @unchecked Sendable {
        let lock = NSLock()
        var screen: String
        var reads = 0, sends: [String] = []
        /// The next read waits on this once (a check still on the queue); bounded, so a slip never hangs.
        var gate: DispatchSemaphore?
        init(_ screen: String) { self.screen = screen }
        var io: AgentPromptIO {
            AgentPromptIO(read: { _ in
                _ = self.lock.withLock { () -> DispatchSemaphore? in defer { self.gate = nil }; return self.gate }?
                    .wait(timeout: .now() + 10)
                return self.lock.withLock { self.reads += 1; return self.screen }
            }, status: { _ in "blocked" }, send: { _, d in self.lock.withLock { self.sends.append(d) } })
        }
        var sent: [String] { lock.withLock { sends } }
        var readCount: Int { lock.withLock { reads } }
    }

    @MainActor private final class Rec {
        var lists: [[AgentSession]?] = []
        var timers: [@MainActor @Sendable () -> Void] = []
        var lastState: AgentState? { lists.last??.first { $0.name == "api" }?.state }
    }

    @MainActor private func controller(_ f: FakeIO) -> (AgentIslandController, Rec) {
        let c = AgentIslandController(), r = Rec()
        c.io = f.io
        c.showsPanel = false
        c.store = AgentIslandStore(geometry: AgentWindowD1Tests.geometry)
        c.store?.expanded = true
        c.autoAllowOn = { true }
        c.controlDch = { nil }   // no dch of its own answers: Prosper decides
        c.now = { Date(timeIntervalSince1970: 1_000_000) }
        c.after = { _, fire in r.timers.append(fire) }
        c.onSessions = { r.lists.append($0) }
        return (c, r)
    }

    /// `claude`: the row's claude_session_id. `version` "": a master too old to say anything (no agent information).
    private func row(_ claude: String?, version: String = "1.60.0", activity: TimeInterval = 1) -> AgentSession {
        AgentSession(key: key, alias: "", activity: activity, state: .blocked, agents: 0, version: version,
                     claudeSessionID: claude, transcriptPath: claude.map { "/Users/example/.claude/projects/p/\($0).jsonl" })
    }

    /// One list change, as apply runs it (the check, then the cards); what goes to the phone.
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

    @MainActor private func fire(_ c: AgentIslandController, _ r: Rec) {
        let t = r.timers
        r.timers = []
        for f in t { f() }
        drain(c)
    }

    /// Not answered, never held: Needs input at once and the prompt's card, as with the setting off.
    @MainActor private func assertLeftToTheHuman(_ c: AgentIslandController, _ f: FakeIO, _ published: AgentState?,
                                                 _ name: String, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(published, .blocked, "\(name): Needs input goes out at once", file: file, line: line)
        XCTAssertFalse(c.heldByAutoAllow(key), "\(name): no hold", file: file, line: line)
        drain(c)
        XCTAssertEqual(f.sent, [], "\(name): no key", file: file, line: line)
        XCTAssertEqual(f.readCount, 1, "\(name): only the card's read, no check", file: file, line: line)
        XCTAssertEqual(c.store?.cards[key], .prompt(try XCTUnwrap(AgentPrompt.parse(Self.screen))),
                       "\(name): its card", file: file, line: line)
        XCTAssertTrue(c.store?.actions[key] == nil, "\(name): not \"Allowed automatically\"", file: file, line: line)
    }

    @MainActor func testAClaudeSessionWithThePromptIsAnswered() {
        let f = FakeIO(Self.screen), (c, _) = controller(f)
        XCTAssertEqual(tick(c, row(Self.sid)), .working, "held while it is checked")
        drain(c)
        XCTAssertEqual(f.sent, ["1"])
        XCTAssertEqual(c.store?.actions[key], AgentIslandController.autoAllowedText)
        XCTAssertTrue(c.store?.cards[key] == nil, "answered: no card")
    }

    @MainActor func testANonClaudeSessionWithTheSameScreenIsNotAnsweredAndKeepsItsCard() throws {
        // dch new enough to name a Claude Code names none: a script, another agent, a file being printed.
        for (name, id) in [("no Claude named", nil), ("an empty id", "")] as [(String, String?)] {
            let f = FakeIO(Self.screen), (c, r) = controller(f)
            try assertLeftToTheHuman(c, f, tick(c, row(id)), name)
            XCTAssertTrue(r.timers.isEmpty, name)
        }
    }

    @MainActor func testASessionWithNoAgentInformationIsNotAnswered() throws {
        // A master too old to say (no version, no claude_session_id): unknown is not Claude Code.
        let f = FakeIO(Self.screen), (c, _) = controller(f)
        try assertLeftToTheHuman(c, f, tick(c, row(nil, version: "")), "no agent information")
        // The same through the list parser: an `-lj` row (dch before --ls-json) and an --ls-json row without the key.
        let lj = AgentIsland.list(dirs: [Self.dir]) { args, _ in
            args == ["-lj"] ? Data("api\t\t1\n".utf8) : Data()
        }
        let noKey = AgentIsland.list(dirs: [Self.dir]) { _, _ in
            Data(#"[{"name":"api","alias":"","activity_epoch":1,"state":"blocked","version":"1.29.2","agents":0}]"#.utf8)
        }
        XCTAssertEqual(lj.count, 1)
        XCTAssertEqual(noKey.count, 1)
        XCTAssertTrue(lj.first?.claudeSessionID == nil && noKey.first?.claudeSessionID == nil)
        for (name, s) in [("-lj row", lj.first),("--ls-json without the key", noKey.first)] {
            guard var s else { return XCTFail(name) }
            s = AgentSession(key: s.key, alias: s.alias, activity: s.activity, state: .blocked, agents: s.agents,
                             version: s.version, claudeSessionID: s.claudeSessionID)
            let g = FakeIO(Self.screen), (d, _) = controller(g)
            try assertLeftToTheHuman(d, g, tick(d, s), name)
        }
    }

    /// The signal is dch's --ls-json `claude_session_id` (with its transcript_path), as the window maps it.
    @MainActor func testTheSignalIsDchsClaudeSessionID() {
        let json = #"[{"name":"api","alias":"","activity_epoch":1,"state":"blocked","version":"1.60.0","agents":0,"#
            + #""claude_session_id":"\#(Self.sid)","transcript_path":"/Users/example/.claude/projects/p/\#(Self.sid).jsonl"}]"#
        let rows = AgentIsland.list(dirs: [Self.dir]) { args, _ in args == ["--ls-json"] ? Data(json.utf8) : nil }
        XCTAssertEqual(rows.first?.claudeSessionID, Self.sid)
        guard let s = rows.first else { return XCTFail("one row") }
        let f = FakeIO(Self.screen), (c, _) = controller(f)
        XCTAssertEqual(tick(c, s), .working)
        drain(c)
        XCTAssertEqual(f.sent, ["1"])
    }

    /// The Claude Code exited (to the shell) while the check was on the queue: the newest list,
    /// read right before the send, decides.
    @MainActor func testASessionThatLostTheSignalBeforeTheSendIsNotAnswered() throws {
        let f = FakeIO(Self.screen), (c, r) = controller(f)
        let gate = DispatchSemaphore(value: 0)
        f.lock.withLock { f.gate = gate }
        XCTAssertEqual(tick(c, row(Self.sid)), .working, "checking")
        tick(c, row(nil, activity: 2))   // the newer list: no Claude Code named any more
        gate.signal()
        drain(c)
        XCTAssertEqual(f.sent, [], "refused at the send")
        XCTAssertEqual(r.lastState, .blocked, "Needs input")
        XCTAssertFalse(c.heldByAutoAllow(key))
        XCTAssertEqual(c.store?.cards[key], .prompt(try XCTUnwrap(AgentPrompt.parse(Self.screen))), "its card")
    }

    /// Answered while Claude, then the signal went before the verify re-read found a new prompt:
    /// nothing more is typed. With the signal kept, the same sequence answers it (the control).
    @MainActor func testASessionThatLostTheSignalBeforeTheVerifyIsNotAnsweredAgain() {
        for keep in [true, false] {
            let f = FakeIO(Self.screen), (c, r) = controller(f)
            tick(c, row(Self.sid))
            drain(c)
            XCTAssertEqual(f.sent, ["1"], "keep \(keep)")
            XCTAssertEqual(r.timers.count, 1, "keep \(keep): the verify re-read is armed")
            f.lock.withLock { f.screen = Self.otherScreen }
            tick(c, row(keep ? Self.sid : nil, activity: 2))
            fire(c, r)
            XCTAssertEqual(f.sent, keep ? ["1", "1"] : ["1"], "keep \(keep)")
            if !keep { XCTAssertEqual(r.lastState, .blocked, "Needs input") }
        }
    }

    /// A shell that starts Claude Code: once dch names it, the prompt on screen gets its check.
    @MainActor func testASessionThatGainsTheSignalIsCheckedThen() {
        let f = FakeIO(Self.screen), (c, _) = controller(f)
        XCTAssertEqual(tick(c, row(nil)), .blocked)
        drain(c)
        XCTAssertEqual(f.sent, [])
        XCTAssertEqual(tick(c, row(Self.sid, activity: 2)), .working)
        drain(c)
        XCTAssertEqual(f.sent, ["1"])
    }
}
