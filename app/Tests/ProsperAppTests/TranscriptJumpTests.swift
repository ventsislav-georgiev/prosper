import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #904 fixtures: a fake transcript file in tempDir() and a standalone model that reads it inline (no watch, no timer,
/// no dch). Turn i is "Prompt i", a Bash call "make i" with its result, and "Done i": blocks 3i, 3i+1, 3i+2.
@MainActor
enum JumpFixture {
    static func line(_ o: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: o) + Data("\n".utf8) }
    static func entry(_ type: String, _ extra: [String: Any]) -> [String: Any] {
        ["type": type, "sessionId": "s-1", "version": "2.1.300"].merging(extra) { $1 }
    }
    static func user(_ text: String) -> [String: Any] { entry("user", ["message": ["role": "user", "content": text]]) }
    static func say(_ text: String) -> [String: Any] {
        entry("assistant", ["message": ["role": "assistant", "content": [["type": "text", "text": text]]]])
    }
    static func bash(_ id: String, _ cmd: String) -> [[String: Any]] {
        [entry("assistant", ["message": ["role": "assistant", "content": [["type": "tool_use", "id": id, "name": "Bash",
                                                                             "input": ["command": cmd]]]]]),
         entry("user", ["message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": id, "content": "ok"]]],
                        "toolUseResult": ["stdout": "ok", "stderr": ""]])]
    }
    static func turns(_ n: Int, from: Int = 0) -> [[String: Any]] {
        (from..<from + n).flatMap { i in [user("Prompt \(i)")] + bash("c\(i)", "make \(i)") + [say("Done \(i)")] }
    }
    static func write(_ url: URL, _ entries: [[String: Any]]) throws { try entries.map(line).reduce(Data(), +).write(to: url) }
    static func append(_ url: URL, _ entries: [[String: Any]]) throws {
        let h = try FileHandle(forWritingTo: url)
        try h.seekToEnd()
        try h.write(contentsOf: entries.map(line).reduce(Data(), +))
        try h.close()
    }
    static func model(_ url: URL) -> AgentTranscriptModel {
        let m = AgentTranscriptModel()
        m.offMain = { $0() }
        m.makeWatch = { _, _ in NSObject() }
        m.tickInterval = 3600
        m.update(AgentTranscriptSource(key: AgentSessionKey(dir: "/tmp/dch-test", name: "api"), dchVersion: "1.30.0",
                                       dchState: "idle", sessionId: "0b7c2f3e-1111-2222-3333-444455556666",
                                       transcriptPath: url.path))
        m.start()
        m.showAnyway = true
        return m
    }
}

struct JumpHost: View {
    let model: AgentTranscriptModel
    let jumper: TranscriptJumper
    var level: AgentVerbosity
    var body: some View {
        AgentTranscriptView(model: model, ownsLifecycle: false, level: level, jumper: jumper)
            .frame(width: 560, height: 400).environment(\.colorScheme, .dark)
    }
}

/// A view that takes first responder: the window's focus before and after a jump.
final class JumpFocusProbe: NSView {
    override var acceptsFirstResponder: Bool { true }
}

/// #904 (#832 X1 step A, spec v2.1 8.4): the jump in a hosted transcript. Offscreen only: a borderless window that is
/// never shown, ordered front or made key; no event is posted; AX flags on this process only (AXTreeSupport), put back.
/// Also the P0 spike's (d) re-check on today's container: each step prints its numbers ("X1D ...") to the log.
@MainActor
final class TranscriptJumpTests: XCTestCase {

    private func scroll(_ v: NSView) -> NSScrollView? {
        if let s = v as? NSScrollView { return s }
        for c in v.subviews { if let s = scroll(c) { return s } }
        return nil
    }
    private func atEnd(_ host: NSView) -> Bool {
        guard let s = scroll(host), let d = s.documentView else { return false }
        return s.contentView.bounds.maxY >= d.frame.height - 2
    }
    private func height(_ host: NSView) -> CGFloat { scroll(host)?.documentView?.frame.height ?? 0 }
    private func visibleMinY(_ host: NSView) -> CGFloat { scroll(host)?.documentVisibleRect.minY ?? -1 }

    /// The distance from the viewport's top to the top of the text an AX client reads as `name`, when it is drawn inside
    /// the scroll area. accessibilityFrame is in AppKit screen space (y up): the top is the larger y.
    private func top(_ tree: [AXTreeNode], _ name: String) -> CGFloat? {
        guard let area = tree.first(where: { $0.role == "AXScrollArea" })?.frame,
              let n = tree.first(where: { $0.names.contains(name) && $0.frame.intersects(area) }) else { return nil }
        return area.maxY - n.frame.maxY
    }
    private func drawn(_ tree: [AXTreeNode], _ name: String) -> Bool {
        guard let area = tree.first(where: { $0.role == "AXScrollArea" })?.frame else { return false }
        return tree.contains { n in n.names.contains { $0.contains(name) } && n.frame.intersects(area) }
    }
    private func report(_ step: String, _ host: NSView, _ tree: [AXTreeNode], _ name: String) {
        let t = top(tree, name).map { String(format: "%.2f", $0) } ?? "-"
        print("X1D \(step) | \(name) top \(t) | offset \(String(format: "%.0f", scroll(host)?.contentView.bounds.origin.y ?? -1))"
              + " | doc \(String(format: "%.0f", height(host))) | at bottom \(atEnd(host))")
    }

    private func scene(level: AgentVerbosity = .focused, turns: Int = 40,
                       _ check: (URL, AgentTranscriptModel, TranscriptJumper, NSWindow, NSHostingView<JumpHost>) throws -> Void) throws {
        let url = tempDir().appendingPathComponent("j.jsonl")
        try JumpFixture.write(url, JumpFixture.turns(turns))
        let m = JumpFixture.model(url)
        defer { m.stop() }
        let j = TranscriptJumper()
        let restore = AXTreeSupport.axOn()
        defer { restore() }
        let (win, host) = AXTreeSupport.hosted(JumpHost(model: m, jumper: j, level: level), CGSize(width: 560, height: 400))
        defer { win.close() }
        try check(url, m, j, win, host)
        XCTAssertFalse(win.isVisible, "never shown")
    }

    /// Red before (no ScrollViewReader on macOS 15+'s request path, no jumper): nothing scrolled. Red without the second
    /// scrollTo (X1 mutant 6): the turn lands on top and "Done 5", its third row, stays below 40 pt. Then the P0 (d)
    /// steps on today's container: it holds while 5 blocks arrive, and the sentinel return follows again.
    func testJumpLandsOnAnUndrawnRowHoldsAndTheSentinelReturnFollows() throws {
        try scene { url, m, j, _, host in
            j.after = { _, _ in }   // the mark stays for this row; its clock is the next row's
            var tree = AXTreeSupport.poll(host) { [self] t in drawn(t, "Done 39") && atEnd(host) }
            report("1 anchored at start", host, tree, "Done 39")
            XCTAssertTrue(atEnd(host), "the first open lands at the end")
            XCTAssertGreaterThan(top(tree, "Done 39") ?? 0, 200, "the last reply is low in the viewport (the frame space is y up)")
            XCTAssertFalse(drawn(tree, "Done 5"), "turn 5 is far above the viewport")
            j.jump(toBlock: 17)   // "Done 5": the third row of turn 5
            tree = AXTreeSupport.poll(host) { [self] t in top(t, "Done 5").map { $0 > -1 && $0 <= sz(40) } ?? false }
            report("2 jump to b17", host, tree, "Done 5")
            let landed = try XCTUnwrap(top(tree, "Done 5"), "Done 5 is drawn")
            XCTAssertTrue(landed > -1 && landed <= sz(40), "within the top 40 pt: \(landed)")
            XCTAssertEqual(j.marked, "b17")
            XCTAssertFalse(atEnd(host))
            // Five blocks arrive: the view stays where the jump put it.
            let y0 = visibleMinY(host), h0 = height(host)
            try JumpFixture.append(url, [JumpFixture.user("Prompt 40")] + JumpFixture.bash("d1", "make 40") + JumpFixture.bash("d2", "make 41")
                                   + [JumpFixture.say("Done 40"), JumpFixture.say("Also 40")])
            m.poll()
            XCTAssertEqual(m.blocks.count, 125, "5 blocks appended")
            _ = AXTreeSupport.poll(host) { [self] _ in height(host) > h0 + 1 }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            tree = AXTreeSupport.poll(host) { _ in true }
            report("3 +5 blocks after the jump", host, tree, "Done 5")
            XCTAssertGreaterThan(height(host), h0, "the new blocks are in the document")
            XCTAssertEqual(visibleMinY(host), y0, accuracy: 1, "documentVisibleRect.minY holds")
            XCTAssertFalse(atEnd(host), "not pulled back to the bottom")
            // Back to latest: the sentinel, and new blocks are followed again.
            j.jumpToLatest()
            tree = AXTreeSupport.poll(host) { [self] _ in atEnd(host) }
            report("4 back to the sentinel", host, tree, "Also 40")
            XCTAssertTrue(atEnd(host), "at the true bottom")
            for k in 0..<2 {
                let h1 = height(host)
                try JumpFixture.append(url, [JumpFixture.user("Prompt \(41 + k)"), JumpFixture.say("Done \(41 + k)"),
                                             JumpFixture.say("More \(41 + k)")])
                m.poll()
                tree = AXTreeSupport.poll(host) { [self] _ in height(host) > h1 + 1 && atEnd(host) }
                report("\(5 + k) +3 blocks", host, tree, "More \(41 + k)")
                XCTAssertGreaterThan(height(host), h1)
                XCTAssertTrue(atEnd(host), "followed (\(k))")
            }
        }
    }

    /// X1 mutant 2: a jump never opens a fold. A block folded in a Focused step lands on the fold's row, which stays
    /// folded ("make 5" is not drawn while the mark shows). The jump moves no focus (the window's first responder) and
    /// changes nothing on the model. The mark goes through the clock seam, under Reduce Motion with no fade.
    func testJumpIntoAFoldKeepsTheFoldFocusAndModelAndTheMarkGoes() throws {
        try scene { _, m, j, win, host in
            var timers: [(TimeInterval, @MainActor @Sendable () -> Void)] = []
            j.after = { d, f in timers.append((d, f)) }
            j.reduceMotion = { true }
            let probe = JumpFocusProbe(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
            host.addSubview(probe)
            XCTAssertTrue(win.makeFirstResponder(probe), "the probe holds the window's focus")
            _ = AXTreeSupport.poll(host) { [self] t in drawn(t, "Done 39") }
            let blocks = m.blocks, chapters = m.chapters, show = m.showAnyway, todos = m.todosOpen
            j.jump(toBlock: 16)   // the Bash call of turn 5, folded in its summary
            let tree = AXTreeSupport.poll(host) { [self] t in drawn(t, "Done 5") }
            XCTAssertTrue(drawn(tree, "Done 5"), "landed on turn 5's summary row, its reply right below")
            XCTAssertEqual(j.marked, "s15", "the fold's row is the one marked")
            XCTAssertFalse(drawn(tree, "make 5"), "the fold is still folded")
            XCTAssertTrue(win.firstResponder === probe, "focus did not move")
            XCTAssertFalse(win.isKeyWindow)
            XCTAssertEqual(m.blocks, blocks)
            XCTAssertEqual(m.chapters, chapters)
            XCTAssertEqual(m.showAnyway, show)
            XCTAssertEqual(m.todosOpen, todos)
            // The mark: 1.2 s on the clock seam, then gone; Reduce Motion removes it without a fade.
            XCTAssertEqual(timers.map(\.0), [1.2])
            timers.last?.1()
            XCTAssertTrue(j.marked == nil, "the mark is removed")
            XCTAssertTrue(TranscriptJumper.removal(reduceMotion: true) == nil, "no fade under Reduce Motion")
            XCTAssertFalse(TranscriptJumper.removal(reduceMotion: false) == nil, "a fade otherwise")
            // A later jump's mark outlives the earlier one's clock.
            j.jump(toBlock: 17)
            _ = AXTreeSupport.poll(host) { _ in j.marked == "b17" }
            j.jump(toBlock: 20)
            _ = AXTreeSupport.poll(host) { _ in j.marked == "b20" }
            XCTAssertEqual(timers.count, 3)
            timers.dropLast().last?.1()
            XCTAssertEqual(j.marked, "b20", "the earlier clock leaves the newer mark")
            timers.last?.1()
            XCTAssertTrue(j.marked == nil)
            XCTAssertTrue(win.firstResponder === probe, "focus did not move")
        }
    }

    /// A jump to a block no row shows (not loaded) is a no-op: no mark, no scroll.
    func testJumpToAMissingBlockDoesNothing() throws {
        try scene(turns: 20) { _, _, j, _, host in
            _ = AXTreeSupport.poll(host) { [self] t in drawn(t, "Done 19") && atEnd(host) }
            let y0 = visibleMinY(host)
            j.jump(toBlock: 999)
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            XCTAssertTrue(j.marked == nil)
            XCTAssertEqual(visibleMinY(host), y0, accuracy: 1)
            XCTAssertTrue(atEnd(host))
        }
    }
}
