import Foundation
import XCTest
@testable import ProsperApp

/// #996 part A: the Agents window lines of the QA audit. Literal screens, literal markdown, a
/// scratch home under tempDir(): no dch, no window, no real ~/.claude.
final class AgentWindowAudit996Tests: XCTestCase {

    static let rule = String(repeating: "\u{2500}", count: 100)

    // MARK: QA #651 INFO-4: promptTail starts below the first composer

    /// A dialog drawn as a rule, a caret line and a rule below Claude Code's composer: with the last
    /// such line taken as the composer (TIP), the plan's question above it was hidden and a message
    /// went out over the dialog. From the first, the question refuses.
    func testPromptTailReadsBelowTheFirstComposerNotADialogDrawnLikeOne() {
        let question = "  Claude has written up a plan and is ready to execute. Would you like to proceed?"
        let lines = ["\u{23FA} Done.", Self.rule, "\u{276F} ", Self.rule, question, "", Self.rule,
                     "\u{276F} Yes, and auto-accept edits", Self.rule]
        let screen = lines.joined(separator: "\n")
        XCTAssertTrue(AgentWindowDriver.promptTail(screen), "the question under the real composer is seen")
        XCTAssertEqual(AgentWindowDriver.refusal(screen), AgentWindowText.promptShown)
        // The plain composer (one, at the bottom) with the question quoted above it: not in the tail.
        let echo = [question, "", Self.rule, "\u{276F} ", Self.rule, "  ? for shortcuts"].joined(separator: "\n")
        XCTAssertFalse(AgentWindowDriver.promptTail(echo))
    }

    // MARK: QA #660 INFO-3: unwrapPasted is one forward scan

    /// 2,000 openers with no closer, then about 1.1 MB of text: as written, under 2 s (the old lazy
    /// backreference regex scanned to the end once per opener). Bound chosen generous: the scan is
    /// linear (tens of ms in a debug build); the regex's k*n is about 2.2e9 steps here.
    func testUnwrapPastedWithThousandsOfUnclosedOpenersIsLinear() throws {
        let openers = (0..<2000).map { "<pasted_content id=\"u\($0)\">\n" }.joined()
        let s = openers + String(repeating: "plain text ", count: 100_000) + "end"
        let t0 = Date()
        let out = TranscriptDecoder.unwrapPasted(s)
        let unwrap = Date().timeIntervalSince(t0)
        XCTAssertTrue(out == s, "no pair: as written")
        XCTAssertLessThan(unwrap, 2.0, "unwrapPasted took \(unwrap) s")
        // Through the decoder, as a user turn.
        let o: [String: Any] = ["type": "user", "sessionId": "s-1", "version": "2.1.300",
                                "message": ["role": "user", "content": s]]
        let line = try JSONSerialization.data(withJSONObject: o) + Data("\n".utf8)
        let t1 = Date()
        let items = TranscriptDecoder.decode(line: line, cap: 2_000_000).items
        let decode = Date().timeIntervalSince(t1)
        XCTAssertLessThan(decode, 2.0, "decode took \(decode) s")
        let text = items.compactMap { item -> String? in
            if case .block(.user(let c), _) = item { return c.text } else { return nil }
        }
        XCTAssertTrue(text.first == s, "the user turn, as written")
        // One closed pair among the unclosed openers still unwraps; the ones before it stay.
        let mixed = openers + "<pasted_content id=\"k3x9\">\nbody\n</pasted_content id=\"k3x9\"> after"
        XCTAssertTrue(TranscriptDecoder.unwrapPasted(mixed) == openers + "body after")
        // The regex's edges: CRLF keeps its CR, a 64-char id pairs, a 65-char one does not, the
        // first closer of the same id ends the body, an empty body.
        let id64 = String(repeating: "a", count: 64), id65 = id64 + "a"
        let edges: [(String, String)] = [
            ("<pasted_content id=\"c1\">\r\nx\r\n</pasted_content id=\"c1\">", "\r\nx\r"),
            ("<pasted_content id=\"\(id64)\">\ny\n</pasted_content id=\"\(id64)\">", "y"),
            ("<pasted_content id=\"\(id65)\">\ny\n</pasted_content id=\"\(id65)\">",
             "<pasted_content id=\"\(id65)\">\ny\n</pasted_content id=\"\(id65)\">"),
            ("<pasted_content id=\"n\">\na <pasted_content id=\"n\">\nb</pasted_content id=\"n\">c</pasted_content id=\"n\">",
             "a <pasted_content id=\"n\">\nbc</pasted_content id=\"n\">"),
            ("<pasted_content id=\"e\">\n</pasted_content id=\"e\">!", "!"),
        ]
        for (input, want) in edges { XCTAssertEqual(TranscriptDecoder.unwrapPasted(input), want, input) }
    }

    // MARK: QA 832 riders 2 and 3: the plan file and the plan compare

    /// A scratch home (its real path: /var is a link) for a plans folder.
    func scratchHome() throws -> String {
        let real = try XCTUnwrap(realpath(tempDir().path, nil))
        defer { free(real) }
        return String(cString: real)
    }

    /// Rider 2: a symlink cycle at the plans folder (a link to itself, and two links to each other
    /// on the way) reads nothing and returns at once: realpath fails with ELOOP.
    func testPlanFileReadWithASymlinkCycleAtThePlansFolderReadsNothing() throws {
        let fm = FileManager.default
        let home = try scratchHome()
        try fm.createDirectory(atPath: home + "/.claude", withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: home + "/.claude/plans", withDestinationPath: home + "/.claude/plans")
        let homeB = home + "/b"
        try fm.createDirectory(atPath: homeB, withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: homeB + "/.claude", withDestinationPath: homeB + "/.other")
        try fm.createSymbolicLink(atPath: homeB + "/.other", withDestinationPath: homeB + "/.claude")
        let footer = "ctrl+g to edit in VS Code \u{00B7} ~/.claude/plans/example-plan.md"
        for h in [home, homeB] {
            let plans = h + "/.claude/plans"
            XCTAssertTrue(AgentPlanInput.read(plans + "/example-plan.md", root: plans) == nil, h)
            let input = AgentPlanInput(id: "toolu_p", plan: nil, file: plans + "/example-plan.md", home: h)
            XCTAssertTrue(input.text(footer: footer) == nil, h)
        }
    }

    /// Rider 3: a table right above a code fence. The render draws no fence line, so the code's
    /// "x | y" is not a table row on screen; at TIP the table state stayed on through the fence and
    /// dropped its "|" on the plan's side only: a false mismatch.
    func testPlanCompareEndsATableAtACodeFence() {
        let plan = ["| a | b |", "|---|---|", "| 1 | 2 |", "```", "x | y", "```", "done"]
        let shown = ["\u{250C}\u{2500}\u{2500}\u{2500}\u{252C}\u{2500}\u{2500}\u{2500}\u{2510}",
                     "\u{2502} a \u{2502} b \u{2502}",
                     "\u{251C}\u{2500}\u{2500}\u{2500}\u{253C}\u{2500}\u{2500}\u{2500}\u{2524}",
                     "\u{2502} 1 \u{2502} 2 \u{2502}",
                     "\u{2514}\u{2500}\u{2500}\u{2500}\u{2534}\u{2500}\u{2500}\u{2500}\u{2518}",
                     "x | y", "done"]
        XCTAssertEqual(AgentPlanInput.flat(plan), AgentPlanInput.flat(shown))
        XCTAssertEqual(AgentPlanInput.flat(plan), "ab12x|ydone")
        // The fence form "~~~" too; a changed code line still mismatches.
        XCTAssertEqual(AgentPlanInput.flat(plan.map { $0 == "```" ? "~~~" : $0 }), AgentPlanInput.flat(shown))
        XCTAssertNotEqual(AgentPlanInput.flat(plan), AgentPlanInput.flat(shown.map { $0 == "x | y" ? "x y" : $0 }))
    }
}
