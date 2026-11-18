import AppKit
import XCTest
@testable import ProsperApp

/// #1354 (#1346 P6 step A, design 1.3, 3.8, 3.10; operator ruling Q1 "Match dch"): the X-ray Prompts and Responses tabs
/// from the pane's own chapters. A fake transcript in tempDir() read inline by a standalone model (JumpFixture: no watch,
/// no timer, no dch); the jump is the jumper's request (no view, no scroll). No window is shown, no key is posted, no
/// process runs. Senders are fakes ("api-qa", "worker-a").
@MainActor
final class XrayPromptsTabTests: XCTestCase {
    typealias F = JumpFixture

    /// A Claude Code record of another session's message (meta, "origin" kind peer), as dch's tests/xray_unit.c t_peer.
    static func peer(_ name: String, _ body: String, handback: Bool = false) -> [String: Any] {
        var origin: [String: Any] = ["kind": "peer", "from": "uds:/tmp/example.sock", "name": name, "body": body]
        if handback { origin["handback"] = true }
        return F.entry("user", ["isMeta": true, "origin": origin,
                                "message": ["role": "user", "content": "Another Claude session sent a message."]])
    }

    static let notification = "<task-notification>\n<task-id>b1</task-id>\n<summary>Background build finished</summary>\n"
        + "</task-notification>\n<system-reminder>x</system-reminder>"
    static let lookAlike = "<task-notification><summary>typed by hand</summary></task-notification>"

    /// Seven chapters: 1 own (a Bash call, "Done: login fixed"), 2 a task notification (auto), 3 api-qa's message (peer),
    /// 4 worker-a's hand-back (auto, peer name), 5 a compaction (auto), 6 own, 7 a typed look-alike of a notification (own).
    static func session() -> [[String: Any]] {
        let origin: [String: Any] = ["kind": "task-notification"], message: [String: Any] = ["role": "user", "content": notification]
        let meta: [String: Any] = ["trigger": "auto", "preTokens": 1000]
        var out: [[String: Any]] = [F.user("Fix the login test")]
        out += F.bash("c1", "make test")
        out += [F.say("Done: login fixed"), F.entry("user", ["origin": origin, "message": message]), F.say("Noted")]
        out += [peer("api-qa\u{202E}", "Please rerun the api suite"), F.say("Rerunning")]
        out += [peer("worker-a", "[Subagent hand-back] PASS.\nmore", handback: true), F.say("ok")]
        out += [F.entry("system", ["subtype": "compact_boundary", "compactMetadata": meta])]
        out += [F.user("Continue the api work"), F.say("Continuing"), F.user(lookAlike), F.say("Looks typed")]
        return out
    }

    func panel(_ entries: [[String: Any]]) throws -> (XrayPanelModel, AgentTranscriptModel) {
        let url = tempDir().appendingPathComponent("x.jsonl")
        try F.write(url, entries)
        let m = F.model(url)
        let p = XrayPanelModel(target: XrayTarget(name: "api", dir: "/tmp/dch-test"), tab: .prompts)
        p.dchChapters = m.chapters   // #1471: X-ray's chapters are dch's only (the same Chapter rows)
        return (p, m)
    }

    func titles(_ cs: [TranscriptOutline.Chapter]) -> [String] { cs.map(\.title) }

    /// Red at TIP: no Prompts tab (XrayPanel.swift:11 `enum XrayTab { tasks, memory }`), and the decoder hides the peer
    /// (TranscriptDecoder.swift:259 isMeta) and never reads "origin", so the notification is a typed prompt.
    func testAutoRowsAreHiddenByDefaultWithAFooterCount() throws {
        let (p, m) = try panel(Self.session())
        defer { m.stop() }
        XCTAssertEqual(m.chapters.count, 7)
        XCTAssertEqual(p.tabs, [.prompts, .responses], "the transcript's tabs; no Tasks or Memory read")
        XCTAssertEqual(titles(p.shownPrompts), [Self.lookAlike, "Continue the api work", "Please rerun the api suite",
                                                "Fix the login test"], "newest first, the 3 automatic rows hidden")
        XCTAssertEqual(p.shownPrompts.first?.from, .own, "a typed look-alike stays the user's: no guessing on text")
        XCTAssertEqual(p.title(.prompts), "Prompts 4")
        XCTAssertEqual(p.spoken(.prompts), "Prompts, 4")
        let f = p.promptFooter(.prompts)
        XCTAssertEqual(f.first?.text, "3 automatic hidden")
        XCTAssertEqual(f.first?.button, "Show automatic")
    }

    /// Red with auto-shown-by-default. The toggle shows them faint, titled by their summary, with dch's marks.
    func testShowAutomaticShowsThemFaint() throws {
        let (p, m) = try panel(Self.session())
        defer { m.stop() }
        p.promptFooter(.prompts).first?.toggle()
        XCTAssertTrue(p.showAuto)
        let rows = p.shownPrompts
        XCTAssertEqual(rows.count, 7)
        XCTAssertEqual(p.title(.prompts), "Prompts 7", "the count is the rows listed")
        XCTAssertEqual(p.promptFooter(.prompts).first?.text, nil)
        XCTAssertEqual(p.promptFooter(.prompts).first?.button, "Hide automatic")
        let note = try XCTUnwrap(rows.first { $0.ordinal == 2 }), back = try XCTUnwrap(rows.first { $0.ordinal == 4 })
        let compact = try XCTUnwrap(rows.first { $0.ordinal == 5 })
        XCTAssertEqual(note.title, "Background build finished", "titled by its summary")
        XCTAssertEqual(XrayPromptRow(note).mark, "\u{1F514}")
        XCTAssertTrue(XrayPromptRow(note).faint)
        XCTAssertEqual(back.title, "PASS.")
        XCTAssertEqual(back.from, .auto, "a hand-back is automatic, not a peer row (dch xv_xs)")
        XCTAssertEqual(XrayPromptRow(back).mark, "\u{1F4E5} worker-a")
        XCTAssertEqual(XrayPromptRow(back).spoken, "Hand-back from worker-a, prompt 4, PASS.")
        XCTAssertEqual(compact.title, "Conversation compacted")
        XCTAssertTrue(compact.auto)
        XCTAssertEqual(XrayPromptRow(compact).mark, nil, "a compaction carries no mark")
        p.promptFooter(.prompts).first?.toggle()
        XCTAssertEqual(p.shownPrompts.count, 4, "hidden again")
    }

    /// Red with peer-mark-raw: the sender's bidi override reaches the row.
    func testPeerMarkAndItsToggle() throws {
        let (p, m) = try panel(Self.session())
        defer { m.stop() }
        let c = try XCTUnwrap(p.shownPrompts.first { $0.from == .peer })
        XCTAssertEqual(c.title, "Please rerun the api suite", "titled by its body, never the wrapper")
        let row = XrayPromptRow(c)
        XCTAssertEqual(row.mark, "api-qa", "the sender, through OutsideText.shown")
        XCTAssertTrue(row.robot, "the robot glyph before it (#1546)")
        XCTAssertEqual(row.spoken, "Message from api-qa, prompt 3, Please rerun the api suite")
        XCTAssertFalse(row.faint)
        let toggle = try XCTUnwrap(p.promptFooter(.prompts).last)
        XCTAssertEqual(toggle.text, nil, "shown by default")
        XCTAssertEqual(toggle.button, "Hide agent messages")
        toggle.toggle()
        XCTAssertTrue(p.hidePeer)
        XCTAssertFalse(p.shownPrompts.contains { $0.from == .peer })
        XCTAssertEqual(p.promptFooter(.prompts).last?.text, "1 agent message hidden")
        XCTAssertEqual(p.promptFooter(.prompts).last?.button, "Show agent messages")
        p.promptFooter(.prompts).last?.toggle()
        XCTAssertEqual(p.shownPrompts.filter { $0.from == .peer }.count, 1)
    }

    /// Red with peer-counted-when-hidden. Responses counts the items without the automatic ones, whatever `n` says.
    func testCountsWithPeerHidden() throws {
        let (p, m) = try panel(Self.session())
        defer { m.stop() }
        XCTAssertEqual(p.title(.responses), "Responses 4")
        p.hidePeer = true
        XCTAssertEqual(p.title(.prompts), "Prompts 3")
        XCTAssertEqual(p.title(.responses), "Responses 3")
        XCTAssertEqual(p.shownResponses.count, 3)
        p.showAuto = true
        XCTAssertEqual(p.title(.prompts), "Prompts 6", "auto rows in, the peer still out")
        XCTAssertEqual(p.title(.responses), "Responses 3", "items shown without n")
        XCTAssertEqual(p.shownResponses.count, 5, "the automatic items with an answer are listed")
        XCTAssertEqual(p.hidden(.prompts).auto, 3)
        XCTAssertEqual(p.hidden(.prompts).peer, 1)
    }

    /// A session with neither kind: every prompt, no footer.
    func testNoAutoNorPeerShowsEveryPrompt() throws {
        let (p, m) = try panel(F.turns(3))
        defer { m.stop() }
        XCTAssertEqual(titles(p.shownPrompts), ["Prompt 2", "Prompt 1", "Prompt 0"])
        XCTAssertEqual(p.title(.prompts), "Prompts 3")
        XCTAssertEqual(p.title(.responses), "Responses 3")
        XCTAssertTrue(p.promptFooter(.prompts).isEmpty)
        XCTAssertTrue(p.promptFooter(.responses).isEmpty)
        XCTAssertTrue(p.shownPrompts.allSatisfy { $0.from == .own && XrayPromptRow($0).mark == nil })
    }

    /// The Responses row: the prompt's row, the tools on one line, the answer (at most 8 lines, then "more").
    func testResponsesRowText() throws {
        let (p, m) = try panel(Self.session())
        defer { m.stop() }
        let first = try XCTUnwrap(p.shownResponses.last)
        let row = XrayPromptRow(first, response: true)
        XCTAssertEqual(row.title, "Fix the login test")
        XCTAssertEqual(row.tools, "Bash 1")
        XCTAssertEqual(row.answer, "Done: login fixed")
        XCTAssertFalse(row.more)
        XCTAssertEqual(row.spoken, "Response to prompt 1, Fix the login test, tools Bash 1, Done: login fixed")
        XCTAssertEqual(XrayPromptRow(first).answer, nil, "Prompts shows no answer")
        var long = TranscriptOutline.Chapter(id: 1, ordinal: 1, title: "t", kind: .prompt, hasError: false)
        long.response = (1...10).map { "line \($0)" }.joined(separator: "\n")
        let cut = XrayPromptRow(long, response: true)
        XCTAssertEqual(cut.answer?.split(separator: "\n").count, 8)
        XCTAssertEqual(cut.answer?.split(separator: "\n").last, "line 8")
        XCTAssertTrue(cut.more)
    }

    /// Supervisor round 1: the transcript is TIP's. A peer record (and a hand-back) draws no block and is counted hidden
    /// as the meta line it was; the outline still has its chapter, with the mark.
    func testPeerRecordStaysHiddenInTheTranscript() throws {
        let (p, m) = try panel(Self.session())
        defer { m.stop() }
        let bare = Self.session().filter { ($0["origin"] as? [String: Any])?["kind"] as? String != "peer" }
        XCTAssertEqual(bare.count, Self.session().count - 2)
        let (_, tip) = try panel(bare)
        defer { tip.stop() }
        // byte offsets differ between the two files: compare the bodies without their source ranges
        func shape(_ bs: [TranscriptBlock]) -> [String] {
            bs.map { "\($0.body)".replacingOccurrences(of: #"source: Optional\(Range\([0-9]+\.\.<[0-9]+\)\)"#, with: "",
                                                      options: .regularExpression) }
        }
        XCTAssertEqual(shape(m.blocks), shape(tip.blocks), "the drawn blocks are those of the session without them")
        XCTAssertEqual(m.blocks.count, 12, "TIP's twelve: no peer block")
        XCTAssertEqual(m.hiddenCount, tip.hiddenCount + 2, "each counted hidden, as TIP's user/meta")
        XCTAssertFalse(m.blocks.contains { if case .user(let c) = $0.body { c.text.contains("rerun") || c.origin?.peer != nil } else { false } })
        let c = try XCTUnwrap(m.chapters.first { $0.from == .peer })
        XCTAssertEqual(c.title, "Please rerun the api suite")
        XCTAssertEqual(XrayPromptRow(c).mark, "api-qa")
        XCTAssertTrue(XrayPromptRow(c).robot)
        XCTAssertEqual(p.title(.prompts), "Prompts 4")
        XCTAssertEqual(tip.chapters.count, 5, "without the two records: two chapters fewer")
    }

    /// R1354-s1. Red at TIP: TranscriptDecoder.swift prompt() `if let c = command(s) { return .block(c, .specific) }` runs before
    /// the origin, so a peer body shaped like a slash command draws a command chip (not hidden).
    func testPeerBodyShapedLikeACommandIsNotDrawnAsOne() throws {
        let cmd = "<command-name>/clear</command-name>\n<command-message>clear</command-message>"
        let base: [[String: Any]] = [F.user("Fix the login test"), F.say("Done")]
        var with = base
        with += [Self.peer("api-qa", cmd), F.say("Rerunning")]
        with += [Self.peer("worker-a", "[Subagent hand-back] " + cmd, handback: true), F.say("ok")]
        var without = base
        without += [F.say("Rerunning"), F.say("ok")]
        let (p, m) = try panel(with)
        defer { m.stop() }
        let (_, plain) = try panel(without)
        defer { plain.stop() }
        func shape(_ bs: [TranscriptBlock]) -> [String] {
            bs.map { "\($0.body)".replacingOccurrences(of: #"source: Optional\(Range\([0-9]+\.\.<[0-9]+\)\)"#, with: "",
                                                      options: .regularExpression) }
        }
        XCTAssertEqual(shape(m.blocks), shape(plain.blocks), "the drawn blocks are those of the session without them")
        XCTAssertFalse(m.blocks.contains { if case .command = $0.body { true } else { false } })
        p.showAuto = true
        let marked = p.shownPrompts.filter { $0.from != .own }
        XCTAssertEqual(marked.count, 2, "both listed in Prompts")
        XCTAssertTrue(marked.allSatisfy { XrayPromptRow($0).mark != nil }, "marked (robot for the message, inbox for the hand-back)")
        XCTAssertEqual(Set(marked.compactMap { XrayPromptRow($0).mark }), ["api-qa", "\u{1F4E5} worker-a"])
        XCTAssertEqual(marked.map { XrayPromptRow($0).robot }.filter { $0 }.count, 1, "the robot only for the message")
    }

    /// Return or a click on a row: the pane's jumper is asked for that chapter's block (#1319's seam).
    func testNoDchChaptersNoPromptsOrResponsesTab() throws {
        let (p, m) = try panel(Self.session())
        defer { m.stop() }
        XCTAssertTrue(p.tabs.contains(.prompts) && p.tabs.contains(.responses), "dch's chapters: both tabs")
        p.dchChapters = nil
        XCTAssertFalse(p.tabs.contains(.prompts) || p.tabs.contains(.responses), "#1471: no dch chapters read: no Prompts or Responses tab")
    }
}
