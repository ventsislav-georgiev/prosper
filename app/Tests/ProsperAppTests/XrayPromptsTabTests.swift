import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #1354 (#1346 P6 step A, design 1.3, 3.8, 3.10; operator ruling Q1 "Match dch"): the X-ray Prompts tab from the
/// pane's own chapters (#1815: no Responses tab; agent messages hidden by default, the choice saved). A fake transcript
/// in tempDir() read inline by a standalone model (JumpFixture: no watch, no timer, no dch); the jump is the jumper's
/// request (no view, no scroll). No window is shown, no key is posted, no process runs. Senders are fakes ("api-qa", "worker-a").
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
        XCTAssertEqual(p.tabs, [.prompts], "the transcript's tab; no Tasks or Memory read, no Responses (#1815)")
        XCTAssertEqual(titles(p.shownPrompts), [Self.lookAlike, "Continue the api work", "Fix the login test"],
                       "newest first, the 3 automatic rows and the agent message hidden")
        XCTAssertEqual(p.shownPrompts.first?.from, .own, "a typed look-alike stays the user's: no guessing on text")
        XCTAssertEqual(p.title(.prompts), "Prompts 3")
        XCTAssertEqual(p.spoken(.prompts), "Prompts, 3")
        let f = p.promptFooter(.prompts)
        XCTAssertEqual(f.first?.label, "Automatic")
        XCTAssertEqual(f.first?.count, 3)
        XCTAssertEqual(f.first?.shown, false)
    }

    /// Red with auto-shown-by-default. The toggle shows them faint, titled by their summary, with dch's marks.
    func testShowAutomaticShowsThemFaint() throws {
        let (p, m) = try panel(Self.session())
        defer { m.stop() }
        p.hidePeer = false   // the agent message counted too
        p.promptFooter(.prompts).first?.toggle()
        XCTAssertTrue(p.showAuto)
        let rows = p.shownPrompts
        XCTAssertEqual(rows.count, 7)
        XCTAssertEqual(p.title(.prompts), "Prompts 7", "the count is the rows listed")
        XCTAssertEqual(p.promptFooter(.prompts).first?.shown, true)
        XCTAssertEqual(p.promptFooter(.prompts).first?.count, 3, "the count stays when shown")
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

    /// Red with peer-mark-raw: the sender's bidi override reaches the row. #1815: hidden by default, Show brings it back.
    func testPeerMarkAndItsToggle() throws {
        let (p, m) = try panel(Self.session())
        defer { m.stop() }
        XCTAssertFalse(p.shownPrompts.contains { $0.from == .peer }, "#1815: hidden by default")
        let show = try XCTUnwrap(p.promptFooter(.prompts).last)
        XCTAssertEqual(show.label, "Agent messages")
        XCTAssertEqual(show.count, 1)
        XCTAssertFalse(show.shown)
        show.toggle()
        XCTAssertFalse(p.hidePeer)
        let c = try XCTUnwrap(p.shownPrompts.first { $0.from == .peer })
        XCTAssertEqual(c.title, "Please rerun the api suite", "titled by its body, never the wrapper")
        let row = XrayPromptRow(c)
        XCTAssertEqual(row.mark, "api-qa", "the sender, through OutsideText.shown")
        XCTAssertTrue(row.robot, "the robot glyph before it (#1546)")
        XCTAssertEqual(row.spoken, "Message from api-qa, prompt 3, Please rerun the api suite")
        XCTAssertFalse(row.faint)
        let toggle = try XCTUnwrap(p.promptFooter(.prompts).last)
        XCTAssertTrue(toggle.shown)
        XCTAssertEqual(toggle.count, 1)
        toggle.toggle()
        XCTAssertTrue(p.hidePeer)
        XCTAssertFalse(p.shownPrompts.contains { $0.from == .peer })
        XCTAssertEqual(p.promptFooter(.prompts).last?.shown, false)
        XCTAssertEqual(p.promptFooter(.prompts).last?.count, 1)
        p.promptFooter(.prompts).last?.toggle()
        XCTAssertEqual(p.shownPrompts.filter { $0.from == .peer }.count, 1)
    }

    /// #1950: both chips with their counts; a toggle flips `shown` and the listed rows; the spoken label has the count.
    /// Red at TIP: promptFooter returns (text, button, toggle), no label, count or shown flag.
    func testFilterChipsCarryCountsAndToggle() throws {
        let (p, m) = try panel(Self.session())
        defer { m.stop() }
        let chips = p.promptFooter(.prompts)
        XCTAssertEqual(chips.map(\.label), ["Automatic", "Agent messages"])
        XCTAssertEqual(chips.map(\.count), [3, 1])
        XCTAssertEqual(chips.map(\.shown), [false, false])
        XCTAssertEqual(chips.map(\.spoken), ["Automatic, 3 rows", "Agent messages, 1 row"])
        XCTAssertEqual(p.shownPrompts.count, 3)
        chips.last?.toggle()
        XCTAssertEqual(p.shownPrompts.count, 4, "the agent message listed")
        XCTAssertEqual(p.promptFooter(.prompts).map(\.shown), [false, true])
        XCTAssertEqual(p.promptFooter(.prompts).map(\.count), [3, 1], "counts do not change with the toggle")
        chips.first?.toggle()
        XCTAssertEqual(p.shownPrompts.count, 7)
        XCTAssertEqual(p.promptFooter(.prompts).map(\.shown), [true, true])
    }

    /// Red with peer-counted-when-hidden.
    func testCountsWithPeerHidden() throws {
        let (p, m) = try panel(Self.session())
        defer { m.stop() }
        p.hidePeer = false
        XCTAssertEqual(p.title(.prompts), "Prompts 4")
        p.hidePeer = true
        XCTAssertEqual(p.title(.prompts), "Prompts 3")
        p.showAuto = true
        XCTAssertEqual(p.title(.prompts), "Prompts 6", "auto rows in, the peer still out")
        XCTAssertEqual(p.hidden(.prompts).auto, 3)
        XCTAssertEqual(p.hidden(.prompts).peer, 1)
    }

    /// A session with neither kind: every prompt, no footer.
    func testNoAutoNorPeerShowsEveryPrompt() throws {
        let (p, m) = try panel(F.turns(3))
        defer { m.stop() }
        XCTAssertEqual(titles(p.shownPrompts), ["Prompt 2", "Prompt 1", "Prompt 0"])
        XCTAssertEqual(p.title(.prompts), "Prompts 3")
        XCTAssertTrue(p.promptFooter(.prompts).isEmpty)
        XCTAssertTrue(p.shownPrompts.allSatisfy { $0.from == .own && XrayPromptRow($0).mark == nil })
    }

    /// #1815: the row is the prompt's only (its answer is the card's); a peer's row spoken with its sender.
    func testPromptRowTextHasNoAnswer() throws {
        let (p, m) = try panel(Self.session())
        defer { m.stop() }
        let first = try XCTUnwrap(p.shownPrompts.last)
        XCTAssertEqual(XrayPromptRow(first).title, "Fix the login test")
        XCTAssertEqual(XrayPromptRow(first).spoken, "Prompt 1, Fix the login test", "no tools, no answer")
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
        XCTAssertEqual(p.title(.prompts), "Prompts 3", "#1815: the agent message hidden by default")
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
        p.hidePeer = false
        let marked = p.shownPrompts.filter { $0.from != .own }
        XCTAssertEqual(marked.count, 2, "both listed in Prompts")
        XCTAssertTrue(marked.allSatisfy { XrayPromptRow($0).mark != nil }, "marked (robot for the message, inbox for the hand-back)")
        XCTAssertEqual(Set(marked.compactMap { XrayPromptRow($0).mark }), ["api-qa", "\u{1F4E5} worker-a"])
        XCTAssertEqual(marked.map { XrayPromptRow($0).robot }.filter { $0 }.count, 1, "the robot only for the message")
    }

    /// Return or a click on a row: the pane's jumper is asked for that chapter's block (#1319's seam).
    func testNoDchChaptersNoPromptsTab() throws {
        let (p, m) = try panel(Self.session())
        defer { m.stop() }
        XCTAssertTrue(p.tabs.contains(.prompts), "dch's chapters: the tab")
        p.dchChapters = nil
        XCTAssertFalse(p.tabs.contains(.prompts), "#1471: no dch chapters read: no Prompts tab")
    }

    // MARK: #1815 (operator 11-21 items 3-4)

    static let hideKey = "xrayHideAgentMessages"

    /// Item 3. Red at base: XrayTab had `responses = "Responses"` (XrayPanel.swift:16) and the strip listed it.
    func testNoResponsesTab() {
        XCTAssertEqual(XrayTab.allCases.map(\.rawValue), ["Prompts", "Refs", "Search", "Tasks", "Questions", "Memory"])   // #1974
        XCTAssertTrue(XrayTab(rawValue: "Responses") == nil, "a stored last tab of Responses reads as Prompts")
    }

    /// Item 4. Red at base: `@Published var hidePeer = false` (XrayPanel.swift:300): shown at every open, nothing saved.
    func testAgentMessagesHiddenByDefaultAndTheChoiceIsSaved() throws {
        let rem = XrayPanels.rememberTab
        Preferences.defaults.removeObject(forKey: Self.hideKey)
        defer { XrayPanels.rememberTab = rem; Preferences.defaults.removeObject(forKey: Self.hideKey) }
        XrayPanels.rememberTab = { true }
        let (p, m) = try panel(Self.session())
        defer { m.stop() }
        XCTAssertTrue(p.hidePeer, "unset: hidden")
        XCTAssertTrue(Preferences.xrayHideAgentMessages)
        try XCTUnwrap(p.promptFooter(.prompts).last).toggle()   // Show agent messages
        XCTAssertEqual(Preferences.defaults.object(forKey: Self.hideKey) as? Bool, false, "the choice is saved")
        let (next, m2) = try panel(Self.session())
        defer { m2.stop() }
        XCTAssertFalse(next.hidePeer, "the next open keeps it")
        next.hidePeer = true
        XCTAssertEqual(Preferences.defaults.object(forKey: Self.hideKey) as? Bool, true)
        XCTAssertTrue(XrayPanelModel(target: XrayTarget(name: "api", dir: "/tmp/dch-test"), tab: .prompts).hidePeer)
    }

    /// Under XCTest the remember seam is off: a toggle in another row stores nothing (no row leaks into another's default).
    func testTheHideToggleStoresNothingWithTheSeamOff() throws {
        Preferences.defaults.removeObject(forKey: Self.hideKey)
        XCTAssertFalse(XrayPanels.rememberTab())
        let (p, m) = try panel(Self.session())
        defer { m.stop() }
        p.hidePeer = false
        XCTAssertTrue(Preferences.defaults.object(forKey: Self.hideKey) == nil)
    }

    /// #1945. Red at 5c214a39: the ordinal cell fit its own text, so "9" and "120" started their titles at different x.
    func testPromptTitlesStartAtOneXWhateverTheOrdinalLength() {
        func row(_ n: Int) -> XrayPromptRow {
            XrayPromptRow(TranscriptOutline.Chapter(id: n, ordinal: n, title: "Fix the login test", kind: .prompt, hasError: false))
        }
        let (a, b) = (row(9), row(120))
        let w = XrayCol.widest([a.ordinal, b.ordinal])
        XCTAssertEqual(w, "120")
        let host = XrayPanelTasksTests()
        func x(_ r: XrayPromptRow, _ widest: String?) -> CGFloat? {
            host.frames(XrayPromptRowView(row: r, ordinalWidest: widest, open: {}).padding(sz(10)).frame(width: 420),
                        size: CGSize(width: 420, height: 60), kinds: ["xrayTitle"])["xrayTitle"]?.minX
        }
        XCTAssertTrue(x(a, w) != nil && x(a, w) == x(b, w), "one title x with the list's widest ordinal")
        XCTAssertTrue(x(a, nil) != x(b, nil), "control: each cell fitting its text drifts")
    }
}
