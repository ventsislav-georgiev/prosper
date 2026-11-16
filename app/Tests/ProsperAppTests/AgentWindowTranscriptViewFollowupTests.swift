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

    // MARK: step D, QA 657 INFO-6: the reader's place across a level switch (macOS 15+)

    /// 30 literal turns: "Prompt i", a Bash call with its result, "Done i": 3 blocks a turn, so turn i starts at id 3 * i.
    private func tvTurns(_ n: Int) -> [[String: Any]] {
        (0..<n).flatMap { i in
            [entry("user", ["message": ["role": "user", "content": "Prompt \(i)"]]), toolUse("c\(i)", "Bash", ["command": "make \(i)"]),
             toolResult("c\(i)", "ok \(i)"), say("Done \(i)")]
        }
    }

    @MainActor
    private func tvScrollView(_ v: NSView) -> NSScrollView? {
        if let s = v as? NSScrollView { return s }
        for c in v.subviews { if let s = tvScrollView(c) { return s } }
        return nil
    }

    /// The clip's lower edge is the document's: the reader is at the end (a read; the rows never scroll the clip).
    @MainActor
    private func tvAtEnd(_ host: NSView) -> Bool {
        guard let s = tvScrollView(host), let d = s.documentView else { return false }
        return s.contentView.bounds.maxY >= d.frame.height - 2
    }

    @MainActor
    private func tvHeight(_ host: NSView) -> CGFloat? { tvScrollView(host)?.documentView?.frame.height }

    /// The "Prompt i" and "Done i" texts whose frame is inside the scroll area's, read the way an AX client reads them
    /// (polled until `done` holds, to AXTreeSupport.poll's ceiling). The caller has turned the flags on.
    @MainActor
    private func tvInView(_ host: NSView, until done: ([String]) -> Bool = { _ in true }) -> [String] {
        func names(_ tree: [AXTreeNode]) -> [String] {
            guard let area = tree.first(where: { $0.role == "AXScrollArea" })?.frame else { return [] }
            return tree.filter { $0.frame.intersects(area) }.flatMap(\.names)
                .filter { $0.hasPrefix("Prompt ") || $0.hasPrefix("Done ") }
        }
        return names(AXTreeSupport.poll(host) { done(names($0)) })
    }

    /// Hosts the scrolling transcript of `n` turns in a window that is never shown, its place in a row-owned box (the
    /// binding SwiftUI writes); the flags are on for this process only and put back.
    @MainActor
    private func tvScene(_ n: Int, _ check: (URL, AgentTranscriptModel, TVPlace, NSHostingView<TVPlaceHost>) throws -> Void) throws {
        let url = tempDir().appendingPathComponent("s.jsonl")
        try write(url, tvTurns(n))
        let m = windowModel(store([session("api", .working, ago: 1, path: url.path)]))
        m.setVisible(true)
        defer { m.close() }
        let place = TVPlace()
        let restore = AXTreeSupport.axOn()
        defer { restore() }
        let (win, host) = AXTreeSupport.hosted(TVPlaceHost(place: place, model: m.transcript, level: .focused),
                                               CGSize(width: 560, height: 400))
        defer { win.close() }
        try check(url, m.transcript, place, host)
    }

    /// Switches the level and waits for the document to change height.
    @MainActor
    private func tvSwitch(_ host: NSHostingView<TVPlaceHost>, _ place: TVPlace, _ t: AgentTranscriptModel) {
        let h0 = tvHeight(host)
        host.rootView = TVPlaceHost(place: place, model: t, level: .verbose)
        _ = AXTreeSupport.poll(host) { [self] _ in tvHeight(host) != h0 }
    }

    /// Kept from today: the first open lands at the end.
    @MainActor
    func testTranscriptViewFollowupFirstOpenLandsAtTheEnd() throws {
        try tvScene(30) { _, _, place, host in
            let seen = tvInView(host) { $0.contains("Done 29") }
            XCTAssertTrue(seen.contains("Done 29"), "\(seen)")
            XCTAssertFalse(seen.contains("Prompt 14"), "\(seen)")
            XCTAssertTrue(tvAtEnd(host))
            XCTAssertTrue(place.top == nil, "no place at the end")
        }
    }

    /// Red before (AgentTranscriptView: the level in the ScrollView's id): a switch made a new ScrollView at the end.
    @MainActor
    func testTranscriptViewFollowupLevelSwitchKeepsTheReadersTopTurn() throws {
        guard #available(macOS 15, *) else { throw XCTSkip("macOS 14 keeps today's jump to the end") }
        try tvScene(30) { _, t, place, host in
            _ = tvInView(host) { $0.contains("Done 29") }
            place.top = 42   // turn 14
            let before = tvInView(host) { $0.contains("Prompt 14") }
            XCTAssertTrue(before.contains("Prompt 14"), "the reader is on turn 14: \(before)")
            tvSwitch(host, place, t)
            let after = tvInView(host) { $0.contains("Prompt 14") }
            XCTAssertTrue(after.contains("Prompt 14"), "still turn 14 after the switch: \(after)")
            XCTAssertFalse(after.contains("Done 29"), "\(after)")
            XCTAssertFalse(tvAtEnd(host), "not at the end")
            XCTAssertEqual(place.top, 42, "the place SwiftUI holds is turn 14's first block")
        }
    }

    /// Red when the end keeps a place (a place left at the end): a new line no longer followed.
    @MainActor
    func testTranscriptViewFollowupAReaderAtTheEndStaysAtTheEnd() throws {
        guard #available(macOS 15, *) else { throw XCTSkip("macOS 14 keeps today's behaviour") }
        try tvScene(30) { url, t, place, host in
            _ = tvInView(host) { $0.contains("Done 29") }
            place.top = 42
            _ = tvInView(host) { $0.contains("Prompt 14") }
            place.top = 87   // turn 29, the last: back at the end
            _ = AXTreeSupport.poll(host) { [self] _ in tvAtEnd(host) && place.top == nil }
            XCTAssertTrue(tvAtEnd(host))
            XCTAssertTrue(place.top == nil, "the end is no place: \(String(describing: place.top))")
            tvSwitch(host, place, t)
            _ = AXTreeSupport.poll(host) { [self] _ in tvAtEnd(host) }
            XCTAssertTrue(tvAtEnd(host), "at the end after the switch")
            // A long answer, taller than the pane: the end follows it.
            let h0 = tvHeight(host)
            try append(url, line(say("Tail\n" + String(repeating: "A long answer line\n", count: 60))))
            t.poll()
            _ = AXTreeSupport.poll(host) { [self] _ in tvHeight(host) != h0 && tvAtEnd(host) }
            XCTAssertNotEqual(tvHeight(host), h0, "the new line is drawn")
            XCTAssertTrue(tvAtEnd(host), "at the end after a new line")
        }
    }

    /// #1334: red before (the row above went red whenever a header row ran first in the process, as in the wide
    /// transcript filter): the same row after a session header is measured at 0.7, 0.85 and 1.0, so it does not hang
    /// on the order the rows run in.
    @MainActor
    func testTranscriptViewFollowupAReaderAtTheEndStaysAtTheEndAfterAHeaderIsMeasured() throws {
        guard #available(macOS 15, *) else { throw XCTSkip("macOS 14 keeps today's behaviour") }
        do {   // the header row's steps, its model closed and the scale put back before the scene
            let saved = ThemeRuntime.scale
            defer { ThemeRuntime.scale = saved }
            let a = session("api", .working, ago: 40, agents: 3)
            let st = store([a])
            let m = windowModel(st)
            m.setVisible(true)
            defer { m.close() }
            m.select(.live(a.key))
            let row = try XCTUnwrap(m.selectedRow)
            for scale: CGFloat in [0.7, 0.85, 1.0] {
                ThemeRuntime.scale = scale
                let header = AgentSessionHeader(row: row, session: a, cwd: "/Users/example/project", open: {}, store: st,
                                                mode: .transcript, setMode: { _ in })
                XCTAssertGreaterThan(NSHostingView(rootView: header.frame(width: 900 * scale)).fittingSize.height, 0)
            }
        }
        try testTranscriptViewFollowupAReaderAtTheEndStaysAtTheEnd()
    }
}

/// The row-owned place: what SwiftUI writes as the reader scrolls, and what a row sets to scroll the way SwiftUI does.
@MainActor final class TVPlace: ObservableObject {
    @Published var top: Int?
}

struct TVPlaceHost: View {
    @ObservedObject var place: TVPlace
    let model: AgentTranscriptModel
    var level: AgentVerbosity
    var body: some View {
        AgentTranscriptView(model: model, ownsLifecycle: false, level: level, position: $place.top)
            .frame(width: 560, height: 400).environment(\.colorScheme, .dark)
    }
}
