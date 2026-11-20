import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

private final class Box1453 { var seen: [String: CGRect] = [:] }
/// A window whose backing scale is pinned (SwiftUI snaps to it); never shown.
private final class Window1453: NSWindow {
    var fixedBacking: CGFloat?
    override var backingScaleFactor: CGFloat { fixedBacking ?? super.backingScaleFactor }
}

/// #1453 (operator 2026-11-17, "use robot emoji here for subagents"): the sub-agent count on a sidebar row and an island
/// card draws the RobotGlyph (#1546: was the robot emoji U+1F916) in the same filled capsule, not the people symbol; VoiceOver keeps the words.
/// Offscreen only: ImageRenderer, or views hosted in windows that are never shown; no event, no file. Fakes only.
extension AgentRowModelEffortTests {
    static let robot1453 = "\u{1F916}"

    /// The agents group as AgentCountGroups draws it, with `lead` in front of the number (the pill stroke, the paddings, the ink).
    func group1453<L: View>(_ n: Int, _ lead: L) -> some View {
        HStack(spacing: sz(2)) {
            lead.font(Neon.font(10.5 - 1))
            Text(AgentIsland.count(n)).font(Neon.font(10.5).monospacedDigit())
        }
        .padding(.horizontal, sz(4))
        .background { Capsule().strokeBorder(AgentSidebarRowView.agentsStroke, lineWidth: 1) }   // #1735: outlined, no fill
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
                let got = try pixels1453(AgentCountGroups(counts: [(.agents, n)], size: 10.5, outlined: true))
                let robot = try pixels1453(group1453(n, RobotGlyph(size: 10.5 - 1)))
                let people = try pixels1453(group1453(n, Image(systemName: "person.2")))
                XCTAssertTrue(got.0 == robot.0 && got.1 == robot.1 && got.2 == robot.2, "the robot and the number: \(n) agents (\(scale))")
                XCTAssertTrue(got.2 != people.2, "not the people symbol: \(n) agents (\(scale))")
            }
        }
    }

    /// #1735: the shells group is the terminal symbol and the number in a white (or textPrimary) outline, not the agents' purple one.
    @MainActor
    func testShellsCountDrawsAWhiteOutlinePillNotThePurpleOne() throws {
        func ref(_ stroke: Color) -> some View {
            HStack(spacing: sz(2)) {
                Image(systemName: AgentSidebar.Count.shells.symbol).font(Neon.font(10.5 - 1))
                Text(AgentIsland.count(2)).font(Neon.font(10.5).monospacedDigit())
            }
            .padding(.horizontal, sz(4))
            .background { Capsule().strokeBorder(stroke, lineWidth: 1) }
            .foregroundStyle(Neon.textSecondary)
            .fixedSize()
        }
        let got = try pixels1453(AgentCountGroups(counts: [(.shells, 2)], size: 10.5, outlined: true))
        let want = try pixels1453(ref(AgentSidebarRowView.shellsStroke))
        let purple = try pixels1453(ref(AgentSidebarRowView.agentsStroke))
        XCTAssertTrue(got.0 == want.0 && got.1 == want.1 && got.2 == want.2, "the shells pill: its own outline, no fill")
        XCTAssertTrue(got.2 != purple.2, "not the agents' purple")
    }

    /// The pill is the capsule it was: the group's frame plus the 4 pt padding each side, its height the group's, within
    /// one device pixel; on the real sidebar row.
    @MainActor
    func testRobot1453ThePillIsUnchangedOnTheRow() {
        let pixel = AXTreeSupport.devicePixel
        atScales { scale in
            for n in [3, 128] {
                let h = hosted1345(outlined1360(agents: n), number: 1, width: AgentWindowModel.fullSidebarWidth - sz(16), backing: 2)
                guard let c = h.frames["capsule.agents"], let g = h.frames["count.agents"] else {
                    XCTFail("probed: \(h.frames.keys.sorted()) (\(scale))"); continue
                }
                let inner = NSHostingView(rootView: HStack(spacing: sz(2)) {
                    RobotGlyph(size: 10.5 - 1)
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
        let group = AXTreeSupport.tree(AgentCountGroups(counts: [(.agents, 3)], size: 10.5, outlined: true), box) { t in t.contains { $0.label == "3 agents" } }
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
        // #1546: the glyph is drawn in the surrounding ink like the text: no chromatic pixel (the emoji's colours are gone).
        let (w, h, data) = try pixels1453(line)
        let lit = stride(from: 0, to: data.count - 3, by: 4).filter { i in
            let c = [data[i], data[i + 1], data[i + 2]], hi = c.max() ?? 0, lo = c.min() ?? 0
            return Int(hi) - Int(lo) > 40
        }.count
        XCTAssertTrue(w > 0 && h > 0 && lit == 0, "the card's agents group is the one-ink robot glyph: \(lit) chromatic pixels")
    }

    /// #1546 source guard: no U+1F916 (the character or its \u{1F916} escape) anywhere in Sources outside Emoji.swift (the
    /// ":robot:" shortcode table); every place draws RobotGlyph.
    func testRobot1546NoRobotEmojiInSourcesOutsideEmojiSwift() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let escapes = ["\\u{1F916}", "\\u{1f916}", "\u{1F916}"]
        var seen = 0, hits: [String] = []
        let e = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        while let url = e?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            seen += 1
            guard url.lastPathComponent != "Emoji.swift" else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            if escapes.contains(where: { text.contains($0) }) { hits.append(url.lastPathComponent) }
        }
        XCTAssertTrue(seen > 100, "the scan read the sources: \(seen) files")
        XCTAssertEqual(hits, [], "the robot emoji outside Emoji.swift")
    }

    /// #1546: at a UI scale other than 1 the header's robot image is 10.5 * scale * sideFactor, as the text beside it scales.
    @MainActor
    func testRobot1546TheHeaderRobotFollowsTheUIScale() {
        let saved = ThemeRuntime.scale
        defer { ThemeRuntime.scale = saved }
        for s in [0.7, 0.85, 1.0] {
            ThemeRuntime.scale = s
            XCTAssertEqual(AgentSidebarTitleRow.countRobotImage().size.width, 10.5 * s * RobotGeometry.sideFactor, accuracy: 0.001, "scale \(s)")
        }
    }

    /// #1546: the AppKit render is a template (the menu tints it) of the asked size, and the view draws.
    @MainActor
    func testRobot1546TheMenuImageIsATemplateOfTheAskedSize() throws {
        let image = RobotGlyph.nsImage(size: 16)
        XCTAssertTrue(image.isTemplate)
        XCTAssertEqual(image.size, NSSize(width: 16, height: 16))
        let (w, h, data) = try pixels1453(RobotGlyph(size: 20).foregroundStyle(Color.white))
        XCTAssertTrue(w > 0 && h > 0 && data.contains { $0 != 0 }, "the glyph draws ink")
    }

    /// A view hosted in a never-shown window of `size` whose backing is pinned: its fitting height and the row probes' frames.
    @MainActor
    func probed1453<V: View>(_ v: V, size: CGSize, backing: CGFloat, waitFor: String? = nil) -> (fit: CGFloat, frames: [String: CGRect]) {
        let box = Box1453()
        AgentSidebarRowView.probe = { kind, _, rect in box.seen[kind] = rect }
        defer { AgentSidebarRowView.probe = nil }
        let win = Window1453(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: true)
        win.fixedBacking = backing
        win.isReleasedWhenClosed = false
        defer { win.contentView = nil; win.close() }
        let host = NSHostingView(rootView: v.frame(width: size.width, alignment: .topLeading).environment(\.colorScheme, .dark))
        host.frame = CGRect(origin: .zero, size: size)
        win.contentView = host
        let deadline = Date().addingTimeInterval(5)
        repeat {
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        } while (waitFor.map { box.seen[$0] == nil } ?? false) && Date() < deadline
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        host.layoutSubtreeIfNeeded()
        XCTAssertFalse(win.isVisible, "never shown")
        return (host.fittingSize.height, box.seen)
    }

    /// QA R1453-s1: the colour emoji's line is taller than SF's, so the detail line (state word, counts) must keep its
    /// height with 3 agents as without, within a device pixel, at every scale, 1x and 2x. Prints the facts as ROBOT1453-FACT.
    @MainActor
    func testRobot1453TheDetailLineKeepsItsHeightWithAgents() {
        let pixel = AXTreeSupport.devicePixel
        atScales { scale in
            for backing: CGFloat in [1, 2] {
                var h: [Int: CGFloat] = [:]
                for n in [0, 3] {
                    let row = AgentSidebarRowView(row: outlined1360(agents: n), selected: false)
                    h[n] = probed1453(row.detailLine([]), size: CGSize(width: sz(274), height: 60), backing: backing).fit
                }
                print("ROBOT1453-FACT detailLine scale \(scale) backing \(backing): agents0 \(h[0] ?? -1) agents3 \(h[3] ?? -1)")
                XCTAssertTrue((h[0] ?? 0) > 0, "measured: \(h) (\(scale) @\(backing)x)")
                XCTAssertEqual(h[3] ?? -1, h[0] ?? -2, accuracy: pixel, "the detail line with agents vs without: \(h) (\(scale) @\(backing)x)")
            }
        }
    }

    /// The island card is a fixed-height row: with agents its card keeps the fixed height and the count group's frame lies
    /// inside the card (no clipping), at every scale, 1x and 2x.
    @MainActor
    func testRobot1453TheCardKeepsItsFixedHeightAndHoldsTheCount() {
        let pixel = AXTreeSupport.devicePixel
        atScales { scale in
            for backing: CGFloat in [1, 2] {
                var cards: [Int: CGRect] = [:]
                for n in [0, 3] {
                    var s = AgentSession(key: AgentSessionKey(dir: "/Users/example/work", name: "api"), alias: "", activity: Self.now - 240, state: .idle, agents: n)
                    s.model = "claude-opus-4-5"
                    let size = CGSize(width: AgentIslandGeometry.expandedWidth - 2 * AgentIslandGeometry.listInset, height: AgentIslandGeometry.rowHeight)
                    let f = probed1453(AgentIslandRow(session: s, now: Self.now, notice: nil, show: .all) {}, size: size, backing: backing, waitFor: "card").frames
                    guard let card = f["card"] else { XCTFail("probed: \(f.keys.sorted()) (\(scale) @\(backing)x)"); continue }
                    cards[n] = card
                    XCTAssertEqual(card.height, AgentIslandGeometry.rowHeight - AgentIslandGeometry.rowGap, accuracy: pixel, "the fixed height: \(card) (\(scale) @\(backing)x)")
                    if n > 0 {
                        guard let g = f["count.agents"] else { XCTFail("no agents group: \(f.keys.sorted()) (\(scale) @\(backing)x)"); continue }
                        print("ROBOT1453-FACT card scale \(scale) backing \(backing): card \(card) group \(g)")
                        XCTAssertTrue(g.minY >= card.minY - pixel && g.maxY <= card.maxY + pixel && g.minX >= card.minX - pixel && g.maxX <= card.maxX + pixel,
                                      "the count group lies inside the card: \(g) in \(card) (\(scale) @\(backing)x)")
                    }
                }
            }
        }
    }
}
