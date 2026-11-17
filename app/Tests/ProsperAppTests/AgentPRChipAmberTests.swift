import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #1451: a PR chip, in an Agent Sessions row and in the island's card, wears the "Needs input" badge's amber: its text
/// is the badge's (agentStateColor(.blocked)) and its fill the badge's 0.14 wash of it, read back from an offscreen render
/// (a view in a never-shown host; no window, no event, no file). The badge has no stroke, so the chip has none. Fakes only.
@MainActor
final class AgentPRChipAmberTests: XCTestCase {
    typealias RGBA = (r: CGFloat, g: CGFloat, b: CGFloat)

    func rgb(_ c: Color) -> RGBA {
        let n = NSColor(c).usingColorSpace(.sRGB) ?? NSColor(c)
        return (n.redComponent, n.greenComponent, n.blueComponent)
    }
    func over(_ bg: RGBA, _ c: Color, _ a: CGFloat) -> RGBA {
        let f = rgb(c)
        return (bg.r * (1 - a) + f.r * a, bg.g * (1 - a) + f.g * a, bg.b * (1 - a) + f.b * a)
    }
    func dist(_ a: RGBA, _ b: RGBA) -> CGFloat { abs(a.r - b.r) + abs(a.g - b.g) + abs(a.b - b.b) }

    /// Every pixel of `view` drawn over black in a never-shown host.
    func pixels<V: View>(_ view: V, size: CGSize) throws -> [RGBA] {
        let root = ZStack(alignment: .topLeading) { Color.black; view }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .environment(\.colorScheme, .dark)
        let h = NSHostingView(rootView: root)
        h.frame = CGRect(origin: .zero, size: size)
        h.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        h.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(h.bitmapImageRepForCachingDisplay(in: h.bounds))
        h.cacheDisplay(in: h.bounds, to: rep)
        var out: [RGBA] = []
        for y in 0..<rep.pixelsHigh { for x in 0..<rep.pixelsWide {
            if let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) { out.append((c.redComponent, c.greenComponent, c.blueComponent)) }
        } }
        return out
    }

    /// The most common pixel that is not the black ground: a chip's (or the badge's) fill.
    func fill(_ px: [RGBA]) -> RGBA? {
        var n: [[Int]: Int] = [:]
        for p in px where p.r + p.g + p.b > 0.02 { n[[Int(p.r * 255), Int(p.g * 255), Int(p.b * 255)], default: 0] += 1 }
        return n.max { $0.value < $1.value }.map { (CGFloat($0.key[0]) / 255, CGFloat($0.key[1]) / 255, CGFloat($0.key[2]) / 255) }
    }

    /// The chip is amber like the badge drawn the same way: its fill is the badge's (the old accent wash is far from it) and
    /// the pixel farthest from that fill (the text's stem) is nearer the badge's amber than the accent.
    func check(_ px: [RGBA], _ tag: String) throws {
        let amber = agentStateColor(.blocked)
        let badge = try XCTUnwrap(fill(try pixels(AgentStateChip(state: .blocked), size: CGSize(width: sz(200), height: sz(24)))))
        let mine = try XCTUnwrap(fill(px), "\(tag): no fill")
        XCTAssertLessThan(dist(mine, badge), 0.02, "\(tag): the fill is the Needs input badge's: \(mine) vs \(badge)")
        guard let ink = px.max(by: { dist($0, mine) < dist($1, mine) }) else { return XCTFail("\(tag): no pixels") }
        XCTAssertLessThan(dist(ink, rgb(amber)), dist(ink, rgb(Neon.blue)), "\(tag): the text reads amber: \(ink)")
        XCTAssertGreaterThan(ink.r, 0.6, "\(tag): the text's red is the amber's: \(ink)")
    }

    func testChipTokensAreTheNeedsInputBadgesOwn() {
        XCTAssertTrue(dist(rgb(AgentSidebarRowView.prChipInk(selected: false)), rgb(agentStateColor(.blocked))) < 0.001)
        let fill = NSColor(AgentSidebarRowView.prChipFill).usingColorSpace(.sRGB)
        XCTAssertTrue(dist(rgb(AgentSidebarRowView.prChipFill), rgb(agentStateColor(.blocked))) < 0.001)
        XCTAssertTrue(abs((fill?.alphaComponent ?? 0) - 0.14) < 0.001, "the badge's 0.14 wash")
    }

    func testSidebarRowPRChipIsAmber() throws {
        let row = AgentSidebar.Row(id: .live(AgentSessionKey(dir: "/tmp/dch-test", name: "api")), title: "api", state: .working,
                                   detail: "", age: "", prs: ["api#12"], prCount: 1, agents: 0, merged: 0)
        let v = AgentSidebarRowView(row: row, selected: false).detailLine(row.prs).fixedSize()
        try check(try pixels(v, size: CGSize(width: sz(200), height: sz(24))), "sidebar row chip")
    }

    func testIslandCardPRChipIsAmber() throws {
        let pr = DchSessionMeta.PR(url: "https://github.com/example/api/pull/12", repo: "example/api", num: 12, title: "t")
        var s = AgentSession(key: AgentSessionKey(dir: "/tmp/dch-test", name: "api"), alias: "", activity: 1_800_000_000 - 240,
                             state: .idle, agents: 0)
        s.meta = DchSessionMeta(openPRs: [pr])
        let prs = AgentIsland.prChips(s.meta)
        XCTAssertEqual(prs.chips.count, 1)
        let row = AgentIslandRow(session: s, now: 1_800_000_000, notice: nil, show: .all) {}
        try check(try pixels(row.prLineView(prs, selected: false), size: CGSize(width: sz(200), height: sz(24))), "island chip")
    }
}
