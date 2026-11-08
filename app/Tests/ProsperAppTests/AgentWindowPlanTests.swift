import XCTest
@testable import ProsperApp

// #802: the plan approval fixture, kept with AgentWindowInteractionTests' other forms (its FormSim draws it).
extension AgentWindowInteractionTests {
    /// Round 3: the plan file of #819's live Claude Code 2.1.318 capture, byte for byte (Claude Code
    /// writes the plan to ~/.claude/plans/<slug>.md; the ExitPlanMode call's input is `{}`).
    static let planMarkdown = """
    ## Steps

    - Create hello.txt in the working directory
    - Verify its contents

    1. Run the command below to create the file
    2. Confirm hello.txt contains "hi"

    ```bash
    echo hi > hello.txt
    ```

    See the [docs](https://example.com) for details.

    | File | Purpose |
    |------|---------|
    | hello.txt | greeting |

    """
    /// A call that carries its plan in its input (older builds): no file read.
    static let planInput = AgentPlanInput(id: "toolu_p", plan: planMarkdown)

    /// The plan as the live dialog drew it (capture 02, text at column 3): heading markers gone,
    /// "-" bullets kept, no fence, a link as "text (url)", the table box-drawn.
    static let planShown = ["Steps", "", "- Create hello.txt in the working directory", "- Verify its contents", "",
                            "1. Run the command below to create the file", "2. Confirm hello.txt contains \"hi\"", "",
                            "echo hi > hello.txt", "", "See the docs (https://example.com) for details.", "",
                            "┌───────────┬──────────┐", "│   File    │ Purpose  │", "├───────────┼──────────┤",
                            "│ hello.txt │ greeting │", "└───────────┴──────────┘"]

    /// The live rows (auto mode on); the last is the feedback input row.
    static let planRows = ["Yes, and use auto mode", "Yes, manually approve edits", "Tell Claude what to change"]
    /// The rows with "showClearContextOnPlanAccept" on, in acceptEdits order (synthetic, from the bundle).
    static let planRowsClear = ["Yes, clear context (31% used) and auto-accept edits", "Yes, auto-accept edits",
                                "Yes, manually approve edits", "No, keep planning"]
    /// The live footer, the plan file's name scrubbed.
    static let planFooter = "ctrl+g to edit in VS Code · ~/.claude/plans/example-plan.md"

    /// Claude Code 2.1.318's plan approval as #819 captured it (100x40, captures 02/03/04): the
    /// "/plan to preview" line and the "▔" edge above, rules at column 2 and 96 wide, text at
    /// column 3, options at column 3 ("❯ " on the caret's), the hint at column 8, the footer last.
    /// `feedback`: what the last (input) row shows instead of its label once typed into.
    static func planScreen(caret: Int, rows: [String] = planRows, plan: [String] = planShown, feedback: String = "",
                           footer: String? = planFooter) -> String {
        let rule = "  " + String(repeating: "─", count: 96), dashed = "  " + String(repeating: "╌", count: 96)
        var l = ["", "  ⎿ \u{00A0}/plan to preview", String(repeating: "▔", count: 100), "", rule, "   Ready to code?", "",
                 "   Here is Claude's plan:", dashed] + plan.map { $0.isEmpty ? "" : "   " + $0 }
            + [dashed, "", "", "", "", rule, "   Claude has written up a plan and is ready to execute. Would you like to proceed?", ""]
        for (i, r) in rows.enumerated() {
            let last = i == rows.count - 1
            l.append((caret == i + 1 ? "   ❯ " : "     ") + "\(i + 1). " + (last && !feedback.isEmpty ? feedback : r))
            if last { l.append("        shift+tab to approve with this feedback") }
        }
        // nil: no editor detected, so Claude Code draws no footer (bundle read, round 4).
        if let footer { l += ["", "   " + footer] }
        return l.joined(separator: "\n")
    }
}

/// #802: plan approval (ExitPlanMode), the multi-select Other answer and "Chat about this" in
/// the Agents window. Every dch call is a fake (AgentWindowInteractionTests.FormSim); nothing
/// reads a real screen or sends a key to a real session.
final class AgentWindowPlanTests: XCTestCase {
    typealias T = AgentWindowInteractionTests
    typealias FormSim = AgentWindowInteractionTests.FormSim
    let t = AgentWindowInteractionTests()
    /// A test that expected a prompt panel errors (fails) with what it got.
    struct NotAPrompt: Error { let panel: String }

    func driver(_ io: AgentPromptIO) -> AgentWindowDriver { t.driver(io) }
    func screen(_ text: String) throws -> AgentPromptScreen { try XCTUnwrap(AgentPrompt.screen(text)) }

    @MainActor
    func prompt(_ text: String, ask: AgentAskInput? = nil, plan: AgentPlanInput?) throws -> AgentWindowPrompt {
        guard case .prompt(let w) = AgentWindowPanel.classify(text, ask: ask, plan: plan) else {
            throw NotAPrompt(panel: "\(AgentWindowPanel.classify(text, ask: ask, plan: plan))")
        }
        return w
    }

    // MARK: - Plan approval: reading and checking

    @MainActor
    func testAgentWindowPlanApprovalOffersOnlyTheCheckedApproveRows() throws {
        let input: [String: Any] = ["plan": T.planMarkdown, "planFilePath": "/tmp/example-plan.md"]
        XCTAssertEqual(AgentPlanInput.parse(input, id: "toolu_p"), T.planInput)
        XCTAssertEqual(AgentPlanInput.parse(input, id: "toolu_p", file: "/x/a.md"), T.planInput, "the call's own plan first")
        XCTAssertNil(AgentPlanInput.parse([:], id: "t"))
        XCTAssertNil(AgentPlanInput.parse(["plan": ""], id: "t"))
        XCTAssertNil(AgentPlanInput.parse(["plan": 3], id: "t"))
        XCTAssertEqual(AgentPlanInput.parse([:], id: "t", file: "/x/a.md"), AgentPlanInput(id: "t", plan: nil, file: "/x/a.md"),
                       "Claude Code 2.1.318's {} input: the plan file")
        // Claude Code draws no "Esc to cancel" under a plan: its ctrl+g line is the footer.
        XCTAssertTrue(AgentPrompt.isFooter(" ctrl+g to edit in VS Code · ~/.claude/plans/example-plan.md"))
        XCTAssertTrue(AgentPrompt.isFooter("ctrl+g to edit in Vim · ~/.claude/plans/a.md · ✓ Plan saved!"))
        // Round 4: only the plan footer. The composer's bare hint, a non-.md path, another suffix are not.
        for line in ["ctrl+g to edit in VS Code", "   ctrl+g to edit in VS Code", "ctrl+g to edit in  · ~/.claude/plans/a.md",
                     "ctrl+g to edit in VS Code · notes.txt", "ctrl+g to edit in VS Code · ~/.claude/plans/a.md · ✔ Plan saved!",
                     "ctrl+g to edit in VS Code · ~/.claude/plans/a.md · Esc", "ctrl+g to edit in VS Code · a.md · b.md · ✓ Plan saved!"] {
            XCTAssertFalse(AgentPrompt.isFooter(line), line)
        }
        XCTAssertNotNil(AgentPrompt.parse(T.planScreen(caret: 1)), "the island reads it too")

        let s = try screen(T.planScreen(caret: 1))
        XCTAssertEqual(s.caret, 1)
        XCTAssertEqual(s.footer, T.planFooter)
        XCTAssertTrue(s.prompt.topFound, "round 3: the top rule at column 2, the title under it, is a frame")
        XCTAssertEqual(s.prompt.options.map(AgentPlanForm.row), [.approve, .approve, .no])
        for caret in [1, 2] {
            let w = try prompt(T.planScreen(caret: caret), plan: T.planInput)
            XCTAssertEqual(w.kind, .choose)
            XCTAssertEqual(w.buttons.map(\.digit), [1, 2, 3], "every row shown")
            XCTAssertEqual(w.approve, [1, 2], "caret \(caret)")
            XCTAssertEqual(w.enabled, [1, 2], "the feedback row stays in the terminal")
            XCTAssertNil(w.why)
            XCTAssertEqual(w.plan, T.planMarkdown, "the window shows the transcript's plan")
            XCTAssertEqual(w.caption, [], "nothing left to the terminal")
        }

        // The clear-context row set: that row is the terminal's; the caret on it is fine (a digit there answers).
        for caret in [1, 2] {
            let c = try prompt(T.planScreen(caret: caret, rows: T.planRowsClear), plan: T.planInput)
            XCTAssertEqual(c.approve, [2, 3], "caret \(caret)")
            XCTAssertEqual(c.caption, [AgentWindowText.planTerminal])
        }
        // Each mode's row set (yyt): auto mode with Ultraplan; bypass (left to the terminal).
        let auto = ["Yes, and use auto mode", "Yes, manually approve edits", "No, refine with Ultraplan in a cloud session",
                    "No, keep planning"]
        XCTAssertEqual(try prompt(T.planScreen(caret: 1, rows: auto), plan: T.planInput).approve, [1, 2])
        let bypass = ["Yes, and switch to BYPASS PERMISSIONS (no further prompts) for this session",
                      "Yes, manually approve edits", "No, keep planning"]
        XCTAssertEqual(try prompt(T.planScreen(caret: 1, rows: bypass), plan: T.planInput).approve, [2])
        // A narrow pty wraps a row anywhere: matched with whitespace dropped.
        let wrapped = T.planScreen(caret: 1).replacingOccurrences(of: "2. Yes, manually approve edits",
                                                                 with: "2. Yes, manually\n        approve edits")
        XCTAssertEqual(try prompt(wrapped, plan: T.planInput).approve, [1, 2])
        // Approvals withheld (a plan over Claude Code's limit): only the feedback row, which no parse takes.
        let one = T.planScreen(caret: 1, rows: ["Tell Claude what to change"])
        XCTAssertEqual(AgentWindowPanel.classify(one, ask: nil, plan: T.planInput),
                       .terminal(AgentWindowText.unreadable, AgentPrompt.tail(one)))
    }

    /// Every check, failed alone: no approve row, nothing enabled, and why (Open in terminal).
    @MainActor
    func testAgentWindowPlanApprovalFallsBackToTheTerminalOnEveryFailedCheck() throws {
        let ok = T.planScreen(caret: 1)
        // Down to the top rule off the screen: the title is the first row.
        let noTop = ok.split(separator: "\n", omittingEmptySubsequences: false).dropFirst(5).joined(separator: "\n")
        let renamed = ok.replacingOccurrences(of: "Yes, manually approve edits", with: "Yes, approve edits by hand")
        let changed = { (a: String, b: String) in AgentPlanInput(id: "t", plan: T.planMarkdown.replacingOccurrences(of: a, with: b)) }
        let cases: [(String, String, AgentPlanInput?, String)] = [
            ("no transcript plan", ok, nil, AgentWindowText.planUnchecked),
            ("another plan", ok, changed("Verify its contents", "Delete its contents"), AgentWindowText.planMismatch),
            ("only the plan's head on screen", T.planScreen(caret: 1, plan: Array(T.planShown.prefix(4))), T.planInput,
             AgentWindowText.planCut),
            ("a line more on screen", T.planScreen(caret: 1, plan: T.planShown + ["Then delete the tests."]), T.planInput,
             AgentWindowText.planMismatch),
            ("an unknown row", T.planScreen(caret: 1, rows: ["Yes, and use auto mode", "Yes, and push to main",
                                                             "Tell Claude what to change"]),
             T.planInput, AgentWindowText.planRow),
            ("an approve row renamed", renamed, T.planInput, AgentWindowText.planRow),
            ("an approve row on the mode-cycle key",
             ok.replacingOccurrences(of: "2. Yes, manually approve edits", with: "2. Yes, manually approve edits (shift+tab)"),
             T.planInput, AgentWindowText.planRow),
            ("another title", ok.replacingOccurrences(of: "Ready to code?", with: "Ready to ship?"), T.planInput,
             AgentWindowText.planLayout),
            ("a line more above the lead", ok.replacingOccurrences(of: "   Ready to code?\n", with: "   Ready to code?\n   Auto mode is on\n"),
             T.planInput, AgentWindowText.planLayout),
            ("another question", ok.replacingOccurrences(of: "ready to execute", with: "ready to deploy"), T.planInput,
             AgentWindowText.planLayout),
            ("lead and approve rows renamed, the title kept",
             renamed.replacingOccurrences(of: "Yes, and use auto mode", with: "Yes, approve each edit")
                .replacingOccurrences(of: "Here is Claude's plan:", with: "Claude's plan:"),
             T.planInput, AgentWindowText.planLayout),
            ("a hidden character", ok.replacingOccurrences(of: "Verify its contents", with: "Verify\u{202E} its contents"),
             changed("Verify its contents", "Verify\u{202E} its contents"), AgentWindowText.planUnsafe),
            ("the top off the screen", noTop, T.planInput, AgentWindowText.planUnsafe),
            ("the caret on the feedback row", T.planScreen(caret: 3), T.planInput, AgentWindowText.planCaret),
            // A "No, keep planning" feedback row, which the island rule alone would enable.
            ("the caret on a No feedback row", T.planScreen(caret: 4, rows: T.planRowsClear), T.planInput, AgentWindowText.planCaret),
            ("feedback typed", T.planScreen(caret: 3, feedback: "Use a table"), T.planInput, AgentWindowText.planRow),
        ]
        for (name, text, plan, why) in cases {
            let w = try prompt(text, plan: plan)
            XCTAssertEqual(w.why, why, name)
            XCTAssertEqual(w.approve, [], name)
            XCTAssertEqual(w.enabled, [], "\(name): no button at all")
            XCTAssertNil(w.plan, name)
            XCTAssertEqual(w.caption, [], name)
        }
        // Not a plan approval at all: the island card's rule, unchanged.
        let perm = try prompt(T.permission(), plan: T.planInput)
        XCTAssertNil(perm.why)
        XCTAssertEqual(perm.enabled, [1, 2])
    }

    /// Round 2: the island now parses the real plan dialog. Always allow sends nothing on it (directly
    /// and through the controller), and the island card enables no mode-change row. Round 3: with
    /// the live layout's top found, its context (title to the rule above the question) is over the
    /// card's cap even for a one-line plan, so only a "No…" row is on; a short dialog in the older
    /// permission layout pins the mode rule itself.
    @MainActor
    func testAgentWindowPlanApprovalTheIslandAllowsNothingAndEnablesNoModeChange() throws {
        let bypass = ["Yes, and switch to BYPASS PERMISSIONS (no further prompts) for this session",
                      "Yes, manually approve edits", "No, keep planning"]
        for rows in [T.planRows, T.planRowsClear, bypass, ["Yes, and use auto mode", "Yes, manually approve edits", "No, keep planning"]] {
          for plan in [T.planShown, ["Add the parser."]] {
            let text = T.planScreen(caret: 1, rows: rows, plan: plan)
            let p = try XCTUnwrap(AgentPrompt.parse(text), "\(rows)")
            XCTAssertTrue(p.topFound)
            XCTAssertTrue(p.isOverCap, "\(rows), \(plan.count) plan lines")
            XCTAssertNil(p.allowYes, "\(rows)")
            let no = rows.filter { $0.hasPrefix("No,") }
            XCTAssertEqual(p.options.filter { p.isEnabled($0) }.map(\.label), no,
                           "the island card: only a No row (\(rows), \(plan.count) plan lines)")
            let f = FormSim(.plan)
            f.planRows = rows
            f.planLines = plan
            XCTAssertEqual(AgentPrompt.autoAllow(T.key, io: f.io, notAgain: nil, answered: false, isOn: { true }), .human)
            XCTAssertEqual(f.log, [], "\(rows)")
            let g = FormSim(.plan)
            g.planRows = rows
            g.planLines = plan
            let c = t.controller(g.io)
            c.store?.sessions = [t.session(.blocked)]
            c.checkAutoAllow()
            t.until("left to the human") { !c.heldByAutoAllow(T.key) }
            c.queue.sync {}
            XCTAssertEqual(g.log, [], "Always allow on, through the controller (\(rows))")
            XCTAssertFalse(c.heldByAutoAllow(T.key))
          }
          // Under the cap: every Yes row of a plan is a mode change, off by that rule alone.
          let short = try XCTUnwrap(AgentPrompt.parse(T.permission(rows, body: [" Here is Claude's plan:", "   Add the parser."])))
          XCTAssertFalse(short.isOverCap)
          XCTAssertEqual(short.options.filter { short.isEnabled($0) }.map(\.label), rows.filter { !$0.hasPrefix("Yes") }, "\(rows)")
          XCTAssertEqual(short.layout.caption.joined().filter { !$0.isWhitespace },
                         AgentCardLayout.modeCaption.filter { !$0.isWhitespace }, "the mode rule, nothing else (\(rows))")
        }
    }

    /// Round 3 (P2): a rule at column 2 is a frame only right above the plan title. In any other
    /// dialog it stays the dialog's text: the top not found, the lines above it kept.
    func testAgentWindowPlanIndentTwoRuleIsAFrameOnlyAboveThePlanTitle() throws {
        let rule = String(repeating: "─", count: 90), inner = "  " + String(repeating: "─", count: 88)
        func dialog(_ top: String, _ title: String) -> String {
            [top, title, "", "   rm -rf .build", "", " Do you want to proceed?", " ❯ 1. Yes", "   2. No"].joined(separator: "\n")
        }
        XCTAssertFalse(try XCTUnwrap(AgentPrompt.parse(dialog(inner, "   Bash command"))).topFound, "no plan title under it")
        XCTAssertFalse(try XCTUnwrap(AgentPrompt.parse(dialog(inner, "   Ready to ship?"))).topFound)
        XCTAssertTrue(try XCTUnwrap(AgentPrompt.parse(dialog(inner, "   Ready to code?"))).topFound)
        XCTAssertTrue(try XCTUnwrap(AgentPrompt.parse(dialog(rule, "   Bash command"))).topFound, "column 0: as before")
        // Inside a dialog framed at column 0: a column-2 rule is text, its lines above stay context.
        let body = [rule, " Bash command", "", "   echo one", inner, "   echo two", "", " Do you want to proceed?",
                    " ❯ 1. Yes", "   2. No"].joined(separator: "\n")
        let p = try XCTUnwrap(AgentPrompt.parse(body))
        XCTAssertTrue(p.context.contains { $0.contains("echo one") }, "\(p.context)")
        XCTAssertTrue(p.context.contains { $0.contains("Bash command") }, "\(p.context)")
    }

    /// A temp home (no symlink on its way: /var is one, so its real path) holding
    /// .claude/plans/example-plan.md with `text`. Never the real ~/.claude.
    func planHome(_ text: String = T.planMarkdown) throws -> (home: String, file: String) {
        let real = try XCTUnwrap(realpath(tempDir().path, nil))
        defer { free(real) }
        let home = String(cString: real), plans = home + "/.claude/plans"
        XCTAssertFalse(home.hasPrefix(NSHomeDirectory() + "/.claude"))
        try FileManager.default.createDirectory(atPath: plans, withIntermediateDirectories: true)
        let file = plans + "/example-plan.md"
        try Data(text.utf8).write(to: URL(fileURLWithPath: file))
        return (home, file)
    }

    /// Round 3 (P1): Claude Code 2.1.318's ExitPlanMode input is {}; the plan is the file the
    /// transcript names, read at every check and only when the dialog's footer names that file.
    @MainActor
    func testAgentWindowPlanFileIsReadOnlyWhenTheDialogNamesIt() throws {
        let (home, file) = try planHome()
        let input = AgentPlanInput(id: "toolu_p", plan: nil, file: file, home: home)
        for caret in [1, 2] {
            let w = try prompt(T.planScreen(caret: caret), plan: input)
            XCTAssertEqual(w.approve, [1, 2], "caret \(caret)")
            XCTAssertNil(w.why)
            XCTAssertEqual(w.plan, T.planMarkdown, "the file's text")
        }
        XCTAssertEqual(try prompt(T.planScreen(caret: 3), plan: input).why, AgentWindowText.planCaret)
        // The footer may name the file by its absolute path; "." components are dropped.
        XCTAssertEqual(try prompt(T.planScreen(caret: 1, footer: "ctrl+g to edit in Vim · \(file)"), plan: input).approve, [1, 2])
        XCTAssertEqual(try prompt(T.planScreen(caret: 1, footer: "ctrl+g to edit in Vim · ~/.claude/./plans/example-plan.md"),
                                  plan: input).approve, [1, 2])
        // Round 4: " · ✓ Plan saved!" after the path still names the file (the .md segment, not the last).
        XCTAssertEqual(try prompt(T.planScreen(caret: 1, footer: T.planFooter + " · ✓ Plan saved!"), plan: input).approve, [1, 2])
        // Another file with the same text, a ".." on the way, a relative path: no buttons.
        try Data(T.planMarkdown.utf8).write(to: URL(fileURLWithPath: home + "/.claude/plans/other-plan.md"))
        for footer in ["ctrl+g to edit in VS Code · ~/.claude/plans/other-plan.md",
                       "ctrl+g to edit in VS Code · ~/.claude/plans/other-plan.md · ✓ Plan saved!",
                       "ctrl+g to edit in VS Code · ~/.claude/plans/../plans/example-plan.md",
                       "ctrl+g to edit in VS Code · .claude/plans/example-plan.md"] {
            let w = try prompt(T.planScreen(caret: 1, footer: footer), plan: input)
            XCTAssertEqual(w.why, AgentWindowText.planFile, footer)
            XCTAssertEqual(w.approve, [], footer)
        }
        // No path, another suffix, not a .md file, no footer at all: not even a prompt.
        for footer in ["ctrl+g to edit in VS Code", "ctrl+g to edit in VS Code · ~/.claude/plans/example-plan.md · ✔ Plan saved!",
                       "ctrl+g to edit in VS Code · ~/.claude/plans/example-plan.md.bak", nil] {
            let text = T.planScreen(caret: 1, footer: footer)
            XCTAssertEqual(AgentWindowPanel.classify(text, ask: nil, plan: input),
                           .terminal(AgentWindowText.unreadable, AgentPrompt.tail(text)), footer ?? "no footer")
        }
        // The transcript names another file than the footer.
        let other = AgentPlanInput(id: "toolu_p", plan: nil, file: home + "/.claude/plans/other-plan.md", home: home)
        XCTAssertEqual(try prompt(T.planScreen(caret: 1), plan: other).why, AgentWindowText.planFile)
        // Read at every check, never kept: the file edited after a pass fails the next check.
        try Data(T.planMarkdown.replacingOccurrences(of: "Verify its", with: "Delete its").utf8).write(to: URL(fileURLWithPath: file))
        XCTAssertEqual(try prompt(T.planScreen(caret: 1), plan: input).why, AgentWindowText.planMismatch)
        try Data(T.planMarkdown.utf8).write(to: URL(fileURLWithPath: file))
        XCTAssertEqual(try prompt(T.planScreen(caret: 1), plan: input).approve, [1, 2])
        // Gone: no buttons.
        try FileManager.default.removeItem(atPath: file)
        XCTAssertEqual(try prompt(T.planScreen(caret: 1), plan: input).why, AgentWindowText.planFile)
    }

    /// Round 3 (P1): the file read's own rules, each failed alone.
    @MainActor
    func testAgentWindowPlanFileReadRefusesAnythingButASmallRegularFileUnderThePlans() throws {
        let (home, file) = try planHome()
        let plans = home + "/.claude/plans", fm = FileManager.default
        let read = { (p: String) in AgentPlanInput.read(p, root: plans) }
        XCTAssertEqual(read(file), T.planMarkdown)
        XCTAssertEqual(read(plans + "//./example-plan.md"), T.planMarkdown, "standardized")
        try Data("x".utf8).write(to: URL(fileURLWithPath: home + "/.claude/outside.md"))
        XCTAssertNotNil(AgentPlanInput.read(home + "/.claude/outside.md", root: home + "/.claude"), "the file itself is fine")
        XCTAssertNil(read(home + "/.claude/outside.md"), "not under the plans")
        XCTAssertNil(read(plans + "/../outside.md"), "a .. component")
        XCTAssertNil(read(plans + "/../plans/example-plan.md"), "a .. component, even back in")
        XCTAssertNil(read(plans), "the directory itself")
        try fm.createDirectory(atPath: plans + "-evil", withIntermediateDirectories: true)
        try Data("x".utf8).write(to: URL(fileURLWithPath: plans + "-evil/a.md"))
        XCTAssertNil(read(plans + "-evil/a.md"), "a sibling sharing the prefix")
        XCTAssertNil(read(".claude/plans/example-plan.md"), "relative")
        // Symlinks: the file, a directory on the way, the plans root's own parent.
        try fm.createSymbolicLink(atPath: plans + "/link.md", withDestinationPath: file)
        XCTAssertNil(read(plans + "/link.md"), "a symlinked file")
        try fm.createDirectory(atPath: home + "/real", withIntermediateDirectories: true)
        try Data("x".utf8).write(to: URL(fileURLWithPath: home + "/real/a.md"))
        try fm.createSymbolicLink(atPath: plans + "/sub", withDestinationPath: home + "/real")
        XCTAssertNil(read(plans + "/sub/a.md"), "a symlinked directory on the way")
        try fm.createSymbolicLink(atPath: home + "/linked", withDestinationPath: home + "/.claude")
        XCTAssertNil(AgentPlanInput.read(home + "/linked/plans/example-plan.md", root: home + "/linked/plans"),
                     "a symlink above the plans root")
        // Not a regular file; the size cap; UTF-8; empty.
        try fm.createDirectory(atPath: plans + "/dir.md", withIntermediateDirectories: true)
        XCTAssertNil(read(plans + "/dir.md"))
        XCTAssertEqual(mkfifo(plans + "/fifo.md", 0o600), 0)
        XCTAssertNil(read(plans + "/fifo.md"), "a FIFO, without blocking")
        let cap = AgentPlanInput.maxFileBytes
        try Data(repeating: 0x61, count: cap).write(to: URL(fileURLWithPath: plans + "/big.md"))
        XCTAssertEqual(read(plans + "/big.md")?.utf8.count, cap, "at the cap")
        try Data(repeating: 0x61, count: cap + 1).write(to: URL(fileURLWithPath: plans + "/big.md"))
        XCTAssertNil(read(plans + "/big.md"), "over the cap")
        try Data([0x61, 0xFF, 0xFE, 0x62]).write(to: URL(fileURLWithPath: plans + "/bin.md"))
        XCTAssertNil(read(plans + "/bin.md"), "not UTF-8")
        try Data().write(to: URL(fileURLWithPath: plans + "/empty.md"))
        XCTAssertNil(read(plans + "/empty.md"))
        // The dialog path: a symlinked plan file the footer names gets no buttons.
        let link = AgentPlanInput(id: "t", plan: nil, file: plans + "/link.md", home: home)
        let w = try prompt(T.planScreen(caret: 1, footer: "ctrl+g to edit in VS Code · ~/.claude/plans/link.md"), plan: link)
        XCTAssertEqual(w.why, AgentWindowText.planFile)
        XCTAssertEqual(AgentPrompt.planFooterPath("   ctrl+g to edit in VS Code · ~/.claude/plans/a.md"), "~/.claude/plans/a.md")
        XCTAssertEqual(AgentPrompt.planFooterPath("ctrl+g to edit in VS Code · ~/.claude/plans/a.md · ✓ Plan saved!"),
                       "~/.claude/plans/a.md", "the .md segment, not the last")
        XCTAssertNil(AgentPrompt.planFooterPath("Esc to cancel · ~/.claude/plans/a.md"))
    }

    /// Round 4: Claude Code's composer shows a bare "ctrl+g to edit in <editor>" hint under a
    /// wrapped draft (bundle read). Under a numbered list and a draft that starts "3. …" it is no
    /// footer, so the screen is no prompt and Always allow sends nothing.
    @MainActor
    func testAgentWindowComposerCtrlGHintIsNoPrompt() throws {
        let rule = String(repeating: "─", count: 90)
        for hint in ["ctrl+g to edit in VS Code", "  ctrl+g to edit in VS Code"] {
            for draft in [["❯ 3. Blue, and also make the", "  border thicker please"], ["❯ 3. Blue"]] {
                let text = (["⏺ Pick one:", "  1. Red", "  2. Green", "", rule] + draft + [rule, hint]).joined(separator: "\n")
                let name = "\(hint) / \(draft.count) draft lines"
                XCTAssertNil(AgentPrompt.screen(text), name)
                XCTAssertNil(AgentPrompt.parse(text), name)
                XCTAssertEqual(AgentWindowPanel.classify(text, ask: nil, plan: T.planInput),
                               .terminal(AgentWindowText.unreadable, AgentPrompt.tail(text)), name)
                let f = FormSim(.plain(text))
                XCTAssertEqual(AgentPrompt.autoAllow(T.key, io: f.io, notAgain: nil, answered: false, isOn: { true }), .human, name)
                XCTAssertEqual(f.log, [], name)
            }
        }
    }

    /// Round 4: with no editor detected Claude Code draws the plan dialog with no footer. The
    /// feedback row's hint is then the last line, so the parse fails: no prompt, Open in terminal.
    @MainActor
    func testAgentWindowPlanWithoutAFooterIsNoPrompt() throws {
        let text = T.planScreen(caret: 1, footer: nil)
        XCTAssertNil(AgentPrompt.screen(text))
        XCTAssertEqual(AgentWindowPanel.classify(text, ask: nil, plan: T.planInput),
                       .terminal(AgentWindowText.unreadable, AgentPrompt.tail(text)))
        let f = FormSim(.plain(text))
        XCTAssertEqual(AgentPrompt.autoAllow(T.key, io: f.io, notAgain: nil, answered: false, isOn: { true }), .human)
        XCTAssertEqual(f.log, [])
    }

    // MARK: - Plan approval: the key

    func testAgentWindowPlanApproveSendsTheDigitOnlyOnTheCheckedDialog() throws {
        let f = FormSim(.plan)
        XCTAssertEqual(driver(f.io).approve(try screen(T.planScreen(caret: 1)), digit: 2), .done)
        XCTAssertEqual(f.log, ["send 2"])
        XCTAssertEqual(f.approved, 2)
        // Round 3: the footer names another plan file after the check: nothing sent.
        let o = FormSim(.plan)
        o.planFooter = "ctrl+g to edit in VS Code · ~/.claude/plans/other-plan.md"
        XCTAssertEqual(driver(o.io).approve(try screen(T.planScreen(caret: 1)), digit: 2), .failed(AgentWindowText.changed))
        XCTAssertEqual(o.log, [])
        // The plan changed after the check: nothing sent.
        let g = FormSim(.plan)
        g.planLines = T.planShown + ["Then delete the tests."]
        XCTAssertEqual(driver(g.io).approve(try screen(T.planScreen(caret: 1)), digit: 2), .failed(AgentWindowText.changed))
        XCTAssertEqual(g.log, [])
        // The caret moved to the feedback row: the digit would be typed there.
        let h = FormSim(.plan)
        h.caret = 3
        XCTAssertEqual(driver(h.io).approve(try screen(T.planScreen(caret: 1)), digit: 2), .failed(AgentWindowText.changed))
        XCTAssertEqual(h.log, [])
        XCTAssertEqual(h.typed, "")
        // Taken but nothing changes: unconfirmed, one key only.
        let k = FormSim(.plan)
        k.deaf = true
        XCTAssertEqual(driver(k.io).approve(try screen(T.planScreen(caret: 1)), digit: 1), .failed(AgentWindowText.unconfirmed))
        XCTAssertEqual(k.log, ["send 1"])
        // dch must say blocked.
        let m = FormSim(.plan)
        m.status = "working"
        XCTAssertEqual(driver(m.io).approve(try screen(T.planScreen(caret: 1)), digit: 2), .failed(AgentWindowText.changed))
        XCTAssertEqual(m.log, [])
    }

    @MainActor
    func testAgentWindowPlanApproveRunsThroughTheControllerAndAStaleClickSendsNothing() throws {
        let f = FormSim(.plan)
        let c = t.controller(f.io)
        c.store?.sessions = [t.session(.blocked)]
        c.checkAutoAllow()
        t.until("Always allow leaves a plan to the human") { !c.heldByAutoAllow(T.key) }
        c.queue.sync {}
        XCTAssertEqual(f.log, [], "a plan is never Always allow's")
        let i = t.interaction(c)
        i.plan = T.planInput
        i.follow(t.session(.blocked))
        guard case .prompt(let w) = i.panel else { return XCTFail("\(i.panel)") }
        XCTAssertEqual(w.approve, [1, 2])
        i.answer(w.buttons[2])
        XCTAssertFalse(i.busy, "the feedback row sends nothing")
        i.answer(w.buttons[1])
        t.until("approved") { !i.busy }
        XCTAssertEqual(f.log, ["send 2"])
        XCTAssertEqual(f.approved, 2)
        XCTAssertNil(i.notice)
        XCTAssertEqual(i.panel, .none, "Claude at work after the answer")

        // The plan on screen changes after the panel was drawn: the click is never consent for it.
        let g = FormSim(.plan)
        let d = t.controller(g.io, autoAllow: false)
        let j = t.interaction(d)
        j.plan = T.planInput
        j.follow(t.session(.blocked))
        guard case .prompt(let v) = j.panel else { return XCTFail("\(j.panel)") }
        g.lock.withLock { g.planLines = T.planShown + ["Then delete the tests."] }
        j.answer(v.buttons[1])
        t.until("refused") { !j.busy }
        XCTAssertEqual(g.log, [])
        XCTAssertEqual(j.notice, AgentWindowText.changed)
        guard case .prompt(let again) = j.panel else { return XCTFail("\(j.panel)") }
        XCTAssertEqual(again.why, AgentWindowText.planMismatch, "re-read: the new plan is checked again")
    }

    /// Round 2: only the main thread's ExitPlanMode is the plan a screen is checked against; a
    /// subagent's (a sidechain) never is, newest or not. An answered one is no longer pending.
    func testAgentWindowPendingPlanIsTheMainThreadsOnly() {
        let d = AgentWindowD1Tests()
        let side: [String: Any] = ["isSidechain": true, "agentId": "ag"]
        let main = d.toolUse("p1", "ExitPlanMode", ["plan": "Main plan"])
        let sub = d.toolUse("p2", "ExitPlanMode", ["plan": "Subagent plan"], side)
        XCTAssertNil(d.asm([d.say("start"), sub]).pendingPlan, "a subagent's plan alone")
        XCTAssertEqual(d.asm([d.say("start"), main]).pendingPlan, AgentPlanInput(id: "p1", plan: "Main plan"))
        XCTAssertEqual(d.asm([d.say("start"), main, sub]).pendingPlan?.id, "p1", "a newer subagent plan is not the main one")
        XCTAssertNil(d.asm([d.say("start"), main, d.toolResult("p1", "ok")]).pendingPlan, "answered")
        XCTAssertNil(d.asm([d.say("start"), d.toolUse("p3", "ExitPlanMode", [:])]).pendingPlan, "no plan text")
        // Round 3: Claude Code 2.1.318's {} input: the newest main-thread plan_mode attachment's file.
        func mode(_ path: Any, _ extra: [String: Any] = [:], sub: Bool = false) -> [String: Any] {
            d.entry("attachment", ["isSidechain": false, "attachment": ["type": "plan_mode", "reminderType": "full",
                                                                        "isSubAgent": sub, "planFilePath": path,
                                                                        "planExists": false]].merging(extra) { $1 })
        }
        let a = "/Users/user/.claude/plans/a.md", b = "/Users/user/.claude/plans/b.md"
        let call = d.toolUse("p3", "ExitPlanMode", [:])
        XCTAssertEqual(d.asm([mode(a), call]).pendingPlan, AgentPlanInput(id: "p3", plan: nil, file: a))
        XCTAssertEqual(d.asm([mode(a), mode(b), call]).pendingPlan?.file, b, "the newest")
        XCTAssertEqual(d.asm([mode(a), call, mode(b)]).pendingPlan?.file, b, "the newest, after the call too")
        XCTAssertEqual(d.asm([mode(a), mode(b, side), call]).pendingPlan?.file, a, "a subagent's attachment is not the main one")
        XCTAssertEqual(d.asm([mode(a), mode(b, sub: true), call]).pendingPlan?.file, a, "nor one flagged isSubAgent")
        XCTAssertNil(d.asm([mode(b, side), call]).pendingPlan)
        XCTAssertNil(d.asm([mode("plans/a.md"), call]).pendingPlan, "a relative path")
        XCTAssertNil(d.asm([mode(3), call]).pendingPlan)
        XCTAssertEqual(d.asm([mode(a), d.toolUse("p4", "ExitPlanMode", ["plan": "Own"])]).pendingPlan,
                       AgentPlanInput(id: "p4", plan: "Own"), "the call's own plan first")
        XCTAssertNil(d.asm([mode(a), call, d.toolResult("p3", "ok")]).pendingPlan, "answered")
        // The attachment stays hidden noise in the transcript.
        let e = TranscriptDecoder.decode(line: d.line(mode(a)))
        XCTAssertEqual(e.planFile, a)
        guard case .hidden("attachment")? = e.items.first, e.items.count == 1 else { return XCTFail("\(e.items)") }
        // Paging: an earlier page's attachment counts when this one has none.
        var late = d.asm([call])
        late.prepend(d.asm([mode(a)]))
        XCTAssertEqual(late.pendingPlan?.file, a)
        var both = d.asm([mode(b), call])
        both.prepend(d.asm([mode(a)]))
        XCTAssertEqual(both.pendingPlan?.file, b, "the later page's is the newer")
    }

    /// Round 2: the plan box shows the transcript's text with every hidden character escaped.
    func testAgentWindowPlanBoxEscapesHiddenCharacters() {
        XCTAssertEqual(AgentPromptPanel.planDisplay("Run a\u{202E}txt.exe\nthen b\u{200B}c"), "Run a⟨U+202E⟩txt.exe\nthen b⟨U+200B⟩c")
        XCTAssertEqual(AgentPromptPanel.planDisplay("# Plan\n\n1. Step"), "# Plan\n\n1. Step", "newlines stay lines")
    }

    @MainActor
    func testAgentWindowModelFeedsThePendingPlanFromTheTranscript() throws {
        let url = tempDir().appendingPathComponent("plan.jsonl")
        let entry: [String: Any] = ["type": "assistant", "sessionId": "s-1", "version": "2.1.318",
                                    "message": ["role": "assistant",
                                                "content": [["type": "tool_use", "id": "toolu_p", "name": "ExitPlanMode",
                                                             "input": ["plan": T.planMarkdown,
                                                                       "planFilePath": "/tmp/example-plan.md"]]]]]
        try (JSONSerialization.data(withJSONObject: entry) + Data("\n".utf8)).write(to: url)
        let f = FormSim(.plan)
        let c = t.controller(f.io, autoAllow: false)
        let st = AgentIslandStore(geometry: AgentWindowD1Tests.geometry)
        st.sessions = [AgentSession(key: T.key, alias: "", activity: 1, state: .blocked, agents: 0, version: "1.30.0",
                                    claudeSessionID: "0b7c2f3e-1111-2222-3333-444455556666", transcriptPath: url.path)]
        let m = AgentWindowModel()
        m.now = { 1_800_000_000 }
        m.openSession = { _ in }
        m.onVisible = { _ in }
        m.ageInterval = 3600
        m.transcript.offMain = { $0() }
        m.transcript.makeWatch = { _, _ in NSObject() }
        m.transcript.tickInterval = 3600
        m.interaction.controller = c
        m.interaction.readQueue = { $0() }
        m.bind(st)
        m.setVisible(true)
        XCTAssertEqual(m.transcript.pendingPlan, T.planInput)
        XCTAssertEqual(m.interaction.plan, T.planInput)
        guard case .prompt(let w) = m.interaction.panel else { return XCTFail("\(m.interaction.panel)") }
        XCTAssertEqual(w.approve, [1, 2], "checked against the transcript's plan")
        // Another session with no transcript: no plan, no approve row.
        let bKey = AgentSessionKey(dir: "/tmp/dch-test", name: "b")
        st.sessions = [st.sessions[0], AgentSession(key: bKey, alias: "", activity: 0, state: .blocked, agents: 0, version: "1.30.0")]
        m.select(try XCTUnwrap(m.rows.first { $0.session?.key == bKey }?.id))
        XCTAssertNil(m.interaction.plan)
        m.select(try XCTUnwrap(m.rows.first { $0.session?.key == T.key }?.id))
        XCTAssertEqual(m.interaction.plan?.id, "toolu_p", "back on A: its own plan")
        // Round 2: the same session losing its mapping (the tail is kept for the grace period): no plan.
        st.sessions = [AgentSession(key: T.key, alias: "", activity: 1, state: .blocked, agents: 0, version: "1.30.0"),
                       st.sessions[1]]
        XCTAssertNil(m.transcript.pendingPlan, "no mapping: no plan")
        XCTAssertNil(m.interaction.plan)
        guard case .prompt(let unmapped) = m.interaction.panel else { return XCTFail("\(m.interaction.panel)") }
        XCTAssertEqual(unmapped.approve, [])
        XCTAssertEqual(unmapped.why, AgentWindowText.planUnchecked)
        m.close()
    }

    // MARK: - Chat about this

    func testAgentWindowChatAboutThisWalksToItsRowAndEnters() throws {
        let f = FormSim(.single)
        XCTAssertEqual(driver(f.io).chat(try screen(T.singleScreen(caret: 1)), digit: 5), .done)
        XCTAssertEqual(f.log, ["down", "down", "down", "down", "enter"], "arrows through the Other row: no digit, no text")
        XCTAssertEqual(f.typed, "")
        // The question changes under the walk.
        let g = FormSim(.single)
        g.afterKey = { $0.question = "Which size?" }
        XCTAssertEqual(driver(g.io).chat(try screen(T.singleScreen(caret: 1)), digit: 5), .failed(AgentWindowText.changed))
        XCTAssertEqual(g.log, ["down"])
        // The caret leaves the row after the last arrow was confirmed: no Enter.
        let h = FormSim(.single)
        h.afterRead = { s in if s.log.count == 4, s.caret == 5 { s.caret = 4 } }
        XCTAssertEqual(driver(h.io).chat(try screen(T.singleScreen(caret: 1)), digit: 5), .failed(AgentWindowText.changed))
        XCTAssertEqual(h.log, ["down", "down", "down", "down"])
        XCTAssertFalse(h.gone)
        // A slow redraw: each arrow waits until the caret shows on the next row, never presses on.
        let slow = FormSim(.multi)
        slow.lag = 2
        XCTAssertEqual(driver(slow.io).chat(try screen(T.multiScreen(slow.checked, caret: 1)), digit: 5), .done)
        XCTAssertEqual(slow.log, ["down", "down", "down", "down", "down", "enter"])
        // Multi-select: past Submit to the row, then Enter.
        let k = FormSim(.multi)
        XCTAssertEqual(driver(k.io).chat(try screen(T.multiScreen(k.checked, caret: 1)), digit: 5), .done)
        XCTAssertEqual(k.log, ["down", "down", "down", "down", "down", "enter"])
        // A box ticked under the walk: refused.
        let m = FormSim(.multi)
        m.afterKey = { s in if s.log.count == 2 { s.checked[0] = true } }
        XCTAssertEqual(driver(m.io).chat(try screen(T.multiScreen(m.checked, caret: 1)), digit: 5), .failed(AgentWindowText.changed))
        XCTAssertEqual(m.log, ["down", "down"])
    }

    @MainActor
    func testAgentWindowChatAboutThisRunsThroughTheController() throws {
        let f = FormSim(.multi)
        let i = t.interaction(t.controller(f.io, autoAllow: false))
        i.ask = T.multiAsk
        i.follow(t.session(.blocked))
        guard case .prompt(let w) = i.panel else { return XCTFail("\(i.panel)") }
        XCTAssertEqual(w.chat?.digit, 5)
        i.chat()
        t.until("chat") { !i.busy }
        XCTAssertEqual(f.log, ["down", "down", "down", "down", "down", "enter"])
        XCTAssertNil(i.notice)
    }

    // MARK: - Multi-select Other

    func testAgentWindowMultiSelectOtherTypesIntoTheEmptyRowAndSubmits() throws {
        let f = FormSim(.multi)
        XCTAssertEqual(driver(f.io).multi(try screen(T.multiScreen(f.checked, caret: 1)), picks: [1], other: (4, "Teal")), .done)
        XCTAssertEqual(f.log, ["send 1", "down", "down", "down", "send Teal", "down", "enter"])
        XCTAssertEqual(f.checked, [true, false, false, true])
        XCTAssertEqual(f.typed, "Teal")
        // The caret starts on the Other row: one row up before a digit, never a digit there.
        let g = FormSim(.multi)
        g.caret = 4
        XCTAssertEqual(driver(g.io).multi(try screen(T.multiScreen(g.checked, caret: 4)), picks: [2], other: (4, "Teal")), .done)
        XCTAssertEqual(g.log, ["up", "send 2", "down", "send Teal", "down", "enter"])
        XCTAssertEqual(g.typed, "Teal", "the digit never landed in the row")
        // The caret is back on the Other row when the digit is due: refused, no digit.
        let h = FormSim(.multi)
        h.caret = 4
        h.afterRead = { s in if s.log == ["up"], s.caret == 3 { s.caret = 4 } }
        XCTAssertEqual(driver(h.io).multi(try screen(T.multiScreen(h.checked, caret: 4)), picks: [2], other: (4, "Teal")),
                       .failed(AgentWindowText.changed))
        XCTAssertEqual(h.log, ["up"])
        XCTAssertEqual(h.typed, "")
        // Only the Other text, no toggles: no digit at all.
        let k = FormSim(.multi)
        XCTAssertEqual(driver(k.io).multi(try screen(T.multiScreen(k.checked, caret: 1)), picks: [], other: (4, "Teal")), .done)
        XCTAssertEqual(k.log, ["down", "down", "down", "send Teal", "down", "enter"])
    }

    func testAgentWindowMultiSelectOtherFailsClosed() throws {
        // Text already in the row: nothing typed after it.
        let f = FormSim(.multi)
        f.caret = 4
        f.typed = "Te"
        f.checked[3] = true
        XCTAssertEqual(driver(f.io).multi(try screen(T.multiScreen(f.checked, caret: 4, typed: "Te")), picks: [], other: (4, "Teal")),
                       .failed(AgentWindowText.changed))
        XCTAssertEqual(f.log, [])
        XCTAssertEqual(f.typed, "Te")
        // The box does not tick when typed into (another Claude Code): unconfirmed, no Submit.
        let g = FormSim(.multi)
        g.autoTick = false
        XCTAssertEqual(driver(g.io).multi(try screen(T.multiScreen(g.checked, caret: 1)), picks: [], other: (4, "Teal")),
                       .failed(AgentWindowText.unconfirmed))
        XCTAssertEqual(g.log, ["down", "down", "down", "send Teal"])
        // The text is confirmed, then gone before Enter: no Enter.
        let h = FormSim(.multi)
        h.afterRead = { s in if s.log.last == "down", s.caret == nil, !s.typed.isEmpty { s.typed = "" } }
        XCTAssertEqual(driver(h.io).multi(try screen(T.multiScreen(h.checked, caret: 1)), picks: [], other: (4, "Teal")),
                       .failed(AgentWindowText.changed))
        XCTAssertEqual(h.log, ["down", "down", "down", "send Teal", "down"])
        XCTAssertFalse(h.gone)
        // The placeholder as the answer: refused before any key (#810).
        for text in ["Type something", "Type  something."] {
            let m = FormSim(.multi)
            XCTAssertEqual(driver(m.io).multi(try screen(T.multiScreen(m.checked, caret: 1)), picks: [1], other: (4, text)),
                           .failed(AgentWindowText.placeholder), text)
            XCTAssertEqual(m.log, [], text)
        }
        // The question changes while walking to the row.
        let k = FormSim(.multi)
        k.afterKey = { s in if s.log == ["down"] { s.question = "Which sizes?" } }
        XCTAssertEqual(driver(k.io).multi(try screen(T.multiScreen(k.checked, caret: 1)), picks: [], other: (4, "Teal")),
                       .failed(AgentWindowText.changed))
        XCTAssertEqual(k.log, ["down"])
    }

    @MainActor
    func testAgentWindowSubmitPicksTypesTheOtherAnswerUnderTheSingleChoiceRules() throws {
        func run(_ text: String) throws -> (FormSim, AgentWindowInteraction) {
            let f = FormSim(.multi)
            let i = t.interaction(t.controller(f.io, autoAllow: false))
            i.ask = T.multiAsk
            i.follow(t.session(.blocked))
            guard case .prompt(let w) = i.panel else { throw NotAPrompt(panel: "\(i.panel)") }
            XCTAssertEqual(w.other?.digit, 4)
            i.picks = [1]
            i.otherText = text
            i.submitPicks()
            t.until("submitted") { !i.busy }
            return (f, i)
        }
        let (a, _) = try run("  Teal ")
        XCTAssertEqual(a.log, ["send 1", "down", "down", "down", "send Teal", "down", "enter"])
        let (b, _) = try run("   ")
        XCTAssertEqual(b.log, ["send 1", "down", "down", "down", "down", "enter"], "blank: no Other answer")
        for (text, why) in [("Type something", AgentWindowText.placeholder), ("Type something.", AgentWindowText.placeholder),
                            ("a\u{1B}[2J", AgentWindowText.oneLine), (String(repeating: "x", count: 501), AgentWindowText.oneLine)] {
            let (f, i) = try run(text)
            XCTAssertEqual(f.log, [], text)
            XCTAssertEqual(i.notice, why, text)
        }
        // #798 I3 kept: an answer inside the placeholder waits for the row to show it ("some").
        let (c, _) = try run("some")
        XCTAssertEqual(c.log, ["send 1", "down", "down", "down", "send some", "down", "enter"])
    }

    /// A multi-select form with a hidden character or its top off the screen offers no Other and no Chat.
    @MainActor
    func testAgentWindowUnsafeOrUncheckedFormsOfferNoOtherAndNoChat() throws {
        let hidden = "Which\u{200B} colors?"
        let h = try prompt(T.multiScreen([false, false, false, false], caret: 1, question: hidden),
                           ask: T.ask(hidden, [("Red", "Red"), ("Green", "Green"), ("Blue", "Blue")], multi: true), plan: nil)
        XCTAssertNil(h.other)
        XCTAssertNil(h.chat)
        let s = try prompt(T.singleScreen(caret: 1), ask: nil, plan: nil)
        XCTAssertNil(s.other, "no transcript")
        XCTAssertNil(s.chat)
    }
}
