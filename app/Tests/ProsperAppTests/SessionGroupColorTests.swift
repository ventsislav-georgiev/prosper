import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #2061: a colour per session group: the palette, Automatic's assignment (distinct, stable per id, a pick wins), the
/// stored list's JSON before and after, the auto colours kept in Preferences, the phone's adopt keeping a pick, dch's
/// `group_color` lines, the header's colour and the palette's contrast on every bundled theme's sidebar. Preferences is
/// the in-memory XCTest store; each row puts the keys back. Fakes only.
final class SessionGroupColorTests: XCTestCase {
    private static let keys = ["agentIslandSessionGroups", "agentIslandSidekickPattern", "agentIslandSidekickPatternUpdated",
                               "agentIslandSessionGroupsUpdated", "agentIslandSessionGroupAutoColors"]

    override func setUp() {
        super.setUp()
        let saved = Self.keys.map { Preferences.defaults.object(forKey: $0) }
        addTeardownBlock {
            for (k, v) in zip(Self.keys, saved) {
                if let v { Preferences.defaults.set(v, forKey: k) } else { Preferences.defaults.removeObject(forKey: k) }
            }
        }
        Self.keys.forEach(Preferences.defaults.removeObject(forKey:))
    }

    private static func g(_ id: String, color: String? = nil) -> SessionGroup {
        SessionGroup(id: id, name: id.uppercased(), pattern: "-\(id)$", color: color)
    }
    private static let hex = SessionGroup.palette.map(\.hex)

    // MARK: - Palette and Automatic

    func testPaletteIsEightDistinctValidColours() {
        XCTAssertEqual(SessionGroup.palette.count, SessionGroup.maxCount)
        XCTAssertEqual(Set(Self.hex).count, 8)
        XCTAssertEqual(Set(SessionGroup.palette.map(\.name)).count, 8)
        XCTAssertTrue(Self.hex.allSatisfy { SessionGroup.validColor($0) == $0 })
        XCTAssertEqual(SessionGroup.validColor("#2563eb"), "#2563EB")
        for bad in ["2563EB", "#2563E", "#2563EBA", "#GGGGGG", "#２５６３ＥＢ", ""] {
            XCTAssertTrue(SessionGroup.validColor(bad) == nil, bad)
        }
    }

    func testAutomaticHandsOutThePaletteInListOrderNeverTwice() {
        let list = (1...8).map { Self.g("g\($0)") }
        let c = SessionGroup.colors(list, auto: [:])
        XCTAssertEqual(list.map { c[$0.id] }, Self.hex)
        XCTAssertEqual(Set(c.values).count, 8)
    }

    func testADeleteOrAMoveRepaintsNoOtherGroup() {
        let list = (1...5).map { Self.g("g\($0)") }
        let first = SessionGroup.colors(list, auto: [:])
        let moved = Array(list.dropFirst().reversed())   // g1 deleted, the rest reversed
        let after = SessionGroup.colors(moved, auto: first)
        for g in moved { XCTAssertEqual(after[g.id], first[g.id], g.id) }
        // A group added after the delete takes the freed colour, not one in use.
        let added = SessionGroup.colors(moved + [Self.g("new")], auto: after)
        XCTAssertEqual(added["new"], Self.hex[0])
    }

    func testAPickWinsAndAnAutomaticGroupMovesOffIt() {
        let list = [Self.g("a"), Self.g("b", color: Self.hex[0])]
        let c = SessionGroup.colors(list, auto: ["a": Self.hex[0]])
        XCTAssertEqual(c["b"], Self.hex[0], "the pick")
        XCTAssertEqual(c["a"], Self.hex[1], "a's kept colour is the pick now: the next free one")
        // A picked colour outside the palette is kept as picked.
        XCTAssertEqual(SessionGroup.colors([Self.g("a", color: "#123456")], auto: [:])["a"], "#123456")
    }

    func testAutomaticClearsAPick() {
        let picked = [Self.g("a"), Self.g("b", color: Self.hex[5])]
        let c = SessionGroup.colors(picked, auto: [:])
        var auto = c.filter { $0.key == "a" }   // what Preferences keeps: the Automatic groups' colours only
        XCTAssertEqual(auto, ["a": Self.hex[0]])
        let cleared = SessionGroup.colors([Self.g("a"), Self.g("b")], auto: auto)
        XCTAssertEqual(cleared["b"], Self.hex[1], "Automatic: the first free colour, not the old pick")
        auto = cleared
        XCTAssertEqual(SessionGroup.colors([Self.g("a"), Self.g("b")], auto: auto), cleared, "stable from then on")
    }

    // MARK: - JSON

    func testAListStoredBeforeColoursDecodesAsAutomatic() throws {
        let old = Data(#"[{"id":"a","name":"A","pattern":"-a$"},{"id":"b","name":"B","pattern":""}]"#.utf8)
        let list = try JSONDecoder().decode([SessionGroup].self, from: old)
        XCTAssertEqual(list.map(\.color), [nil, nil])
        Preferences.defaults.set(old, forKey: "agentIslandSessionGroups")
        XCTAssertEqual(Preferences.agentIslandSessionGroups.map(\.id), ["a", "b"], "the old list still reads")
        let plain = String(decoding: try JSONEncoder().encode([SessionGroup(id: "a", name: "A", pattern: "")]), as: UTF8.self)
        XCTAssertFalse(plain.contains("color"), "Automatic writes no key: \(plain)")
    }

    func testAPickRoundTripsAndABadStoredColourReadsAsAutomatic() {
        Preferences.agentIslandSessionGroups = [Self.g("a", color: "#dc2626"), Self.g("b")]
        XCTAssertEqual(Preferences.agentIslandSessionGroups.map(\.color), ["#DC2626", nil])
        Preferences.defaults.set(Data(#"[{"id":"a","name":"A","pattern":"","color":"red"}]"#.utf8), forKey: "agentIslandSessionGroups")
        XCTAssertEqual(Preferences.agentIslandSessionGroups.map(\.color), [nil])
    }

    // MARK: - Preferences

    func testAutoColoursAreStoredOnceAndSurviveADelete() {
        Preferences.agentIslandSessionGroups = [Self.g("a"), Self.g("b"), Self.g("c", color: Self.hex[7])]
        let first = Preferences.sessionGroupColors()
        XCTAssertEqual(first, ["a": Self.hex[0], "b": Self.hex[1], "c": Self.hex[7]])
        XCTAssertEqual(Preferences.defaults.dictionary(forKey: "agentIslandSessionGroupAutoColors") as? [String: String],
                       ["a": Self.hex[0], "b": Self.hex[1]], "the Automatic ones only")
        Preferences.agentIslandSessionGroups = [Self.g("b"), Self.g("c", color: Self.hex[7])]   // a deleted
        XCTAssertEqual(Preferences.sessionGroupColors(), ["b": Self.hex[1], "c": Self.hex[7]], "b keeps its colour")
        XCTAssertEqual(Preferences.defaults.dictionary(forKey: "agentIslandSessionGroupAutoColors") as? [String: String],
                       ["b": Self.hex[1]], "a's entry goes")
    }

    func testThePhonesAdoptKeepsAPickOnAGroupItKeeps() {
        Preferences.agentIslandSessionGroups = [Self.g("a", color: Self.hex[4]), Self.g("b", color: Self.hex[5])]
        Preferences.adoptSessionGroups([Self.g("a"), Self.g("c")], updated: 7)
        XCTAssertEqual(Preferences.agentIslandSessionGroups.map(\.color), [Self.hex[4], nil])
    }

    // MARK: - dch's lines

    func testColourLinesFollowTheGroupLinesForEveryWrittenGroup() {
        let groups = [Self.g("a"), SessionGroup(id: "m", name: "Manual", pattern: ""),
                      SessionGroup(id: "x", name: "Bad", pattern: "a.b")]   // "." is not portable: no group line, no colour
        let colors = SessionGroup.colors(groups, auto: [:])
        XCTAssertEqual(DchConfigWriter.colorValues(groups, colors: colors), ["A = \(Self.hex[0])", "Manual = \(Self.hex[1])"])
        let old = Data("# mine\ngroup = Old = -o$\ngroup_color = Old = #000000\nkeep = 1\n".utf8)
        let out = DchConfigWriter.render(old, autoAllow: false, pattern: "-a$", groups: DchConfigWriter.groupValues(groups),
                                         colors: DchConfigWriter.colorValues(groups, colors: colors))
        XCTAssertEqual(String(decoding: out, as: UTF8.self),
                       "# mine\ngroup = A = -a$\ngroup = Manual =\ngroup_color = A = #2563EB\ngroup_color = Manual = #15803D\n"
                       + "keep = 1\nauto_allow = false\nsidekick_pattern = -a$\n")
    }

    func testWithoutOwnedGroupLinesTheFilesColourLinesStay() {
        let old = Data("group = Old = -o$\ngroup_color = Old = #000000\n".utf8)
        let out = DchConfigWriter.render(old, autoAllow: false, pattern: "", groups: nil, colors: ["A = #2563EB"])
        XCTAssertEqual(String(decoding: out, as: UTF8.self),
                       "group = Old = -o$\ngroup_color = Old = #000000\nauto_allow = false\nsidekick_pattern = \n")
        XCTAssertEqual(DchConfigWriter.adoptable(["Old = -o$"]).map(\.color), [nil], "an adopted group is Automatic")
    }

    // MARK: - The header

    func testAGroupSectionGetsItsColourAndNoOtherSectionDoes() {
        let colors = ["qa": "#2563EB"]
        let group = AgentSidebar.Section(title: "QA", rows: [], id: AgentSidebar.groupFold("qa"))
        XCTAssertNotNil(AgentSidebar.groupColor(group, colors))
        XCTAssertNil(AgentSidebar.groupColor(AgentSidebar.Section(title: "Sessions", rows: []), colors))
        XCTAssertNil(AgentSidebar.groupColor(AgentSidebar.Section(title: "QB", rows: [], id: AgentSidebar.groupFold("qb")), colors))
    }

    // MARK: - Contrast

    /// Every palette colour clears 3:1 (WCAG 1.4.11: the tick is a graphic, not text) over every bundled theme's sidebar
    /// as drawn (NeonSidebarSurface: the sidebar colour, its top under the accent wash), light and dark alike.
    @MainActor
    func testEveryPaletteColourClearsThreeToOneOnEveryThemesSidebar() throws {
        // The registry as AgentGlyphContrastTests reads it: the built-in plus every bundled theme-* directory.
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/ProsperApp/Resources/extensions", isDirectory: true)
        let themes = try [ThemeDescriptor.builtIn] + FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("theme-") }
            .map { d -> ThemeDescriptor in
                let json = d.appendingPathComponent("theme.json")
                let spec = try ThemeSpec.decode(Data(contentsOf: json))
                return ThemeDescriptor(id: "test.2061.\(d.lastPathComponent)", title: d.lastPathComponent,
                                       appearance: spec.appearance, extensionID: "test.2061", jsonPath: json)
            }
        XCTAssertEqual(themes.count, AgentGlyphContrastTests.expected.count)
        func rgb(_ c: Color) -> [CGFloat] {
            let n = NSColor(c).usingColorSpace(.sRGB) ?? NSColor(c)
            return [n.redComponent, n.greenComponent, n.blueComponent]
        }
        var pairs = 0
        for d in themes {
            let p = ThemePalette.load(for: d), side = rgb(p.sidebar), tint = rgb(p.blue), w = NeonSidebarSurface.washOpacity
            let washed: [CGFloat] = zip(side, tint).map { $0 * (1 - CGFloat(w)) + $1 * CGFloat(w) }
            for bg: [CGFloat] in [side, washed] {
                let bgc = NSColor(srgbRed: bg[0], green: bg[1], blue: bg[2], alpha: 1)
                for (name, h) in SessionGroup.palette {
                    let c = try XCTUnwrap(Color(hex: h))
                    let r = ThemeContrastTests.contrast(NSColor(c), on: bgc)
                    XCTAssertGreaterThanOrEqual(r, 3.0, "\(d.title) (\(d.appearance)): \(name) is \(r):1")
                    pairs += 1
                }
            }
        }
        XCTAssertEqual(pairs, AgentGlyphContrastTests.expected.count * 2 * 8)
    }
}
