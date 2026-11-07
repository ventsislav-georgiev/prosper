import AppKit
import os
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
        /// #754: the next read waits on this (a wedged dch), once.
        var gate: DispatchSemaphore?
        init(_ screens: String...) { self.screens = screens }
        func set(_ screen: String, status: String = "blocked") {
            lock.withLock { screens = [screen]; self.status = status }
        }
        var io: AgentPromptIO {
            AgentPromptIO(read: { _ in
                self.lock.withLock { () -> DispatchSemaphore? in defer { self.gate = nil }; return self.gate }?.wait()
                return self.lock.withLock {
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
        let r = AgentPrompt.autoAllow(key, io: f.io, notAgain: nil, answered: false, isOn: { true })
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
            XCTAssertEqual(AgentPrompt.autoAllow(key, io: f.io, notAgain: nil, answered: false, isOn: { true }), .allowed(p), name)
            XCTAssertEqual(f.sends, ["1"], name)
            let card = FakeIO(screen)
            XCTAssertEqual(AgentPrompt.answer(key, digit: 1, expected: p, io: card.io), .changed, "\(name): the card's Yes")
            XCTAssertEqual(card.sends, [], name)
        }
        XCTAssertFalse(try XCTUnwrap(AgentPrompt.parse(Self.offTop)).topFound, "the fixture's head is off the screen")
    }

    /// #756: a long command in Claude Code's "│ " gutter fills the screen (head
    /// off the top), and a running background agent stretches the footer past
    /// 64 characters, cut at the screen width; the session-title rule under it.
    private static let backgroundAgentFooter =
        " Esc to cancel · Tab to amend · ctrl+x ctrl+k twice to stop background ag…"
    private static let offTopLongFooter = ((1...48).map { " │ line \($0) of a long synthetic command body" }
        + [String(repeating: "╌", count: 75), " A variable in this command can't be checked before it runs", "",
           " Do you want to proceed?", " ❯ 1. Yes", "   2. No", "", backgroundAgentFooter,
           String(repeating: "─", count: 67) + " probe ─"]).joined(separator: "\n")

    func testAPromptWithABackgroundAgentFooterIsAllowedButTheCardStillRefuses() throws {
        XCTAssertGreaterThan(Self.backgroundAgentFooter.trimmingCharacters(in: .whitespaces).count, 64)
        let p = try XCTUnwrap(AgentPrompt.parse(Self.offTopLongFooter), "a footer past 64 still ends the dialog")
        XCTAssertFalse(p.topFound)
        XCTAssertEqual(p.question, "Do you want to proceed?")
        XCTAssertEqual(p.allowYes?.digit, 1)
        XCTAssertEqual(p.options.map { p.isEnabled($0) }, [false, true], "the card: No only, the head is off the screen")
        let f = FakeIO(Self.offTopLongFooter)
        XCTAssertEqual(AgentPrompt.autoAllow(key, io: f.io, notAgain: nil, answered: false, isOn: { true }), .allowed(p))
        XCTAssertEqual(f.sends, ["1"])
        let card = FakeIO(Self.offTopLongFooter)
        XCTAssertEqual(AgentPrompt.answer(key, digit: 1, expected: p, io: card.io), .changed, "the card's Yes")
        XCTAssertEqual(card.sends, [])
    }

    func testEveryOtherPromptIsLeftAlone() {
        for (name, screen) in Self.neverAnswered + Self.unparsed {
            let f = FakeIO(screen)
            XCTAssertEqual(AgentPrompt.autoAllow(key, io: f.io, notAgain: nil, answered: false, isOn: { true }), .human, name)
            XCTAssertEqual(f.sends, [], name)
        }
    }

    func testTheSamePromptIsNeverAnsweredTwice() throws {
        let p = try XCTUnwrap(AgentPrompt.parse(Self.bash3))
        let f = FakeIO(Self.bash3)
        XCTAssertEqual(AgentPrompt.autoAllow(key, io: f.io, notAgain: p, answered: true, isOn: { true }), .human)
        XCTAssertEqual(f.sends, [])
        let other = try XCTUnwrap(AgentPrompt.parse(Self.otherBash))
        XCTAssertEqual(AgentPrompt.autoAllow(key, io: f.io, notAgain: other, answered: true, isOn: { true }), .allowed(p))
        XCTAssertEqual(f.sends, ["1"])
    }

    func testAChangedScreenBetweenReadsSendsNothing() {
        let f = FakeIO(Self.bash3, Self.otherBash)
        XCTAssertEqual(AgentPrompt.autoAllow(key, io: f.io, notAgain: nil, answered: false, isOn: { true }), .human)
        XCTAssertEqual(f.sends, [])
    }

    // MARK: - #784: the auto-block countdown

    private static func countdown(_ t: String, tail: String = "to avoid holding up an unattended session") -> String {
        " ⚠ Claude Code will automatically block this request in \(t), \(tail)"
    }
    private static let rmCommand = "   cd ~/personal/dobby && rtk git status -sb | head -1 && git merge --no-ff dobby-557c"
        + " -m \"Merge #557 r5: ...\" && git push origin main; ... rm -rf ~/personal/dobby-557-review && echo cleaned;"
        + " ... --expect-version $v >/dev/null && echo ledger-ok"
    private static let rmReason =
        "   Dangerous rm operation on working directory or its ancestor: /Users/ventsislav.georgiev/personal/dobby-557-review"

    /// The operator's screen (#784): a Bash dialog with its reason line and Claude
    /// Code's auto-block countdown above the question. `lines`: the countdown rows.
    private static func rmScreen(_ lines: [String], command: String = rmCommand, reason: String = rmReason) -> String {
        ([String(repeating: "─", count: 90), " Bash command", " Merge #557 r5, push, clean, record",
          " " + String(repeating: "╌", count: 89), command, " " + String(repeating: "╌", count: 89), reason]
            + lines + ["", " Do you want to proceed?", " ❯ 1. Yes", "   2. No", "", " Esc to cancel · Tab to amend"])
            .joined(separator: "\n")
    }
    private static func rmScreen(_ t: String) -> String { rmScreen([countdown(t)]) }

    func testTheCountdownTickingBetweenTheReadsIsStillAllowed() throws {
        let p = try XCTUnwrap(AgentPrompt.parse(Self.rmScreen("1:35")))
        XCTAssertEqual(p.allowYes?.digit, 1, "the operator's screen is a plain permission prompt")
        XCTAssertEqual(p.context.last, String(Self.countdown("1:35").dropFirst()), "the countdown is context")
        let f = FakeIO(Self.rmScreen("1:35"), Self.rmScreen("1:34"))
        XCTAssertEqual(AgentPrompt.autoAllow(key, io: f.io, notAgain: nil, answered: false, isOn: { true }), .allowed(p))
        XCTAssertEqual(f.sends, ["1"])
        XCTAssertEqual(f.reads, 2)
        // A minute boundary and the U+FE0F glyph form too.
        let fe = { (t: String) in Self.rmScreen("1:00").replacingOccurrences(of: "⚠ Claude", with: "⚠\u{FE0F} Claude")
            .replacingOccurrences(of: "1:00", with: t) }
        let g = FakeIO(fe("1:00"), fe("0:59"))
        XCTAssertEqual(AgentPrompt.autoAllow(key, io: g.io, notAgain: nil, answered: false, isOn: { true }),
                       .allowed(try XCTUnwrap(AgentPrompt.parse(fe("1:00")))))
        XCTAssertEqual(g.sends, ["1"])
    }

    /// A narrow pty wraps the countdown; its time can land on either row.
    func testAWrappedCountdownTickingIsStillAllowed() throws {
        let wraps: [(String) -> [String]] = [
            { [" ⚠ Claude Code will automatically block this", "   request in \($0), to avoid holding up an", "   unattended session"] },
            { [" ⚠ Claude Code will automatically block this request in", "   \($0), to avoid holding up an unattended", "   session"] },
        ]
        for (n, wrap) in wraps.enumerated() {
            let a = Self.rmScreen(wrap("1:35"), command: "   rm -rf ~/personal/dobby-557-review", reason: "   Dangerous rm")
            let b = Self.rmScreen(wrap("1:34"), command: "   rm -rf ~/personal/dobby-557-review", reason: "   Dangerous rm")
            let p = try XCTUnwrap(AgentPrompt.parse(a), "wrap \(n)")
            let f = FakeIO(a, b)
            XCTAssertEqual(AgentPrompt.autoAllow(key, io: f.io, notAgain: nil, answered: false, isOn: { true }), .allowed(p), "wrap \(n)")
            XCTAssertEqual(f.sends, ["1"], "wrap \(n)")
            // The card's Yes: the same tick is accepted.
            XCTAssertTrue(p.options.allSatisfy { p.isEnabled($0) }, "wrap \(n): the card shows Yes enabled")
            let c = FakeIO(b)
            XCTAssertEqual(AgentPrompt.answer(key, digit: 1, expected: p, io: c.io), .sent, "wrap \(n): the card")
            XCTAssertEqual(c.sends, ["1"], "wrap \(n)")
        }
    }

    func testTheCardsAnswerAcceptsTheCountdownTicking() throws {
        let short = { (t: String) in Self.rmScreen([Self.countdown(t)], command: "   rm -rf ~/personal/dobby-557-review",
                                                   reason: "   Dangerous rm operation") }
        let p = try XCTUnwrap(AgentPrompt.parse(short("1:35")))
        XCTAssertTrue(p.options.allSatisfy { p.isEnabled($0) }, "the card shows Yes enabled")
        let f = FakeIO(short("1:34"))
        XCTAssertEqual(AgentPrompt.answer(key, digit: 1, expected: p, io: f.io), .sent)
        XCTAssertEqual(f.sends, ["1"])
        // Anything else changed: the card's Yes refuses (no fallback key).
        let g = FakeIO(short("1:34").replacingOccurrences(of: "dobby-557-review", with: "dobby"))
        XCTAssertEqual(AgentPrompt.answer(key, digit: 1, expected: p, io: g.io), .changed)
        XCTAssertEqual(g.sends, [])
    }

    /// Only the M:SS on the countdown's own wording may differ between the reads.
    func testAnythingElseChangedBetweenTheReadsIsRefused() {
        let first = Self.rmScreen("1:35")
        let changed: [(String, String)] = [
            ("the command (the subject), countdown ticking too",
             Self.rmScreen([Self.countdown("1:34")], command: Self.rmCommand.replacingOccurrences(of: "dobby-557-review", with: "dobby"))),
            ("the command only, same countdown",
             Self.rmScreen([Self.countdown("1:35")], command: Self.rmCommand.replacingOccurrences(of: "557", with: "558"))),
            ("the reason line", Self.rmScreen([Self.countdown("1:34")], reason: Self.rmReason + "x")),
            ("the countdown's tail", Self.rmScreen([Self.countdown("1:34", tail: "to avoid holding up a busy session")])),
            ("the countdown's head", Self.rmScreen([Self.countdown("1:34").replacingOccurrences(of: "block", with: "allow")])),
            ("the countdown's glyph", Self.rmScreen([Self.countdown("1:34").replacingOccurrences(of: "⚠", with: "!")])),
            ("text after the time", Self.rmScreen([Self.countdown("1:34 x")])),
            ("the time's shape", Self.rmScreen([Self.countdown("1:34:00")])),
            ("the time gone", Self.rmScreen([Self.countdown("soon")])),
            ("an extra line", Self.rmScreen([Self.countdown("1:34"), " rm -rf ~"])),
            ("the countdown gone", Self.rmScreen([])),
        ]
        for (name, second) in changed {
            let f = FakeIO(first, second)
            XCTAssertEqual(AgentPrompt.autoAllow(key, io: f.io, notAgain: nil, answered: false, isOn: { true }), .human, name)
            XCTAssertEqual(f.sends, [], name)
        }
        // A time in the command is no countdown: it never masks.
        let timed = { (t: String) in Self.rmScreen([Self.countdown("1:35")], command: "   sleep \(t)") }
        let f = FakeIO(timed("1:35"), timed("1:34"))
        XCTAssertEqual(AgentPrompt.autoAllow(key, io: f.io, notAgain: nil, answered: false, isOn: { true }), .human)
        XCTAssertEqual(f.sends, [])
        // Only the time ticks, on a line that is not exactly the countdown wording: refused.
        let notCountdown: [(String, (String) -> String)] = [
            ("text before it", { " echo x && " + Self.countdown($0).dropFirst() }),
            ("text after it", { Self.countdown($0) + " && rm -rf ~" }),
            ("another tail", { Self.countdown($0, tail: "to avoid holding up a busy session") }),
            ("another head", { Self.countdown($0).replacingOccurrences(of: "block", with: "allow") }),
            ("no glyph", { Self.countdown($0).replacingOccurrences(of: "⚠ ", with: "") }),
            ("another glyph", { Self.countdown($0).replacingOccurrences(of: "⚠", with: "!") }),
        ]
        for (name, line) in notCountdown {
            let g = FakeIO(Self.rmScreen([line("1:35")]), Self.rmScreen([line("1:34")]))
            XCTAssertEqual(AgentPrompt.autoAllow(key, io: g.io, notAgain: nil, answered: false, isOn: { true }), .human, name)
            XCTAssertEqual(g.sends, [], name)
        }
    }

    /// The loop guard holds across a tick: the same prompt answered last is not answered again.
    func testTheLoopGuardHoldsAcrossATick() throws {
        let p = try XCTUnwrap(AgentPrompt.parse(Self.rmScreen("1:35")))
        let f = FakeIO(Self.rmScreen("1:30"))
        XCTAssertEqual(AgentPrompt.autoAllow(key, io: f.io, notAgain: p, answered: true, isOn: { true }), .human)
        XCTAssertEqual(f.sends, [])
    }

    // MARK: - #783: the don't-ask-again row's apostrophe

    private func assertYesOnThreeOptions(_ apostrophe: Character, file: StaticString = #filePath, line: UInt = #line) throws {
        let screen = Self.dialog(Self.proceed, ["Yes", "Yes, and don\(apostrophe)t ask again for: /usr/bin/true qa310 *", Self.noTell])
        let p = try XCTUnwrap(AgentPrompt.parse(screen), file: file, line: line)
        XCTAssertEqual(p.allowYes?.digit, 1, file: file, line: line)
        let f = FakeIO(screen)
        XCTAssertEqual(AgentPrompt.autoAllow(key, io: f.io, notAgain: nil, answered: false, isOn: { true }), .allowed(p),
                       file: file, line: line)
        XCTAssertEqual(f.sends, ["1"], "Yes, never the don't-ask-again row", file: file, line: line)
    }

    func testThreeOptionsWithAStraightApostropheGetYes() throws { try assertYesOnThreeOptions("'") }

    /// Claude Code 2.1.309 draws "don’t" with U+2019.
    func testThreeOptionsWithACurlyApostropheGetYes() throws { try assertYesOnThreeOptions("\u{2019}") }

    func testThreeOptionsWithALeftCurlyQuoteGetYes() throws { try assertYesOnThreeOptions("\u{2018}") }

    /// QA #581 F1: a timed-out (empty) or unknown status is not "the answer took".
    func testAnEmptyOrUnknownStatusAfterAnAnswerIsTheHumans() {
        for status in ["", "\n", "garbage"] {
            let f = FakeIO("")
            f.status = status
            XCTAssertEqual(AgentPrompt.autoAllow(key, io: f.io, notAgain: nil, answered: true, isOn: { true }), .human, "status \(status.debugDescription)")
        }
        for status in ["working", "idle\n", "done"] {
            let f = FakeIO("")
            f.status = status
            XCTAssertEqual(AgentPrompt.autoAllow(key, io: f.io, notAgain: nil, answered: true, isOn: { true }), .gone, status)
        }
    }

    func testNoPromptIsGoneOnlyAfterAnAnswerAndOnlyWhenDchAgrees() {
        let idle = Self.unparsed[0].1
        let f = FakeIO(idle)
        f.status = "working"
        XCTAssertEqual(AgentPrompt.autoAllow(key, io: f.io, notAgain: nil, answered: true, isOn: { true }), .gone)
        XCTAssertEqual(AgentPrompt.autoAllow(key, io: f.io, notAgain: nil, answered: false, isOn: { true }), .human)
        f.status = "blocked\n"
        XCTAssertEqual(AgentPrompt.autoAllow(key, io: f.io, notAgain: nil, answered: true, isOn: { true }), .human)
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

    private func session(_ state: AgentState, activity: TimeInterval = 1) -> AgentSession {
        AgentSession(key: key, alias: "", activity: activity, state: state, agents: 0)
    }

    /// One poll that changed the list, as apply runs it; returns what apply publishes.
    @MainActor @discardableResult
    private func tick(_ c: AgentIslandController, _ state: AgentState, activity: TimeInterval = 1) -> AgentState? {
        c.store?.sessions = [session(state, activity: activity)]
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

    // MARK: - #754

    /// INFO-R1: switched off while the check is stuck on a wedged read: no send.
    @MainActor func testSwitchedOffWhileTheCheckIsQueuedSendsNothing() {
        XCTAssertEqual(AgentPrompt.autoAllow(key, io: FakeIO(Self.bash3).io, notAgain: nil, answered: false,
                                             isOn: { false }), .human)
        let f = FakeIO(Self.bash3), gate = DispatchSemaphore(value: 0), on = OSAllocatedUnfairLock(initialState: true)
        f.gate = gate
        let (c, r) = controller(f, on: nil)
        c.autoAllowOn = { on.withLock { $0 } }   // the setting itself, no Settings hook
        tick(c, .blocked)
        on.withLock { $0 = false }
        gate.signal()
        drain(c)
        XCTAssertEqual(f.sends, [], "the queue re-reads the setting before the send")
        XCTAssertEqual(r.lastState, .blocked, "left to the human")
        XCTAssertNil(c.store?.actions[key])
    }

    /// INFO-R2: switched off (Settings) during a check that ends .human: the card is still read.
    @MainActor func testSwitchedOffDuringAHumanCheckStillReadsTheCard() throws {
        let plan = Self.neverAnswered[0].1
        let f = FakeIO(plan), gate = DispatchSemaphore(value: 0), on = OSAllocatedUnfairLock(initialState: true)
        f.gate = gate
        let (c, r) = controller(f, on: nil)
        c.autoAllowOn = { on.withLock { $0 } }
        c.store?.expanded = true
        tick(c, .blocked)
        c.refreshCards()   // skips the key: the check holds it
        on.withLock { $0 = false }
        c.autoAllowChanged()   // the hold drops now
        XCTAssertEqual(r.lastState, .blocked)
        gate.signal()
        drain(c)
        drain(c)
        XCTAssertEqual(c.store?.cards[key], .prompt(try XCTUnwrap(AgentPrompt.parse(plan))))
    }

    /// INFO-R3: the Settings toggle's hook stores the setting and tells the controller.
    @MainActor func testTheSettingsHookStoresAndDropsTheHold() {
        let k = "agentIslandAutoAllow", saved = Preferences.defaults.object(forKey: k)
        defer { Preferences.defaults.set(saved, forKey: k) }
        Preferences.agentIslandAutoAllow = true
        let f = FakeIO(Self.bash3), (c, r) = controller(f, on: nil)   // the real setting seam
        tick(c, .blocked)
        drain(c)
        XCTAssertFalse(r.everBlocked)
        AgentIslandPane.autoAllowToggled(false, c)
        XCTAssertFalse(Preferences.agentIslandAutoAllow)
        XCTAssertEqual(r.lastState, .blocked, "published at once")
        AgentIslandPane.autoAllowToggled(true, c)
        XCTAssertTrue(Preferences.agentIslandAutoAllow)
        XCTAssertEqual(r.lastState, .working, "on: the blocked session is checked again")
        drain(c)
    }

    // MARK: - #755 (QA #585)

    /// INFO-1: off then on within one check that types Yes: held, never Needs input.
    @MainActor func testOffThenOnDuringACheckKeepsItsYes() {
        let f = FakeIO(Self.bash3), gate = DispatchSemaphore(value: 0), on = OSAllocatedUnfairLock(initialState: true)
        f.gate = gate
        let (c, r) = controller(f, on: nil)
        c.autoAllowOn = { on.withLock { $0 } }
        tick(c, .blocked)
        on.withLock { $0 = false }
        c.autoAllowChanged()
        XCTAssertEqual(r.lastState, .blocked)
        on.withLock { $0 = true }
        c.autoAllowChanged()
        XCTAssertEqual(r.lastState, .working, "the check in flight holds it again")
        gate.signal()
        drain(c)
        XCTAssertEqual(f.sends, ["1"])
        XCTAssertEqual(r.lastState, .working)
        XCTAssertEqual(c.published(c.store?.sessions ?? []).first?.state, .working)
        XCTAssertEqual(c.store?.actions[key], AgentIslandController.autoAllowedText)
        XCTAssertEqual(r.timers.count, 1, "its re-read is armed")
    }

    /// INFO-1: the orphaned check read the setting off and refused; back on, the
    /// still-blocked session is checked again and answered.
    @MainActor func testOffThenOnAfterAnOffRefusalChecksAgain() {
        let f = FakeIO(Self.bash3), gate = DispatchSemaphore(value: 0), on = OSAllocatedUnfairLock(initialState: true)
        f.gate = gate
        let (c, r) = controller(f, on: nil)
        c.autoAllowOn = { on.withLock { $0 } }
        tick(c, .blocked)
        on.withLock { $0 = false }
        c.autoAllowChanged()
        gate.signal()
        c.queue.sync {}   // refused (.human); its main hop is still queued
        XCTAssertEqual(f.sends, [])
        on.withLock { $0 = true }
        c.autoAllowChanged()
        drain(c)
        drain(c)
        XCTAssertEqual(f.sends, ["1"], "checked again while on")
        XCTAssertEqual(r.lastState, .working)
        XCTAssertEqual(c.store?.actions[key], AgentIslandController.autoAllowedText)
    }

    /// INFO-2: switched off after the Yes, which did not take: the card shows at once,
    /// both when the result came first and when it lands after the toggle.
    @MainActor func testSwitchedOffAfterAYesShowsTheCardAtOnce() throws {
        let p = try XCTUnwrap(AgentPrompt.parse(Self.bash3))
        for late in [false, true] {
            let f = FakeIO(Self.bash3), on = OSAllocatedUnfairLock(initialState: true)
            let (c, r) = controller(f, on: nil)
            c.autoAllowOn = { on.withLock { $0 } }
            c.store?.expanded = true
            tick(c, .blocked)
            c.refreshCards()   // skips the key: the check holds it
            if late { c.queue.sync {} } else { drain(c) }
            XCTAssertEqual(f.sends, ["1"], "late \(late)")
            XCTAssertNil(c.store?.cards[key], "late \(late)")
            on.withLock { $0 = false }
            c.autoAllowChanged()
            XCTAssertEqual(r.lastState, .blocked, "late \(late)")
            drain(c)
            drain(c)
            XCTAssertEqual(c.store?.cards[key], .prompt(p), "late \(late): the prompt still up gets its card")
        }
    }

    // MARK: - #790: subagent prompts and hook confirmations

    /// Claude Code 2.1.318's Bash dialog for a subagent's call, as the operator's
    /// phone showed it (92 columns): the title's "· from the <agent> agent", the
    /// description over the dashed command frame, then (`hook`) a PreToolUse hook's
    /// "ask": its reasonString (`Hook <name> requires confirmation for this
    /// command:`, the reason, the dim "[<source>]") and its dim configString line.
    private static func subagentBash(hook: [String]? = hookBlock, title: String = " Bash command · from the worker-opus-high agent",
                                     top: Bool = true, footer: String = backgroundAgentFooter, titleRule: Bool = false) -> String {
        let rule = String(repeating: "─", count: 92), dash = " " + String(repeating: "╌", count: 91)
        return ((top ? [rule] : []) + [title, " Read changelog script and 1.69 release", dash,
                "   cd /Users/ventsislav.georgiev/personal/a4kStreaming && cat scripts/update_changelog.py; head -40",
                "   CHANGELOG.md; /usr/bin/git log --oneline -3 plugin.video.a4kstreaming/plugin.video.a4kstreaming-1.69.0;",
                "   /usr/bin/git show --stat plugin.video.a4kstreaming/plugin.video.a4kstreaming-1.69.0 | head -30;",
                "   cat .git/guard-hooks/post-commit", dash]
            + (hook ?? []) + ["", " Do you want to proceed?", " ❯ 1. Yes", "   2. No", "", footer]
            + (titleRule ? [String(repeating: "─", count: 80) + " dch-a4k ─"] : [])).joined(separator: "\n")
    }

    private static let hookBlock = [
        "   Hook PreToolUse:Bash requires confirmation for this command:",
        "   a4k identity guard: guard or git/ssh config tampering (hooksPath, config hooks, pushurl,",
        "   approval file, guard files, refs/remotes, ssh keys). [settings]",
        " settings.json to update hooks",
    ]

    /// A subagent's prompt in every layout the report allows (title suffix, head
    /// off the screen, long or short footer, session-title rule, a wrapped title).
    private static let subagentLayouts: [(String, @Sendable (_ hook: [String]?) -> String)] = [
        ("as reported", { subagentBash(hook: $0) }),
        ("no top rule", { subagentBash(hook: $0, top: false) }),
        ("no title suffix", { subagentBash(hook: $0, title: " Bash command") }),
        ("short footer", { subagentBash(hook: $0, footer: " Esc to cancel · Tab to amend") }),
        ("session-title rule", { subagentBash(hook: $0, titleRule: true) }),
        ("title wrapped", { subagentBash(hook: $0, title: " Bash command · from the\n worker-opus-high agent") }),
    ]

    /// The hook block as a narrow pty wraps it, and with one of its two markers gone.
    private static let hookVariants: [(String, [String])] = [
        ("as reported", hookBlock),
        ("no [settings]", hookBlock.map { $0.replacingOccurrences(of: " [settings]", with: "") }),
        ("reason line only", Array(hookBlock.dropLast())),
        ("configString line only", Array(hookBlock.dropFirst())),
        ("wrapped inside the hook name", ["   Hook PreToolUse:", "   Bash requires confirmation for", "   this command:",
                                          "   a4k identity guard: guard or git/ssh config tampering [settings]",
                                          " settings.json to", " update hooks"]),
        ("wrapped, reason marker only", ["   Hook PreToolUse:Bash requires", "   confirmation for this command:", "   a4k guard"]),
        ("wrapped, configString only", ["   a4k guard", " plugin hooks.json to update", " hooks"]),
        ("no reason", ["   Hook PreToolUse:Bash requires confirmation for this command.", " SKILL.md to update hooks"]),
        // Second ruling: the user's settings "ask" permission rules.
        ("ask rule", ["   Permission rule Bash(git push:*) requires confirmation for this command.",
                      " /permissions to update rules"]),
        ("ask rule, managed policy (no hint)", ["   Permission rule Bash(git push:*) requires confirmation for this command."]),
        ("ask rule wrapped inside the rule", ["   Permission rule Bash(git", "   push:*) requires", "   confirmation for this command.",
                                             " /permissions to update", " rules"]),
        ("ask rule in auto mode", ["   Ask rule Bash(git push:*) overrides auto mode for this command.",
                                   " /permissions to let auto mode decide"]),
        ("ask rule in auto mode, wrapped", ["   Ask rule Bash(git push:*) overrides", "   auto mode for this command."]),
        ("auto-mode hint only, wrapped", ["   a4k guard", " /permissions to let auto", " mode decide"]),
    ]

    /// #790 diagnosis: at b18a9e0 nothing in the rule refused the reported
    /// screen (title suffix, long footer, "[settings]", the configString line are
    /// all plain context). After the operator's ruling, only the hook block
    /// refuses: the same subagent prompt without it still gets Yes.
    func testASubagentPromptWithoutAHookGetsYes() throws {
        for (name, layout) in Self.subagentLayouts {
            let screen = layout(nil), p = try XCTUnwrap(AgentPrompt.parse(screen), name)
            XCTAssertEqual(p.question, "Do you want to proceed?", name)
            XCTAssertEqual(p.allowYes?.digit, 1, name)
            let f = FakeIO(screen)
            XCTAssertEqual(AgentPrompt.autoAllow(key, io: f.io, notAgain: nil, answered: false, isOn: { true }), .allowed(p), name)
            XCTAssertEqual(f.sends, ["1"], name)
        }
    }

    /// #790 (operator rulings): a hook's "ask" and a settings ask rule always
    /// wait for the human, in every layout and wrap, with any marker alone.
    func testAUserAskConfirmationIsLeftToTheHuman() throws {
        for (name, layout) in Self.subagentLayouts {
            for (hookName, hook) in Self.hookVariants {
                let screen = layout(hook), what = "\(name), \(hookName)"
                let p = try XCTUnwrap(AgentPrompt.parse(screen), "\(what): parses, so the rule is what refuses it")
                XCTAssertEqual(p.question, "Do you want to proceed?", what)
                XCTAssertNil(p.allowYes, what)
                let f = FakeIO(screen)
                XCTAssertEqual(AgentPrompt.autoAllow(key, io: f.io, notAgain: nil, answered: false, isOn: { true }), .human, what)
                XCTAssertEqual(f.sends, [], what)
            }
        }
        // With a "don't ask again" row too.
        let three = Self.subagentBash().replacingOccurrences(of: "   2. No", with: "   2. \(Self.dontAsk)\n   3. No")
        XCTAssertEqual(try XCTUnwrap(AgentPrompt.parse(three)).options.count, 3)
        XCTAssertNil(try XCTUnwrap(AgentPrompt.parse(three)).allowYes)
    }

    /// Each marker alone refuses; a working-directory reason (whose hint is also
    /// "/permissions to update rules"), the words apart in a command, Claude
    /// Code's ordinary Bash reason line and a classifier's ask (no ruling) do not.
    func testOnlyTheUserAskWordingRefuses() {
        for context in [["Path is outside the allowed working directories.", "/permissions to update rules"],
                        ["  git hook install", "  echo requires confirmation", "  update the hooks", "  ask rule auto mode"],
                        ["Bash command", "  rm -rf .build", "This command requires approval"],
                        ["Classifier bash-safety requires confirmation for this command.", "Deletes files"]] {
            XCTAssertFalse(AgentPrompt.isUserAskConfirmation(context), "\(context)")
        }
        for context in [["Hook PreToolUse:Bash requires confirmation for this command:"],
                        ["settings.json to update hooks"],
                        ["Permission rule Bash(rm:*) requires confirmation for this command."],
                        ["Ask rule Bash(rm:*) overrides auto mode for this command."],
                        ["/permissions to let auto mode decide"]] {
            XCTAssertTrue(AgentPrompt.isUserAskConfirmation(context), "\(context)")
        }
    }

    /// The card and the click path are unchanged: a human's Yes still answers a hook's prompt.
    func testTheCardStillAnswersAHookConfirmation() throws {
        let screen = Self.dialog(Self.proceed, ["Yes", "No"], body: ["   rm -rf .build"] + Self.hookBlock)
        let p = try XCTUnwrap(AgentPrompt.parse(screen))
        XCTAssertNil(p.allowYes)
        XCTAssertTrue(p.isEnabled(p.options[0]), "the card's Yes")
        let f = FakeIO(screen)
        XCTAssertEqual(AgentPrompt.answer(key, digit: 1, expected: p, io: f.io), .sent)
        XCTAssertEqual(f.sends, ["1"])
    }

    /// QA #613 INFO-1: a managed policy ask rule draws no hint line, so only the reason
    /// refuses it; a rule over 300 characters (the old bound) must still be the human's.
    func testALongManagedPolicyAskRuleIsLeftToTheHuman() throws {
        let rule = "Bash(/usr/bin/" + String(repeating: "x", count: 320) + ":*)"
        XCTAssertGreaterThan(rule.count, 300)
        let wrapped = { (head: String, tail: String) -> [String] in
            let text = head + rule + tail
            return stride(from: 0, to: text.count, by: 80).map { i in
                "   " + String(text.dropFirst(i).prefix(80))
            }
        }
        for (name, hook) in [("permission rule", wrapped("Permission rule ", " requires confirmation for this command.")),
                             ("ask rule in auto mode", wrapped("Ask rule ", " overrides auto mode for this command."))] {
            let screen = Self.subagentBash(hook: hook), p = try XCTUnwrap(AgentPrompt.parse(screen), name)
            XCTAssertEqual(p.question, "Do you want to proceed?", name)
            XCTAssertNil(p.allowYes, name)
            let f = FakeIO(screen)
            XCTAssertEqual(AgentPrompt.autoAllow(key, io: f.io, notAgain: nil, answered: false, isOn: { true }), .human, name)
            XCTAssertEqual(f.sends, [], name)
        }
    }

    // MARK: - #792: dch's own auto-allow answers, Prosper stands down

    /// The installed dch, faked: its version (nil = none installed), `--build` and
    /// `--config` (nil = timed out); every call and its env recorded.
    private final class FakeDch: @unchecked Sendable {
        let lock = NSLock()
        var version: [Int]? = [1, 29, 2]
        var build: String? = "full\n"
        var config: String? = "/Users/probe/.config/dch/config\nauto_allow = true\nsidekick_pattern = -qa\n"
        var calls: [[String]] = [], envs: [[String: String]] = []
        @MainActor init(_ c: AgentIslandController) {
            c.controlDch = { self.lock.withLock { self.version.map { DchCommand.Binary(path: "/fake/dch", version: $0) } } }
            c.runDch = { path, args, env in
                self.lock.withLock {
                    XCTAssertEqual(path, "/fake/dch")
                    self.calls.append(args)
                    self.envs.append(env)
                    return (args == ["--build"] ? self.build : args == ["--config"] ? self.config : nil).map { Data($0.utf8) }
                }
            }
        }
    }

    private static let dchAnswer = DchAutoAllowed(at: 1_000_005, title: "Bash command")

    private func row(_ state: AgentState, master: String = "1.29.2", allowed: DchAutoAllowed? = nil,
                     name: String = "s", activity: TimeInterval = 1) -> AgentSession {
        AgentSession(key: AgentSessionKey(dir: "/d", name: name), alias: "", activity: activity, state: state, agents: 0,
                     version: master, autoAllowed: allowed)
    }

    /// One list change, as apply runs it; what goes to the phone.
    @MainActor @discardableResult
    private func list(_ c: AgentIslandController, _ rows: AgentSession...) -> [AgentState] {
        c.store?.sessions = rows
        c.checkAutoAllow()
        return c.published(rows).map(\.state)
    }

    func testTheListParsesDchsAutoAllowed() {
        let rows = DchCommand.parseListJSON(Data("""
        [{"name":"a","state":"working","version":"1.29.2","auto_allowed":{"at":1000005,"title":"Bash command"}},
         {"name":"b","state":"blocked","version":"1.29.2","auto_allowed":null},
         {"name":"c","state":"idle"},
         {"name":"d","state":"idle","auto_allowed":{"at":"soon","title":"Bash command"}}]
        """.utf8))
        XCTAssertEqual(rows.map(\.autoAllowed), [Self.dchAnswer, nil, nil, nil])
        let s = AgentIsland.list(dirs: ["/d"]) { _, _ in
            Data(#"[{"name":"a","state":"working","auto_allowed":{"at":1000005,"title":"Bash command"}}]"#.utf8)
        }
        XCTAssertEqual(s.first?.autoAllowed, Self.dchAnswer, "carried into the island's session")
    }

    @MainActor func testStandingDownSendsNothingHoldsTheRowThenShowsDchsAnswer() {
        let f = FakeIO(Self.bash3), (c, r) = controller(f), d = FakeDch(c)
        XCTAssertEqual(list(c, row(.blocked)), [.working], "held while it is checked")
        drain(c)
        XCTAssertEqual(f.sends, [], "Prosper sends nothing")
        XCTAssertEqual(f.reads, 0, "nor reads the screen")
        XCTAssertEqual(d.calls, [["--build"], ["--config"]])
        XCTAssertEqual(d.envs.last?["DCH_SOCKET_DIR"], "/d", "the island's dch env (listEnv)")
        XCTAssertNil(d.envs.last?["DCH_SESSION"])
        XCTAssertEqual(c.published(c.store?.sessions ?? []).map(\.state), [.working], "still held: no Needs input")
        XCTAssertFalse(r.everBlocked)
        XCTAssertNil(c.store?.actions[key])
        XCTAssertEqual(r.timers.count, 1, "the bounded wait is armed")
        // dch answers: the row leaves blocked with its auto_allowed.
        XCTAssertEqual(list(c, row(.working, allowed: Self.dchAnswer)), [.working])
        XCTAssertEqual(c.store?.actions[key], AgentIslandController.autoAllowedText)
        fire(c, r)
        XCTAssertFalse(r.everBlocked, "the wait's end is a no-op once the row left blocked")
        XCTAssertEqual(f.sends, [])
        XCTAssertEqual(d.calls.count, 2, "and checks nothing: the row is not blocked")
        XCTAssertTrue(r.timers.isEmpty)
        // The next prompt: one --config per blocked event, --build cached.
        XCTAssertEqual(list(c, row(.blocked, allowed: Self.dchAnswer)), [.working])
        drain(c)
        XCTAssertEqual(d.calls, [["--build"], ["--config"], ["--config"]])
        XCTAssertEqual(f.sends, [])
    }

    @MainActor func testNoAnswerFromDchFallsBackToNeedsInputAfterTheWait() {
        let f = FakeIO(Self.bash3), (c, r) = controller(f), d = FakeDch(c)
        var delays: [TimeInterval] = []
        c.after = { delay, fire in delays.append(delay); r.timers.append(fire) }
        list(c, row(.blocked))
        drain(c)
        XCTAssertEqual(delays, [AgentIslandController.standDownWait])
        XCTAssertEqual(AgentIslandController.standDownWait, 5, "verifyDelay 2 + the poll floor 2 + one 1 s tick")
        XCTAssertFalse(r.everBlocked)
        fire(c, r)
        XCTAssertEqual(r.lastState, .blocked, "the normal Needs input")
        XCTAssertEqual(c.published(c.store?.sessions ?? []).map(\.state), [.blocked])
        XCTAssertEqual(f.sends, [], "and still nothing typed")
        XCTAssertTrue(r.timers.isEmpty)
        XCTAssertEqual(list(c, row(.blocked)), [.blocked], "the human's for the rest of the stretch")
        drain(c)
        XCTAssertEqual(d.calls.count, 2, "not checked again")
    }

    /// dch answered and a new prompt is already up when the wait ends: that one is left to dch too.
    @MainActor func testANewPromptAfterDchsAnswerIsStoodDownAgain() {
        let f = FakeIO(Self.bash3), (c, r) = controller(f), d = FakeDch(c)
        list(c, row(.blocked))
        drain(c)
        XCTAssertEqual(list(c, row(.blocked, allowed: Self.dchAnswer)), [.working])
        XCTAssertEqual(c.store?.actions[key], AgentIslandController.autoAllowedText)
        fire(c, r)
        XCTAssertEqual(d.calls, [["--build"], ["--config"], ["--config"]], "checked again")
        XCTAssertFalse(r.everBlocked)
        XCTAssertEqual(r.timers.count, 1, "a new wait")
        fire(c, r)   // no further answer: the human's
        XCTAssertEqual(r.lastState, .blocked)
        XCTAssertEqual(f.sends, [])
    }

    /// Every case dch does not clearly answer: Prosper's engine as today (it types Yes).
    @MainActor func testEveryOtherCaseRunsProspersEngineAsToday() {
        let listing = "/Users/probe/.config/dch/config\n"
        let cases: [(String, String, (FakeDch) -> Void, [[String]])] = [
            ("auto_allow off", "1.29.2", { $0.config = listing + "auto_allow = false\nsidekick_pattern = -qa\n" },
             [["--build"], ["--config"]]),
            ("config timed out", "1.29.2", { $0.config = nil }, [["--build"], ["--config"]]),
            ("config empty", "1.29.2", { $0.config = "" }, [["--build"], ["--config"]]),
            ("config garbage", "1.29.2", { $0.config = "dch: no config path (set HOME or DCH_CONFIG)\n\u{1}\u{2}" },
             [["--build"], ["--config"]]),
            ("master older", "1.28.9", { _ in }, []),
            ("master too old to say", "", { _ in }, []),
            ("lite build", "1.30.0", { $0.build = "lite\n" }, [["--build"]]),
            ("build timed out", "1.30.0", { $0.build = nil }, [["--build"]]),
            ("no dch installed", "1.30.0", { $0.version = nil }, []),
            ("installed dch older: --build never called", "1.30.0", { $0.version = [1, 29, 1] }, []),
        ]
        for (name, master, setUp, calls) in cases {
            let f = FakeIO(Self.bash3), (c, r) = controller(f), d = FakeDch(c)
            setUp(d)
            XCTAssertEqual(list(c, row(.blocked, master: master)), [.working], name)
            drain(c)
            XCTAssertEqual(f.sends, ["1"], "\(name): Prosper answers")
            XCTAssertEqual(c.store?.actions[key], AgentIslandController.autoAllowedText, name)
            XCTAssertEqual(d.calls, calls, name)
            XCTAssertFalse(r.everBlocked, name)
            fire(c, r)   // the re-read after Prosper's own answer
            XCTAssertEqual(d.calls, calls, "\(name): the re-read asks dch nothing")
        }
    }

    /// Only the normalised listing line counts: the single-key form's raw value and
    /// anything not exactly "auto_allow = true" on a listing line is not true.
    @MainActor func testOnlyTheNormalisedListingLineCountsAsOn() {
        let path = "/Users/probe/.config/dch/config\n"
        for config in ["yes\n", "true\n", "auto_allow = true\n", path + "auto_allow = yes\n", path + "auto_allow = on\n",
                       path + "auto_allow = 1\n", path + "auto_allow=true\n", path + " auto_allow = true\n",
                       path + "auto_allow = TRUE\n", path + "auto_allow = true # on\n", path + "# auto_allow = true\n"] {
            let f = FakeIO(Self.bash3), (c, _) = controller(f), d = FakeDch(c)
            d.config = config
            list(c, row(.blocked))
            drain(c)
            XCTAssertEqual(f.sends, ["1"], "\(config.debugDescription): Prosper answers")
        }
        let f = FakeIO(Self.bash3), (c, _) = controller(f), d = FakeDch(c)
        d.config = path + "sidekick_pattern = -qa\nauto_allow = true"   // any order, no trailing newline
        list(c, row(.blocked))
        drain(c)
        XCTAssertEqual(f.sends, [], "the listing line: dch's")
    }

    /// A row first seen with an old answer, or the same answer again, shows nothing; off, nothing either.
    @MainActor func testOnlyANewDchAnswerShows() {
        let f = FakeIO(Self.bash3), (c, _) = controller(f)
        list(c, row(.working, allowed: Self.dchAnswer))
        XCTAssertNil(c.store?.actions[key], "first seen: not this run's")
        list(c, row(.idle, allowed: Self.dchAnswer))
        XCTAssertNil(c.store?.actions[key], "unchanged")
        c.autoAllowOn = { false }
        list(c, row(.working, allowed: DchAutoAllowed(at: 1_000_009, title: "Bash command")))
        XCTAssertNil(c.store?.actions[key], "Always allow off: as today")
        c.autoAllowOn = { true }
        list(c, row(.working, allowed: DchAutoAllowed(at: 1_000_009, title: "Bash command")))
        XCTAssertNil(c.store?.actions[key], "seen again after off: first seen")
        list(c, row(.working, allowed: DchAutoAllowed(at: 1_000_012, title: "Bash command")))
        XCTAssertEqual(c.store?.actions[key], AgentIslandController.autoAllowedText)
    }

    /// #792 review: a 1.29.0 or 1.29.1 master auto-allows, so it is dch's too; an installed
    /// dch under 1.29.2 still leaves every row to Prosper.
    @MainActor func testTheMasterGateIs1290AndTheInstalledGate1292() {
        for master in ["1.29.0", "1.29.1"] {
            let f = FakeIO(Self.bash3), (c, _) = controller(f), d = FakeDch(c)
            XCTAssertEqual(list(c, row(.blocked, master: master)), [.working], master)
            drain(c)
            XCTAssertEqual(f.sends, [], "\(master): stood down")
            XCTAssertEqual(d.calls, [["--build"], ["--config"]], master)
        }
        for master in ["1.28.2", "1.28.99", ""] {
            let f = FakeIO(Self.bash3), (c, _) = controller(f), d = FakeDch(c)
            list(c, row(.blocked, master: master))
            drain(c)
            XCTAssertEqual(f.sends, ["1"], "\(master.debugDescription): Prosper answers")
            XCTAssertEqual(d.calls, [], master)
        }
        let f = FakeIO(Self.bash3), (c, _) = controller(f), d = FakeDch(c)
        d.version = [1, 29, 1]
        list(c, row(.blocked, master: "1.29.1"))
        drain(c)
        XCTAssertEqual(f.sends, ["1"], "installed 1.29.1: Prosper answers")
        XCTAssertEqual(d.calls, [], "--build never asked of it")
    }

    /// Per row: an old master's prompt is Prosper's, a 1.29.2+ master's is dch's.
    @MainActor func testMixedMastersArePerRow() {
        let f = FakeIO(Self.bash3), (c, r) = controller(f), d = FakeDch(c)
        let sentTo = OSAllocatedUnfairLock<[String]>(initialState: []), base = f.io
        c.io = AgentPromptIO(read: base.read, status: base.status,
                             send: { k, digit in sentTo.withLock { $0.append(k.name) }; base.send(k, digit) })
        let old = row(.blocked, master: "1.28.2", name: "old"), new = row(.blocked, master: "1.30.0", name: "new")
        XCTAssertEqual(list(c, old, new), [.working, .working])
        drain(c)
        XCTAssertEqual(sentTo.withLock { $0 }, ["old"], "Prosper answers the old master's row only")
        XCTAssertEqual(d.calls.filter { $0 == ["--config"] }.count, 1, "the new row's check only")
        XCTAssertEqual(c.store?.actions[old.key], AgentIslandController.autoAllowedText)
        XCTAssertNil(c.store?.actions[new.key])
        XCTAssertEqual(c.published([old, new]).map(\.state), [.working, .working], "both held")
        _ = r
    }

    // MARK: - #792 INFO-4 (QA #614): the --build cache and the wait's re-check

    /// INFO-3: a timed-out --build is not asked again inside `dchBuildRetry` (Prosper answers
    /// meanwhile, no 12 s poll stall per stretch); past it, it is.
    @MainActor func testATimedOutBuildIsAskedAgainOnlyAfterTheRetryWindow() {
        let f = FakeIO(Self.bash3), (c, r) = controller(f), d = FakeDch(c)
        d.build = nil
        list(c, row(.blocked))
        drain(c)
        XCTAssertEqual(d.calls, [["--build"]])
        XCTAssertEqual(f.sends, ["1"], "timed out: Prosper answers")
        list(c, row(.working))
        r.now += AgentIslandController.dchBuildRetry - 1
        list(c, row(.blocked))
        drain(c)
        XCTAssertEqual(d.calls, [["--build"]], "inside the window: not asked")
        XCTAssertEqual(f.sends, ["1", "1"], "and Prosper answers")
        d.build = "full\n"
        list(c, row(.working))
        r.now += 1
        list(c, row(.blocked))
        drain(c)
        XCTAssertEqual(d.calls, [["--build"], ["--build"], ["--config"]], "past it: asked again")
        XCTAssertEqual(f.sends, ["1", "1"], "dch's now: stood down")
    }

    /// A cached "full" is per installed version: a new dch is asked again, the same one never.
    @MainActor func testANewInstalledVersionAsksBuildAgain() {
        let f = FakeIO(Self.bash3), (c, _) = controller(f), d = FakeDch(c)
        list(c, row(.blocked))
        drain(c)
        list(c, row(.working))
        list(c, row(.blocked))
        drain(c)
        XCTAssertEqual(d.calls, [["--build"], ["--config"], ["--config"]], "same version: cached")
        d.version = [1, 30, 0]
        list(c, row(.working))
        list(c, row(.blocked))
        drain(c)
        XCTAssertEqual(d.calls.suffix(2), [["--build"], ["--config"]], "a new version: asked again")
        XCTAssertEqual(f.sends, [])
    }

    /// The wait ends with dch's auto_allow switched off meanwhile. dch answered (its
    /// auto_allowed moved): the next prompt is checked, the gate is false, Prosper answers it.
    @MainActor func testTheWaitsRecheckAnswersOnceDchsAutoAllowIsOff() {
        let f = FakeIO(Self.bash3), (c, r) = controller(f), d = FakeDch(c)
        list(c, row(.blocked))
        drain(c)
        d.config = "/Users/probe/.config/dch/config\nauto_allow = false\n"
        f.set(Self.otherBash)
        XCTAssertEqual(list(c, row(.blocked, allowed: Self.dchAnswer)), [.working], "still held")
        fire(c, r)
        XCTAssertEqual(d.calls, [["--build"], ["--config"], ["--config"]], "checked again")
        XCTAssertEqual(f.sends, ["1"], "Prosper answers the next prompt")
        XCTAssertFalse(r.everBlocked)
    }

    /// No answer from dch, auto_allow switched off: the wait's end is the human's as designed (the
    /// gate is not asked); the prompt it showed stays the human's at the next print (#791).
    @MainActor func testTheWaitsEndWithNoAnswerIsTheHumansEvenWithDchsAutoAllowOff() {
        let f = FakeIO(Self.bash3), (c, r) = controller(f), d = FakeDch(c)
        list(c, row(.blocked))
        drain(c)
        d.config = "/Users/probe/.config/dch/config\nauto_allow = false\n"
        fire(c, r)
        XCTAssertEqual(r.lastState, .blocked, "Needs input")
        XCTAssertEqual(d.calls.count, 2)
        r.now += AgentPollGate.floor
        list(c, row(.blocked, activity: 2))
        drain(c)
        XCTAssertEqual(f.reads, 1, "read once")
        XCTAssertEqual(d.calls.count, 2, "no gate: that prompt is the human's")
        XCTAssertEqual(f.sends, [])
        XCTAssertEqual(c.published(c.store?.sessions ?? []).map(\.state), [.blocked])
    }

    // MARK: - #791: a different prompt replacing the one left to the human

    /// A row's print, `floor` after the last: one list with the new activity, its re-read and check.
    @MainActor private func printed(_ c: AgentIslandController, _ r: Rec, _ activity: TimeInterval) {
        r.now += AgentPollGate.floor
        tick(c, .blocked, activity: activity)
        drain(c)   // the re-read
        drain(c)   // a check it started
    }

    /// The operator's case: the first prompt (a hook's) goes to the human; the subagent's next
    /// prompt, queued behind it, replaces it while the row stays blocked, and gets Yes.
    @MainActor func testAPromptQueuedBehindOneLeftToTheHumanGetsYes() {
        let f = FakeIO(Self.subagentBash()), (c, r) = controller(f)
        tick(c, .blocked)
        drain(c)
        XCTAssertEqual(r.lastState, .blocked, "the first prompt is the human's")
        XCTAssertEqual(f.reads, 1)
        f.set(Self.subagentBash(hook: nil))
        XCTAssertEqual(tick(c, .blocked, activity: 2), .blocked, "inside the floor: not read yet")
        XCTAssertEqual(f.reads, 1)
        XCTAssertEqual(r.timers.count, 1, "a timer covers the print")
        r.now += AgentPollGate.floor
        fire(c, r)   // the re-read: a different prompt
        drain(c)     // its check, on that screen
        XCTAssertEqual(f.sends, ["1"])
        XCTAssertEqual(f.reads, 3, "the re-read, then the #475 identity re-read")
        XCTAssertEqual(c.store?.actions[key], AgentIslandController.autoAllowedText)
        XCTAssertEqual(c.published(c.store?.sessions ?? []).first?.state, .working, "answered: held")
    }

    /// A print while the first check runs (a prompt still rendering) is read once that check
    /// leaves it to the human, with no further list change needed.
    @MainActor func testAPrintDuringTheCheckIsReadAfterIt() {
        let f = FakeIO(Self.neverAnswered[0].1, Self.subagentBash(hook: nil)), (c, r) = controller(f)
        tick(c, .blocked)   // its read sees the first screen, every later read the second
        tick(c, .blocked, activity: 2)   // still being checked: nothing yet
        drain(c)
        XCTAssertEqual(f.reads, 1)
        XCTAssertEqual(r.timers.count, 1, "the print is due a read")
        r.now += AgentPollGate.floor
        fire(c, r)
        drain(c)
        XCTAssertEqual(f.sends, ["1"], "the prompt it rendered into gets Yes")
    }

    /// Review round 1: a re-read whose blocked stretch ended while it was in flight is dropped
    /// (no check, no state, nothing sent); the next stretch gets a fresh check of its own.
    @MainActor func testAStaleRereadIsDropped() {
        let f = FakeIO(Self.neverAnswered[0].1), (c, r) = controller(f)
        tick(c, .blocked)
        drain(c)
        let hold = DispatchSemaphore(value: 0)
        f.lock.withLock { f.gate = hold }
        f.set(Self.bash2)   // a different, plain prompt: what the held read returns
        r.now += AgentPollGate.floor
        tick(c, .blocked, activity: 2)   // the re-read, held inside the fake read
        XCTAssertEqual(tick(c, .working, activity: 2), .working, "the stretch ends meanwhile")
        hold.signal()
        drain(c)
        drain(c)
        XCTAssertEqual(f.sends, [])
        XCTAssertEqual(f.reads, 2, "the held re-read only: no check started")
        XCTAssertEqual(c.published([session(.blocked, activity: 2)]).first?.state, .blocked, "no state left for the row")
        tick(c, .blocked, activity: 3)
        drain(c)
        XCTAssertEqual(f.reads, 4, "a fresh check: its read, then the #475 re-read")
        XCTAssertEqual(f.sends, ["1"])
    }

    /// Blocked, not blocked and blocked again before the held re-read returns: the stale read is
    /// dropped and the new stretch's own check answers, once.
    @MainActor func testAStaleRereadAcrossARestartedStretchAnswersOnce() {
        let f = FakeIO(Self.neverAnswered[0].1), (c, r) = controller(f)
        tick(c, .blocked)
        drain(c)
        let hold = DispatchSemaphore(value: 0)
        f.lock.withLock { f.gate = hold }
        f.set(Self.bash2)
        r.now += AgentPollGate.floor
        tick(c, .blocked, activity: 2)   // the re-read, held
        tick(c, .working, activity: 2)
        XCTAssertEqual(tick(c, .blocked, activity: 3), .working, "a new stretch: held while its check queues")
        hold.signal()
        drain(c)
        drain(c)
        XCTAssertEqual(f.sends, ["1"], "answered once, by the new stretch's check")
        XCTAssertEqual(f.reads, 4, "the held re-read, the check's read, the #475 re-read")
    }

    /// Review round 1 (QA #581: off reads nothing): a row left to the human, the setting turned off
    /// with no autoAllowChanged, then a print on the collapsed path: no --read, nothing sent.
    @MainActor func testOffReadsNothingOnACollapsedPrint() {
        final class Rows: @unchecked Sendable {
            let lock = NSLock(); var rows: [AgentSession] = []
            func get() -> [AgentSession] { lock.withLock { rows } }
            func set(_ r: [AgentSession]) { lock.withLock { rows = r } }
        }
        func touch(_ dir: URL, _ name: String, mtime: TimeInterval) {
            let path = dir.appendingPathComponent(name).path
            FileManager.default.createFile(atPath: path, contents: nil)
            try? FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: mtime)], ofItemAtPath: path)
        }
        let dir = tempDir(), path = dir.path, rows = Rows(), k = AgentSessionKey(dir: path, name: "s")
        let t0 = Date().timeIntervalSince1970.rounded(.down)
        touch(dir, "s.sock", mtime: t0 - 60)
        touch(dir, "s.sock.act", mtime: t0 - 30)
        rows.set([AgentSession(key: k, alias: "", activity: 0, state: .blocked, agents: 0)])
        let f = FakeIO(Self.subagentBash()), c = AgentIslandController(), r = Rec()
        let on = OSAllocatedUnfairLock(initialState: true)
        c.io = f.io
        c.showsPanel = false
        c.center = NotificationCenter()
        c.touchFonts = {}
        c.autoAllowOn = { on.withLock { $0 } }
        c.now = { r.now }
        c.monitorClicks = { _ in nil }
        c.currentGeometry = { Self.geometry }
        c.makePoller = { AgentIslandPoller(dirs: { [path] }, list: { _, _ in rows.get() }) }
        addTeardownBlock { @MainActor in c.extLive = false; c.reload() }
        c.extLive = true
        c.reload()
        func waitUntil(_ what: String, _ ok: () -> Bool) {
            let deadline = Date().addingTimeInterval(10)
            while !ok(), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
            XCTAssertTrue(ok(), what)
        }
        waitUntil("the first prompt is the human's") { f.lock.withLock { f.reads } == 1 && c.published(c.store?.sessions ?? []).first?.state == .blocked }
        on.withLock { $0 = false }   // Settings off, no autoAllowChanged
        r.now += 60                  // past the floor: a re-read would start at once
        f.set(Self.subagentBash(hook: nil))
        touch(dir, "s.sock.act", mtime: t0 - 20)
        waitUntil("the print went the collapsed way") { c.deferred?.first?.activity == t0 - 20 }
        c.queue.sync {}
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(f.lock.withLock { f.reads }, 1, "off: nothing read")
        XCTAssertEqual(f.lock.withLock { f.sends }, [])
    }

    /// The prompt left to the human is never answered, however long it stays up and prints:
    /// here one the loop guard left (Prosper's Yes did not take), past the loop window.
    @MainActor func testThePromptLeftToTheHumanIsNeverAnswered() {
        let f = FakeIO(Self.bash3), (c, r) = controller(f)
        tick(c, .blocked)
        drain(c)
        XCTAssertEqual(f.sends, ["1"])
        r.now += AgentIslandController.verifyDelay
        fire(c, r)   // the same prompt back: the loop guard's, the human's
        XCTAssertEqual(r.lastState, .blocked)
        r.now += AgentIslandController.loopWindow
        for a in 2...6 { printed(c, r, TimeInterval(a)) }
        XCTAssertEqual(f.sends, ["1"], "never answered again")
        XCTAssertEqual(r.lastState, .blocked)
        XCTAssertEqual(c.published(c.store?.sessions ?? []).first?.state, .blocked)
    }

    /// The countdown ticking under a prompt left to the human is that prompt: one read per
    /// print, no check (no gate fork, no second read, no send).
    @MainActor func testACountdownTickIsNotADifferentPrompt() {
        let screen = { (t: String) in Self.subagentBash(hook: Self.hookBlock + [Self.countdown(t)]) }
        let f = FakeIO(screen("1:35")), (c, r) = controller(f), d = FakeDch(c)
        d.config = "/Users/probe/.config/dch/config\nauto_allow = false\n"
        list(c, row(.blocked))
        drain(c)
        XCTAssertEqual(r.lastState, .blocked)
        XCTAssertEqual(d.calls, [["--build"], ["--config"]])
        for (n, t) in ["1:33", "1:31", "1:29"].enumerated() {
            f.set(screen(t))
            r.now += AgentPollGate.floor
            list(c, row(.blocked, activity: TimeInterval(2 + n)))
            drain(c)
            drain(c)
        }
        XCTAssertEqual(f.reads, 4, "one read per print")
        XCTAssertEqual(d.calls.count, 2, "no check")
        XCTAssertEqual(f.sends, [])
        XCTAssertEqual(r.lastState, .blocked)
    }

    /// A hook's prompt queued second is checked and refused (#790), then is the human's.
    @MainActor func testAHookPromptQueuedSecondIsRefused() {
        let f = FakeIO(Self.neverAnswered[0].1), (c, r) = controller(f)
        tick(c, .blocked)
        drain(c)
        f.set(Self.subagentBash())
        printed(c, r, 2)
        XCTAssertEqual(f.sends, [])
        XCTAssertEqual(f.reads, 2, "the re-read; the check decides on that screen")
        XCTAssertEqual(r.lastState, .blocked, "the human's again")
        printed(c, r, 3)
        XCTAssertEqual(f.reads, 3, "now the prompt left to the human: read, not checked")
        XCTAssertEqual(f.sends, [])
    }

    /// A row dch's auto-allow answers: left to the human after the wait (nothing read), its
    /// first re-read only learns the prompt; a different one stands down again.
    @MainActor func testADchGatedRowStandsDownOnTheRecheck() {
        let f = FakeIO(Self.bash3), (c, r) = controller(f), d = FakeDch(c)
        list(c, row(.blocked))
        drain(c)
        fire(c, r)   // no answer from dch: the human's
        XCTAssertEqual(r.lastState, .blocked)
        XCTAssertEqual(f.reads, 0)
        r.now += AgentPollGate.floor
        list(c, row(.blocked, activity: 2))
        drain(c)
        drain(c)
        XCTAssertEqual(f.reads, 1)
        XCTAssertEqual(f.sends, [], "the prompt the human was given: never checked")
        XCTAssertEqual(d.calls.count, 2)
        f.set(Self.otherBash)
        r.now += AgentPollGate.floor
        list(c, row(.blocked, activity: 3))
        drain(c)
        drain(c)
        XCTAssertEqual(d.calls, [["--build"], ["--config"], ["--config"]], "the gate, again")
        XCTAssertEqual(f.sends, [], "dch's: stood down")
        XCTAssertEqual(c.published(c.store?.sessions ?? []).map(\.state), [.working], "held for dch's answer")
        XCTAssertEqual(r.timers.count, 1, "the wait")
        fire(c, r)
        XCTAssertEqual(r.lastState, .blocked)
        XCTAssertEqual(f.sends, [])
    }

    /// The fork budget: a row left to the human that does not print forks nothing; one that
    /// prints every second (a countdown) is read once per poll floor, 30 reads a minute.
    @MainActor func testTheRecheckForkBudget() {
        let f = FakeIO(Self.subagentBash()), (c, r) = controller(f)
        tick(c, .blocked)
        drain(c)
        for _ in 0..<60 {
            r.now += 1
            tick(c, .blocked)
            fire(c, r)
        }
        XCTAssertEqual(f.reads, 1, "a still row: no fork")
        XCTAssertTrue(r.timers.isEmpty)
        for s in 1...60 {
            r.now += 1
            tick(c, .blocked, activity: TimeInterval(1 + s))
            fire(c, r)
        }
        XCTAssertEqual(f.reads, 1 + 30, "printing every second: one read per floor")
        XCTAssertEqual(f.sends, [])
    }

    /// Collapsed, a print is a list where only the activity moved, held back from the view
    /// (#768): the re-check runs from there too. Real poller over sidecar files, fake dch IO.
    @MainActor func testARecheckRunsWhileCollapsed() {
        final class Rows: @unchecked Sendable {
            let lock = NSLock(); var rows: [AgentSession] = []
            func get() -> [AgentSession] { lock.withLock { rows } }
            func set(_ r: [AgentSession]) { lock.withLock { rows = r } }
        }
        func touch(_ dir: URL, _ name: String, mtime: TimeInterval) {
            let path = dir.appendingPathComponent(name).path
            FileManager.default.createFile(atPath: path, contents: nil)
            try? FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: mtime)], ofItemAtPath: path)
        }
        let dir = tempDir(), path = dir.path, rows = Rows(), k = AgentSessionKey(dir: path, name: "s")
        let t0 = Date().timeIntervalSince1970.rounded(.down)
        touch(dir, "s.sock", mtime: t0 - 60)
        touch(dir, "s.sock.act", mtime: t0 - 30)
        rows.set([AgentSession(key: k, alias: "", activity: 0, state: .blocked, agents: 0)])
        let f = FakeIO(Self.subagentBash()), c = AgentIslandController()
        c.io = f.io
        c.showsPanel = false
        c.center = NotificationCenter()
        c.touchFonts = {}
        c.autoAllowOn = { true }
        c.monitorClicks = { _ in nil }
        c.currentGeometry = { Self.geometry }
        c.makePoller = { AgentIslandPoller(dirs: { [path] }, list: { _, _ in rows.get() }) }
        addTeardownBlock { @MainActor in c.extLive = false; c.reload() }
        c.extLive = true
        c.reload()
        func waitUntil(_ what: String, _ ok: () -> Bool) {
            let deadline = Date().addingTimeInterval(10)
            while !ok(), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
            XCTAssertTrue(ok(), what)
        }
        waitUntil("the first prompt is the human's") { f.lock.withLock { f.reads } == 1 && c.published(c.store?.sessions ?? []).first?.state == .blocked }
        f.set(Self.subagentBash(hook: nil))
        touch(dir, "s.sock.act", mtime: t0 - 20)
        waitUntil("the queued prompt gets Yes") { f.lock.withLock { f.sends } == ["1"] }
        XCTAssertEqual(c.store?.expanded, false)
        XCTAssertEqual(c.store?.sessions.first?.activity, t0 - 30, "collapsed: held back, the store untouched")
        XCTAssertEqual(c.deferred?.first?.activity, t0 - 20)
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
