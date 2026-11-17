import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #1453 (operator 2026-11-17, "use robot emoji here for subagents"): the sub-agent count on a sidebar row and an island
/// card draws the robot emoji (U+1F916) in the same capsule outline, not the people symbol; VoiceOver keeps the words.
/// Offscreen only: ImageRenderer, or views hosted in windows that are never shown; no event, no file. Fakes only.
extension AgentRowModelEffortTests {
    static let robot1453 = "\u{1F916}"

    /// The agents group as AgentCountGroups draws it, with `lead` in front of the number (the outline, the paddings, the ink).
    func group1453<L: View>(_ n: Int, _ lead: L) -> some View {
        HStack(spacing: sz(2)) {
            lead.font(Neon.font(10.5 - 1))
            Text(AgentIsland.count(n)).font(Neon.font(10.5).monospacedDigit())
        }
        .padding(.horizontal, sz(4))
        .background { Capsule().strokeBorder(Color.white, lineWidth: 1) }
        .foregroundStyle(Neon.textSecondary)
        .fixedSize()
    }

    @MainActor
    func pixels1453<V: View>(_ v: V) throws -> (Int, Int, Data) {
        let r = ImageRenderer(content: v.background(Color.black))
        r.scale = 2
        let cg = try XCTUnwrap(r.cgImage)
        return (cg.width, cg.height, try XCTUnwrap(cg.dataProvider?.data as Data?))
    }

    /// The count group is pixel for pixel the robot version and not the people-symbol version, at every scale.
    @MainActor
    func testRobot1453TheCountDrawsTheEmojiNotThePeopleIcon() throws {
        try atScales { scale in
            for n in [3, 128] {
                let got = try pixels1453(AgentCountGroups(counts: [(.agents, n)], size: 10.5, outline: .white))
                let robot = try pixels1453(group1453(n, Text(Self.robot1453)))
                let people = try pixels1453(group1453(n, Image(systemName: "person.2")))
                XCTAssertTrue(got.0 == robot.0 && got.1 == robot.1 && got.2 == robot.2, "the robot and the number: \(n) agents (\(scale))")
                XCTAssertTrue(got.2 != people.2, "not the people symbol: \(n) agents (\(scale))")
            }
        }
    }

    /// The outline is the capsule it was: the group's frame plus the 4 pt padding each side, its height the group's, within
    /// one device pixel; on the real sidebar row.
    @MainActor
    func testRobot1453TheOutlineIsUnchangedOnTheRow() {
        let pixel = AXTreeSupport.devicePixel
        atScales { scale in
            for n in [3, 128] {
                let h = hosted1345(outlined1360(agents: n), number: 1, width: AgentWindowModel.fullSidebarWidth - sz(16), backing: 2)
                guard let c = h.frames["capsule.agents"], let g = h.frames["count.agents"] else {
                    XCTFail("probed: \(h.frames.keys.sorted()) (\(scale))"); continue
                }
                let inner = NSHostingView(rootView: HStack(spacing: sz(2)) {
                    Text(Self.robot1453).font(Neon.font(10.5 - 1))
                    Text(AgentIsland.count(n)).font(Neon.font(10.5).monospacedDigit())
                }.fixedSize()).fittingSize
                XCTAssertEqual(c.width, inner.width + 2 * sz(4), accuracy: 1 + pixel, "the capsule is the robot group plus its padding: \(c) \(inner) (\(scale))")
                XCTAssertEqual(c.width, g.width, accuracy: pixel, "the capsule is the group's frame: \(c) \(g) (\(scale))")
                XCTAssertEqual(c.height, g.height, accuracy: pixel, "no vertical padding: \(c) \(g) (\(scale))")
            }
        }
    }

    /// VoiceOver reads the words, never the emoji (nor its name): on the row, the group and the island card.
    @MainActor
    func testRobot1453VoiceOverKeepsTheWordsOnTheRowAndTheCard() {
        let box = CGSize(width: 300, height: 60)
        func reads(_ t: [AXTreeNode], _ s: String) -> Bool { t.contains { n in [n.label, n.title, n.value, n.help].contains { $0.contains(s) } } }
        let group = AXTreeSupport.tree(AgentCountGroups(counts: [(.agents, 3)], size: 10.5, outline: .white), box) { t in t.contains { $0.label == "3 agents" } }
        XCTAssertTrue(group.contains { $0.label == "3 agents" }, "the words: \(group.map(\.label))")
        XCTAssertFalse(reads(group, Self.robot1453) || reads(group, "robot"), "no emoji, no emoji name: \(group.map(\.label))")
        let row = AXTreeSupport.tree(AgentSidebarRowView(row: outlined1360(agents: 3), selected: false).frame(width: AgentWindowModel.fullSidebarWidth - sz(16)),
                                     CGSize(width: AgentWindowModel.fullSidebarWidth, height: 60)) { t in t.contains { $0.label.hasPrefix("sec-1") } }
        XCTAssertEqual(row.first { $0.label.hasPrefix("sec-1") }?.label, "sec-1, Working, 3 agents, 199 merged pull requests, 7 open pull requests")
        XCTAssertFalse(reads(row, Self.robot1453) || reads(row, "robot"), "the row never reads the emoji")
        var s = AgentSession(key: AgentSessionKey(dir: "/Users/example/work", name: "api"), alias: "", activity: Self.now - 240, state: .idle, agents: 3)
        s.model = "claude-opus-4-5"
        let card = AXTreeSupport.tree(AgentIslandRow(session: s, now: Self.now, notice: nil, show: .all) {}.frame(width: AgentIslandGeometry.expandedWidth - 2 * AgentIslandGeometry.listInset),
                                      CGSize(width: AgentIslandGeometry.expandedWidth, height: AgentIslandGeometry.rowHeight)) { t in t.contains { $0.label.contains("3 agents") } }
        XCTAssertTrue(card.contains { $0.label.contains("3 agents") }, "the card's words: \(card.map(\.label))")
        XCTAssertFalse(reads(card, Self.robot1453) || reads(card, "robot"), "the card never reads the emoji")
    }

    /// Both surfaces build their count line from AgentCountGroups: the island card's detail line is the row's (the card
    /// draws `side.detailLine`), so its agents group is the robot group of the first row.
    @MainActor
    func testRobot1453TheCardLineIsTheRowsRobotGroup() throws {
        var s = AgentSession(key: AgentSessionKey(dir: "/Users/example/work", name: "api"), alias: "", activity: Self.now - 240, state: .idle, agents: 3)
        s.model = "claude-opus-4-5"
        let r = AgentIslandRow.sidebarRow(s, show: .all, now: Self.now, notice: nil)
        XCTAssertEqual(r.counts.first.map { "\($0.0) \($0.1)" }, "agents 3", "the card's row carries the agents count")
        let line = AgentSidebarRowView(row: r, selected: false, inks: AgentIslandRow.inks).detailLine([])
        // The robot is a colour glyph; the symbol, the outline and the text are one ink: a chromatic pixel is the emoji's.
        let (w, h, data) = try pixels1453(line)
        let lit = stride(from: 0, to: data.count - 3, by: 4).filter { i in
            let c = [data[i], data[i + 1], data[i + 2]], hi = c.max() ?? 0, lo = c.min() ?? 0
            return Int(hi) - Int(lo) > 40
        }.count
        XCTAssertTrue(w > 0 && h > 0 && lit > 0, "the card's agents group is drawn with the colour emoji: \(lit) chromatic pixels")
    }
}
