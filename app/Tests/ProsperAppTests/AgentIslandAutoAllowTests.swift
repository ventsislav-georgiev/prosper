import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #751: Always allow permission prompts. Every dch call is a fake; no test
/// reads a real screen, sends a key or posts to the Worker.
final class AgentIslandAutoAllowTests: XCTestCase {

    // MARK: - Fixtures

    /// A Claude Code dialog in the #475 probe layout: top rule, title, body, question, options.
    private static func dialog(_ question: String, _ options: [String], title: String = "Bash command",
                               body: [String] = ["   rm -rf .build", "   Clean the build tree"]) -> String {
        var lines = [String(repeating: "─", count: 90), " \(title)", ""] + body + ["", " \(question)"]
        for (i, o) in options.enumerated() { lines.append((i == 0 ? " ❯ " : "   ") + "\(i + 1). \(o)") }
        return lines.joined(separator: "\n")
    }

    private static let proceed = "Do you want to proceed?"
    private static let noTell = "No, and tell Claude what to do differently (esc)"
    private static let dontAsk = "Yes, and don't ask again for rm commands in /Users/probe/proj"
    /// Claude Code's Bash permission with its "don't ask again" row.
    private static let bash3 = dialog(proceed, ["Yes", dontAsk, noTell])
    private static let bash2 = dialog(proceed, ["Yes", noTell])
    private static let otherBash = dialog(proceed, ["Yes", noTell], body: ["   swift build", "   Build the package"])

    /// Plain permission prompts the setting never answers, each failing one rule.
    private static let neverAnswered: [(String, String)] = [
        ("plan approval", dialog("Would you like to proceed?",
                                 ["Yes, and use auto mode", "Yes, manually approve edits", "No, keep planning"],
                                 title: "Ready to code?", body: [" Here is Claude's plan:", "   Add the parser."])),
        ("trust folder", dialog("Quick safety check: Is this a project you created or one you trust?",
                                ["Yes, I trust this folder", "No, exit"], title: "Accessing workspace:",
                                body: [" /Users/probe/proj"])),
        ("other question, Yes/No", dialog("Do you trust the files in this folder?", ["Yes", "No"])),
        ("edit dialog", dialog("Do you want to make this edit to AgentIslandModel.swift?",
                               ["Yes", "Yes, allow all edits during this session (shift+tab)", noTell], title: "Edit file",
                               body: ["  42 -        let dirs = dirs()", "  42 +        let dirs = self.dirs()"])),
        ("model picker", dialog("Switch between Claude models.", ["Default (recommended)", "Opus", "Sonnet"],
                                title: "Select model", body: [])),
        ("first is not plain Yes", dialog(proceed, ["Yes, proceed", "No, exit"])),
        ("last is not No", dialog(proceed, ["Yes", "Always"])),
        ("mode change middle row", dialog(proceed, ["Yes", "Yes, allow all edits during this session (shift+tab)", noTell])),
        ("always allow dir middle row", dialog(proceed, ["Yes", "Yes, and always allow access to /tmp/x", noTell])),
        ("four options", dialog(proceed, ["Yes", dontAsk, "Yes, and don't ask again for git commands", noTell])),
        // QA #581: the don't-ask-again row's mode-change rule, and the hint and wrap rules on Yes and No.
        ("don't ask again with the mode key", dialog(proceed, ["Yes", "Yes, and don't ask again for rm commands (shift+tab)", noTell])),
        ("Yes with a key hint", dialog(proceed, ["Yes (tab)", noTell])),
        ("Yes with a wrapped line", dialog(proceed, ["Yes", noTell]).replacingOccurrences(
            of: " ❯ 1. Yes\n", with: " ❯ 1. Yes\n      and run every queued command\n")),
        ("No with a wrapped line", dialog(proceed, ["Yes", "No, and tell Claude what to do"])
            + "\n      differently\n\n Esc to cancel · Tab to amend"),
        ("AskUserQuestion Yes/No", """
        ──────────────────────────────────────────────────────────────────────────────────────────
         ☐ Proceed

        Do you want to proceed?

        ❯ 1. Yes
          2. No
        """),
        ("AskUserQuestion form", """
        ──────────────────────────────────────────────────────────────────────────────────────────
         ☐ Proceed

        Do you want to proceed?

        ❯ 1. Yes
             Go ahead with the deploy
          2. No
             Stop here
          3. Type something.
        ──────────────────────────────────────────────────────────────────────────────────────────
          4. Chat about this

        Enter to select · ↑/↓ to navigate · Esc to cancel
        """),
    ]

    /// Blocked screens with no parsable prompt: free text, the idle box, codex.
    private static let unparsed: [(String, String)] = [
        ("idle input box", """
        ⏺ Which file should I open?

        ──────────────────────────────────────────────────────────────────────────────────────────
        ❯
        ──────────────────────────────────────────────────────────────────────────────────────────
          ? for shortcuts
        """),
        ("codex", """
        • Running cargo test -p core

          Allow command?

          $ cargo test -p core
        """),
    ]

    /// Hidden characters in the command: the card refuses "Yes", Always allow does not.
    private static let hidden = dialog(proceed, ["Yes", noTell], body: ["   echo safe \u{202E}txt.exe"])

    /// The operator's case: a long `gh pr create` heredoc on a narrow pty, the
    /// dialog's top rule and title scrolled off; the screen starts mid-heredoc.
    private static let offTop = (["     body line 3 of the PR description"]
        + (4...24).map { "     body line \($0) of the PR description" }
        + ["     EOF", "     )\"", "   Create the pull request", "",
           " Do you want to proceed?", " ❯ 1. Yes",
           "   2. Yes, and don't ask again for gh pr create commands in /Users/probe/proj",
           "   3. \(noTell)"]).joined(separator: "\n")

    // MARK: - Fake dch

    /// Screens are read in order, the last one repeating; status and sends are recorded.
    private final class FakeIO: @unchecked Sendable {
        let lock = NSLock()
        var screens: [String]
        var status = "blocked"
        var reads = 0, sends: [String] = []
        init(_ screens: String...) { self.screens = screens }
        func set(_ screen: String, status: String = "blocked") {
            lock.withLock { screens = [screen]; self.status = status }
        }
        var io: AgentPromptIO {
            AgentPromptIO(read: { _ in
                self.lock.withLock {
                    self.reads += 1
                    return self.screens.count > 1 ? self.screens.removeFirst() : self.screens[0]
                }
            }, status: { _ in self.lock.withLock { self.status } },
            send: { _, d in self.lock.withLock { self.sends.append(d) } })
        }
    }

    private let key = AgentSessionKey(dir: "/d", name: "s")

    // MARK: - The prompt rule

    func testAllowYesOnlyOnAPlainPermissionPrompt() throws {
        for screen in [Self.bash3, Self.bash2] {
            let yes = try XCTUnwrap(XCTUnwrap(AgentPrompt.parse(screen)).allowYes)
            XCTAssertEqual(yes.digit, 1)
            XCTAssertEqual(yes.label, "Yes")
        }
        for (name, screen) in Self.neverAnswered {
            let p = try XCTUnwrap(AgentPrompt.parse(screen), "\(name) parses, so the rule is what refuses it")
            XCTAssertNil(p.allowYes, name)
        }
        for (name, screen) in Self.unparsed { XCTAssertNil(AgentPrompt.parse(screen), name) }
    }

    func testPicksYesNeverDontAskAgain() throws {
        let f = FakeIO(Self.bash3)
        let r = AgentPrompt.autoAllow(key, io: f.io, notAgain: nil, answered: false)
        XCTAssertEqual(r, .allowed(try XCTUnwrap(AgentPrompt.parse(Self.bash3))))
        XCTAssertEqual(f.sends, ["1"], "the plain Yes, never the don't-ask-again row (2)")
        XCTAssertEqual(f.reads, 2, "the answer re-reads (#475 full-identity check)")
    }

    /// What only guards a human's view (the card's rule) never stops Always allow:
    /// a head off the screen, a context over the 10-row cap, hidden characters.
    /// The card itself still refuses them.
    func testOffScreenLongAndHiddenPromptsAreAllowedButTheCardStillRefuses() throws {
        for (name, screen) in [("top off the screen", Self.offTop), ("hidden characters", Self.hidden)] {
            let p = try XCTUnwrap(AgentPrompt.parse(screen), name)
            XCTAssertEqual(p.allowYes?.digit, 1, name)
            let f = FakeIO(screen)
            XCTAssertEqual(AgentPrompt.autoAllow(key, io: f.io, notAgain: nil, answered: false), .allowed(p), name)
            XCTAssertEqual(f.sends, ["1"], name)
            let card = FakeIO(screen)
            XCTAssertEqual(AgentPrompt.answer(key, digit: 1, expected: p, io: card.io), .changed, "\(name): the card's Yes")
            XCTAssertEqual(card.sends, [], name)
        }
        XCTAssertFalse(try XCTUnwrap(AgentPrompt.parse(Self.offTop)).topFound, "the fixture's head is off the screen")
    }

    func testEveryOtherPromptIsLeftAlone() {
        for (name, screen) in Self.neverAnswered + Self.unparsed {
            let f = FakeIO(screen)
            XCTAssertEqual(AgentPrompt.autoAllow(key, io: f.io, notAgain: nil, answered: false), .human, name)
            XCTAssertEqual(f.sends, [], name)
        }
    }

    func testTheSamePromptIsNeverAnsweredTwice() throws {
        let p = try XCTUnwrap(AgentPrompt.parse(Self.bash3))
        let f = FakeIO(Self.bash3)
        XCTAssertEqual(AgentPrompt.autoAllow(key, io: f.io, notAgain: p, answered: true), .human)
        XCTAssertEqual(f.sends, [])
        let other = try XCTUnwrap(AgentPrompt.parse(Self.otherBash))
        XCTAssertEqual(AgentPrompt.autoAllow(key, io: f.io, notAgain: other, answered: true), .allowed(p))
        XCTAssertEqual(f.sends, ["1"])
    }

    func testAChangedScreenBetweenReadsSendsNothing() {
        let f = FakeIO(Self.bash3, Self.otherBash)
        XCTAssertEqual(AgentPrompt.autoAllow(key, io: f.io, notAgain: nil, answered: false), .human)
        XCTAssertEqual(f.sends, [])
    }

    /// QA #581 F1: a timed-out (empty) or unknown status is not "the answer took".
    func testAnEmptyOrUnknownStatusAfterAnAnswerIsTheHumans() {
        for status in ["", "\n", "garbage"] {
            let f = FakeIO("")
            f.status = status
            XCTAssertEqual(AgentPrompt.autoAllow(key, io: f.io, notAgain: nil, answered: true), .human, "status \(status.debugDescription)")
        }
        for status in ["working", "idle\n", "done"] {
            let f = FakeIO("")
            f.status = status
            XCTAssertEqual(AgentPrompt.autoAllow(key, io: f.io, notAgain: nil, answered: true), .gone, status)
        }
    }

    func testNoPromptIsGoneOnlyAfterAnAnswerAndOnlyWhenDchAgrees() {
        let idle = Self.unparsed[0].1
        let f = FakeIO(idle)
        f.status = "working"
        XCTAssertEqual(AgentPrompt.autoAllow(key, io: f.io, notAgain: nil, answered: true), .gone)
        XCTAssertEqual(AgentPrompt.autoAllow(key, io: f.io, notAgain: nil, answered: false), .human)
        f.status = "blocked\n"
        XCTAssertEqual(AgentPrompt.autoAllow(key, io: f.io, notAgain: nil, answered: true), .human)
        XCTAssertEqual(f.sends, [])
    }

    // MARK: - Setting

    func testTheSettingIsOffByDefault() {
        let k = "agentIslandAutoAllow", saved = Preferences.defaults.object(forKey: k)
        defer { Preferences.defaults.set(saved, forKey: k) }
        Preferences.defaults.removeObject(forKey: k)
        XCTAssertFalse(Preferences.agentIslandAutoAllow)
        Preferences.agentIslandAutoAllow = true
        XCTAssertTrue(Preferences.defaults.bool(forKey: k), "stored under agentIslandAutoAllow")
        Preferences.agentIslandAutoAllow = false
        XCTAssertFalse(Preferences.agentIslandAutoAllow)
    }

    // MARK: - Controller

    private static let geometry = AgentIslandGeometry.make(
        frame: CGRect(x: 0, y: 0, width: 1512, height: 982), visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 950),
        topLeft: CGRect(x: 0, y: 950, width: 663.5, height: 32), topRight: CGRect(x: 848.5, y: 950, width: 663.5, height: 32),
        safeTop: 32)

    /// What the controller published (onSessions), its re-read timers and its clock.
    @MainActor private final class Rec {
        var lists: [[AgentSession]?] = []
        var timers: [@MainActor @Sendable () -> Void] = []
        var now = Date(timeIntervalSince1970: 1_000_000)
        /// The state "s" last went out with.
        var lastState: AgentState? { lists.last??.first { $0.name == "s" }?.state }
        var everBlocked: Bool { lists.contains { $0?.contains { $0.name == "s" && $0.state == .blocked } == true } }
    }

    @MainActor private func controller(_ f: FakeIO, on: Bool? = true) -> (AgentIslandController, Rec) {
        let c = AgentIslandController(), r = Rec()
        c.io = f.io
        c.showsPanel = false
        c.store = AgentIslandStore(geometry: Self.geometry)
        if let on { c.autoAllowOn = { on } }
        c.now = { r.now }
        c.after = { _, fire in r.timers.append(fire) }
        c.onSessions = { r.lists.append($0) }
        return (c, r)
    }

    private func session(_ state: AgentState) -> AgentSession {
        AgentSession(key: key, alias: "", activity: 1, state: state, agents: 0)
    }

    /// One poll that changed the list, as apply runs it; returns what apply publishes.
    @MainActor @discardableResult
    private func tick(_ c: AgentIslandController, _ state: AgentState) -> AgentState? {
        c.store?.sessions = [session(state)]
        c.checkAutoAllow()
        return c.published(c.store?.sessions ?? []).first?.state
    }

    /// Runs the queued dch work, then the main hops it posted.
    @MainActor private func drain(_ c: AgentIslandController) {
        c.queue.sync {}
        let hopped = expectation(description: "main hops")
        DispatchQueue.main.async { hopped.fulfill() }
        wait(for: [hopped], timeout: 5)
    }

    /// Fires the re-read timers armed so far, then drains.
    @MainActor private func fire(_ c: AgentIslandController, _ r: Rec) {
        let t = r.timers
        r.timers = []
        for f in t { f() }
        drain(c)
    }

    @MainActor func testOffByDefaultAndOffReadsAndHoldsNothing() {
        let k = "agentIslandAutoAllow", saved = Preferences.defaults.object(forKey: k)
        defer { Preferences.defaults.set(saved, forKey: k) }
        Preferences.defaults.removeObject(forKey: k)
        let f = FakeIO(Self.bash3), (c, r) = controller(f, on: nil)   // the real setting seam
        XCTAssertEqual(tick(c, .blocked), .blocked, "published as is")
        drain(c)
        XCTAssertEqual(f.reads, 0, "nothing read")
        XCTAssertEqual(f.sends, [])
        XCTAssertTrue(r.timers.isEmpty)
        XCTAssertNil(c.store?.actions[key])
    }

    @MainActor func testAnsweredPromptNeverGoesOutBlocked() {
        let f = FakeIO(Self.bash3), (c, r) = controller(f)
        XCTAssertEqual(tick(c, .blocked), .working, "held while it is checked")
        drain(c)
        XCTAssertEqual(f.sends, ["1"])
        XCTAssertEqual(c.published(c.store?.sessions ?? []).first?.state, .working, "held after the answer")
        XCTAssertFalse(r.everBlocked, "no Needs input published")
        XCTAssertEqual(c.store?.actions[key], AgentIslandController.autoAllowedText)
        XCTAssertEqual(r.timers.count, 1, "a re-read is armed")
        XCTAssertEqual(tick(c, .working), .working)
        XCTAssertEqual(tick(c, .blocked), .working, "a new blocked stretch is checked again")
    }

    @MainActor func testEveryOtherPromptGoesOutAsNeedsInputAtOnce() {
        for (name, screen) in Self.neverAnswered + Self.unparsed {
            let f = FakeIO(screen), (c, r) = controller(f)
            tick(c, .blocked)
            drain(c)
            XCTAssertEqual(f.sends, [], name)
            XCTAssertEqual(r.lastState, .blocked, "\(name): published by the decision")
            XCTAssertEqual(c.published(c.store?.sessions ?? []).first?.state, .blocked, name)
            XCTAssertNil(c.store?.actions[key], name)
            XCTAssertTrue(r.timers.isEmpty, name)
            tick(c, .blocked)
            drain(c)
            XCTAssertEqual(f.reads, 1, "\(name): left to the human, not read again")
        }
    }

    @MainActor func testAnOffScreenPromptNeverGoesOutBlocked() {
        let f = FakeIO(Self.offTop), (c, r) = controller(f)
        XCTAssertEqual(tick(c, .blocked), .working)
        drain(c)
        XCTAssertEqual(f.sends, ["1"])
        XCTAssertFalse(r.everBlocked)
        XCTAssertEqual(c.store?.actions[key], AgentIslandController.autoAllowedText)
    }

    @MainActor func testAFailedAnswerFallsBackToNeedsInput() {
        let f = FakeIO(Self.bash3, Self.otherBash), (c, r) = controller(f)   // the screen changes under the answer
        tick(c, .blocked)
        drain(c)
        XCTAssertEqual(f.sends, [])
        XCTAssertEqual(r.lastState, .blocked)
        XCTAssertNil(c.store?.actions[key])
    }

    @MainActor func testThePromptStillUpAfterTheAnswerFallsBack() {
        let f = FakeIO(Self.bash3), (c, r) = controller(f)
        tick(c, .blocked)
        drain(c)
        XCTAssertFalse(r.everBlocked)
        fire(c, r)   // still listed blocked, same prompt on screen
        XCTAssertEqual(f.sends, ["1"], "answered once only")
        XCTAssertEqual(r.lastState, .blocked, "the normal Needs input")
        XCTAssertTrue(r.timers.isEmpty)
    }

    @MainActor func testTheAnswerTakingStaysQuiet() {
        let f = FakeIO(Self.bash3), (c, r) = controller(f)
        tick(c, .blocked)
        drain(c)
        f.set(Self.unparsed[0].1, status: "working")   // the list is stale, dch is not
        fire(c, r)
        XCTAssertFalse(r.everBlocked)
        XCTAssertEqual(c.published(c.store?.sessions ?? []).first?.state, .working)
        XCTAssertEqual(r.timers.count, 1, "read again while still listed blocked")
        f.set(Self.otherBash)   // a new permission prompt in the same blocked stretch
        fire(c, r)
        XCTAssertEqual(f.sends, ["1", "1"])
        XCTAssertFalse(r.everBlocked)
        f.set(Self.neverAnswered[0].1)   // then a plan approval: the human's
        fire(c, r)
        XCTAssertEqual(f.sends, ["1", "1"])
        XCTAssertEqual(r.lastState, .blocked)
    }

    @MainActor func testTheSamePromptBackRightAfterIsLeftToTheHuman() {
        let f = FakeIO(Self.bash3), (c, r) = controller(f)
        tick(c, .blocked)
        drain(c)
        tick(c, .working)
        r.now += AgentIslandController.loopWindow - 1
        tick(c, .blocked)
        drain(c)
        XCTAssertEqual(f.sends, ["1"], "back right after: not again")
        XCTAssertEqual(r.lastState, .blocked)
        tick(c, .working)
        r.now += 2   // past the window since the answer
        XCTAssertEqual(tick(c, .blocked), .working)
        drain(c)
        XCTAssertEqual(f.sends, ["1", "1"], "a later appearance is answered again")
    }

    // MARK: - QA #581 fixes

    /// F1: dch wedged after the answer (read and status time out to ""): Needs input goes out.
    @MainActor func testAWedgedDchAfterTheAnswerPublishesNeedsInput() {
        let f = FakeIO(Self.bash3), (c, r) = controller(f)
        tick(c, .blocked)
        drain(c)
        f.set("", status: "")
        fire(c, r)
        XCTAssertEqual(r.lastState, .blocked)
        XCTAssertTrue(r.timers.isEmpty, "no further re-read")
    }

    /// F2: expanded, a prompt left to the human gets its card (the check held the
    /// key while apply's refreshCards ran); so does the screen after a .gone.
    @MainActor func testACardIsReadForAPromptLeftToTheHuman() throws {
        let plan = Self.neverAnswered[0].1
        let f = FakeIO(plan), (c, r) = controller(f)
        c.store?.expanded = true
        tick(c, .blocked)
        c.refreshCards()   // apply's order: the check first, then the cards
        drain(c)
        drain(c)
        XCTAssertEqual(c.store?.cards[key], .prompt(try XCTUnwrap(AgentPrompt.parse(plan))))
        let g = FakeIO(Self.bash3), (d, s) = controller(g)
        d.store?.expanded = true
        tick(d, .blocked)
        d.refreshCards()
        drain(d)
        XCTAssertNil(d.store?.cards[key], "answered: no card")
        g.set(Self.unparsed[0].1, status: "working")
        fire(d, s)
        drain(d)
        XCTAssertEqual(d.store?.cards[key], .context(AgentPrompt.tail(Self.unparsed[0].1)), "gone: the screen's card")
        _ = r
    }

    /// F3: switched off between the answer and the re-read: nothing more is typed.
    @MainActor func testSwitchedOffBeforeTheRereadTypesNothing() {
        let f = FakeIO(Self.bash3), (c, r) = controller(f)
        tick(c, .blocked)
        drain(c)
        f.set(Self.otherBash)   // a new plain prompt the re-read would answer
        c.autoAllowOn = { false }   // the seam only: no Settings hook ran
        fire(c, r)
        XCTAssertEqual(f.sends, ["1"])
        XCTAssertEqual(r.lastState, .blocked, "the hold is dropped and published")
    }

    /// F3: the Settings toggle drops every hold at once.
    @MainActor func testTurningTheSettingOffPublishesAtOnce() {
        let f = FakeIO(Self.bash3), (c, r) = controller(f)
        tick(c, .blocked)
        drain(c)
        XCTAssertFalse(r.everBlocked)
        c.autoAllowOn = { false }
        c.autoAllowChanged()
        XCTAssertEqual(r.lastState, .blocked)
        let reads = f.reads
        fire(c, r)
        XCTAssertEqual(f.reads, reads, "the armed re-read is a no-op")
        XCTAssertEqual(f.sends, ["1"])
    }

    /// The next list change with the setting off publishes as is (the clear in checkAutoAllow).
    @MainActor func testAListChangeWithTheSettingOffDropsTheHold() {
        let f = FakeIO(Self.bash3), (c, _) = controller(f)
        tick(c, .blocked)
        drain(c)
        c.autoAllowOn = { false }
        XCTAssertEqual(tick(c, .blocked), .blocked)
    }

    /// Teardown drops every hold.
    @MainActor func testTeardownDropsTheHold() {
        let f = FakeIO(Self.bash3), (c, _) = controller(f)
        tick(c, .blocked)
        drain(c)
        XCTAssertEqual(c.published([session(.blocked)]).first?.state, .working)
        c.extLive = false
        c.reload()   // extLive off: teardown
        XCTAssertEqual(c.published([session(.blocked)]).first?.state, .blocked)
    }

    /// INFO-3: a re-read timer from an earlier answer is a no-op.
    @MainActor func testAStaleRereadTimerIsANoOp() {
        let f = FakeIO(Self.bash3), (c, r) = controller(f)
        tick(c, .blocked)
        drain(c)
        let stale = r.timers
        r.timers = []
        tick(c, .working)
        r.now += AgentIslandController.loopWindow + 1
        f.set(Self.otherBash)
        tick(c, .blocked)
        drain(c)
        XCTAssertEqual(f.sends, ["1", "1"])
        let reads = f.reads
        for t in stale { t() }
        drain(c)
        XCTAssertEqual(f.reads, reads, "the old timer starts no re-read")
        XCTAssertEqual(r.timers.count, 1, "only the live one is armed")
    }

    /// A re-read colliding with an island click publishes Needs input.
    @MainActor func testARereadCollidingWithAClickPublishesNeedsInput() throws {
        let f = FakeIO(Self.bash3), (c, r) = controller(f)
        tick(c, .blocked)
        drain(c)
        let p = try XCTUnwrap(AgentPrompt.parse(Self.bash3))
        c.answer(session(.blocked), p, p.options[0])   // in flight
        let t = r.timers
        r.timers = []
        for x in t { x() }
        XCTAssertEqual(r.lastState, .blocked)
        drain(c)
    }

    @MainActor func testAnIslandClickInFlightLeavesItToTheHuman() throws {
        let f = FakeIO(Self.bash3), (c, _) = controller(f)
        c.store?.sessions = [session(.blocked)]
        c.store?.expanded = true
        let p = try XCTUnwrap(AgentPrompt.parse(Self.bash3))
        c.answer(session(.blocked), p, p.options[0])
        XCTAssertEqual(tick(c, .blocked), .blocked)
        drain(c)
        XCTAssertEqual(f.sends, ["1"], "the click's answer only")
    }

    /// The real poll path: reload's timer -> apply -> onSessions, with a fake poller.
    @MainActor func testThePollPublishesTheHeldStateNotBlocked() throws {
        let dir = tempDir()
        FileManager.default.createFile(atPath: dir.appendingPathComponent("s.sock").path, contents: nil)
        let f = FakeIO(Self.bash3), (c, r) = controller(f)
        let path = dir.path
        c.store = nil
        c.center = NotificationCenter()
        c.currentGeometry = { Self.geometry }
        c.makePoller = {
            AgentIslandPoller(dirs: { [path] }, list: { _, _ in
                [AgentSession(key: AgentSessionKey(dir: path, name: "s"), alias: "", activity: 1, state: .blocked, agents: 0)]
            })
        }
        addTeardownBlock { @MainActor in c.extLive = false; c.reload() }
        c.extLive = true
        c.reload()
        let deadline = Date().addingTimeInterval(5)
        while r.lists.isEmpty, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertEqual(r.lastState, .working, "the first publish already holds it")
        drain(c)
        XCTAssertEqual(f.sends, ["1"])
        XCTAssertFalse(r.everBlocked)
    }

    // MARK: - Offscreen renders (never on screen: an unwindowed hosting view and ImageRenderer)

    @MainActor func testRenderTheSettingAndTheRowText() throws {
        let out = tempDir()
        let extra = ProcessInfo.processInfo.environment["PROSPER_RENDER_DIR"].map { URL(fileURLWithPath: $0) }
        func write(_ png: Data, _ name: String) throws {
            try png.write(to: out.appendingPathComponent("\(name).png"))
            if let extra { try png.write(to: extra.appendingPathComponent("\(name).png")) }
        }
        let k = "agentIslandAutoAllow", saved = Preferences.defaults.object(forKey: k)
        defer { Preferences.defaults.set(saved, forKey: k) }
        for on in [false, true] {
            Preferences.agentIslandAutoAllow = on
            let width = sz(560)
            let h = NSHostingView(rootView: AgentIslandPane().frame(width: width).padding(sz(16))
                .background(Color(white: 0.1)).preferredColorScheme(.dark))
            h.frame = CGRect(origin: .zero, size: CGSize(width: width + 2 * sz(16), height: 10))
            h.frame.size = h.fittingSize
            h.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            h.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(h.bounds.height, 4 * sz(20))
            let rep = try XCTUnwrap(h.bitmapImageRepForCachingDisplay(in: h.bounds))
            h.cacheDisplay(in: h.bounds, to: rep)
            try write(try XCTUnwrap(rep.representation(using: .png, properties: [:])), "settings-auto-allow-\(on ? "on" : "off")")
        }
        let store = AgentIslandStore(geometry: Self.geometry)
        let now = Date().timeIntervalSince1970
        store.sessions = [AgentSession(key: key, alias: "prosper-751", activity: now - 3, state: .working, agents: 0),
                          AgentSession(key: AgentSessionKey(dir: "/d", name: "qa"), alias: "", activity: now - 60,
                                       state: .blocked, agents: 0)]
        store.actions[key] = AgentIslandController.autoAllowedText
        store.expanded = true
        let r = ImageRenderer(content: AgentIslandView(store: store).padding(20).background(Color(white: 0.75)))
        r.scale = 2
        let cg = try XCTUnwrap(r.cgImage)
        try write(try XCTUnwrap(NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])),
                  "agent-island-row-allowed-automatically")
    }
}
