import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #798 Agent window B: the input box, interrupt and native prompt answers, plus the
/// QA #626 follow-ups. Every dch call is a fake (a small simulation of Claude Code's
/// forms); no test reads a real screen or sends a key to a real session. Windows are
/// built and never shown; key events are built by hand and handed to them.
final class AgentWindowInteractionTests: XCTestCase {

    static let key = AgentSessionKey(dir: "/tmp/dch-test", name: "s")
    static let rule = String(repeating: "─", count: 100)

    // MARK: - Fixtures (Claude Code 2.1.3xx layouts, as in AgentIslandPromptTests)

    /// S7 run-8: AskUserQuestion multiSelect, drawn from a state.
    static func multiScreen(_ checked: [Bool], caret: Int?, question: String = "Which colors?", typed: String = "") -> String {
        let names = ["Red", "Green", "Blue"]
        let mark = { (i: Int) in caret == i ? "❯" : " " }
        var l = ["❯ Use the AskUserQuestion tool with multiSelect set to true to ask me 'Which colors?' with options",
                 "  Red, Green, Blue", rule, "←  ☐ Colors  ✔ Submit  →", "", question, ""]
        for i in 0..<3 {
            l.append("\(mark(i + 1)) \(i + 1). [\(checked[i] ? "✔" : " ")] \(names[i])")
            l.append("         \(names[i])")
        }
        l.append("\(mark(4)) 4. [\(checked[3] ? "✔" : " ")] \(typed.isEmpty ? "Type something" : typed)")
        l.append(caret == nil ? "   ❯ Submit" : "     Submit")
        l += [rule, "\(mark(5)) 5. Chat about this", "", "Enter to select · ↑/↓ to navigate · Esc to cancel"]
        return l.joined(separator: "\n")
    }

    /// S6 run-7: AskUserQuestion, one question, drawn from a state (the Other row shows typed text).
    static func singleScreen(caret: Int, typed: String = "", question: String = "Which color?") -> String {
        let mark = { (i: Int) in caret == i ? "❯" : " " }
        return ["❯ Use the AskUserQuestion tool to ask me 'Which color?' with options Red, Green, Blue", rule,
                " ☐ Color", "", question, "",
                "\(mark(1)) 1. Red", "     Choose red", "\(mark(2)) 2. Green", "     Choose green",
                "\(mark(3)) 3. Blue", "     Choose blue", "\(mark(4)) 4. \(typed.isEmpty ? "Type something." : typed)", rule,
                "\(mark(5)) 5. Chat about this", "", "Enter to select · ↑/↓ to navigate · Esc to cancel"]
            .joined(separator: "\n")
    }

    /// S9 run-10: AskUserQuestion with previews, the caret on `caret`.
    static func previewScreen(caret: Int) -> String {
        run10.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            for (d, name) in [(1, "Grid"), (2, "List"), (3, "Cards")] where line.dropFirst(2).hasPrefix("\(d). \(name)") {
                return (caret == d ? "❯" : " ") + line.dropFirst()
            }
            return String(line)
        }.joined(separator: "\n")
    }

    static let run10 = #"""
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

    /// #805: a live capture, verbatim: `dch --read` of a private 100x40 session, Claude Code 2.1.318
    /// (Haiku, --safe-mode), caret on the empty Other row (work/805/cap/05-caret-on-other-empty.txt).
    /// The focused empty row keeps its placeholder (dimmed in --ansi), typing replaces it and
    /// deleting back to empty brings it back (captures 06-10); the footer names ctrl+g only there.
    static let live05 = #"""

     ▐▛███▛█   Claude Code v2.1.318
    ▝▜██████▀  Haiku 5.5 · Claude Team
     ▝▝   ▝▝   ~/personal/.prosper-supervisor/work/805/cap

    ⚠ Safe mode: all customizations are disabled (CLAUDE.md, skills, plugins, hooks, MCP, agents, and
      more)
      Restart without --safe-mode to re-enable

    ▎ Auto mode is now Claude Code's default permission mode.
    ▎ Auto mode lets Claude handle permission prompts automatically. Claude checks each tool call for
    ▎ risky actions and prompt injection before executing, runs the ones it assesses as lower-risk, and
    ▎ blocks the rest.
    ▎ https://code.claude.com/docs/en/permission-modes

    ❯ Call the AskUserQuestion tool now with exactly one single-select question 'Which fruit?' (header
      'Fruit') and 3 options: Apple (description 'A red fruit'), Banana (description 'A yellow fruit'),
      Cherry (description 'A small fruit'). Do nothing else.
    ────────────────────────────────────────────────────────────────────────────────────────────────────
     ☐ Fruit

    Which fruit?

      1. Apple
         A red fruit
      2. Banana
         A yellow fruit
      3. Cherry
         A small fruit
    ❯ 4. Type something.
    ────────────────────────────────────────────────────────────────────────────────────────────────────
      5. Chat about this

    Enter to select · ↑/↓ to navigate · ctrl+g to edit in VS Code · Esc to cancel
    """#

    /// The live capture drawn from a state: the caret on `caret`, the Other row showing `typed`.
    static func liveScreen(caret: Int, typed: String = "") -> String {
        live05.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            for d in 1...4 where line.dropFirst(2).hasPrefix("\(d). ") {
                return (caret == d ? "❯ " : "  ") + (d == 4 && !typed.isEmpty ? "4. \(typed)" : String(line.dropFirst(2)))
            }
            return caret == 4 ? String(line) : line.replacingOccurrences(of: " · ctrl+g to edit in VS Code", with: "")
        }.joined(separator: "\n")
    }

    static let liveAsk = ask("Which fruit?", [("Apple", "A red fruit"), ("Banana", "A yellow fruit"), ("Cherry", "A small fruit")])

    /// A Claude Code permission dialog in the #475 probe layout.
    static func permission(_ options: [String] = ["Yes", "No, and tell Claude what to do differently (esc)"],
                           body: [String] = ["   rm -rf .build", "   Clean the build tree"]) -> String {
        var lines = [String(repeating: "─", count: 90), " Bash command", ""] + body + ["", " Do you want to proceed?"]
        for (i, o) in options.enumerated() { lines.append((i == 0 ? " ❯ " : "   ") + "\(i + 1). \(o)") }
        return lines.joined(separator: "\n")
    }

    static let plan = permission(["Yes, and use auto mode", "Yes, manually approve edits", "No, keep planning"],
                                 body: [" Here is Claude's plan:", "   Add the parser."])

    /// A permission prompt Always allow leaves to the human (no plain "Yes"), its mode changes off.
    static let modeSwitch = permission(["Yes, and switch to auto mode", "Yes, allow all edits during this session (shift+tab)",
                                        "No, and tell Claude what to do differently (esc)"])

    static let idleScreen = "⏺ Done.\n\n" + rule + "\n❯ \n" + rule + "\n  ? for shortcuts"

    static func ask(_ q: String, _ options: [(String, String)], multi: Bool = false) -> AgentAskInput {
        AgentAskInput(id: "toolu_1", questions: [.init(question: q, header: "Color",
                                                       options: options.map { .init(label: $0.0, description: $0.1) },
                                                       multiSelect: multi)])
    }

    static let singleAsk = ask("Which color?", [("Red", "Choose red"), ("Green", "Choose green"), ("Blue", "Choose blue")])
    static let multiAsk = ask("Which colors?", [("Red", "Red"), ("Green", "Green"), ("Blue", "Blue")], multi: true)
    static let previewAsk = ask("Which layout?", [("Grid", ""), ("List", ""), ("Cards", "")])

    // MARK: - A small Claude Code form simulation behind dch

    final class FormSim: @unchecked Sendable {
        enum Kind { case multi, single, live, preview, plan, plain(String) }
        let lock = NSLock()
        let kind: Kind
        var checked = [false, false, false, false]
        var caret: Int? = 1
        var typed = ""
        var question: String?
        var gone = false
        var status = "blocked"
        /// Keys are taken but change nothing on screen (a missed key).
        var deaf = false
        var log: [String] = []
        var reads = 0
        /// Runs after each key with the lock held: a prompt changing under the sequence.
        var afterKey: ((FormSim) -> Void)?
        /// Runs after each read with the lock held (the screen returned is the one before it).
        var afterRead: ((FormSim) -> Void)?
        /// #802: a multi-select's Other row ticks its box when text is typed (Claude Code 2.1.318); false: it does not.
        var autoTick = true
        /// #802: the plan approval's rows and rendered plan; `typed` is its feedback row's text.
        var planRows = AgentWindowInteractionTests.planRows
        var planLines = AgentWindowInteractionTests.planShown
        var planFooter = AgentWindowInteractionTests.planFooter
        /// The plan row a digit approved.
        var approved: Int?
        /// #802: a slow redraw: an arrow's move shows only after this many more reads.
        var lag = 0
        private var lagged: (caret: Int?, reads: Int)?

        init(_ kind: Kind) { self.kind = kind }

        private func screen() -> String {
            if gone { return AgentWindowInteractionTests.idleScreen }
            switch kind {
            case .multi: return multiScreen(checked, caret: caret, question: question ?? "Which colors?", typed: typed)
            case .single: return singleScreen(caret: caret ?? 1, typed: typed, question: question ?? "Which color?")
            case .live: return liveScreen(caret: caret ?? 1, typed: typed)
            case .preview: return previewScreen(caret: caret ?? 1)
            case .plan: return planScreen(caret: caret ?? 1, rows: planRows, plan: planLines, feedback: typed, footer: planFooter)
            case .plain(let s): return s
            }
        }

        private static let order: [Int?] = [1, 2, 3, 4, nil, 5]

        private func key(_ k: String) {
            log.append(k)
            defer { afterKey?(self) }
            guard !deaf else { return }
            switch (kind, k) {
            case (.multi, "down"), (.multi, "up"):
                let i = Self.order.firstIndex(where: { $0 == caret })!
                let to = Self.order[min(max(i + (k == "down" ? 1 : -1), 0), Self.order.count - 1)]
                if lag > 0 { lagged = (to, lag) } else { caret = to }
            case (.single, "down"), (.live, "down"): caret = min((caret ?? 1) + 1, 5)
            case (.single, "up"), (.live, "up"): caret = max((caret ?? 1) - 1, 1)
            case (.plan, "down"): caret = min((caret ?? 1) + 1, planRows.count)
            case (.plan, "up"): caret = max((caret ?? 1) - 1, 1)
            // Submit, or "Chat about this" (5).
            case (.multi, "enter"): if caret == nil || caret == 5 { gone = true; status = "working" }
            case (_, "enter"): gone = true; status = "working"
            default: break
            }
        }

        private func send(_ t: String) {
            log.append("send \(t)")
            defer { afterKey?(self) }
            guard !deaf else { return }
            switch kind {
            // #802: the Other row (4) is an input row: every key there is text, and text ticks its box.
            case .multi:
                if caret == 4 {
                    typed += t
                    if autoTick { checked[3] = !typed.isEmpty }
                } else if let d = Int(t), (1...4).contains(d) { checked[d - 1].toggle() }
            case .preview: if let d = Int(t), (1...3).contains(d) { caret = d }
            case .single, .live: if caret == 4 { typed += t } else if Int(t) != nil { gone = true; status = "working" }
            case .plain: gone = true; status = "working"
            // The feedback row (the last) is an input row: a digit there is text.
            case .plan:
                if caret == planRows.count { typed += t } else if let d = Int(t), (1..<planRows.count).contains(d) {
                    approved = d; gone = true; status = "working"
                }
            }
        }

        var io: AgentPromptIO {
            AgentPromptIO(read: { _ in
                              self.lock.withLock {
                                  self.reads += 1
                                  let s = self.screen()
                                  if let l = self.lagged {
                                      self.lagged = l.reads > 1 ? (l.caret, l.reads - 1) : nil
                                      if l.reads == 1 { self.caret = l.caret }
                                  }
                                  self.afterRead?(self)
                                  return s
                              }
                          },
                          status: { _ in self.lock.withLock { self.status } },
                          send: { _, t in self.lock.withLock { self.send(t) } },
                          keys: { _, ks in self.lock.withLock { for k in ks { self.key(k) } } })
        }
    }

    func driver(_ io: AgentPromptIO) -> AgentWindowDriver {
        AgentWindowDriver(key: Self.key, io: io, pause: { _ in })
    }

    func screen(_ text: String) throws -> AgentPromptScreen { try XCTUnwrap(AgentPrompt.screen(text)) }

    // MARK: - Parser: caret and multi-select (fail closed)

    func testAgentWindowParserReadsTheMultiSelectFormAndKeepsParseStrict() throws {
        let s = try screen(Self.multiScreen([false, true, false, false], caret: 1))
        XCTAssertEqual(s.checked, [false, true, false, false])
        XCTAssertEqual(s.caret, 1)
        XCTAssertEqual(s.prompt.question, "Which colors?")
        XCTAssertEqual(s.prompt.options.map(\.label), ["Red", "Green", "Blue", "Type something", "Chat about this"])
        XCTAssertEqual(s.prompt.options.map(\.detail), [["Red"], ["Green"], ["Blue"], [], []], "the Submit row is not a detail")
        XCTAssertNil(AgentPrompt.parse(Self.multiScreen([false, false, false, false], caret: 1)), "parse stays non-multi")
        XCTAssertNil(try screen(Self.multiScreen([true, true, true, true], caret: nil)).caret, "on Submit")
        // The caret is not identity: the island's compare is unchanged.
        XCTAssertTrue(try screen(Self.multiScreen([false, false, false, false], caret: 1)).prompt
            .sameDialog(try screen(Self.multiScreen([false, false, false, false], caret: 3)).prompt))
        for (why, text) in [
            ("an unknown mark", Self.multiScreen([false, false, false, false], caret: 1).replacingOccurrences(of: "[ ] Red", with: "[?] Red")),
            ("no Submit row", Self.multiScreen([false, false, false, false], caret: 1).replacingOccurrences(of: "     Submit\n", with: "")),
            ("a caret on an option and on Submit", Self.multiScreen([false, false, false, false], caret: 1)
                .replacingOccurrences(of: "     Submit", with: "   ❯ Submit")),
            ("no caret anywhere", Self.multiScreen([false, false, false, false], caret: 1).replacingOccurrences(of: "❯ 1.", with: "  1.")),
            ("a box after a plain option", Self.multiScreen([false, false, false, false], caret: 1)
                .replacingOccurrences(of: "  5. Chat about this", with: "  5. [ ] Chat about this")),
        ] {
            XCTAssertNil(AgentPrompt.screen(text), why)
        }
        let single = try screen(Self.singleScreen(caret: 3))
        XCTAssertNil(single.checked)
        XCTAssertEqual(single.caret, 3)
        XCTAssertEqual(single.prompt, AgentPrompt.parse(Self.singleScreen(caret: 3)))
        XCTAssertEqual(try screen(Self.previewScreen(caret: 2)).caret, 2)
        XCTAssertFalse(try screen(Self.previewScreen(caret: 2)).prompt.preview.isEmpty)
    }

    // MARK: - Cross-check against the transcript's AskUserQuestion input

    func testAgentWindowAskInputParsesTolerantlyAndCrossChecksTheScreen() throws {
        let input: [String: Any] = ["questions": [["question": "Which color?", "header": "Color", "multiSelect": false,
                                                   "options": [["label": "Red", "description": "Choose red"],
                                                               ["label": "Green", "description": "Choose green"],
                                                               ["label": "Blue", "description": "Choose blue"]]]]]
        let a = try XCTUnwrap(AgentAskInput.parse(input, id: "t"))
        XCTAssertEqual(a, AgentAskInput(id: "t", questions: Self.singleAsk.questions))
        XCTAssertNil(AgentAskInput.parse(["questions": "x"], id: "t"))
        XCTAssertNil(AgentAskInput.parse(["questions": [["question": "q", "options": [["description": "no label"]]]]], id: "t"))
        XCTAssertNil(AgentAskInput.parse([:], id: "t"))

        let s = try screen(Self.singleScreen(caret: 1))
        XCTAssertTrue(a.matches(s))
        XCTAssertTrue(Self.multiAsk.matches(try screen(Self.multiScreen([false, false, false, false], caret: 1))))
        XCTAssertTrue(Self.previewAsk.matches(try screen(Self.previewScreen(caret: 1))))
        let mismatches: [(String, AgentAskInput)] = [
            ("another question", Self.ask("Which colour?", [("Red", "Choose red"), ("Green", "Choose green"), ("Blue", "Choose blue")])),
            ("another label", Self.ask("Which color?", [("Red", "Choose red"), ("Teal", "Choose green"), ("Blue", "Choose blue")])),
            ("another description", Self.ask("Which color?", [("Red", "Choose red"), ("Green", "Pick green"), ("Blue", "Choose blue")])),
            ("an option more", Self.ask("Which color?", [("Red", "Choose red"), ("Green", "Choose green"), ("Blue", "Choose blue"),
                                                         ("Pink", "Choose pink"), ("Gray", ""), ("Teal", "")])),
            ("multiSelect", Self.ask("Which color?", [("Red", "Choose red"), ("Green", "Choose green"), ("Blue", "Choose blue")], multi: true)),
            ("fewer options: an unknown row left", Self.ask("Which color?", [("Red", "Choose red"), ("Green", "Choose green")])),
        ]
        for (why, ask) in mismatches { XCTAssertFalse(ask.matches(s), why) }
    }

    @MainActor
    func testAgentWindowPanelKindsAndFallbacks() throws {
        guard case .prompt(let single) = AgentWindowPanel.classify(Self.singleScreen(caret: 1), ask: Self.singleAsk) else {
            return XCTFail("a single choice")
        }
        XCTAssertEqual(single.kind, .choose)
        XCTAssertEqual(single.other?.digit, 4, "the Other row takes typed text")
        XCTAssertEqual(single.buttons.map(\.digit), [1, 2, 3])
        XCTAssertEqual(single.chat?.digit, 5, "#802: Chat about this is a walk and Enter, not its digit")
        guard case .prompt(let noAsk) = AgentWindowPanel.classify(Self.singleScreen(caret: 1), ask: nil) else { return XCTFail() }
        XCTAssertNil(noAsk.other, "no transcript: the island card's digits only, no new sequence")
        XCTAssertNil(noAsk.chat)
        XCTAssertEqual(noAsk.buttons.map(\.digit), [1, 2, 3, 4, 5])

        XCTAssertEqual(AgentWindowPanel.classify(Self.singleScreen(caret: 1), ask: Self.multiAsk),
                       .terminal(AgentWindowText.mismatch, AgentPrompt.tail(Self.singleScreen(caret: 1))))
        let multi = Self.multiScreen([true, false, false, false], caret: 1)
        XCTAssertEqual(AgentWindowPanel.classify(multi, ask: nil), .terminal(AgentWindowText.unchecked, AgentPrompt.tail(multi)))
        guard case .prompt(let m) = AgentWindowPanel.classify(multi, ask: Self.multiAsk) else { return XCTFail() }
        XCTAssertEqual(m.kind, .multi)
        XCTAssertEqual(m.buttons.map(\.digit), [1, 2, 3], "the asked options")
        XCTAssertEqual(m.other?.digit, 4, "#802: Other takes typed text")
        XCTAssertEqual(m.chat?.digit, 5)
        let preview = Self.previewScreen(caret: 1)
        XCTAssertEqual(AgentWindowPanel.classify(preview, ask: nil), .terminal(AgentWindowText.unchecked, AgentPrompt.tail(preview)))
        guard case .prompt(let p) = AgentWindowPanel.classify(preview, ask: Self.previewAsk) else { return XCTFail() }
        XCTAssertEqual(p.kind, .preview)
        XCTAssertEqual(p.enabled, [1, 2, 3])
        XCTAssertNil(p.other)
        XCTAssertNil(p.chat, "the preview form's Chat row stays in the terminal: it has no digit to verify")

        guard case .prompt(let perm) = AgentWindowPanel.classify(Self.permission(), ask: Self.singleAsk) else { return XCTFail() }
        XCTAssertEqual(perm.kind, .choose, "a permission prompt is never cross-checked")
        XCTAssertEqual(perm.enabled, [1, 2])
        guard case .prompt(let mode) = AgentWindowPanel.classify(Self.modeSwitch, ask: nil) else { return XCTFail() }
        XCTAssertEqual(mode.enabled, [3], "the island card's rule: mode changes stay off")
        XCTAssertFalse(mode.caption.isEmpty)
        XCTAssertNil(mode.why, "not a plan approval")
        // #802: a plan approval offers only checked approve rows; no transcript plan: none, and why.
        guard case .prompt(let plan) = AgentWindowPanel.classify(Self.plan, ask: nil) else { return XCTFail() }
        XCTAssertEqual(plan.enabled, [], "not even the island rule's No row")
        XCTAssertEqual(plan.why, AgentWindowText.planUnchecked)
        XCTAssertEqual(plan.approve, [])

        XCTAssertEqual(AgentWindowPanel.classify(Self.idleScreen, ask: nil),
                       .terminal(AgentWindowText.unreadable, AgentPrompt.tail(Self.idleScreen)))
    }

    // MARK: - Multi-select: toggle, walk to Submit, Enter, each key verified

    func testAgentWindowMultiSelectTogglesWalksToSubmitAndEnters() throws {
        let f = FormSim(.multi)
        let e = try screen(Self.multiScreen(f.checked, caret: 1))
        XCTAssertEqual(driver(f.io).multi(e, picks: [1, 3]), .done)
        XCTAssertEqual(f.log, ["send 1", "send 3", "down", "down", "down", "down", "enter"])
        XCTAssertTrue(f.gone)
        // From below Submit: up.
        let g = FormSim(.multi)
        g.caret = 5
        XCTAssertEqual(driver(g.io).multi(try screen(Self.multiScreen(g.checked, caret: 5)), picks: [2]), .done)
        XCTAssertEqual(g.log, ["send 2", "up", "enter"])
        // Unticking what the screen had ticked.
        let h = FormSim(.multi)
        h.checked = [true, true, false, false]
        XCTAssertEqual(driver(h.io).multi(try screen(Self.multiScreen(h.checked, caret: 1)), picks: [2]), .done)
        XCTAssertEqual(h.log, ["send 1", "down", "down", "down", "down", "enter"])
    }

    func testAgentWindowMultiSelectStopsWhenThePromptChangesBetweenKeys() throws {
        // The question changes right after the first key: the second key's re-read refuses.
        let f = FormSim(.multi)
        f.afterKey = { $0.question = "Which sizes?" }
        let e = try screen(Self.multiScreen(f.checked, caret: 1))
        XCTAssertEqual(driver(f.io).multi(e, picks: [1, 3]), .failed(AgentWindowText.changed))
        XCTAssertEqual(f.log, ["send 1"], "nothing after the change")
        // A box ticked by someone else before the sequence: the first key's re-read refuses.
        let g = FormSim(.multi)
        g.checked = [false, false, true, false]
        XCTAssertEqual(driver(g.io).multi(try screen(Self.multiScreen([false, false, false, false], caret: 1)), picks: [1]),
                       .failed(AgentWindowText.changed))
        XCTAssertEqual(g.log, [])
        // The caret moved by itself between two arrows.
        let h = FormSim(.multi)
        h.afterKey = { s in if s.log == ["down"] { s.caret = 4 } }
        XCTAssertEqual(driver(h.io).multi(try screen(Self.multiScreen(h.checked, caret: 1)), picks: []),
                       .failed(AgentWindowText.changed))
        XCTAssertEqual(h.log, ["down"])
    }

    /// Review round 2 S2: the caret moves by itself after the toggles were confirmed and before
    /// the walk's first arrow. The arrow's own re-read must refuse on the caret alone: the
    /// form, its boxes and dch's state are all as planned.
    func testAgentWindowMultiSelectWalkRefusesWhenTheCaretMovedBeforeTheFirstArrow() throws {
        let f = FormSim(.multi)
        // The read that confirms the toggle returns the planned caret, then the caret moves.
        f.afterRead = { s in if s.log == ["send 2"], s.caret == 1 { s.caret = 3 } }
        XCTAssertEqual(driver(f.io).multi(try screen(Self.multiScreen(f.checked, caret: 1)), picks: [2]),
                       .failed(AgentWindowText.changed))
        XCTAssertEqual(f.log, ["send 2"], "no arrow from a caret that is not where the walk was planned")
        XCTAssertEqual(f.checked, [false, true, false, false])
    }

    func testAgentWindowMultiSelectNeedsBlockedAndAConfirmedKey() throws {
        let f = FormSim(.multi)
        f.status = "working"
        XCTAssertEqual(driver(f.io).multi(try screen(Self.multiScreen(f.checked, caret: 1)), picks: [1]),
                       .failed(AgentWindowText.changed))
        XCTAssertEqual(f.log, [], "dch must say blocked before any key")
        let g = FormSim(.multi)
        g.status = ""
        XCTAssertEqual(driver(g.io).multi(try screen(Self.multiScreen(g.checked, caret: 1)), picks: [1]),
                       .failed(AgentWindowText.changed), "a timed-out status is not blocked")
        XCTAssertEqual(g.log, [])
        let h = FormSim(.multi)
        h.deaf = true
        XCTAssertEqual(driver(h.io).multi(try screen(Self.multiScreen(h.checked, caret: 1)), picks: [1, 2]),
                       .failed(AgentWindowText.unconfirmed))
        XCTAssertEqual(h.log, ["send 1"], "an unconfirmed toggle stops the sequence")
        XCTAssertEqual(h.reads, 1 + 12, "one re-read before, then a bounded wait")
    }

    // MARK: - Preview form: digit moves the focus, Enter answers

    func testAgentWindowPreviewFormMovesFocusThenEnters() throws {
        let f = FormSim(.preview)
        XCTAssertEqual(driver(f.io).preview(try screen(Self.previewScreen(caret: 1)), digit: 3), .done)
        XCTAssertEqual(f.log, ["send 3", "enter"])
        let g = FormSim(.preview)
        g.caret = 2
        XCTAssertEqual(driver(g.io).preview(try screen(Self.previewScreen(caret: 2)), digit: 2), .done)
        XCTAssertEqual(g.log, ["enter"], "already focused: Enter only")
        // The focus lands elsewhere: no Enter.
        let h = FormSim(.preview)
        h.afterKey = { $0.caret = 1 }
        XCTAssertEqual(driver(h.io).preview(try screen(Self.previewScreen(caret: 1)), digit: 3), .failed(AgentWindowText.unconfirmed))
        XCTAssertEqual(h.log, ["send 3"])
        let k = FormSim(.preview)
        k.afterKey = { $0.caret = 2 }
        XCTAssertEqual(driver(k.io).preview(try screen(Self.previewScreen(caret: 1)), digit: 3), .failed(AgentWindowText.changed))
        XCTAssertEqual(k.log, ["send 3"])
    }

    // MARK: - Other: walk to the row, type, verify, Enter

    func testAgentWindowOtherTextWalksTypesVerifiesAndEnters() throws {
        let f = FormSim(.single)
        XCTAssertEqual(driver(f.io).other(try screen(Self.singleScreen(caret: 1)), digit: 4, text: "Teal, please"), .done)
        XCTAssertEqual(f.log, ["down", "down", "down", "send Teal, please", "enter"])
        // Typed text never shows: no Enter.
        let g = FormSim(.single)
        g.caret = 4
        g.afterKey = { s in if s.log.last?.hasPrefix("send") == true { s.typed = "" } }
        XCTAssertEqual(driver(g.io).other(try screen(Self.singleScreen(caret: 4)), digit: 4, text: "Teal"),
                       .failed(AgentWindowText.unconfirmed))
        XCTAssertEqual(g.log, ["send Teal"])
        // Review round 2 S3: the typed text is confirmed, then vanishes before Enter. Enter's
        // re-read must refuse on the text alone (the Other row's text is not part of the identity).
        let k = FormSim(.single)
        k.caret = 4
        k.afterRead = { s in if s.log == ["send Teal"], !s.typed.isEmpty { s.typed = "" } }
        XCTAssertEqual(driver(k.io).other(try screen(Self.singleScreen(caret: 4)), digit: 4, text: "Teal"),
                       .failed(AgentWindowText.changed))
        XCTAssertEqual(k.log, ["send Teal"], "no Enter once the answer is gone from the row")
        // The question changed under the walk.
        let h = FormSim(.single)
        h.afterKey = { $0.question = "Which size?" }
        XCTAssertEqual(driver(h.io).other(try screen(Self.singleScreen(caret: 1)), digit: 4, text: "Teal"),
                       .failed(AgentWindowText.changed))
        XCTAssertEqual(h.log, ["down"])
        XCTAssertNil(AgentWindowDriver.otherText("  "))
        XCTAssertNil(AgentWindowDriver.otherText("a\u{1B}[2J"), "no control characters")
        XCTAssertNil(AgentWindowDriver.otherText(String(repeating: "x", count: 501)))
        XCTAssertEqual(AgentWindowDriver.otherText("  Teal "), "Teal")
    }

    /// QA #629 INFO-5: Other types only into the empty row ("Type something."), never after text
    /// already there ("Te" + "Teal" = "TeTeal"): refused before the text, with nothing typed.
    func testAgentWindowOtherTypesOnlyIntoTheEmptyRow() throws {
        let f = FormSim(.single)
        f.caret = 4
        f.typed = "Te"
        XCTAssertEqual(driver(f.io).other(try screen(Self.singleScreen(caret: 4)), digit: 4, text: "Teal"),
                       .failed(AgentWindowText.changed))
        XCTAssertEqual(f.log, [], "nothing typed after the row's own text")
        XCTAssertEqual(f.typed, "Te")
        // Text appears in the row during the walk: the walk ends, the text is not typed.
        let g = FormSim(.single)
        g.afterKey = { s in if s.caret == 4 { s.typed = "Te" } }
        XCTAssertEqual(driver(g.io).other(try screen(Self.singleScreen(caret: 1)), digit: 4, text: "Teal"),
                       .failed(AgentWindowText.changed))
        XCTAssertEqual(g.log, ["down", "down", "down"])
        XCTAssertEqual(g.typed, "Te")
    }

    /// #810 (QA #634 INFO 1): "Type something." as the answer would be typed, never confirm (the row
    /// still reads as the placeholder) and stay in the row, so a retry typed "Type something.X".
    /// Refused before any key, with its own reason, in every whitespace form.
    func testAgentWindowOtherRefusesThePlaceholderAsTheAnswer() throws {
        for text in ["Type something.", "Type something", "Typesomething.", " Type  something. "] {
            let f = FormSim(.single)
            XCTAssertEqual(driver(f.io).other(try screen(Self.singleScreen(caret: 1)), digit: 4, text: text),
                           .failed(AgentWindowText.placeholder), text)
            XCTAssertEqual(f.log, [], "nothing typed: \(text)")
            XCTAssertEqual(f.typed, "", text)
            XCTAssertNil(AgentWindowDriver.otherText(text), text)
        }
        XCTAssertEqual(AgentWindowDriver.otherText("Type something else"), "Type something else")
    }

    /// #805 (QA #629 R2 item 1): an answer inside the placeholder ("some", "Type", "thing.") is in
    /// "Typesomething." before the row redraws. A row still showing the placeholder never confirms
    /// the text, so no Enter; once the row shows it, the answer goes through.
    func testAgentWindowOtherAnswerInsideThePlaceholderWaitsForTheRow() throws {
        let fixtures: [(String, FormSim.Kind, String)] = [("single", .single, Self.singleScreen(caret: 4)),
                                                          ("live", .live, Self.liveScreen(caret: 4))]
        for (name, kind, e) in fixtures {
            for text in ["some", "Type", "thing."] {
                // The text never lands: the row keeps its placeholder.
                let f = FormSim(kind)
                f.caret = 4
                f.afterKey = { s in if s.log.last?.hasPrefix("send") == true { s.typed = "" } }
                XCTAssertEqual(driver(f.io).other(try screen(e), digit: 4, text: text), .failed(AgentWindowText.unconfirmed),
                               "\(name) \(text)")
                XCTAssertEqual(f.log, ["send \(text)"], "\(name) \(text): no Enter on the placeholder")
                // It lands: answered.
                let g = FormSim(kind)
                g.caret = 4
                XCTAssertEqual(driver(g.io).other(try screen(e), digit: 4, text: text), .done, "\(name) \(text)")
                XCTAssertEqual(g.log, ["send \(text)", "enter"], "\(name) \(text)")
            }
        }
    }

    /// #805 (QA #629 R2 item 2): the Other path against the live capture (`live05`): the focused
    /// empty row reads "Type something.", so the gate lets the text in, and the typed row confirms it.
    /// Before #805 the capture did not parse at all (its footer was over isFooter's cap), so the
    /// walk's last arrow never confirmed and every Other answer from another row was refused.
    @MainActor
    func testAgentWindowOtherTypesAndEntersOnTheLiveCapture() throws {
        XCTAssertEqual(Self.liveScreen(caret: 4), Self.live05, "the fixture's own state is the capture, verbatim")
        let s = try screen(Self.live05)
        XCTAssertEqual(s.caret, 4)
        XCTAssertNil(s.checked)
        XCTAssertEqual(s.prompt.options.map(\.label), ["Apple", "Banana", "Cherry", "Type something.", "Chat about this"])
        XCTAssertTrue(Self.liveAsk.matches(s))
        // The caret on Other adds "ctrl+g to edit in VS Code" to the footer (77 characters): still the footer.
        XCTAssertNotNil(AgentPrompt.parse(Self.live05), "the island card reads it too")
        XCTAssertTrue(AgentPrompt.isFooter("Enter to select · ↑/↓ to navigate · ctrl+g to edit in VS Code · Esc to cancel"))
        XCTAssertFalse(AgentPrompt.isFooter("Enter to select · ↑/↓ to navigate · ctrl+g to edit in VS Code · Esc to cancel it"))
        XCTAssertFalse(AgentPrompt.isFooter("Output: press Enter to select a file, then the arrows · Esc to cancel"),
                       "a long line only containing it keeps the cap")
        for caret in [1, 4] {
            guard case .prompt(let w) = AgentWindowPanel.classify(Self.liveScreen(caret: caret), ask: Self.liveAsk) else {
                return XCTFail("caret \(caret)")
            }
            XCTAssertEqual(w.other?.digit, 4, "caret \(caret): Other offered")
            XCTAssertEqual(w.buttons.map(\.digit), [1, 2, 3])
            XCTAssertEqual(w.chat?.digit, 5)
        }
        let f = FormSim(.live)
        XCTAssertEqual(driver(f.io).other(try screen(Self.liveScreen(caret: 1)), digit: 4, text: "Kiwi please"), .done)
        XCTAssertEqual(f.log, ["down", "down", "down", "send Kiwi please", "enter"])
        // Already on the empty row (the capture itself), and back to empty after deleting (captures 07, 09: the same screen).
        let g = FormSim(.live)
        g.caret = 4
        XCTAssertEqual(driver(g.io).other(try screen(Self.live05), digit: 4, text: "Kiwi please"), .done)
        XCTAssertEqual(g.log, ["send Kiwi please", "enter"])
    }

    /// QA #649 INFO 5: a multi-select whose Other row has no box (it follows the boxes and the
    /// Submit row): Submit with typed text must send nothing, not index the boxes past their end
    /// (an app crash). QA #651 INFO-3 (#818): classify no longer offers that row as a typed answer;
    /// the driver's guard stays as defense in depth.
    @MainActor
    func testAgentWindowMultiSelectUnboxedOtherRowSendsNothing() throws {
        let text = ["❯ Use the AskUserQuestion tool with multiSelect set to true to ask me 'Which colors?'", Self.rule,
                    "←  ☐ Colors  ✔ Submit  →", "", "Which colors?", "",
                    "❯ 1. [ ] Red", "         Red", "  2. [ ] Green", "         Green", "  3. [ ] Blue", "         Blue",
                    "     Submit", "  4. Type something", Self.rule, "  5. Chat about this", "",
                    "Enter to select · ↑/↓ to navigate · Esc to cancel"].joined(separator: "\n")
        guard case .prompt(let w) = AgentWindowPanel.classify(text, ask: Self.multiAsk) else { return XCTFail("not a prompt") }
        XCTAssertEqual(w.kind, .multi)
        XCTAssertNil(w.other, "the unboxed Other row is not offered")
        XCTAssertEqual(w.buttons.map(\.digit), [1, 2, 3])
        XCTAssertEqual(w.chat?.digit, 5, "Chat about this still is")
        // The boxed Other row of the same form still is.
        guard case .prompt(let boxed) = AgentWindowPanel.classify(Self.multiScreen([false, false, false, false], caret: 1),
                                                                  ask: Self.multiAsk) else { return XCTFail("not a prompt") }
        XCTAssertEqual(boxed.other?.digit, 4)
        for picks: Set<Int> in [[], [1]] {
            let f = FormSim(.plain(text))
            XCTAssertEqual(driver(f.io).multi(w.screen, picks: picks, other: (4, "Teal")), .failed(AgentWindowText.unchecked))
            XCTAssertEqual(f.log, [], "\(picks): nothing sent")
        }
    }

    /// #818 Q4: with the caret on an input row Claude Code types a digit into the row as text, so
    /// `AgentPrompt.answer` (the island card, the window's single choice) re-reads the caret and
    /// sends nothing there. The live capture, then each rule of `caretOnInput` alone.
    func testIslandAnswerSendsNothingWithTheCaretOnAnInputRow() throws {
        let noChat = { (s: String) -> String in
            let t = s.replacingOccurrences(of: "\n" + Self.rule + "\n  5. Chat about this", with: "")
            XCTAssertNotEqual(t, s, "the Chat about this row taken off")
            return t
        }
        func answer(_ now: String, _ expected: String) throws -> (AgentPromptAnswer, [String]) {
            let f = FormSim(.plain(now))
            return (AgentPrompt.answer(Self.key, digit: 1, expected: try XCTUnwrap(AgentPrompt.parse(expected)), io: f.io), f.log)
        }
        let cases: [(String, String, String)] = [
            ("live05: the placeholder, the ctrl+g footer, above Chat about this", Self.live05, Self.liveScreen(caret: 1)),
            ("typed text above Chat about this, no ctrl+g footer",
             Self.singleScreen(caret: 4, typed: "Kiwi"), Self.singleScreen(caret: 1, typed: "Kiwi")),
            ("the placeholder alone", noChat(Self.singleScreen(caret: 4)), noChat(Self.singleScreen(caret: 1))),
            ("the ctrl+g footer alone", noChat(Self.liveScreen(caret: 4, typed: "Kiwi")), noChat(Self.liveScreen(caret: 1, typed: "Kiwi"))),
        ]
        for (name, now, expected) in cases {
            let (r, log) = try answer(now, expected)
            XCTAssertEqual(r, .changed, name)
            XCTAssertEqual(log, [], "\(name): nothing typed into the row")
            // The same dialog with the caret on an answer row: the digit goes.
            XCTAssertEqual(try answer(expected, expected).0, .sent, "\(name), caret on 1")
        }
        // The plan feedback row (its hint), with no ctrl+g footer: the island never answers a plan
        // (#823), so the rule is pinned on the read itself.
        let rows = AgentWindowInteractionTests.planRowsClear
        XCTAssertTrue(try XCTUnwrap(AgentPrompt.screen(Self.planScreen(caret: 4, rows: rows, footer: "Esc to cancel"))).caretOnInput)
        XCTAssertFalse(try XCTUnwrap(AgentPrompt.screen(Self.planScreen(caret: 1, rows: rows, footer: "Esc to cancel"))).caretOnInput)
        // Through the live form: the caret on Other, a click on 1 types nothing.
        let g = FormSim(.live)
        g.caret = 4
        XCTAssertEqual(AgentPrompt.answer(Self.key, digit: 1, expected: try XCTUnwrap(AgentPrompt.parse(Self.liveScreen(caret: 1))),
                                          io: g.io), .changed)
        XCTAssertEqual(g.typed, "")
        XCTAssertEqual(g.log, [])
    }

    /// QA #653 INFO-1 (#825): a short pty with the form's top rule (and its header chips) scrolled
    /// off, and Other text typed in the terminal before the card drew. The "No, …" row stays on
    /// with the top off; a click on it would type its digit into Other. The caret above "Chat about
    /// this" is an input row chip line or not, so nothing is sent.
    func testIslandAnswerSendsNothingWithTheCaretOnTypedOtherAndTheTopOffTheScreen() throws {
        func screen(caret: Int) -> String {
            let mark = { (i: Int) in caret == i ? "❯" : " " }
            return ["Which color?", "",
                    "\(mark(1)) 1. Red", "     Choose red", "\(mark(2)) 2. No, skip the color", "     Pick none",
                    "\(mark(3)) 3. Kiwi", Self.rule, "\(mark(4)) 4. Chat about this", "",
                    "Enter to select · ↑/↓ to navigate · Esc to cancel"].joined(separator: "\n")
        }
        let shown = try XCTUnwrap(AgentPrompt.parse(screen(caret: 1)))
        XCTAssertFalse(shown.topFound, "the top is off the screen")
        XCTAssertFalse(shown.context.last.map(AgentPrompt.isChipLine) ?? false, "no chip line")
        let no = try XCTUnwrap(shown.options.first { $0.label.hasPrefix("No,") })
        XCTAssertTrue(shown.isEnabled(no), "the deny row stays on")
        XCTAssertTrue(try XCTUnwrap(AgentPrompt.screen(screen(caret: 3))).caretOnInput)
        let f = FormSim(.plain(screen(caret: 3)))
        XCTAssertEqual(AgentPrompt.answer(Self.key, digit: no.digit, expected: shown, io: f.io), .changed)
        XCTAssertEqual(f.log, [], "nothing typed into Other")
        // Control: the caret on Red, the No click answers.
        let g = FormSim(.plain(screen(caret: 1)))
        XCTAssertEqual(AgentPrompt.answer(Self.key, digit: no.digit, expected: shown, io: g.io), .sent)
        XCTAssertEqual(g.log, ["send 2"])
    }

    /// QA #658 INFO-1 (#826): Other's typed text reads exactly "Chat about this", no ctrl+g footer.
    /// The real "Chat about this" row is the bottom one, so the caret on Other is an input row.
    func testCaretOnInputWithOtherTypedAsChatAboutThis() throws {
        let screen = ["Which color?", "",
                      "  1. Red", "  2. Kiwi", "❯ 3. Chat about this", Self.rule, "  4. Chat about this", "",
                      "Enter to select · ↑/↓ to navigate · Esc to cancel"].joined(separator: "\n")
        let s = try XCTUnwrap(AgentPrompt.screen(screen))
        XCTAssertEqual(s.caret, 3)
        XCTAssertTrue(s.caretOnInput, "the caret on typed Other")
    }

    /// A screen that a test swaps between the window drawing its panel and the click.
    final class ScreenBox: @unchecked Sendable {
        let lock = NSLock()
        private var screen: String
        private(set) var sent: [String] = []
        init(_ screen: String) { self.screen = screen }
        func set(_ s: String) { lock.withLock { screen = s } }
        var io: AgentPromptIO {
            AgentPromptIO(read: { _ in self.lock.withLock { self.screen } }, status: { _ in "blocked" },
                          send: { _, t in self.lock.withLock { self.sent.append(t) } })
        }
    }

    /// Supervisor review h2 (#818): a fresh read with no caret, or with the caret on no known row,
    /// never lets a digit go. The parse needs exactly one caret, on an option, so through
    /// `answer` (the island card, the window's single choice) such a read is no prompt at all;
    /// `caretOnInput` itself is pinned on hand-built reads (no caret, a caret on digit 9).
    @MainActor
    func testIslandAnswerSendsNothingWithNoCaretOrACaretOnNoRow() throws {
        let shown = Self.permission(), bare = shown.replacingOccurrences(of: "❯", with: " ")
        XCTAssertNotEqual(bare, shown)
        let p = try XCTUnwrap(AgentPrompt.parse(shown))
        XCTAssertNil(AgentPrompt.screen(bare), "no caret: no prompt")
        // The island card: no caret sends nothing; the caret on row 1 sends the digit.
        let f = FormSim(.plain(bare))
        XCTAssertEqual(AgentPrompt.answer(Self.key, digit: 1, expected: p, io: f.io), .changed)
        XCTAssertEqual(f.log, [])
        let ok = FormSim(.plain(shown))
        XCTAssertEqual(AgentPrompt.answer(Self.key, digit: 1, expected: p, io: ok.io), .sent)
        XCTAssertEqual(ok.log, ["send 1"])
        // The rule itself.
        let s = try XCTUnwrap(AgentPrompt.screen(shown))
        XCTAssertFalse(s.caretOnInput, "the caret on row 1")
        for caret: Int? in [nil, 9] {
            var r = s
            r.caret = caret
            XCTAssertTrue(r.caretOnInput, "caret \(String(describing: caret))")
        }
        // The window's single choice: drawn with the caret on row 1, clicked after the caret went.
        for (now, sent) in [(bare, [String]()), (shown, ["1"])] {
            let box = ScreenBox(shown)
            let i = interaction(controller(box.io, autoAllow: false))
            i.follow(session(.blocked))
            guard case .prompt(let w) = i.panel else { return XCTFail("\(i.panel)") }
            XCTAssertTrue(w.enabled.contains(1))
            box.set(now)
            i.answer(w.buttons[0])
            until("answered") { !i.busy }
            XCTAssertEqual(box.sent, sent, now == bare ? "no caret" : "control")
            if now == bare { XCTAssertEqual(i.notice, AgentWindowText.changed) }
        }
    }

    /// #818 Q3: Claude Code draws "Chat about this" outside the form's numbered rows, so its digit
    /// answers nothing: the island card (and the window's single choice without the ask) keeps it off.
    @MainActor
    func testIslandCardKeepsChatAboutThisOff() throws {
        for text in [Self.singleScreen(caret: 1), Self.liveScreen(caret: 1)] {
            let p = try XCTUnwrap(AgentPrompt.parse(text))
            let chat = try XCTUnwrap(p.options.last)
            XCTAssertEqual(chat.label, "Chat about this")
            XCTAssertFalse(p.isEnabled(chat))
            XCTAssertTrue(p.isEnabled(p.options[0]))
            let f = FormSim(.plain(text))
            XCTAssertEqual(AgentPrompt.answer(Self.key, digit: chat.digit, expected: p, io: f.io), .changed)
            XCTAssertEqual(f.log, [])
            guard case .prompt(let w) = AgentWindowPanel.classify(text, ask: nil) else { return XCTFail("not a prompt") }
            XCTAssertFalse(w.enabled.contains(chat.digit))
            XCTAssertNil(w.chat, "no walk without the ask")
        }
    }

    // MARK: - Messages

    final class MessageFake: @unchecked Sendable {
        let lock = NSLock()
        var statuses: [String]
        var screens: [String]
        var reply: String
        var says: [String] = []
        var keys: [[String]] = []
        /// QA #651 INFO-2: what `noMirror` answers (dch-lite: true), and how often it was asked.
        var lite = false
        var mirrorAsks = 0
        /// #820: the first read is the one before the message or Esc: Claude's composer, no prompt.
        init(statuses: [String], screens: [String] = [AgentWindowInteractionTests.idleScreen], reply: String = #"{"name":"s","result":"ok","reason":"","detail":""}"#) {
            (self.statuses, self.screens, self.reply) = (statuses, screens, reply)
        }
        private func next(_ a: inout [String]) -> String { a.count > 1 ? a.removeFirst() : a[0] }
        var io: AgentPromptIO {
            AgentPromptIO(read: { _ in self.lock.withLock { self.next(&self.screens) } },
                          status: { _ in self.lock.withLock { self.next(&self.statuses) } },
                          send: { _, _ in XCTFail("a message never goes through --send") },
                          keys: { _, k in self.lock.withLock { self.keys.append(k) } },
                          say: { _, t in self.lock.withLock { self.says.append(t); return self.reply } },
                          noMirror: { _ in self.lock.withLock { self.mirrorAsks += 1; return self.lite } })
        }
    }

    func testAgentWindowSendsOneMessageThroughSayAndConfirmsIt() {
        let text = "Fix the build.\nThen run the tests\n\n  and report."
        let f = MessageFake(statuses: ["idle\n", "working\n"])
        XCTAssertEqual(driver(f.io).send(text), .done)
        XCTAssertEqual(f.says, [text], "one --say call: the newlines stay inside one message")
        let g = MessageFake(statuses: ["done"])
        XCTAssertEqual(driver(g.io).send("hi"), .failed(AgentWindowText.unconfirmed), "idle again with no echo: not confirmed")
        let h = MessageFake(statuses: ["idle"], screens: [Self.idleScreen, "", "> Fix the build please now and then"])
        XCTAssertEqual(driver(h.io).send("Fix the build please now and then"), .done, "the head shows on screen")
        let k = MessageFake(statuses: ["idle", "blocked"])
        XCTAssertEqual(driver(k.io).send("go"), .done, "a prompt after the message: it was taken")
        XCTAssertEqual(AgentWindowDriver.message("a\r\nb\rc\n"), "a\nb\nc")
        XCTAssertNil(AgentWindowDriver.message(" \n\t"))
        XCTAssertEqual(AgentWindowDriver.count(AgentWindowDriver.head("ab  cd"), in: "x a b\n  cd y abcd"), 2)
    }

    /// QA #629 INFO-1: a message keeps LF and tab (plain text inside dch's bracketed paste) and
    /// drops every other control character: ESC[201~ would end the paste early and the rest
    /// would arrive as keystrokes; C1 CSI (U+009B), DEL and NUL go too.
    @MainActor
    func testAgentWindowMessageDropsControlCharacters() {
        XCTAssertEqual(AgentWindowDriver.message("a\u{1B}[201~b\u{7}c\u{9B}d\u{7F}e\u{0}f\tg\r\nh"), "a[201~bcdef\tg\nh")
        XCTAssertNil(AgentWindowDriver.message("\u{1B}\u{3}\n"), "nothing but controls: nothing to send")
        XCTAssertEqual(AgentWindowDriver.message("👩‍💻 o\u{200B}k"), "👩‍💻 o\u{200B}k", "only controls go: ZWJ emoji and format characters stay")
        let f = MessageFake(statuses: ["idle", "working"])
        let i = interaction(controller(f.io, autoAllow: false))
        i.follow(session(.idle))
        i.draft = "fix it\u{1B}[201~\u{1B}[A\nthen test"
        i.send()
        until("sent") { !i.busy }
        XCTAssertEqual(f.says, ["fix it[201~[A\nthen test"], "what --say gets has no ESC")
        XCTAssertEqual(i.draft, "")
    }

    func testAgentWindowRefusesAMessageUnlessIdleOrDone() {
        for (status, why) in [("working", AgentWindowText.working), ("blocked", AgentWindowText.blocked), ("", AgentWindowText.noStatus)] {
            let f = MessageFake(statuses: [status])
            XCTAssertEqual(driver(f.io).send("hi"), .failed(why), status)
            XCTAssertEqual(f.says, [], "\(status): nothing typed")
        }
    }

    func testAgentWindowMapsEverySayRefusal() {
        let cases: [(String, String)] = [
            (#"{"name":"s","result":"skipped","reason":"prompt","detail":""}"#, AgentWindowText.blocked),
            (#"{"name":"s","result":"skipped","reason":"draft","detail":""}"#, AgentWindowText.draft),
            (#"{"name":"s","result":"skipped","reason":"no_screen","detail":""}"#, AgentWindowText.noScreen),
            (#"{"name":"s","result":"skipped","reason":"not_claude","detail":""}"#, AgentWindowText.notClaude),
            (#"{"name":"s","result":"failed","reason":"not_submitted","detail":""}"#, AgentWindowText.notSubmitted),
            // #854: dch 1.46's signal outcomes.
            (#"{"name":"s","result":"failed","reason":"draft_left","detail":""}"#, AgentWindowText.draftLeft),
            (#"{"name":"s","result":"failed","reason":"withdrawn","detail":""}"#, AgentWindowText.notSent),
            (#"{"name":"s","result":"failed","reason":"interrupted","detail":""}"#, AgentWindowText.notSent),
            (#"{"name":"s","result":"failed","reason":"no_session","detail":""}"#, "dch didn't send it (no_session). Open in terminal"),
            ("", AgentWindowText.unconfirmed),
            ("dch: unknown option --say", AgentWindowText.unconfirmed),
        ]
        for (reply, why) in cases {
            let f = MessageFake(statuses: ["idle", "working"], reply: reply)
            XCTAssertEqual(driver(f.io).send("hi"), .failed(why), reply)
        }
    }

    // MARK: - Interrupt

    func testAgentWindowInterruptSendsEscOnlyWhileWorkingAndConfirms() {
        let f = MessageFake(statuses: ["working", "working", "idle"])
        XCTAssertEqual(driver(f.io).interrupt(), .done)
        XCTAssertEqual(f.keys, [["esc"]])
        let g = MessageFake(statuses: ["idle"])
        XCTAssertEqual(driver(g.io).interrupt(), .failed(AgentWindowText.notWorking))
        XCTAssertEqual(g.keys, [])
        let h = MessageFake(statuses: ["working"])
        XCTAssertEqual(driver(h.io).interrupt(), .failed(AgentWindowText.unconfirmed))
        XCTAssertEqual(h.keys, [["esc"]])
        let k = MessageFake(statuses: ["working"], screens: [Self.idleScreen, "", "⎿  Interrupted · What should Claude do instead?"])
        XCTAssertEqual(driver(k.io).interrupt(), .done)
    }

    /// QA #629 INFO-2: dch's status is asked last, right before the Esc: a prompt raised while
    /// the screen was read gets no Esc (it would answer "No").
    func testAgentWindowInterruptAsksTheStatusRightBeforeTheKey() {
        let f = FormSim(.plain(Self.idleScreen))
        f.status = "working"
        f.afterRead = { $0.status = "blocked" }
        XCTAssertEqual(driver(f.io).interrupt(), .failed(AgentWindowText.notWorking))
        XCTAssertEqual(f.log, [], "no Esc into the prompt")
        XCTAssertEqual(f.reads, 1)
        let g = FormSim(.plain(Self.idleScreen))
        g.status = "working"
        g.afterKey = { $0.status = "idle" }
        XCTAssertEqual(driver(g.io).interrupt(), .done)
        XCTAssertEqual(g.log, ["esc"])
    }

    /// #820: dch can say idle or working over a prompt it misreads (1.35.0 over Claude Code
    /// 2.1.318's plan approval). A pasted "1" could approve the plan, an Esc rejects it: the
    /// screen read right before the paste or the Esc must hold no prompt, and must have been read.
    func testAgentWindowMessageAndInterruptSendNothingOverAPromptDchMissed() {
        let prompts = [("plan", Self.planScreen(caret: 1)), ("plan-feedback-row", Self.planScreen(caret: 3)),
                       ("ask-live", Self.liveScreen(caret: 1)), ("ask-other-row", Self.liveScreen(caret: 4)),
                       ("ask-multi", Self.multiScreen([false, true, false, false], caret: 1)),
                       ("ask-preview", Self.previewScreen(caret: 1)), ("permission", Self.permission())]
        for (name, screen) in prompts {
            for st in ["idle", "done"] {
                let f = MessageFake(statuses: [st, "working"], screens: [screen])
                XCTAssertEqual(driver(f.io).send("1"), .failed(AgentWindowText.promptShown), "\(name) \(st)")
                XCTAssertEqual(f.says, [], "\(name) \(st): nothing pasted")
            }
            let g = MessageFake(statuses: ["working", "idle"], screens: [screen])
            XCTAssertEqual(driver(g.io).interrupt(), .failed(AgentWindowText.promptShown), name)
            XCTAssertEqual(g.keys, [], "\(name): no Esc")
        }
        // Fail closed: no read (dch timed out) sends nothing either.
        let f = MessageFake(statuses: ["idle", "working"], screens: [""])
        XCTAssertEqual(driver(f.io).send("1"), .failed(AgentWindowText.unconfirmed))
        XCTAssertEqual(f.says, [])
        let g = MessageFake(statuses: ["working", "idle"], screens: [""])
        XCTAssertEqual(driver(g.io).interrupt(), .failed(AgentWindowText.unconfirmed))
        XCTAssertEqual(g.keys, [])
        // The live capture after the plan's Esc (#819 capture 05, Claude's composer): sent.
        let after = ["✻ Brewed for 7s · done 9:38 PM", Self.rule, "❯ ", Self.rule, "  ⏸ plan mode on (shift+tab to cycle)"]
            .joined(separator: "\n")
        let h = MessageFake(statuses: ["idle", "working"], screens: [after])
        XCTAssertEqual(driver(h.io).send("1"), .done)
        XCTAssertEqual(h.says, ["1"])
    }

    /// QA #651 F1: a plan approval with no footer (no editor detected) is no parsed prompt, and
    /// dch before 1.36.1 says working over it: the caret row or the plan's question still
    /// refuses, so no paste picks a row and no Esc rejects the plan, whatever the status.
    func testAgentWindowMessageAndInterruptSendNothingOverAnUnparsedPlan() {
        let plan = Self.planScreen(caret: 1, footer: nil)
        XCTAssertNil(AgentPrompt.screen(plan), "the parse's contract stays: approve() needs the footer")
        // Each check alone: the question line renamed (the caret row), no caret drawn (the question).
        let noQuestion = plan.replacingOccurrences(of: "Claude has written up a plan and is ready to execute. ", with: "")
        let noCaret = Self.planScreen(caret: 0, footer: nil)
        for (name, screen) in [("plan", plan), ("caret-row", noQuestion), ("plan-question", noCaret)] {
            XCTAssertNil(AgentPrompt.screen(screen), name)
            XCTAssertEqual(AgentWindowDriver.refusal(screen), AgentWindowText.promptShown, name)
            for st in ["idle", "done", "working"] {
                let f = MessageFake(statuses: [st, "working"], screens: [screen])
                XCTAssertNotEqual(driver(f.io).send("1"), .done, "\(name) \(st)")
                XCTAssertEqual(f.says, [], "\(name) \(st): nothing pasted")
                XCTAssertEqual(f.keys, [], "\(name) \(st)")
                let g = MessageFake(statuses: [st, "idle"], screens: [screen])
                XCTAssertEqual(driver(g.io).interrupt(), .failed(AgentWindowText.promptShown), "\(name) \(st)")
                XCTAssertEqual(g.keys, [], "\(name) \(st): no Esc")
                XCTAssertEqual(g.says, [], "\(name) \(st)")
            }
            let f = MessageFake(statuses: ["idle", "working"], screens: [screen])
            XCTAssertEqual(driver(f.io).send("1"), .failed(AgentWindowText.promptShown), name)
        }
    }

    /// QA #651 F1: Claude Code's composer holding a draft that starts with a digit ("❯ 1. fix
    /// the build", under a rule, closed by a rule) is typed text, never a caret row: sent. So is
    /// such a message echoed in the transcript above the composer, and the plan's question quoted there.
    func testAgentWindowComposerDraftWithADigitStillSends() {
        let draft = ["⏺ Done.", "", Self.rule, "❯ 1. fix the build", "  2. then run the tests", Self.rule, "  ? for shortcuts"]
        let echo = ["❯ 1. fix the build", "", "  Claude has written up a plan, the dialog said.", "", Self.rule, "❯ ", Self.rule,
                    "  ⏸ plan mode on (shift+tab to cycle)"]
        for (name, lines) in [("draft", draft), ("echo", echo)] {
            let screen = lines.joined(separator: "\n")
            XCTAssertNil(AgentWindowDriver.refusal(screen), name)
            let f = MessageFake(statuses: ["idle", "working"], screens: [screen])
            XCTAssertEqual(driver(f.io).send("go"), .done, name)
            XCTAssertEqual(f.says, ["go"], name)
            let g = MessageFake(statuses: ["working", "idle"], screens: [screen])
            XCTAssertEqual(driver(g.io).interrupt(), .done, name)
            XCTAssertEqual(g.keys, [["esc"]], name)
        }
        // A focused "Chat about this" row right under a rule, with no rule below it, is a dialog row.
        let chat = [Self.rule, "❯ 5. Chat about this"].joined(separator: "\n")
        XCTAssertEqual(AgentWindowDriver.refusal(chat), AgentWindowText.promptShown)
    }

    /// QA #651 INFO-2: on a dch with no terminal mirror (dch-lite) every read is empty. Still
    /// nothing is sent, but the window says why: noScreen, not "Couldn't confirm". A full dch
    /// whose read timed out still reads unconfirmed. The mirror is asked only after an empty read.
    func testAgentWindowNoMirrorSaysSoAndSendsNothing() {
        for lite in [true, false] {
            let f = MessageFake(statuses: ["idle", "working"], screens: [""])
            f.lite = lite
            XCTAssertEqual(driver(f.io).send("1"), .failed(lite ? AgentWindowText.noScreen : AgentWindowText.unconfirmed))
            XCTAssertEqual(f.says, [])
            let g = MessageFake(statuses: ["working", "idle"], screens: [""])
            g.lite = lite
            XCTAssertEqual(driver(g.io).interrupt(),
                           .failed(lite ? AgentWindowText.noScreenInterrupt : AgentWindowText.unconfirmed))
            XCTAssertEqual(g.keys, [])
        }
        let h = MessageFake(statuses: ["idle", "working"])
        h.lite = true
        XCTAssertEqual(driver(h.io).send("go"), .done, "a screen read: the mirror is not asked")
        XCTAssertEqual(h.mirrorAsks, 0)
        // Live: the probe is `--read <name>` with the session's env; exit 3 alone means no mirror.
        final class Rec: @unchecked Sendable { let lock = NSLock(); var calls: [[String]] = [] }
        let r = Rec()
        let io = AgentPromptIO.live(run: { _, _ in Data() }, say: { _, _ in Data() }, noMirror: { args, env in
            XCTAssertEqual(env["DCH_SOCKET_DIR"], "/tmp/dch-test")
            r.lock.withLock { r.calls.append(args) }; return true
        })
        XCTAssertTrue(io.noMirror(Self.key))
        XCTAssertEqual(r.calls, [["--read", "s"]])
    }

    /// #820 through the window: the list and dch say idle, the screen holds a plan approval. The
    /// notice says why (with Open in terminal) and the draft stays.
    @MainActor
    func testAgentWindowMessageOverAMissedPromptShowsWhyAndKeepsTheDraft() {
        let f = MessageFake(statuses: ["idle", "working"], screens: [Self.planScreen(caret: 1)])
        let i = interaction(controller(f.io, autoAllow: false))
        i.follow(session(.idle))
        i.draft = "1"
        i.send()
        until("refused") { !i.busy }
        XCTAssertEqual(i.notice, AgentWindowText.promptShown)
        XCTAssertEqual(i.draft, "1")
        XCTAssertEqual(f.says, [])
        let g = MessageFake(statuses: ["working", "working"], screens: [Self.planScreen(caret: 1)])
        let k = interaction(controller(g.io, autoAllow: false))
        k.follow(session(.working))
        k.interrupt()
        until("refused") { !k.busy }
        XCTAssertEqual(k.notice, AgentWindowText.promptShown)
        XCTAssertEqual(g.keys, [])
    }

    func testAgentWindowLiveIOCallsKeysAndSayWithTheSessionEnv() {
        final class Rec: @unchecked Sendable { var calls: [[String]] = [] }
        let r = Rec(), l = Rec()
        let io = AgentPromptIO.live(run: { args, env in
            XCTAssertEqual(env["DCH_SOCKET_DIR"], "/tmp/dch-test")
            r.calls.append(args); return Data()
        }, say: { args, env in
            XCTAssertEqual(env["DCH_SOCKET_DIR"], "/tmp/dch-test")
            l.calls.append(args); return Data(#"{"result":"ok"}"#.utf8)
        })
        io.keys(Self.key, ["esc"])
        XCTAssertEqual(io.say(Self.key, "-a\nb"), #"{"result":"ok"}"#)
        XCTAssertEqual(r.calls, [["--keys", "s", "esc"]])
        XCTAssertEqual(l.calls, [["--say", "s", "--json", "--", "-a\nb"]], "the text after --, so a leading dash is text")
        XCTAssertGreaterThan(AgentPromptIO.sayTimeout, 30 + 25, "dch's land wait and Enter retries fit")
    }

    /// QA #629 F1: the live argv of every verb. `--send` carries free Other text, and dch
    /// parses anything before "--" as its own flags ("-kl" kills every session, "-m" clears
    /// an alias), so the text always goes after "--", even text that is itself "--".
    func testAgentWindowLiveSendPutsTheTextAfterDashDash() {
        final class Rec: @unchecked Sendable { let lock = NSLock(); var calls: [[String]] = [] }
        let r = Rec()
        let io = AgentPromptIO.live(run: { args, _ in r.lock.withLock { r.calls.append(args) }; return Data() },
                                    say: { args, _ in r.lock.withLock { r.calls.append(args) }; return Data() })
        for t in ["-kl", "--", "-m x", "3"] { io.send(Self.key, t) }
        io.keys(Self.key, ["down", "enter"])
        _ = io.say(Self.key, "-kl")
        _ = io.read(Self.key)
        _ = io.status(Self.key)
        XCTAssertEqual(r.calls, [["--send", "s", "--", "-kl"], ["--send", "s", "--", "--"], ["--send", "s", "--", "-m x"],
                                 ["--send", "s", "--", "3"], ["--keys", "s", "down", "enter"],
                                 ["--say", "s", "--json", "--", "-kl"], ["--read", "s"], ["--status", "s"]])
        // The Other path end to end: the typed text reaches dch only after "--".
        let f = FormSim(.single)
        f.caret = 4
        r.lock.withLock { r.calls = [] }
        let rec = AgentPromptIO.live(run: { args, env in
            r.lock.withLock { r.calls.append(args) }
            switch args[0] {
            case "--read": return Data(f.io.read(Self.key).utf8)
            case "--status": return Data(f.io.status(Self.key).utf8)
            case "--send": f.io.send(Self.key, args.last ?? "")
            case "--keys": f.io.keys(Self.key, Array(args[2...]))
            default: break
            }
            return Data()
        })
        XCTAssertEqual(driver(rec).other(try! screen(Self.singleScreen(caret: 4)), digit: 4, text: "-kl"), .done)
        XCTAssertEqual(r.calls.filter { $0[0] == "--send" || $0[0] == "--keys" }, [["--send", "s", "--", "-kl"], ["--keys", "s", "enter"]])
    }

    // MARK: - Through the controller: the window's click is the human's

    @MainActor
    func controller(_ io: AgentPromptIO, autoAllow: Bool = true) -> AgentIslandController {
        let c = AgentIslandController()
        c.io = io
        c.showsPanel = false
        c.store = AgentIslandStore(geometry: AgentWindowD1Tests.geometry)
        c.autoAllowOn = { autoAllow }
        c.after = { _, _ in }
        c.onSessions = { _ in }
        return c
    }

    func session(_ state: AgentState) -> AgentSession {
        AgentSession(key: Self.key, alias: "", activity: 1, state: state, agents: 0)
    }

    @MainActor
    func interaction(_ c: AgentIslandController?) -> AgentWindowInteraction {
        let i = AgentWindowInteraction()
        i.controller = c
        i.pause = { _ in }
        i.readQueue = { $0() }
        return i
    }

    @MainActor
    func until(_ what: String, _ cond: () -> Bool) {
        let deadline = Date().addingTimeInterval(5)
        while !cond(), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertTrue(cond(), what)
    }

    @MainActor
    func testAgentWindowAnswersThroughTheIslandsClickPathAndLeavesThePromptToTheHuman() throws {
        let f = FormSim(.plain(Self.modeSwitch))
        let c = controller(f.io)
        c.store?.sessions = [session(.blocked)]
        c.checkAutoAllow()
        until("Always allow leaves the prompt to the human") { !c.heldByAutoAllow(Self.key) }
        let i = interaction(c)
        i.follow(session(.blocked))
        guard case .prompt(let w) = i.panel else { return XCTFail("\(i.panel)") }
        XCTAssertEqual(w.enabled, [3])
        i.answer(w.buttons[0])
        XCTAssertFalse(i.busy, "a disabled option sends nothing")
        i.answer(w.buttons[2])
        XCTAssertTrue(i.busy)
        XCTAssertTrue(c.heldByAutoAllow(Self.key), "in flight: the island shows no card meanwhile")
        until("answered") { !i.busy }
        XCTAssertEqual(f.log, ["send 3"])
        XCTAssertNil(i.notice)
        XCTAssertEqual(i.panel, .none, "the read after the answer finds Claude at work, not an unreadable prompt")
        // The same prompt back is the human's: Always allow types nothing.
        f.lock.withLock { f.gone = false; f.status = "blocked" }
        c.store?.sessions = [session(.blocked)]
        c.checkAutoAllow()
        c.queue.sync {}
        XCTAssertEqual(f.log, ["send 3"])
    }

    @MainActor
    func testAgentWindowShowsNoButtonsWhileAlwaysAllowHoldsThePrompt() {
        let f = FormSim(.plain(Self.permission()))
        let gate = DispatchSemaphore(value: 0)
        // The first read waits for the test; every later one passes.
        let c = controller(AgentPromptIO(read: { k in gate.wait(); gate.signal(); return f.io.read(k) },
                                         status: f.io.status, send: f.io.send))
        c.store?.sessions = [session(.blocked)]
        c.checkAutoAllow()
        XCTAssertTrue(c.heldByAutoAllow(Self.key))
        let i = interaction(c)
        i.follow(session(.blocked))
        XCTAssertEqual(i.panel, .held)
        XCTAssertEqual(i.reads, 0, "nothing read while held")
        gate.signal()
        until("Always allow answered") { !c.heldByAutoAllow(Self.key) || f.lock.withLock { !f.log.isEmpty } }
        c.queue.sync {}
        XCTAssertEqual(f.log, ["send 1"], "Always allow's own answer, unchanged")
    }

    /// Review round 2 S1 (#791/#794): every Always allow state that is not the human's holds
    /// the window, with no click in flight too: checking (the check reading the screen),
    /// answered (Prosper's Yes sent, its verify re-read pending) and left to dch (#792). The
    /// panel is held, nothing is read, and no answer, preview, Submit or Other attempt sends
    /// a key. Left to the human (.human(left:)): the buttons show.
    @MainActor
    func testAgentWindowEveryAlwaysAllowStateButTheHumansHoldsTheWindow() throws {
        let option = try XCTUnwrap(AgentPrompt.parse(Self.permission())).options[0]
        func settle(_ c: AgentIslandController) {
            c.queue.sync {}
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        func attempts(_ i: AgentWindowInteraction, _ name: String) {
            XCTAssertEqual(i.panel, .held, name)
            XCTAssertEqual(i.reads, 0, "\(name): nothing read while held")
            i.answer(option)
            i.choosePreview(option)
            i.picks = [1]
            i.submitPicks()
            i.otherText = "x"
            i.sendOther()
            XCTAssertFalse(i.busy, name)
        }

        // checking: Always allow's read is held at the gate.
        let gate = DispatchSemaphore(value: 0)
        let a = FormSim(.plain(Self.permission()))
        a.deaf = true   // its Yes is taken but the screen stays: the prompt is still on screen while answered
        let ca = controller(AgentPromptIO(read: { k in gate.wait(); gate.signal(); return a.io.read(k) },
                                          status: a.io.status, send: a.io.send, keys: a.io.keys))
        ca.store?.sessions = [session(.blocked)]
        ca.checkAutoAllow()
        XCTAssertTrue(ca.heldByAutoAllow(Self.key))
        attempts({ let i = interaction(ca); i.follow(session(.blocked)); return i }(), "checking")
        XCTAssertEqual(a.log, [])

        // answered: the check sent its Yes and is off the session; the verify re-read is pending.
        gate.signal()
        until("Always allow answered") { ca.store?.actions[Self.key] == AgentIslandController.autoAllowedText }
        settle(ca)
        XCTAssertEqual(a.log, ["send 1"])
        XCTAssertTrue(ca.heldByAutoAllow(Self.key), "answered holds")
        attempts({ let i = interaction(ca); i.follow(session(.blocked)); return i }(), "answered")
        settle(ca)
        XCTAssertEqual(a.log, ["send 1"], "answered: only Always allow's own key")

        // dch: dch answers this prompt itself (#792), Prosper stands down and reads nothing.
        let d = FormSim(.plain(Self.permission()))
        let cd = controller(d.io)
        final class Calls: @unchecked Sendable { let lock = NSLock(); var args: [[String]] = [] }
        let calls = Calls()
        cd.controlDch = { DchCommand.Binary(path: "/fake/dch", version: [1, 29, 2]) }
        cd.runDch = { _, a, _ in
            calls.lock.withLock { calls.args.append(a) }
            return (a == ["--build"] ? "full\n" : a == ["--config"]
                    ? "/Users/probe/.config/dch/config\nauto_allow = true\nsidekick_pattern = -qa\n" : nil).map { Data($0.utf8) }
        }
        let row = AgentSession(key: Self.key, alias: "", activity: 1, state: .blocked, agents: 0, version: "1.29.2")
        cd.store?.sessions = [row]
        cd.checkAutoAllow()
        settle(cd)
        XCTAssertEqual(calls.lock.withLock { calls.args }, [["--build"], ["--config"]], "dch's own auto-allow was asked")
        XCTAssertEqual(d.reads, 0, "left to dch: the check read no screen")
        XCTAssertTrue(cd.heldByAutoAllow(Self.key), "left to dch holds")
        attempts({ let i = interaction(cd); i.follow(row); return i }(), "dch")
        settle(cd)
        XCTAssertEqual(d.log, [], "dch: no key from Prosper")

        // human: Always allow left the prompt to the human; the window shows its buttons.
        let h = FormSim(.plain(Self.modeSwitch))
        let ch = controller(h.io)
        ch.store?.sessions = [session(.blocked)]
        ch.checkAutoAllow()
        settle(ch)
        XCTAssertEqual(h.log, [], "no plain Yes: never Always allow's")
        XCTAssertFalse(ch.heldByAutoAllow(Self.key), "the human's: no hold")
        let ih = interaction(ch)
        ih.follow(session(.blocked))
        guard case .prompt(let w) = ih.panel else { return XCTFail("human: \(ih.panel)") }
        XCTAssertFalse(w.enabled.isEmpty, "human: buttons")
    }

    @MainActor
    func testAgentWindowAnActionWhileAnIslandClickIsInFlightSendsNothing() throws {
        let f = FormSim(.plain(Self.modeSwitch))
        let c = controller(f.io, autoAllow: false)
        c.store?.sessions = [session(.blocked)]
        let i = interaction(c)
        i.follow(session(.blocked))
        guard case .prompt(let w) = i.panel else { return XCTFail() }
        let p = w.screen.prompt
        c.answer(session(.blocked), p, p.options[2])   // the island click, in flight
        i.answer(w.buttons[2])
        XCTAssertEqual(i.notice, AgentWindowText.busy)
        XCTAssertFalse(i.busy)
        c.queue.sync {}
        until("the click landed") { f.lock.withLock { !f.log.isEmpty } }
        XCTAssertEqual(f.log, ["send 3"], "one answer only")
    }

    @MainActor
    func testAgentWindowWindowSequencesRunThroughTheControllerAndRefreshThePanel() throws {
        let f = FormSim(.multi)
        let c = controller(f.io, autoAllow: false)
        let i = interaction(c)
        i.ask = Self.multiAsk
        i.follow(session(.blocked))
        guard case .prompt(let w) = i.panel else { return XCTFail("\(i.panel)") }
        XCTAssertEqual(w.kind, .multi)
        XCTAssertEqual(i.picks, [])
        i.picks = [2]
        i.submitPicks()
        until("submitted") { !i.busy }
        XCTAssertEqual(f.log, ["send 2", "down", "down", "down", "down", "enter"])
        // A form changed under the click shows the reason and reads again.
        let g = FormSim(.multi)
        let d = controller(g.io, autoAllow: false)
        let j = interaction(d)
        j.ask = Self.multiAsk
        j.follow(session(.blocked))
        g.lock.withLock { g.checked = [true, false, false, false] }
        j.picks = [2]
        j.submitPicks()
        until("refused") { !j.busy }
        XCTAssertEqual(g.log, [])
        XCTAssertEqual(j.notice, AgentWindowText.changed)
        guard case .prompt(let again) = j.panel else { return XCTFail() }
        XCTAssertEqual(again.screen.checked, [true, false, false, false], "the panel shows the screen as it is now")
        XCTAssertEqual(j.picks, [1])
    }

    /// Review round 1 F1: a form the island rule must not answer (a hidden character, or
    /// its top rule off screen) has every box off, and Submit must send nothing: it would
    /// untick the screen's boxes and press Enter, an empty answer nobody chose.
    @MainActor
    func testAgentWindowUnsafeFormsSendNothing() throws {
        let hidden = "Which\u{200B} colors?"
        let lines = Self.multiScreen([true, false, false, false], caret: 1).split(separator: "\n", omittingEmptySubsequences: false)
        let rule = try XCTUnwrap(lines.firstIndex { $0.hasPrefix("─") })
        let cases: [(String, String, AgentAskInput)] = [
            ("hidden character", Self.multiScreen([true, false, false, false], caret: 1, question: hidden),
             Self.ask(hidden, [("Red", "Red"), ("Green", "Green"), ("Blue", "Blue")], multi: true)),
            ("no top rule", lines[(rule + 1)...].joined(separator: "\n"), Self.multiAsk),
        ]
        for (name, screen, ask) in cases {
            let f = FormSim(.plain(screen))
            let i = interaction(controller(f.io, autoAllow: false))
            i.ask = ask
            i.follow(session(.blocked))
            guard case .prompt(let w) = i.panel else { return XCTFail("\(name): \(i.panel)") }
            XCTAssertEqual(w.kind, .multi, name)
            XCTAssertEqual(w.enabled, [], "\(name): every box off")
            i.picks = [1, 2]
            i.submitPicks()
            XCTAssertFalse(i.busy, name)
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            XCTAssertEqual(f.log, [], "\(name): no io.send, no io.keys")
        }
        // The preview form: its options are its only buttons, all off, and none runs.
        // A hidden character inside the preview box (the cross-check reads only question and options).
        let preview = Self.previewScreen(caret: 1).replacingOccurrences(of: "| item |", with: "| it\u{200B}em |")
        XCTAssertNotEqual(preview, Self.previewScreen(caret: 1))
        let f = FormSim(.plain(preview))
        let i = interaction(controller(f.io, autoAllow: false))
        i.ask = Self.previewAsk
        i.follow(session(.blocked))
        guard case .prompt(let w) = i.panel else { return XCTFail("preview: \(i.panel)") }
        XCTAssertEqual(w.kind, .preview)
        XCTAssertEqual(w.enabled, [])
        XCTAssertNil(w.other)
        for o in w.buttons { i.choosePreview(o) }
        i.submitPicks()
        i.otherText = "x"
        i.sendOther()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(f.log, [], "preview: nothing sent")
    }

    @MainActor
    func testAgentWindowMessageKeepsTheTextUnlessConfirmed() {
        let f = MessageFake(statuses: ["idle", "idle"])
        let c = controller(f.io, autoAllow: false)
        let i = interaction(c)
        i.follow(session(.idle))
        i.draft = "first line\nsecond line"
        i.send()
        until("sent") { !i.busy }
        XCTAssertEqual(f.says, ["first line\nsecond line"])
        XCTAssertEqual(i.notice, AgentWindowText.unconfirmed)
        XCTAssertEqual(i.draft, "first line\nsecond line", "unconfirmed: the text stays in the box")
        f.lock.withLock { f.statuses = ["idle", "working"] }
        i.send()
        until("sent again") { !i.busy }
        XCTAssertNil(i.notice)
        XCTAssertEqual(i.draft, "", "confirmed: the box is cleared")
        // Blocked or working per the list: nothing goes to dch, nothing is marked human.
        i.follow(session(.working))
        i.draft = "later"
        i.send()
        XCTAssertFalse(i.busy)
        XCTAssertEqual(i.notice, AgentWindowText.working)
        XCTAssertEqual(f.says.count, 2)
        XCTAssertEqual(i.draft, "later")
        // The draft is per session and survives a switch.
        i.follow(AgentSession(key: AgentSessionKey(dir: "/tmp/dch-test", name: "t"), alias: "", activity: 1, state: .idle, agents: 0))
        XCTAssertEqual(i.draft, "")
        i.follow(session(.working))
        XCTAssertEqual(i.draft, "later")
    }

    /// QA #629 INFO-3: a confirmed message clears its own session's draft even when the
    /// selection moved during the send, so Return back on that row cannot send it twice.
    @MainActor
    func testAgentWindowAConfirmedMessageClearsItsDraftAfterARowSwitch() {
        let f = MessageFake(statuses: ["idle", "working"])
        let gate = DispatchSemaphore(value: 0)
        let io = AgentPromptIO(read: f.io.read, status: f.io.status, send: f.io.send, keys: f.io.keys,
                               say: { k, t in gate.wait(); return f.io.say(k, t) })
        let i = interaction(controller(io, autoAllow: false))
        let other = AgentSession(key: AgentSessionKey(dir: "/tmp/dch-test", name: "t"), alias: "", activity: 1, state: .idle, agents: 0)
        i.follow(session(.idle))
        i.draft = "hello"
        i.send()
        XCTAssertTrue(i.busy)
        i.follow(other)
        i.draft = "for t"
        gate.signal()
        until("sent") { !i.busy }
        XCTAssertNil(i.notice)
        XCTAssertEqual(i.draft, "for t", "the other row's draft is its own")
        i.follow(session(.idle))
        XCTAssertEqual(i.draft, "", "the sent session's draft is cleared")
        i.send()
        XCTAssertFalse(i.busy)
        XCTAssertEqual(f.says, ["hello"], "sent once")
    }

    @MainActor
    func testAgentWindowInterruptGoesThroughTheController() {
        let f = MessageFake(statuses: ["working", "idle"])
        let c = controller(f.io, autoAllow: false)
        let i = interaction(c)
        i.follow(session(.working))
        i.interrupt()
        until("interrupted") { !i.busy }
        XCTAssertEqual(f.keys, [["esc"]])
        XCTAssertNil(i.notice)
        i.follow(session(.idle))
        i.interrupt()
        XCTAssertEqual(f.keys, [["esc"]], "not working: no Esc")
    }

    // MARK: - Energy: reads only on a transition

    @MainActor
    func testAgentWindowReadsOnlyOnTransitionsNeverOnATimer() {
        let f = FormSim(.plain(Self.permission()))
        let c = controller(f.io, autoAllow: false)
        let i = interaction(c)
        i.follow(session(.working))
        XCTAssertEqual(i.reads, 0)
        i.follow(session(.blocked))
        XCTAssertEqual(i.reads, 1, "landing on blocked reads once")
        for _ in 0..<5 { i.follow(session(.blocked)) }
        XCTAssertEqual(i.reads, 1, "list rebuilds read nothing")
        i.follow(session(.working))
        i.follow(session(.blocked))
        XCTAssertEqual(i.reads, 2, "re-entering blocked reads once")
        i.follow(nil)
        XCTAssertEqual(i.panel, .none)
        i.follow(session(.blocked))
        XCTAssertEqual(i.reads, 3, "shown again: one read")
        let off = interaction(nil)
        off.follow(session(.blocked))
        XCTAssertEqual(off.reads, 0, "no controller: nothing read")
        XCTAssertEqual(f.reads, 3)
    }

    @MainActor
    func testAgentWindowModelFeedsTheInteractionAndStopsItWhenHidden() throws {
        let url = tempDir().appendingPathComponent("ask.jsonl")
        let input: [String: Any] = ["questions": [["question": "Which colors?", "header": "Colors", "multiSelect": true,
                                                   "options": [["label": "Red", "description": "Red"],
                                                               ["label": "Green", "description": "Green"],
                                                               ["label": "Blue", "description": "Blue"]]]]]
        let entry: [String: Any] = ["type": "assistant", "sessionId": "s-1", "version": "2.1.300",
                                    "message": ["role": "assistant",
                                                "content": [["type": "tool_use", "id": "toolu_9", "name": "AskUserQuestion",
                                                             "input": input]]]]
        try (JSONSerialization.data(withJSONObject: entry) + Data("\n".utf8)).write(to: url)
        let f = FormSim(.multi)
        let c = controller(f.io, autoAllow: false)
        let st = AgentIslandStore(geometry: AgentWindowD1Tests.geometry)
        st.sessions = [AgentSession(key: Self.key, alias: "", activity: 1, state: .blocked, agents: 0, version: "1.30.0",
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
        showTranscript(m)   // #822: the prompt panel is Transcript mode's
        XCTAssertEqual(f.reads, 0, "hidden: nothing read")
        m.setVisible(true)
        XCTAssertEqual(m.transcript.pendingAsk?.id, "toolu_9")
        XCTAssertEqual(m.interaction.ask, m.transcript.pendingAsk)
        guard case .prompt(let w) = m.interaction.panel else { return XCTFail("\(m.interaction.panel)") }
        XCTAssertEqual(w.kind, .multi, "cross-checked against the transcript's input")
        // Review round 1 I2: another session with no transcript is never checked against A's question.
        let bKey = AgentSessionKey(dir: "/tmp/dch-test", name: "b")
        let a = st.sessions[0]
        st.sessions = [a, AgentSession(key: bKey, alias: "", activity: 0, state: .blocked, agents: 0, version: "1.30.0")]
        m.select(try XCTUnwrap(m.rows.first { $0.session?.key == bKey }?.id))
        XCTAssertNil(m.transcript.pendingAsk)
        XCTAssertNil(m.interaction.ask, "B has no transcript: no ask")
        m.select(try XCTUnwrap(m.rows.first { $0.session?.key == Self.key }?.id))
        XCTAssertEqual(m.interaction.ask?.id, "toolu_9", "back on A: its own ask")
        // The same session losing its mapping (the tail is kept for the grace period): no ask either.
        st.sessions = [AgentSession(key: Self.key, alias: "", activity: 1, state: .blocked, agents: 0, version: "1.30.0"),
                       st.sessions[1]]
        XCTAssertNil(m.interaction.ask, "no mapping: no ask")
        m.setVisible(false)
        XCTAssertEqual(m.interaction.panel, .none)
        let reads = f.reads
        st.sessions = st.sessions
        XCTAssertEqual(f.reads, reads, "hidden: a list change reads nothing")
        m.close()
    }

    // MARK: - Keys: the text field gets Return and the arrows (QA #626 INFO-2)

    func keyEvent(_ code: UInt16, _ chars: String, _ flags: NSEvent.ModifierFlags = [], window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber,
                         context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
    }

    func click(_ x: CGFloat, window: NSWindow) -> NSEvent {
        NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: x, y: 10), modifierFlags: [], timestamp: 0,
                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    @MainActor
    func testAgentWindowTheInputBoxGetsReturnAndArrowsAndTheSidebarOnlyItsOwn() throws {
        let st = AgentIslandStore(geometry: AgentWindowD1Tests.geometry)
        st.sessions = [session(.idle), AgentSession(key: AgentSessionKey(dir: "/tmp/dch-test", name: "t"), alias: "",
                                                    activity: 0, state: .working, agents: 0)]
        var opened = 0
        let m = AgentWindowModel()
        m.onVisible = { _ in }
        m.openSession = { _ in opened += 1 }
        m.ageInterval = 3600
        m.transcript.offMain = { $0() }
        m.bind(st)
        showTranscript(m)   // #822: the input box and the sidebar's Return are Transcript mode's
        m.setVisible(true)
        defer { m.close() }
        let first = m.selection
        XCTAssertNotNil(first)

        let win = AgentsNSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 400), styleMask: [.titled],
                                 backing: .buffered, defer: true)
        win.isReleasedWhenClosed = false
        win.model = m
        let tv = AgentComposerTextView(frame: NSRect(x: 400, y: 0, width: 300, height: 80))
        var submits = 0
        tv.onSubmit = { submits += 1 }
        win.contentView?.addSubview(tv)
        XCTAssertTrue(win.makeFirstResponder(tv))
        tv.string = "ab\ncd"
        tv.setSelectedRange(NSRange(location: 5, length: 0))

        win.sendEvent(keyEvent(36, "\r", window: win))
        XCTAssertEqual(submits, 1, "Return sends")
        XCTAssertEqual(opened, 0, "Return in the input box opens nothing")
        win.sendEvent(keyEvent(126, "\u{F700}", window: win))
        XCTAssertEqual(m.selection, first, "up stays in the input box")
        XCTAssertEqual(tv.selectedRange().location, 2, "the caret moved up a line")
        win.sendEvent(keyEvent(125, "\u{F701}", window: win))
        XCTAssertEqual(m.selection, first)
        XCTAssertEqual(tv.selectedRange().location, 5)
        win.sendEvent(keyEvent(36, "\r", .shift, window: win))
        XCTAssertEqual(tv.string, "ab\ncd\n", "Shift-Return adds a line")
        XCTAssertEqual(submits, 1)
        win.sendEvent(keyEvent(76, "\u{3}", window: win))
        XCTAssertEqual(submits, 2, "keypad Enter sends too")

        // Focus out of any text view: a click in the detail pane, then the sidebar.
        win.makeFirstResponder(nil)
        win.sendEvent(click(500, window: win))
        XCTAssertFalse(win.sidebarFocused)
        win.sendEvent(keyEvent(125, "\u{F701}", window: win))
        XCTAssertEqual(m.selection, first, "arrows outside the sidebar pass on")
        win.sendEvent(keyEvent(36, "\r", window: win))
        XCTAssertEqual(opened, 0, "Return outside the sidebar passes on")
        win.sendEvent(click(100, window: win))
        XCTAssertTrue(win.sidebarFocused)
        win.sendEvent(keyEvent(125, "\u{F701}", window: win))
        XCTAssertNotEqual(m.selection, first, "the sidebar's down")
        m.interaction.composer = tv   // #845: the input box the pane registers
        win.sendEvent(keyEvent(36, "\r", window: win))
        XCTAssertTrue(win.firstResponder === tv, "#845: the sidebar's Return moves into the input box")
        XCTAssertFalse(win.sidebarFocused)
        XCTAssertEqual(opened, 0, "and opens no terminal app")
        win.sendEvent(click(100, window: win))
        XCTAssertFalse(win.firstResponder === tv, "#845: a sidebar click takes the keys back from the input box")
        XCTAssertTrue(win.sidebarFocused)
        win.sendEvent(keyEvent(48, "\t", window: win))
        XCTAssertFalse(win.sidebarFocused, "Tab moves the focus on")
        XCTAssertFalse(win.isVisible, "never shown")
    }

    // MARK: - QA #626 INFO-1: per-session view state, late full text dropped

    @MainActor
    func testAgentWindowViewStateIsKeyedBySessionAndALateFullTextIsDropped() async throws {
        let dir = tempDir()
        let a = dir.appendingPathComponent("a.jsonl"), b = dir.appendingPathComponent("b.jsonl")
        let big = (0..<2000).map { "output line \($0)" }.joined(separator: "\n")
        func line(_ o: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: o) + Data("\n".utf8) }
        let use: [String: Any] = ["type": "assistant", "sessionId": "s", "version": "2.1.300",
                                  "message": ["role": "assistant", "content": [["type": "tool_use", "id": "t1", "name": "Bash",
                                                                                "input": ["command": "seq"]]]]]
        let result: [String: Any] = ["type": "user", "sessionId": "s", "version": "2.1.300",
                                     "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "t1", "content": big]]],
                                     "toolUseResult": ["stdout": big, "stderr": ""]]
        try (line(use) + line(result)).write(to: a)
        try (line(use) + line(result)).write(to: b)
        let m = AgentTranscriptModel()
        var jobs: [@Sendable () -> Void] = []
        m.offMain = { jobs.append($0) }
        m.makeWatch = { _, _ in NSObject() }
        m.tickInterval = 3600
        func src(_ name: String, _ url: URL) -> AgentTranscriptSource {
            AgentTranscriptSource(key: AgentSessionKey(dir: "/d", name: name), dchVersion: "1.30.0", dchState: "idle",
                                  sessionId: name, transcriptPath: url.path)
        }
        m.update(src("a", a))
        m.start()
        defer { m.stop() }
        while !jobs.isEmpty { jobs.removeFirst()() }
        let idA = m.viewIdentity, blockA = try XCTUnwrap(m.blocks.first?.id)
        guard case .bash(_, _, let clip?, _) = m.blocks.first?.body else { return XCTFail("\(m.blocks)") }
        XCTAssertTrue(clip.capped)

        // Expand starts on a's block; b is selected before the read lands.
        let expand = Task { await m.fullText(clip) }
        while jobs.isEmpty { await Task.yield() }
        let late = jobs.removeFirst()
        m.update(src("b", b))
        while !jobs.isEmpty { jobs.removeFirst()() }
        XCTAssertEqual(m.blocks.first?.id, blockA, "b's first block has a's id: ids restart per file")
        XCTAssertNotEqual(m.viewIdentity, idA, "so the list's view state is keyed by session and generation")
        late()
        let text = await expand.value
        XCTAssertNil(text, "a's full text never lands in b's block")
    }

    // MARK: - QA #626 INFO-6/7: naming, the island off, show and teardown

    @MainActor
    func testAgentWindowShowThenCloseTearsEverythingDownWithoutShowing() throws {
        let c = controller(FormSim(.plain("")).io, autoAllow: false)
        let w = AgentsWindow()
        var presented = 0, dismissed = 0
        var built: AgentsNSWindow?
        w.island = { c }
        w.present = { _ in presented += 1 }
        w.dismissed = { _ in dismissed += 1 }
        w.build = { m in
            let win = AgentsNSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled, .closable],
                                     backing: .buffered, defer: true)
            win.isReleasedWhenClosed = false
            win.model = m
            built = win
            return win
        }
        w.show()
        let model = try XCTUnwrap(w.model)
        XCTAssertTrue(model.interaction.controller === c)
        XCTAssertNotNil(c.onStoreChanged)
        XCTAssertNotNil(c.onHoldChanged)
        XCTAssertEqual(presented, 1)
        w.show()
        XCTAssertTrue(w.model === model, "a second show presents the same window")
        XCTAssertEqual(presented, 2)
        let win = try XCTUnwrap(built)
        win.close()
        XCTAssertNil(w.model)
        XCTAssertNil(w.window)
        XCTAssertNil(c.onStoreChanged)
        XCTAssertNil(c.onHoldChanged)
        XCTAssertEqual(dismissed, 1)
        XCTAssertNil(model.interaction.session, "the interaction let go of the session")
        XCTAssertFalse(win.isVisible, "never on screen")
        XCTAssertEqual(AgentsWindow.title, "Agent Sessions")
    }

    /// #626 INFO-7: the status menu's "Agent Sessions…" item opens AgentsWindow.shared. #805
    /// (QA #629 R2): the item comes from AgentsWindow.menuItem, the builder MenuBarController
    /// uses, so no status item, registry, defaults or observer is made; the shared window's
    /// seams are swapped for the test, so nothing goes on screen.
    @MainActor
    func testAgentWindowStatusMenuItemOpensTheAgentsWindow() throws {
        let w = AgentsWindow.shared
        XCTAssertFalse(w.isOpen)
        let (island, build, present, dismissed) = (w.island, w.build, w.present, w.dismissed)
        defer { (w.island, w.build, w.present, w.dismissed) = (island, build, present, dismissed) }
        let c = controller(FormSim(.plain("")).io, autoAllow: false)
        var presented = 0
        w.island = { c }
        w.present = { _ in presented += 1 }
        w.dismissed = { _ in }
        w.build = { m in
            let win = AgentsNSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled, .closable],
                                     backing: .buffered, defer: true)
            win.isReleasedWhenClosed = false
            win.model = m
            return win
        }
        let item = AgentsWindow.menuItem()
        XCTAssertEqual(item.title, "Agent Sessions\u{2026}")
        let action = try XCTUnwrap(item.action)
        // The item's target is weak: it must outlive the menu on its own.
        let target = try XCTUnwrap(item.target)
        XCTAssertTrue(AgentsWindow.menuItem().target === target, "one target for every item")
        XCTAssertTrue(NSApplication.shared.sendAction(action, to: target, from: item))
        XCTAssertEqual(presented, 1)
        let win = try XCTUnwrap(w.window)
        XCTAssertTrue(w.model?.interaction.controller === c)
        win.close()
        XCTAssertFalse(w.isOpen)
        XCTAssertFalse(win.isVisible, "never on screen")
    }

    // MARK: - Offscreen renders: input box and every prompt kind

    static var renderDir: URL? {
        ProcessInfo.processInfo.environment["PROSPER_RENDER_DIR"].map { URL(fileURLWithPath: $0) }
    }

    @MainActor
    func render<V: View>(_ view: V, size: CGSize, dark: Bool, margin: CGFloat = 24) throws -> NSBitmapImageRep {
        let root = ZStack(alignment: .topLeading) {
            Color(nsColor: dark ? .black : .white)
            view.frame(width: size.width, height: size.height, alignment: .topLeading)
        }
        .frame(width: size.width + margin, height: size.height + margin, alignment: .topLeading)
        .environment(\.colorScheme, dark ? .dark : .light)
        let h = NSHostingView(rootView: root)
        h.frame = CGRect(origin: .zero, size: CGSize(width: size.width + margin, height: size.height + margin))
        h.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        h.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(h.bitmapImageRepForCachingDisplay(in: h.bounds))
        h.cacheDisplay(in: h.bounds, to: rep)
        return rep
    }

    func overflow(_ rep: NSBitmapImageRep, content: CGSize, canvas: CGSize) -> Int {
        let sx = CGFloat(rep.pixelsWide) / canvas.width, sy = CGFloat(rep.pixelsHigh) / canvas.height
        guard let bg = rep.colorAt(x: rep.pixelsWide - 1, y: rep.pixelsHigh - 1)?.usingColorSpace(.sRGB) else { return 0 }
        var n = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide where CGFloat(x) >= content.width * sx + 1 || CGFloat(y) >= content.height * sy + 1 {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if abs(c.redComponent - bg.redComponent) + abs(c.greenComponent - bg.greenComponent)
                    + abs(c.blueComponent - bg.blueComponent) > 0.1 { n += 1 }
            }
        }
        return n
    }

    func ink(_ rep: NSBitmapImageRep) -> Int {
        guard let bg = rep.colorAt(x: 2, y: 2)?.usingColorSpace(.sRGB) else { return 0 }
        var n = 0
        for y in stride(from: 0, to: rep.pixelsHigh, by: 3) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 3) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if abs(c.redComponent - bg.redComponent) + abs(c.greenComponent - bg.greenComponent)
                    + abs(c.blueComponent - bg.blueComponent) > 0.15 { n += 1 }
            }
        }
        return n
    }

    func save(_ rep: NSBitmapImageRep, _ name: String) throws {
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: tempDir("agents-window-b-renders").appendingPathComponent("\(name).png"))
        if let dir = Self.renderDir { try png.write(to: dir.appendingPathComponent("\(name).png")) }
    }

    @MainActor
    func testAgentWindowRendersTheInputBoxAndEveryPromptKindWithoutClipping() throws {
        let savedScale = ThemeRuntime.scale, savedPalette = ThemeRuntime.palette
        defer { ThemeRuntime.scale = savedScale; ThemeRuntime.palette = savedPalette }
        // Each case: a session state, a screen behind dch (nil: not blocked), the transcript's ask, a draft, a notice.
        let longPermission = Self.permission(["Yes", "Yes, and don't ask again for rm commands in /Users/example/projects/prosper",
                                              "No, and tell Claude what to do differently (esc)"],
                                             body: ["   rm -rf .build/arm64-apple-macosx/debug/ProsperPackageTests.xctest",
                                                    "   Clean the build tree before a full test run"])
        let cases: [(String, AgentState, String?, AgentAskInput?, String, Bool)] = [
            ("input-idle", .idle, nil, nil, "", false),
            ("input-draft", .done, nil, nil, "Fix the failing test.\nThen run the full suite and report the counts.", false),
            ("input-working", .working, nil, nil, "", false),
            ("permission", .blocked, longPermission, nil, "", false),
            ("plan-mode-change", .blocked, Self.plan, nil, "", false),
            ("ask-single-other", .blocked, Self.singleScreen(caret: 1), Self.singleAsk, "", false),
            ("ask-multi", .blocked, Self.multiScreen([true, false, true, false], caret: 1), Self.multiAsk, "", false),
            ("ask-preview", .blocked, Self.previewScreen(caret: 2), Self.previewAsk, "", false),
            ("fallback-mismatch", .blocked, Self.singleScreen(caret: 1), Self.multiAsk, "", false),
            // #802: plan approval (rows offered, and the fallback), the multi-select Other answer, Chat about this.
            ("plan-approve", .blocked, Self.planScreen(caret: 1), nil, "", false),
            ("plan-fallback", .blocked, Self.planScreen(caret: 3), nil, "", false),
            ("ask-multi-other", .blocked, Self.multiScreen([true, false, false, false], caret: 1), Self.multiAsk, "", false),
            ("fallback-unreadable", .blocked, Self.idleScreen, nil, "", false),
            ("notice", .idle, nil, nil, "Keep this text", true),
        ]
        for dark in [true, false] {
            ThemeRuntime.palette = dark ? savedPalette : AgentWindowD1Tests.lightPalette
            for scale: CGFloat in [1.0, 0.85, 0.7] {
                ThemeRuntime.scale = scale
                let tag = "\(dark ? "dark" : "light")-\(scale)"
                // The narrowest detail pane (the window's minimum width less the sidebar).
                let width = 640 * scale - sz(290) - 1
                for (name, state, screen, ask, draft, notice) in cases {
                    let f = FormSim(.plain(screen ?? ""))
                    if notice { f.status = "idle" }
                    let c = controller(AgentPromptIO(read: f.io.read, status: { _ in "idle" }, send: { _, _ in },
                                                     say: { _, _ in "" }), autoAllow: false)
                    let i = interaction(c)
                    i.ask = ask
                    if name.hasPrefix("plan-") { i.plan = Self.planInput }
                    let s = session(state)
                    i.follow(s)
                    if name == "ask-multi-other" { i.otherText = "Teal, and a darker shade if there is one" }
                    i.draft = draft
                    if name == "plan-approve" || name == "plan-fallback" {
                        guard case .prompt(let w) = i.panel else { return XCTFail("\(name): \(i.panel)") }
                        XCTAssertEqual(w.approve.isEmpty, name == "plan-fallback", name)
                    }
                    if notice {
                        i.send()
                        until("the notice") { !i.busy }
                        XCTAssertEqual(i.notice, AgentWindowText.unconfirmed)
                    }
                    let size = CGSize(width: width, height: 560 * scale)
                    let rep = try render(AgentInteractionPane(model: i, session: s, open: {}), size: size, dark: dark)
                    try save(rep, "b-\(name)-\(tag)")
                    XCTAssertGreaterThan(ink(rep), 60, "\(name) \(tag) draws")
                    XCTAssertEqual(overflow(rep, content: size, canvas: CGSize(width: size.width + 24, height: size.height + 24)),
                                   0, "nothing drawn past the pane (\(name) \(tag))")
                    let fit = NSHostingView(rootView: AgentInteractionPane(model: i, session: s, open: {}).frame(width: width))
                    XCTAssertLessThanOrEqual(fit.fittingSize.width, width + 0.5, "\(name) \(tag) fits its width")
                    XCTAssertLessThan(fit.fittingSize.height, size.height, "\(name) \(tag) fits the canvas")
                }
            }
        }
    }
}
