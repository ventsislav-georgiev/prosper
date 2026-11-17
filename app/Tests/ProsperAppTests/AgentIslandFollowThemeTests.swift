import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #1452: Settings > Agent Island > Look > Follow theme, off by default. Off, every ink #1375 themed is the island's own again
/// (TIP before #1375: white on the black notch); on, #1375's theme inks (AgentIslandThemeTests runs with it on). Plus the
/// island's PR chip ink on a light theme (#1451 b). Scratch defaults only (Preferences.defaults is a temp suite under XCTest);
/// views render in never-shown hosts (no window shown, no event, no file). Fakes only.
@MainActor
final class AgentIslandFollowThemeTests: XCTestCase {
    typealias RGBA = (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat)
    static let key = "agentIslandFollowsTheme"
    private static var saved: Any?

    override func setUp() {
        super.setUp()
        MainActor.assumeIsolated {
            Self.saved = Preferences.defaults.object(forKey: Self.key)
            Preferences.defaults.removeObject(forKey: Self.key)
        }
    }

    override func tearDown() {
        MainActor.assumeIsolated {
            if let v = Self.saved { Preferences.defaults.set(v, forKey: Self.key) } else { Preferences.defaults.removeObject(forKey: Self.key) }
        }
        super.tearDown()
    }

    func rgba(_ c: Color) -> RGBA {
        let n = NSColor(c).usingColorSpace(.sRGB) ?? NSColor(c)
        return (n.redComponent, n.greenComponent, n.blueComponent, n.alphaComponent)
    }
    func dist(_ a: RGBA, _ b: RGBA) -> CGFloat { abs(a.r - b.r) + abs(a.g - b.g) + abs(a.b - b.b) + abs(a.a - b.a) }
    func onto(_ b: RGBA, _ c: Color) -> RGBA {
        let f = rgba(c)
        return (b.r * (1 - f.a) + f.r * f.a, b.g * (1 - f.a) + f.g * f.a, b.b * (1 - f.a) + f.b * f.a, 1)
    }
    func ns(_ c: RGBA) -> NSColor { NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1) }

    /// The bundled theme `name` (a folder under Resources/extensions), loaded as AgentIslandThemeTests loads it.
    func palette(_ name: String) throws -> ThemePalette {
        if name == "Default" { return ThemePalette.load(for: .builtIn) }
        let json = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/ProsperApp/Resources/extensions/\(name)/theme.json")
        let spec = try ThemeSpec.decode(Data(contentsOf: json))
        return ThemePalette.load(for: ThemeDescriptor(id: "test.1452.\(name)", title: name, appearance: spec.appearance,
                                                      extensionID: "test.1452", jsonPath: json))
    }

    /// Runs `body` on a dark and a light theme, Increase Contrast off, the palette put back after.
    func onTwoThemes(_ body: (String, ThemePalette) throws -> Void) throws {
        _ = ThemeStore.shared
        let (savedPalette, savedIC) = (ThemeRuntime.palette, ThemeRuntime.increaseContrast)
        defer { ThemeRuntime.palette = savedPalette; ThemeRuntime.increaseContrast = savedIC }
        ThemeRuntime.increaseContrast = false
        for name in ["Default", "theme-daylight"] {
            let p = try palette(name)
            ThemeRuntime.palette = p
            try body(name, p)
        }
    }

    /// Every ink the switch covers, by name: the black shape's, the History row's (plain and hovered), the prompt card's
    /// and the composer's.
    func inks() -> [(String, Color)] {
        var out: [(String, Color)] = [("shown tab", AgentIslandInk.selectedTab), ("blocked on card", AgentIslandInk.blockedOnCard)]
        for s in AgentState.allCases { out.append(("glyph \(s)", AgentIslandInk.glyph(s))) }
        for part in AgentIslandHistoryRow.Part.allCases {
            out.append(("history \(part)", AgentIslandHistoryRow.ink(part, selected: false)))
            out.append(("history hovered \(part)", AgentIslandHistoryRow.ink(part, selected: true)))
        }
        out += [("history card", AgentIslandHistoryRow.ownCardFill(selected: false)),
                ("history hovered card", AgentIslandHistoryRow.ownCardFill(selected: true)),
                ("prompt card", AgentPromptCardView.cardFill), ("question", AgentPromptCardView.questionInk),
                ("context", AgentPromptCardView.contextInk), ("open terminal", AgentPromptCardView.jumpInk),
                ("wash", AgentPromptCardView.wash), ("context fill", AgentPromptCardView.contextFill),
                ("hint fill", AgentPromptCardView.hintFill), ("draft", AgentIslandComposer.draftInk),
                ("field", AgentIslandComposer.fieldFill)]
        for st in [AgentPromptOption.Style.accent, .deny, .plain] {
            let l = AgentPromptCardView.look(st)
            out += [("\(st) fill", l.fill), ("\(st) text", l.text), ("\(st) dim", l.dim),
                    ("\(st) hint", AgentPromptCardView.hintInk(st)), ("\(st) detail", AgentPromptCardView.detailInk(st))]
        }
        return out
    }

    // MARK: The setting

    /// Unset reads off: the island draws its own colours. TIP: no setting, the inks always followed the theme.
    func testFollowThemeIsOffByDefault() {
        XCTAssertTrue(Preferences.defaults.object(forKey: Self.key) == nil, "unset in the scratch suite")
        XCTAssertFalse(Preferences.agentIslandFollowsTheme)
        XCTAssertFalse(AgentIslandInk.follows)
        Preferences.agentIslandFollowsTheme = true
        XCTAssertTrue(AgentIslandInk.follows, "the switch reads the stored Bool")
    }

    /// The Settings row: "Follow theme" with its subtitle, a checkbox that reads off by default, in the Agent Island page's
    /// list of sections. Hosted in a never-shown window, read from its accessibility tree.
    func testTheSettingsRowExistsAndReadsOffByDefault() throws {
        XCTAssertEqual(AgentIslandLookSection.label, "Follow theme")
        XCTAssertEqual(AgentIslandLookSection.subtitle, "Off: the island keeps its own colours.")
        let size = CGSize(width: 520, height: 160)
        let nodes = AXTreeSupport.tree(AgentIslandLookSection().frame(width: size.width).preferredColorScheme(.dark), size) {
            $0.contains { $0.label == AgentIslandLookSection.label && $0.role == "AXCheckBox" }
        }
        let box = nodes.last { $0.label == AgentIslandLookSection.label && $0.role == "AXCheckBox" }
        XCTAssertTrue(box != nil, "a Follow theme checkbox; read \(nodes.map { "\($0.role) \($0.label)" }.prefix(8))")
        // The checkbox seeds from the stored Bool (unset: off); AXTreeSupport reads String values only, so the box's NSNumber
        // value is not read here. Hosting it wrote nothing: the stored setting is still unset.
        XCTAssertTrue(Preferences.defaults.object(forKey: Self.key) == nil, "the section seeds off and stores nothing")
        let src = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/ProsperApp/SettingsWindow.swift"), encoding: .utf8)
        XCTAssertTrue(src.contains("AgentIslandRowDetailsSection(); AgentIslandLookSection(); AgentSessionsSection()"),
                      "the section is on the Agent Island page")
    }

    // MARK: Off

    /// Off, every ink is TIP's before #1375 (the literal values 294fef25 replaced), on a dark and a light theme alike, so a
    /// theme switch changes nothing. TIP: `question` was `Neon.textPrimary`, `history card` the sidebar, and so on.
    func testOffEveryInkIsTheIslandsOwnOnTwoThemes() throws {
        let white = Color.white, deny = Color(red: 0.95, green: 0.4, blue: 0.4)
        let amber = Color(red: 1.0, green: 0.7, blue: 0.0), orange = Color(red: 0.85, green: 0.47, blue: 0.34)
        let own: [String: Color] = [
            "shown tab": white.opacity(0.9), "blocked on card": amber,
            "glyph blocked": amber, "glyph working": orange, "glyph done": Color(red: 0.4, green: 0.75, blue: 0.45),
            "glyph idle": white.opacity(0.4),
            "history card": white.opacity(0.05), "history hovered card": white.opacity(0.10),
            "prompt card": white.opacity(0.05), "question": white, "context": white.opacity(0.6),
            "open terminal": white.opacity(0.7), "wash": white.opacity(0.08), "context fill": white.opacity(0.04),
            "hint fill": white.opacity(0.1), "draft": white.opacity(0.9), "field": .clear,
            "accent fill": orange, "accent text": white, "accent dim": white.opacity(0.7), "accent hint": white.opacity(0.6),
            "accent detail": white.opacity(0.55),
            "deny fill": deny.opacity(0.18), "deny text": deny, "deny dim": deny.opacity(0.7), "deny hint": deny.opacity(0.6),
            "deny detail": deny.opacity(0.55),
            "plain fill": white.opacity(0.08), "plain text": white.opacity(0.9), "plain dim": white.opacity(0.63),
            "plain hint": white.opacity(0.54), "plain detail": white.opacity(0.495),
        ]
        let history: [AgentIslandHistoryRow.Part: Color] = [
            .glyph: white.opacity(0.35), .title: white.opacity(0.8), .age: white.opacity(0.4), .icon: white.opacity(0.35),
            .pinned: white.opacity(0.8), .status: white.opacity(0.7), .end: white.opacity(0.5), .crash: amber, .cwd: white.opacity(0.35),
        ]
        XCTAssertEqual(history.count, AgentIslandHistoryRow.Part.allCases.count, "every part listed")
        var seen: [String: RGBA] = [:]
        try onTwoThemes { name, _ in
            let all = inks()
            XCTAssertEqual(all.count, own.count + 2 * history.count, "every ink checked")
            for (ink, c) in all {
                let part = AgentIslandHistoryRow.Part.allCases.first { ink == "history \($0)" || ink == "history hovered \($0)" }
                guard let want = part.flatMap({ history[$0] }) ?? own[ink] else { XCTFail("\(ink): no literal"); continue }
                XCTAssertLessThan(dist(rgba(c), rgba(want)), 0.003, "\(name): \(ink) is the island's own, read \(rgba(c))")
                if let before = seen[ink] { XCTAssertLessThan(dist(rgba(c), before), 0.001, "\(ink): a theme switch changed it") }
                seen[ink] = rgba(c)
            }
        }
    }

    // MARK: On

    /// On, the inks are #1375's theme inks (the two themes give different ones). TIP of this entry: the same, always.
    func testOnTheInksAreTheThemes() throws {
        Preferences.agentIslandFollowsTheme = true
        var differ = 0
        var first: [String: RGBA] = [:]
        try onTwoThemes { name, p in
            let quiet = AgentSidebarRowView.ink(.quiet, selected: false)
            let pairs: [(String, Color, Color)] = [
                ("question", AgentPromptCardView.questionInk, p.textPrimary),
                ("context", AgentPromptCardView.contextInk, p.textSecondary),
                ("open terminal", AgentPromptCardView.jumpInk, p.textPrimary),
                ("prompt card", AgentPromptCardView.cardFill, p.sidebar),
                ("wash", AgentPromptCardView.wash, p.textPrimary.opacity(0.08)),
                ("plain text", AgentPromptCardView.look(.plain).text, p.textPrimary),
                ("plain hint", AgentPromptCardView.hintInk(.plain), p.textSecondary),
                ("plain detail", AgentPromptCardView.detailInk(.plain), p.textPrimary),
                ("history title", AgentIslandHistoryRow.ink(.title, selected: false), p.textPrimary),
                ("history age", AgentIslandHistoryRow.ink(.age, selected: false), quiet),
                ("history cwd", AgentIslandHistoryRow.ink(.cwd, selected: false), quiet),
                ("draft", AgentIslandComposer.draftInk, p.textPrimary),
                ("field", AgentIslandComposer.fieldFill, p.sidebar),
                ("glyph working", AgentIslandInk.glyph(.working),
                 AgentIslandInk.readable(agentStateColor(.working), on: .black, else: .white, dim: true)),
            ]
            for (ink, c, want) in pairs {
                XCTAssertLessThan(dist(rgba(c), rgba(want)), 0.003, "\(name): \(ink) is the theme's, read \(rgba(c))")
                if let a = first[ink], dist(a, rgba(c)) > 0.05 { differ += 1 }
                first[ink] = rgba(c)
            }
        }
        XCTAssertGreaterThan(differ, 5, "the themes give different inks")
    }

    /// A change redraws the island as a theme switch does (ThemeStore publishes): the same hosted History row, the setting
    /// flipped on a light theme, its card's pixel goes from TIP's near-black wash to the light sidebar. TIP: no setting.
    func testFlippingTheSettingRedrawsTheHostedCard() throws {
        _ = ThemeStore.shared
        let (savedPalette, savedIC) = (ThemeRuntime.palette, ThemeRuntime.increaseContrast)
        defer { ThemeRuntime.palette = savedPalette; ThemeRuntime.increaseContrast = savedIC; ThemeStore.shared.objectWillChange.send() }
        ThemeRuntime.increaseContrast = false
        let light = try palette("theme-daylight")
        ThemeRuntime.palette = light
        ThemeStore.shared.objectWillChange.send()
        let width = AgentIslandGeometry.expandedWidth - 2 * AgentIslandGeometry.listInset
        let size = CGSize(width: width, height: AgentIslandGeometry.rowHeight)
        let rec = DchHistoryRecord(key: AgentSessionKey(dir: "/d", name: "api"), cwd: "/src", updated: 999_940, ended: 999_940, end: "signal 9")
        let root = ZStack(alignment: .topLeading) {
            Color.black
            AgentIslandHistoryRow(record: rec, now: 1_000_000, status: nil, enabled: true, action: {}).frame(width: width)
        }.frame(width: size.width, height: size.height, alignment: .topLeading)
        let (win, h) = AXTreeSupport.hosted(root, size)   // a borderless window that is never shown
        defer { XCTAssertFalse(win.isVisible, "never on screen"); win.contentView = nil; win.close() }
        func px() throws -> RGBA {
            h.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            h.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(h.bitmapImageRepForCachingDisplay(in: h.bounds))
            h.cacheDisplay(in: h.bounds, to: rep)
            let k = CGFloat(rep.pixelsWide) / h.bounds.width
            let c = try XCTUnwrap(rep.colorAt(x: Int(4 * k), y: Int(size.height / 2 * k))?.usingColorSpace(.sRGB))
            return (c.redComponent, c.greenComponent, c.blueComponent, 1)
        }
        let sidebar = rgba(light.sidebar), own = onto((0, 0, 0, 1), AgentIslandHistoryRow.ownCardFill(selected: false))
        let off = try px()
        XCTAssertLessThan(dist(off, own), 0.15, "off: the island's own near-black card, read \(off)")
        Preferences.agentIslandFollowsTheme = true
        ThemeStore.shared.objectWillChange.send()   // what the Settings row's onChange sends
        let on = try px()
        XCTAssertLessThan(dist(on, sidebar), 0.15, "on: the light sidebar card, read \(on)")
        XCTAssertLessThan(dist(on, sidebar), dist(on, own), "nearer the sidebar than the own card, read \(on)")
    }

    // MARK: #1451 b: the island's PR chip

    /// The island's chip is at least 3:1 over its card (drawn over the black notch) under the chip's wash, in both Follow theme
    /// states. On, the card is the theme's sidebar (#1371), so the text is the sidebar's readable amber (#FFB300 on a dark
    /// theme; on a light one the bright amber reads 1.4 to 1.6:1). #1452 b: off, the card is the island's dark own on every
    /// theme, so the text is the bright #FFB300. Parent (ab3250d4): the sidebar's amber and card in both states.
    func testIslandChipInkReadsOnTheCardInBothStates() throws {
        for follows in [false, true] {
            Preferences.agentIslandFollowsTheme = follows
            try onTwoThemes { name, p in
                let ink = AgentIslandRow.chipInk(selected: false), card = AgentIslandRow.card(hover: false)
                let ground = onto(onto((0, 0, 0, 1), card), AgentSidebarRowView.prChipFill)
                let r = ThemeContrastTests.contrast(ns(onto(ground, ink)), on: ns(ground))
                XCTAssertGreaterThanOrEqual(r, 3, "\(name) follows \(follows): the island chip is \(r):1")
                if follows {
                    XCTAssertLessThan(dist(rgba(card), rgba(p.sidebar)), 0.001, "\(name): the card is the sidebar")
                    XCTAssertLessThan(dist(rgba(ink), rgba(AgentSidebarRowView.prChipInk(selected: false))), 0.001,
                                      "\(name): the sidebar chip's ink")
                }
                let want = !follows || name == "Default" ? Color(red: 1.0, green: 0.7, blue: 0.0) : AgentSidebarRowView.darkAmber
                XCTAssertLessThan(dist(rgba(ink), rgba(want)), 0.003, "\(name) follows \(follows): \(rgba(ink))")
            }
        }
    }

    // MARK: #1452 b: the live session rows

    /// The session row's inks and card as `name` gives them, by name (plain and hovered card; the badge palette's tokens).
    func sessionRowInks() -> [String: Color] {
        var out: [String: Color] = ["card": AgentIslandRow.card(hover: false), "hovered card": AgentIslandRow.card(hover: true),
                                    "chip": AgentIslandRow.chipInk(selected: false), "hovered chip": AgentIslandRow.chipInk(selected: true)]
        guard let i = AgentIslandRow.inks else { return out }
        out["primary"] = i.primary; out["quiet"] = i.quiet; out["blue"] = i.blue; out["blocked"] = i.blocked; out["mark"] = i.mark
        out["badge text"] = i.badges.textPrimary; out["badge quiet"] = i.badges.textSecondary; out["badge fill"] = i.badges.blue
        out["badge fill strong"] = i.badges.magenta
        return out
    }

    /// Off, on a dark and a light theme: the session row passes the island's own inks, each its dark literal, the same on both
    /// themes, and the hosted row draws them: its card pixel is the dark own card and its brightest pixel is the white text
    /// (on theme-daylight the theme's text is dark). Parent (ab3250d4): no own inks (the row took the theme's) and the card
    /// was the theme's sidebar, light on theme-daylight.
    func testOffTheSessionRowIsDarkOnTwoThemes() throws {
        let white = Color.white, d = ThemePalette.default
        let want: [String: Color] = [
            "card": white.opacity(0.05), "hovered card": white.opacity(0.10),
            "chip": Color(red: 1.0, green: 0.7, blue: 0.0), "hovered chip": Color(red: 1.0, green: 0.7, blue: 0.0),
            "primary": white.opacity(0.8), "quiet": white.opacity(0.7), "blue": d.blue,
            "blocked": Color(red: 1.0, green: 0.7, blue: 0.0), "mark": white.opacity(0.35),
            "badge text": d.textPrimary, "badge quiet": d.textSecondary, "badge fill": d.blue, "badge fill strong": d.magenta,
        ]
        var seen: [String: RGBA] = [:]
        try onTwoThemes { name, _ in
            let all = sessionRowInks()
            XCTAssertEqual(Set(all.keys), Set(want.keys), "\(name): every ink is the island's own")
            for (ink, c) in all {
                guard let w = want[ink] else { continue }
                XCTAssertLessThan(dist(rgba(c), rgba(w)), 0.003, "\(name): \(ink) is the dark own, read \(rgba(c))")
                if let before = seen[ink] { XCTAssertLessThan(dist(rgba(c), before), 0.001, "\(ink): a theme switch changed it") }
                seen[ink] = rgba(c)
            }
            let px = try rowPixels()
            let card = onto((0, 0, 0, 1), white.opacity(0.05))
            XCTAssertLessThan(dist(px.lead, card), 0.03, "\(name): the drawn card is the dark own, read \(px.lead)")
            XCTAssertGreaterThan(px.brightest, 0.5, "\(name): the row's text is drawn white, brightest \(px.brightest)")
        }
    }

    /// The hosted session row over the black notch (never shown): the pixel in its leading inset and its brightest pixel.
    func rowPixels() throws -> (lead: RGBA, brightest: CGFloat) {
        let width = AgentIslandGeometry.expandedWidth - 2 * AgentIslandGeometry.listInset
        let size = CGSize(width: width, height: AgentIslandGeometry.rowHeight)
        var s = AgentSession(key: AgentSessionKey(dir: "/Users/example/work", name: "api"), alias: "", activity: 1_000_000 - 240,
                             state: .idle, agents: 3)
        s.model = "claude-opus-4-5"
        s.effort = "high"
        let root = ZStack(alignment: .topLeading) {
            Color.black
            AgentIslandRow(session: s, now: 1_000_000, notice: nil, show: .all) {}.frame(width: width)
        }.frame(width: size.width, height: size.height, alignment: .topLeading)
        let h = NSHostingView(rootView: root)
        h.frame = CGRect(origin: .zero, size: size)
        h.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        h.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(h.bitmapImageRepForCachingDisplay(in: h.bounds))
        h.cacheDisplay(in: h.bounds, to: rep)
        let k = CGFloat(rep.pixelsWide) / size.width
        let c = try XCTUnwrap(rep.colorAt(x: Int(3 * k), y: Int(size.height / 2 * k))?.usingColorSpace(.sRGB))
        var top: CGFloat = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let p = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                top = max(top, (p.redComponent + p.greenComponent + p.blueComponent) / 3)
            }
        }
        return ((c.redComponent, c.greenComponent, c.blueComponent, 1), top)
    }

    /// On: the session row takes the theme's inks (no own inks) and the theme's sidebar card, as #1371/#1375 drew it.
    func testOnTheSessionRowKeepsTheThemesInks() throws {
        Preferences.agentIslandFollowsTheme = true
        try onTwoThemes { name, p in
            XCTAssertTrue(AgentIslandRow.inks == nil, "\(name): on, the row's own theme inks")
            XCTAssertLessThan(dist(rgba(AgentIslandRow.card(hover: false)), rgba(p.sidebar)), 0.001, "\(name): the sidebar card")
            XCTAssertLessThan(dist(rgba(AgentIslandRow.card(hover: true)), rgba(p.sidebar)), 0.001, "\(name): hover adds the fill")
        }
    }

    /// The Agent Sessions sidebar rows never change: in both Follow theme states, on both themes, a sidebar row has no own
    /// inks and every ink, plain and selected, is the theme's `ink(_:selected:)`, the same in both states.
    func testTheSidebarRowsAreTheSameInBothStates() throws {
        let row = AgentSidebar.Row(id: .live(AgentSessionKey(dir: "/Users/example/work", name: "api")), title: "api",
                                   state: .working, detail: "Working", age: "4m", prs: ["api#12"], prCount: 1, agents: 2, merged: 0)
        var seen: [String: RGBA] = [:]
        for follows in [false, true] {
            Preferences.agentIslandFollowsTheme = follows
            try onTwoThemes { name, _ in
                for selected in [false, true] {
                    let v = AgentSidebarRowView(row: row, selected: selected)
                    XCTAssertTrue(v.inks == nil, "\(name) follows \(follows): a sidebar row takes no island inks")
                    for k in [AgentSidebarRowView.Ink.quiet, .blue, .blocked] {
                        let c = rgba(v.ink(k)), key = "\(name) \(selected) \(k)"
                        XCTAssertLessThan(dist(c, rgba(AgentSidebarRowView.ink(k, selected: selected))), 0.001, "\(key): the theme's")
                        if let before = seen[key] { XCTAssertLessThan(dist(c, before), 0.001, "\(key): the setting changed it") }
                        seen[key] = c
                    }
                }
            }
        }
        XCTAssertEqual(seen.count, 12)
    }
}
