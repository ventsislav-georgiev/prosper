import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #1371: Agent Island's session row is drawn from the Agent Sessions sidebar row's pieces (line 1: state mark, title,
/// model and effort badges; line 2: the state word, the counts, the age at the end), keeps its own PR chips and their
/// links below, has one even gap between rows, and its card follows the selected theme. Every view is hosted in a
/// never-shown host (no event, no window ordered in, no URL opened: the opener is a fake). Fakes only.
@MainActor
final class AgentIslandRowStyleTests: XCTestCase {
    static let now: TimeInterval = 1_000_000
    static let scales: [CGFloat] = [0.7, 0.85, 1.0]
    final class Box { var seen: [String: CGRect] = [:] }

    func session(meta: DchSessionMeta? = nil) -> AgentSession {
        var s = AgentSession(key: AgentSessionKey(dir: "/Users/example/work", name: "api"), alias: "",
                             activity: Self.now - 240, state: .idle, agents: 3)
        s.transcriptPath = "/Users/example/t.jsonl"
        s.model = "claude-opus-4-5"
        s.effort = "high"
        s.meta = meta
        return s
    }

    func pr(_ repo: String, _ num: Int) -> DchSessionMeta.PR {
        .init(url: "https://github.com/\(repo)/pull/\(num)", repo: repo, num: num, title: "")
    }

    var width: CGFloat { AgentIslandGeometry.expandedWidth - 2 * AgentIslandGeometry.listInset }

    func row(_ s: AgentSession) -> some View {
        AgentIslandRow(session: s, now: Self.now, notice: nil, show: .all) {}.frame(width: width)
    }

    /// The row's part frames by probe kind, hosted in a borderless window that is never shown.
    func frames(_ s: AgentSession) -> [String: CGRect] {
        let box = Box()
        AgentSidebarRowView.probe = { kind, _, r in box.seen[kind] = r }
        defer { AgentSidebarRowView.probe = nil }
        let (win, host) = AXTreeSupport.hosted(row(s), CGSize(width: width, height: 120))
        let end = Date().addingTimeInterval(2)
        while ["mark", "title", "badges", "age", "card"].contains(where: { box.seen[$0] == nil }) && Date() < end {
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertFalse(win.isVisible, "never on screen")
        win.contentView = nil
        win.close()
        return box.seen
    }

    func onScales(_ body: (CGFloat) throws -> Void) rethrows {
        let saved = ThemeRuntime.scale
        defer { ThemeRuntime.scale = saved }
        for scale in Self.scales {
            ThemeRuntime.scale = scale
            try body(scale)
        }
    }

    // MARK: Positions

    /// Line 1 is the mark, the title, then the badges (the model's then the effort's, the sidebar's own order); the age
    /// ends at the row's trailing inset; line 2 is below line 1. TIP: no badges at all (no "badges" probe), the age on
    /// line 1, and no mark probe.
    func testLineOneOrderAndTheAgeAtTheTrailingInsetAtEveryScale() throws {
        let pixel = AXTreeSupport.devicePixel   // CI backs at 1x (a pixel is 1 pt there, 0.5 pt at 2x): never a literal 0.5
        XCTAssertEqual(AgentSidebarRowView.badges(model: "Opus 4.5", effort: "high").map(\.text), ["Opus 4.5", "high"],
                       "the model's badge, then the effort's")
        try onScales { scale in
            let f = frames(session())
            let mark = try XCTUnwrap(f["mark"], "mark at \(scale)"), title = try XCTUnwrap(f["title"], "title at \(scale)")
            let badges = try XCTUnwrap(f["badges"], "badges at \(scale)"), age = try XCTUnwrap(f["age"], "age at \(scale)")
            XCTAssertLessThanOrEqual(mark.maxX, title.minX + pixel, "mark before the title at \(scale)")
            XCTAssertLessThanOrEqual(title.maxX, badges.minX + pixel, "title before the badges at \(scale)")
            XCTAssertGreaterThan(badges.width, sz(20), "both badges' slot drawn at \(scale)")
            XCTAssertEqual(age.maxX, width - AgentIslandGeometry.rowTrail, accuracy: pixel, "age at the trailing inset at \(scale)")
            XCTAssertGreaterThanOrEqual(age.minY, title.maxY - pixel, "the age is on line two at \(scale)")
            XCTAssertNotNil(f["count.agents"], "the outlined agents count is drawn at \(scale)")
            XCTAssertTrue(f["capsule.agents"] != nil, "with its outline at \(scale)")
        }
    }

    /// The PR chips are the third line, below line two (where the merged count now is), and their links still fire through
    /// the row's accessibility actions on the fake opener. TIP: no "chips" probe (the chips had none).
    func testPRChipsStayBelowLineTwoAndTheirLinksFire() throws {
        let pixel = AXTreeSupport.devicePixel   // CI backs at 1x (a pixel is 1 pt there, 0.5 pt at 2x): never a literal 0.5
        let meta = DchSessionMeta(openPRs: [pr("acme/api", 12), pr("acme/web", 7)], merged: 3)
        try onScales { scale in
            let f = frames(session(meta: meta))
            let chips = try XCTUnwrap(f["chips"], "the chips are drawn at \(scale)")
            let age = try XCTUnwrap(f["age"]), merged = try XCTUnwrap(f["count.merged"], "merged on line two at \(scale)")
            XCTAssertGreaterThanOrEqual(chips.minY, age.maxY - pixel, "chips below line two at \(scale)")
            XCTAssertLessThan(merged.maxY, chips.minY + pixel, "the merged count is above the chips at \(scale)")
        }
        var opened: [URL] = []
        let saved = AgentIsland.openURL
        AgentIsland.openURL = { opened.append($0) }
        defer { AgentIsland.openURL = saved }
        let restore = AXTreeSupport.axOn()
        defer { restore() }
        let (win, host) = AXTreeSupport.hosted(row(session(meta: meta)), CGSize(width: width, height: 120))
        defer { win.contentView = nil; win.close() }
        var actions: [NSAccessibilityCustomAction] = []
        let end = Date().addingTimeInterval(5)
        while actions.count < 2 && Date() < end {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            actions = customActions(host).filter { $0.name.hasPrefix("Open ") }
        }
        // AppKit lists SwiftUI's custom actions in its own order (reversed here); the row pins the set, not the order.
        XCTAssertEqual(actions.map(\.name).sorted(), ["Open api#12", "Open web#7"])
        for a in actions { XCTAssertTrue(a.handler?() ?? false, a.name) }
        XCTAssertEqual(opened.map(\.absoluteString).sorted(),
                       ["https://github.com/acme/api/pull/12", "https://github.com/acme/web/pull/7"])
        XCTAssertFalse(win.isVisible, "never shown")
    }

    func customActions(_ host: NSView) -> [NSAccessibilityCustomAction] {
        var out: [NSAccessibilityCustomAction] = []
        func walk(_ e: Any, depth: Int) {
            guard depth < 60, let o = e as? NSObject else { return }
            if o.responds(to: Selector(("accessibilityCustomActions"))) {
                out += o.value(forKey: "accessibilityCustomActions") as? [NSAccessibilityCustomAction] ?? []
            }
            for k in o.value(forKey: "accessibilityChildren") as? [Any] ?? [] { walk(k, depth: depth + 1) }
        }
        walk(host, depth: 0)
        // A wrapper can repeat its button's actions: each name once, in order.
        return out.reduce(into: []) { acc, a in if !acc.contains(where: { $0.name == a.name }) { acc.append(a) } }
    }

    // MARK: Spacing

    /// One row is its card plus the gap (2 pt, a literal: TIP 4); two rows stacked are twice one, so the gap between two
    /// cards is the same 2 pt. The card holds both lines (or three with chips) at every scale.
    func testTheGapBetweenTwoRowsIsTwoPointsAtEveryScale() throws {
        XCTAssertEqual(AgentIslandGeometry.rowGap, 2)
        try onScales { scale in
            for meta in [nil, DchSessionMeta(openPRs: [pr("acme/api", 12)], merged: 3)] {
                let s = session(meta: meta)
                let card = try XCTUnwrap(frames(s)["card"], "card at \(scale)")
                let one = NSHostingView(rootView: row(s)).fittingSize.height
                let two = NSHostingView(rootView: VStack(spacing: 0) { row(s); row(s) }.frame(width: width)).fittingSize.height
                XCTAssertEqual(one - card.height, 2, accuracy: 0.01, "the gap at \(scale), chips \(meta != nil)")
                XCTAssertEqual(two, 2 * one, accuracy: 0.01, "two rows at \(scale)")
                XCTAssertEqual(one, AgentIslandGeometry.height(of: s, show: .all), accuracy: 0.01, "the panel's height at \(scale)")
            }
        }
    }

    // MARK: Theme

    static let expected = ["Default", "theme-amber", "theme-blossom", "theme-contrast-dark", "theme-contrast-light",
                           "theme-crimson", "theme-daylight", "theme-default", "theme-ember", "theme-emerald",
                           "theme-fern", "theme-gold", "theme-graphite", "theme-indigo", "theme-lavender",
                           "theme-lime", "theme-mint", "theme-rose", "theme-silver", "theme-solar",
                           "theme-teal", "theme-violet"]
    typealias RGBA = (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat)

    /// The 22 themes as ThemeContrastTests loads them; the literal list above must be all of them.
    func themes() throws -> [ThemeDescriptor] {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/ProsperApp/Resources/extensions", isDirectory: true)
        let bundled = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("theme-") }
            .map { d -> ThemeDescriptor in
                let json = d.appendingPathComponent("theme.json")
                let spec = try ThemeSpec.decode(Data(contentsOf: json))
                return ThemeDescriptor(id: "test.1371.\(d.lastPathComponent)", title: d.lastPathComponent,
                                       appearance: spec.appearance, extensionID: "test.1371", jsonPath: json)
            }
        let all = [ThemeDescriptor.builtIn] + bundled
        XCTAssertEqual(Set(all.map(\.title)), Set(Self.expected), "the literal list is every bundled theme")
        XCTAssertEqual(all.count, 22)
        return all
    }

    func rgba(_ c: Color) -> RGBA {
        let n = NSColor(c).usingColorSpace(.sRGB) ?? NSColor(c)
        return (n.redComponent, n.greenComponent, n.blueComponent, n.alphaComponent)
    }
    func dist(_ a: RGBA, _ b: RGBA) -> CGFloat { abs(a.r - b.r) + abs(a.g - b.g) + abs(a.b - b.b) }

    /// On every theme: the card is the theme's sidebar surface (the token, and the drawn pixel over the island's black
    /// beside the age), the title is drawn in textPrimary (its farthest pixel from the card), and textPrimary on the card
    /// clears 4.5:1, the bound of the sidebar's contrast rows (AgentRowSelectedTextTests). TIP: white at 0.05 over black.
    func testTheCardAndItsTextFollowEveryTheme() throws {
        _ = ThemeStore.shared
        let (savedPalette, savedIC, savedScale) = (ThemeRuntime.palette, ThemeRuntime.increaseContrast, ThemeRuntime.scale)
        defer { ThemeRuntime.palette = savedPalette; ThemeRuntime.increaseContrast = savedIC; ThemeRuntime.scale = savedScale }
        ThemeRuntime.increaseContrast = false
        ThemeRuntime.scale = 1.0
        var reads = 0
        for d in try themes() {
            let p = ThemePalette.load(for: d)
            ThemeRuntime.palette = p
            let card = rgba(p.sidebar)
            XCTAssertLessThan(dist(rgba(AgentIslandRow.cardFill), card), 0.001, "\(d.title): the card token")
            let r = ThemeContrastTests.contrast(NSColor(p.textPrimary),
                                                on: NSColor(srgbRed: card.r, green: card.g, blue: card.b, alpha: 1))
            XCTAssertGreaterThanOrEqual(r, 4.5, "\(d.title): primary text on the card is \(r):1")
            let f = frames(session())
            let title = try XCTUnwrap(f["title"], d.title), age = try XCTUnwrap(f["age"], d.title)
            let size = CGSize(width: width, height: AgentIslandGeometry.rowHeight)
            let root = ZStack(alignment: .topLeading) { Color.black; row(session()) }
                .frame(width: size.width, height: size.height, alignment: .topLeading)
            let h = NSHostingView(rootView: root)
            h.frame = CGRect(origin: .zero, size: size)
            h.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            h.layoutSubtreeIfNeeded()
            guard let rep = h.bitmapImageRepForCachingDisplay(in: h.bounds) else { return XCTFail("no bitmap") }
            h.cacheDisplay(in: h.bounds, to: rep)
            let k = CGFloat(rep.pixelsWide) / size.width
            // Beside the age, inside the card's straight edge: the card's own colour (the row's top padding is rowGap / 2).
            let y = AgentIslandGeometry.rowGap / 2 + age.midY
            let px = try XCTUnwrap(rep.colorAt(x: Int((width - 6) * k), y: Int(y * k))?.usingColorSpace(.sRGB))
            XCTAssertLessThan(dist((px.redComponent, px.greenComponent, px.blueComponent, 1), card), 0.03,
                              "\(d.title): the card is drawn in the sidebar colour, read \(px)")
            // The title's farthest pixel from the card: textPrimary where a stem is fully covered.
            var best: RGBA = card, far: CGFloat = 0
            let band = title.offsetBy(dx: 0, dy: AgentIslandGeometry.rowGap / 2)
            for yy in Int(band.minY * k)..<min(rep.pixelsHigh, Int(band.maxY * k)) {
                for xx in Int(band.minX * k)..<min(rep.pixelsWide, Int(band.maxX * k)) {
                    guard let c = rep.colorAt(x: xx, y: yy)?.usingColorSpace(.sRGB) else { continue }
                    let v: RGBA = (c.redComponent, c.greenComponent, c.blueComponent, 1)
                    if dist(v, card) > far { far = dist(v, card); best = v }
                }
            }
            XCTAssertLessThan(dist(best, rgba(p.textPrimary)), dist(best, card) + 0.001, "\(d.title): title ink \(best)")
            XCTAssertLessThan(dist(best, rgba(p.textPrimary)), 0.25, "\(d.title): the title is drawn in textPrimary, read \(best)")
            reads += 1
        }
        XCTAssertEqual(reads, 22)
    }
}
