import XCTest
@testable import ProsperApp

// #2000: Codex 0.167's approval overlay on the island card. Screens are dch v1.185.0's
// tests/detect_codex_test.py rows (strings of openai/codex rust-v0.167.2) and tests/fake_codex_tui.py's dialog.

private let foot = "  Press enter to confirm or esc to cancel"

private let execScreen = """
  Would you like to run the following command?

  Reason: clean the build directory

  $ rm -rf build

› 1. Yes, proceed (y)
  2. Yes, and don't ask again for this command in this session (a)
  3. No, and tell Codex what to do differently (esc)

""" + foot

private let patchScreen = """
  Would you like to make the following edits?

  Destination: src/main.rs

› 1. Yes, proceed (y)
  2. Yes, and don't ask again for these files (a)
  3. No, and tell Codex what to do differently (esc)

""" + foot

private let networkScreen = """
  Do you want to approve network access to "example.com"?

  Reason: fetch the crate index

› 1. Yes, just this once (y)
  2. Yes, and allow this host for this conversation (a)
  3. No, and block this host in the future (d)

""" + foot

private let pagerLikeScreen = """
• The pager footer reads pgup/pgdn/⌃b/⌃f page  q close at its bottom.
  Would you like to run the following command?
  $ rm -rf build
› 1. Yes, proceed (y)
  2. No, and tell Codex what to do differently (esc)

""" + foot

/// tests/fake_codex_tui.py, mode "dialog".
private let fakeTUIScreen = [">_ OpenAI Codex (v0.167.2)", "", "Would you like to run the following command?", "",
                             "$ rm -rf build", "", "› 1. Yes, proceed (y)",
                             "  2. No, and tell Codex what to do differently (esc)", "",
                             "  Press enter to confirm or esc to cancel"].joined(separator: "\n")

/// Every other option-bearing or blocked-looking Codex row of detect_codex_test.py: no answer buttons.
private let contextScreens: [(String, String)] = [
    ("cross-thread approval footer", """
  Thread: worker [explorer]
  Would you like to run the following command?
  $ cargo test
› 1. Yes, proceed (y)

  Press enter to confirm or esc to cancel or o to open thread
"""),
    ("MCP elicitation form", """
  Field 1/1
  Allow this request?
› 1. Allow   Run the tool and continue
  2. Allow for this session
  3. Always allow
  4. Cancel  Cancel this tool call

  enter to submit | esc to cancel
"""),
    ("request_user_input last question", """
  Which database should the service use?
› 1. Postgres
  2. SQLite
  Type your answer (optional)

  tab to add notes | enter to submit all | esc to interrupt
"""),
    ("trust this folder", """
  Folder access
  /work/project
  Trust this folder? Codex can read, edit, and run files here, subject to your permission settings.
› 1. Trust and continue
  2. Quit
  enter continue and create sandbox · esc quit
"""),
    ("hooks need review", """
  Hooks need review
  2 hooks are new or changed.
  Hooks can run outside the sandbox after you trust them.
› 1. Review hooks
  2. Trust all and continue
  3. Continue without trusting (hooks won't run)
  enter confirm · esc skip
"""),
    ("resume cwd picker", """
  Working directory · Resume
› 1. Use session directory (/work/a)
  2. Use current directory (/work/b)
  3. Always use session directory
  4. Always use current directory
"""),
    ("approval footer quoted mid-line", """
• The overlay says Press enter to confirm or esc to cancel at the bottom.
• The form says enter to submit | esc to cancel there.

› Ask Codex to do anything
  ? for shortcuts                                       100% context left
"""),
    ("transcript pager replays an approval", """
  Would you like to run the following command?
  $ rm -rf build
  Press enter to confirm or esc to cancel
  ↑/↓ scroll  pgup/pgdn/⌃b/⌃f/⌃u/⌃d page  q close
"""),
    ("dialog phrases quoted above the composer", """
• Codex asks before it runs anything in a new folder:
  Press enter to confirm or esc to cancel at the bottom.

› Ask Codex to do anything
  ? for shortcuts                                       100% context left
"""),
    ("busy row", "• Working (12s • esc to interrupt)\n\n› Ask Codex to do anything"),
    ("idle composer", "• Done.\n\n› Ask Codex to do anything\n  ? for shortcuts      100% context left"),
]

final class AgentIslandCodexPromptTests: XCTestCase {
    private struct NoPrompt: Error {}

    private func codexPrompt(_ screen: String, file: StaticString = #filePath, line: UInt = #line) throws -> AgentPrompt {
        guard case .prompt(let p) = AgentPrompt.card(screen: screen) else {
            XCTFail("no Codex prompt", file: file, line: line)
            throw NoPrompt()
        }
        return p
    }

    func testCodexApprovalsGetOptionsWithTheirShortcutKeys() throws {
        let exec = try codexPrompt(execScreen)
        XCTAssertTrue(exec.codex)
        XCTAssertEqual(exec.question, "Would you like to run the following command?")
        XCTAssertEqual(exec.context, ["Reason: clean the build directory", "", "$ rm -rf build"])
        XCTAssertEqual(exec.options.map(\.label), ["Yes, proceed",
                                                   "Yes, and don't ask again for this command in this session",
                                                   "No, and tell Codex what to do differently"], "the (y) suffix is off")
        XCTAssertEqual(exec.options.map(\.hint), ["y", "a", "esc"], "shown as the key chip")
        XCTAssertEqual(exec.options.map(\.codexKey), ["y", "a", nil], "Esc is never a key to type")
        XCTAssertEqual(exec.options.map(\.digit), [1, 2, 3])
        XCTAssertTrue(exec.topFound)

        let patch = try codexPrompt(patchScreen)
        XCTAssertEqual(patch.question, "Would you like to make the following edits?")
        XCTAssertEqual(patch.context, ["Destination: src/main.rs"])
        XCTAssertEqual(patch.options.map(\.codexKey), ["y", "a", nil])

        let net = try codexPrompt(networkScreen)
        XCTAssertEqual(net.question, "Do you want to approve network access to \"example.com\"?")
        XCTAssertEqual(net.context, ["Reason: fetch the crate index"])
        XCTAssertEqual(net.options.map(\.label).last, "No, and block this host in the future")
        XCTAssertEqual(net.options.map(\.codexKey), ["y", "a", "d"])

        let pager = try codexPrompt(pagerLikeScreen)
        XCTAssertEqual(pager.context, ["$ rm -rf build"], "transcript above the title is not the overlay")
        XCTAssertEqual(pager.options.map(\.codexKey), ["y", nil])

        let fake = try codexPrompt(fakeTUIScreen)
        XCTAssertEqual(fake.context, ["$ rm -rf build"], "the banner above the title is not the overlay")
        XCTAssertEqual(fake.options.map(\.label), ["Yes, proceed", "No, and tell Codex what to do differently"])
    }

    func testEveryOtherCodexScreenKeepsTheContextCard() {
        for (name, screen) in contextScreens {
            XCTAssertTrue(AgentPrompt.codex(screen) == nil, name)
            XCTAssertEqual(AgentPrompt.card(screen: screen), .context(AgentPrompt.tail(screen)), name)
        }
    }

    func testUncertainCodexOverlaysKeepTheContextCard() {
        let variants = [
            ("no caret", execScreen.replacingOccurrences(of: "› 1.", with: "  1.")),
            ("two carets", execScreen.replacingOccurrences(of: "  2. Yes", with: "› 2. Yes")),
            ("an option with no shortcut", execScreen.replacingOccurrences(of: " (a)", with: "")),
            ("an upper-case shortcut", execScreen.replacingOccurrences(of: "(a)", with: "(A)")),
            ("a wrapped option", execScreen.replacingOccurrences(of: "in this session (a)", with: "in this\n     session (a)")),
            ("digits out of order", execScreen.replacingOccurrences(of: "  3. No", with: "  4. No")),
            ("an unknown title", execScreen.replacingOccurrences(of: "run the following command?", with: "do this?")),
            ("the composer under it", execScreen + "\n\n› Ask Codex to do anything"),
            ("a command row that reads like the title",
             execScreen.replacingOccurrences(of: "  $ rm -rf build",
                                             with: "  $ echo\n  Would you like to run the following command?")),
        ]
        for (name, screen) in variants {
            XCTAssertTrue(AgentPrompt.codex(screen) == nil, name)
            guard case .context = AgentPrompt.card(screen: screen) else { XCTFail(name); continue }
        }
    }

    func testClaudeScreensNeverTakeTheCodexParse() {
        // AgentIslandPromptTests' bashScreen (the #475 probe session).
        let claude = """
        ──────────────────────────────────────────────────────────────────────────────────────────
         Bash command

           rm -rf .build && swift build -c release
           Clean and rebuild the release products

         Do you want to proceed?
         ❯ 1. Yes
           2. Yes, and don't ask again for rm commands in /Users/example/proj
           3. No, and tell Claude what to do differently (esc)
        """
        XCTAssertTrue(AgentPrompt.codex(claude) == nil)
        guard case .prompt(let p) = AgentPrompt.card(screen: claude) else { return XCTFail("Claude's card") }
        XCTAssertFalse(p.codex)
        XCTAssertTrue(AgentPrompt.option("› 1. Yes") == nil, "Claude's option parse still takes only ❯")
    }

    // MARK: - Answer

    private final class FakeDch: @unchecked Sendable {
        var screen = execScreen
        var status = "blocked\n"
        var sent: [String] = []
        var reads = 0
        let key = AgentSessionKey(dir: "/d", name: "api")
        var io: AgentPromptIO {
            AgentPromptIO(read: { [self] _ in reads += 1; return screen }, status: { [self] _ in status },
                          send: { [self] in XCTAssertEqual($0, key); sent.append($1) })
        }
        func answer(_ digit: Int, expected: AgentPrompt) -> AgentPromptAnswer {
            AgentPrompt.answer(key, digit: digit, expected: expected, io: io)
        }
    }

    func testCodexAnswerTypesTheShortcutLetterNeverTheDigit() throws {
        let f = FakeDch(), p = try codexPrompt(execScreen)
        XCTAssertEqual(p.options.count, 3)
        XCTAssertTrue(p.options.prefix(2).allSatisfy(p.isEnabled), "the y and a options are on")
        XCTAssertEqual(f.answer(1, expected: p), .sent)
        XCTAssertEqual(f.answer(2, expected: p), .sent)
        XCTAssertEqual(f.sent, ["y", "a"], "the shortcut letter, no Enter, never the digit")
        XCTAssertEqual(f.reads, 2, "re-read at each click")

        let n = FakeDch()
        n.screen = networkScreen
        XCTAssertEqual(n.answer(3, expected: try codexPrompt(networkScreen)), .sent)
        XCTAssertEqual(n.sent, ["d"], "a decline with a letter is answered")
    }

    func testCodexEscOptionIsOffAndSendsNothing() throws {
        let f = FakeDch(), p = try codexPrompt(execScreen)
        let no = try XCTUnwrap(p.options.last)
        XCTAssertFalse(p.isEnabled(no), "Esc is never typed into Codex")
        XCTAssertEqual(f.answer(3, expected: p), .changed)
        XCTAssertEqual(f.sent, [])
        XCTAssertEqual(f.reads, 0, "refused before any dch call")
    }

    func testChangedCodexScreenSendsNothing() throws {
        let f = FakeDch(), p = try codexPrompt(execScreen)
        f.screen = execScreen.replacingOccurrences(of: "rm -rf build", with: "rm -rf src")
        XCTAssertEqual(f.answer(1, expected: p), .changed, "another command")
        f.screen = "• Done.\n\n› Ask Codex to do anything"
        XCTAssertEqual(f.answer(1, expected: p), .changed, "the overlay is gone")
        f.screen = execScreen
        f.status = "working\n"
        XCTAssertEqual(f.answer(1, expected: p), .changed, "dch no longer says blocked")
        XCTAssertEqual(f.sent, [])
        XCTAssertEqual(AgentPrompt.card(screen: f.screen), .prompt(p), "the re-read is the Codex parse")
    }
}
