import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #1269 step B: Focused's turn label follows the session's working state (QA #657 INFO-3a), and a page whose call
/// order repeats an id carries it once (R1269-b). Transcripts are literal values or a file written in tempDir(); the
/// session is a fake from the island store (no dch). The hosted row's window is never shown; AX flags only on this
/// process through AXTreeSupport. Every closure here runs on the main actor, inside the row.
extension AgentWindowD1Tests {

    // MARK: item 1: the turn label

    /// Red before: the choice did not exist; AgentTranscriptView passed `working: model.toolPending` alone.
    @MainActor
    func testTranscriptViewFollowupTurnWorkingTable() {
        let table: [(state: String?, tool: Bool, working: Bool)] = [
            ("working", false, true), ("working", true, true),
            ("idle", false, false), ("idle", true, true),
            ("done", false, false), ("blocked", false, false), ("blocked", true, true),
            ("", false, false), ("", true, true), (nil, false, false), (nil, true, true),
        ]
        for r in table {
            XCTAssertEqual(AgentTranscriptView.turnWorking(state: r.state, toolPending: r.tool), r.working,
                           "\(r.state ?? "nil") tool \(r.tool)")
        }
    }

    /// The summary's words for a turn with one step: "Working \u{B7} 1 step" while working, "1 step" when not.
    @MainActor
    func testTranscriptViewFollowupLabelWordsAreUnchanged() {
        let blocks = asm([entry("user", ["message": ["role": "user", "content": "go"]]),
                          toolUse("b1", "Bash", ["command": "make"]), toolResult("b1", "ok")]).blocks
        func label(_ working: Bool) -> String? {
            for r in TranscriptVerbosity.project(blocks, level: .focused, working: working) {
                if case .summary(let s, _, _) = r.kind { return s.label }
            }
            return nil
        }
        XCTAssertEqual(label(AgentTranscriptView.turnWorking(state: "working", toolPending: false)), "Working \u{B7} 1 step")
        XCTAssertEqual(label(AgentTranscriptView.turnWorking(state: "idle", toolPending: false)), "1 step")
    }

    /// Red before (AgentTranscriptView.swift `working: model.toolPending`): between the two calls of a working session
    /// the hosted view read "1 step"; now it holds "Working" from the first call to the second.
    @MainActor
    func testTranscriptViewFollowupHostedLabelHoldsWorkingBetweenTwoCalls() throws {
        let url = tempDir().appendingPathComponent("w.jsonl")
        try write(url, [entry("user", ["message": ["role": "user", "content": "Fix the build"]]),
                        toolUse("b1", "Bash", ["command": "make"]), toolResult("b1", "ok")])
        let m = windowModel(store([session("api", .working, ago: 1, path: url.path)]))
        m.setVisible(true)
        defer { m.close() }
        let t = m.transcript
        XCTAssertEqual(t.source?.dchState, "working", "the window handed the session's state to the model")
        XCTAssertFalse(t.toolPending, "between two calls: none open")
        // Every name the AX walk reads once the summary ending in `steps` is drawn (a Button may join its label's words).
        func summary(_ steps: String) -> [String] {
            let v = AgentTranscriptView(model: t, scrolls: false, ownsLifecycle: false, level: .focused)
                .frame(width: 560).environment(\.colorScheme, .dark)
            let tree = AXTreeSupport.tree(v, CGSize(width: 560, height: 400)) { tr in
                tr.contains { n in n.names.contains { $0.hasSuffix(steps) } }
            }
            return tree.flatMap(\.names).filter { $0.hasSuffix(steps) }
        }
        let between = summary("1 step")
        XCTAssertFalse(between.isEmpty, "the summary is read")
        XCTAssertTrue(between.allSatisfy { $0.hasSuffix("Working \u{B7} 1 step") }, "\(between)")
        try append(url, line(toolUse("b2", "Bash", ["command": "make test"])))
        t.poll()
        let second = summary("2 steps")
        XCTAssertFalse(second.isEmpty, "the summary is read")
        XCTAssertTrue(second.allSatisfy { $0.hasSuffix("Working \u{B7} 2 steps") }, "\(second)")
    }

    // MARK: rider R1269-b: a repeated id in the page's call order

    /// Red before: prepend() carried the page's order [t1, t1] whole, so the two slots counted against maxPending and
    /// evicted t1 (the first slot) though only two distinct calls were open; t1's live result then made an orphan card.
    func testTranscriptViewFollowupARepeatedIdOnThePageIsCarriedOnce() {
        var live = asm([toolUse("x", "Bash", ["command": "pwd"])], maxPending: 2)
        live.prepend(asm([toolUse("t1", "Bash", ["command": "ls"]), toolUse("t1", "Bash", ["command": "ls"])], maxPending: 100))
        XCTAssertEqual(live.blocks.count, 3)
        live.add(TranscriptDecoder.decode(line: line(toolResult("t1", "out"))), source: nil)
        XCTAssertEqual(live.blocks.count, 3, "t1 is still tracked: no orphan card: \(live.blocks.map(\.body))")
        XCTAssertTrue(live.orphans.isEmpty)
        live.add(TranscriptDecoder.decode(line: line(toolResult("x", "here"))), source: nil)
        XCTAssertEqual(live.blocks.count, 3, "x is still tracked too")
        XCTAssertEqual(live.blocks.filter(\.pending).count, 1, "only the page's first t1 call, which no id tracks, reads running")
    }

    // MARK: step C, R1269-q1: an ended pane never reads Working

    /// Red before: turnWorking had no ended column; an ended pane's last state ("working", a call open at the kill)
    /// read Working for as long as the pane was kept.
    @MainActor
    func testTranscriptViewFollowupEndedPaneTurnWorkingTable() {
        let table: [(state: String?, tool: Bool, ended: Bool, working: Bool)] = [
            ("working", true, true, false), ("working", false, true, false), ("idle", true, true, false),
            (nil, true, true, false), (nil, false, true, false),
            ("working", true, false, true), ("working", false, false, true), ("idle", true, false, true),
            ("idle", false, false, false),
        ]
        for r in table {
            XCTAssertEqual(AgentTranscriptView.turnWorking(state: r.state, toolPending: r.tool, ended: r.ended), r.working,
                           "\(r.state ?? "nil") tool \(r.tool) ended \(r.ended)")
        }
        let blocks = asm([entry("user", ["message": ["role": "user", "content": "go"]]),
                          toolUse("b1", "Bash", ["command": "make"])]).blocks
        let label = TranscriptVerbosity.project(blocks, level: .focused,
                                                working: AgentTranscriptView.turnWorking(state: "working", toolPending: true, ended: true))
            .compactMap { r -> String? in if case .summary(let s, _, _) = r.kind { return s.label } else { return nil } }
        XCTAssertEqual(label, ["1 step"], "ended, working, a call open: the label reads N steps")
    }

    /// Red before (AgentTranscriptView.swift: the view did not pass `ended`): a session that ended while dch last said
    /// working, with a call open at the kill, read "Working \u{B7} 1 step" under its Ended header.
    @MainActor
    func testTranscriptViewFollowupHostedEndedPaneReadsSteps() throws {
        let url = tempDir().appendingPathComponent("e.jsonl")
        try write(url, [entry("user", ["message": ["role": "user", "content": "Fix the build"]]),
                        toolUse("b1", "Bash", ["command": "make"])])
        let m = windowModel(store([session("api", .working, ago: 1, path: url.path)]))
        m.setVisible(true)
        defer { m.close() }
        let t = m.transcript
        XCTAssertEqual(t.source?.dchState, "working", "the last state the window handed the model")
        XCTAssertTrue(t.toolPending, "the call open at the kill")
        func summary(ended: Bool) -> [String] {
            let v = AgentTranscriptView(model: t, scrolls: false, ownsLifecycle: false, level: .focused, ended: ended)
                .frame(width: 560).environment(\.colorScheme, .dark)
            let tree = AXTreeSupport.tree(v, CGSize(width: 560, height: 400)) { tr in
                tr.contains { n in n.names.contains { $0.hasSuffix("1 step") } }
            }
            return tree.flatMap(\.names).filter { $0.hasSuffix("1 step") }
        }
        let live = summary(ended: false)
        XCTAssertFalse(live.isEmpty, "the summary is read")
        XCTAssertTrue(live.allSatisfy { $0.hasSuffix("Working \u{B7} 1 step") }, "live: \(live)")
        let ended = summary(ended: true)
        XCTAssertFalse(ended.isEmpty, "the summary is read")
        XCTAssertFalse(ended.contains { $0.contains("Working") }, "ended: \(ended)")
    }
}
