import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #1306 (#1076 phase 2B): Increase Contrast reaches the Agent Island's secondary text and the
/// Agent Sessions chrome edges. Every store injects both accessibility readers and a private
/// center: no row reads the Mac's own setting, and nothing is shown.
@MainActor
final class IncreaseContrastIslandTests: XCTestCase {
    private static var savedPalette = ThemePalette.default
    private static var savedIncreaseContrast = false

    override func setUp() {
        super.setUp()
        MainActor.assumeIsolated {
            IncreaseContrastIslandTests.savedPalette = ThemeRuntime.palette
            IncreaseContrastIslandTests.savedIncreaseContrast = ThemeRuntime.increaseContrast
        }
    }

    override func tearDown() {
        MainActor.assumeIsolated {
            ThemeRuntime.increaseContrast = IncreaseContrastIslandTests.savedIncreaseContrast
            ThemeRuntime.palette = IncreaseContrastIslandTests.savedPalette
        }
        super.tearDown()
    }

    private static func alpha(_ c: Color) -> CGFloat {
        (NSColor(c).usingColorSpace(.sRGB) ?? NSColor(c)).alphaComponent
    }

    private static func source(_ rel: String) throws -> String {
        let app = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: app.appendingPathComponent("Sources/ProsperApp/" + rel), encoding: .utf8)
    }

    private static func count(_ needle: String, in hay: String) -> Int {
        hay.components(separatedBy: needle).count - 1
    }

    private func store(ic: Bool) -> ThemeStore {
        ThemeStore(defaults: scratchDefaults("ic1306"), cacheDir: tempDir("ic1306"),
                   increaseContrastReader: { ic }, reduceTransparencyReader: { false },
                   workspaceCenter: NotificationCenter())
    }

    /// The island's secondary text (white at 0.6 to 0.9) and the sessions chrome edges (accent at
    /// 0.6/0.9, tint at 0.45) keep their alpha off and are opaque on, through the injected reader.
    func testIslandTextAndSessionsEdgesAreOpaqueOnlyUnderIncreaseContrast() {
        let alphas: [Double] = [0.45, 0.6, 0.75, 0.8, 0.9]
        for ic in [false, true] {
            let s = store(ic: ic)
            XCTAssertEqual(s.increaseContrast, ic)
            for a in alphas {
                XCTAssertEqual(Self.alpha(Neon.faded(.white, a)), ic ? 1 : CGFloat(a), accuracy: 0.001, "white \(a) ic \(ic)")
                XCTAssertEqual(Self.alpha(Neon.faded(Neon.blue, a)), ic ? 1 : CGFloat(a), accuracy: 0.001, "blue \(a) ic \(ic)")
                XCTAssertEqual(Self.alpha(Neon.faded(Color.red, a)), ic ? 1 : CGFloat(a), accuracy: 0.001, "tint \(a) ic \(ic)")
            }
        }
    }

    /// The dim sites that stay at their alpha (the "0" of an island with nothing live, the Resume
    /// hint, the idle colour) are told apart from primary text (alpha < 1) yet still clear 3:1 on
    /// the island's black, so they need no Increase Contrast branch.
    func testKeptDimSitesClearThreeToOneOnBlackAndStayBelowPrimary() {
        func lin(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        for a in [0.35, 0.4, 0.45] {
            let ratio = (lin(a) + 0.05) / 0.05 // white over black at alpha a is grey a
            XCTAssertGreaterThanOrEqual(ratio, 3.0, "white \(a) on black")
            XCTAssertLessThan(a, 0.9, "stays told apart from primary")
        }
        XCTAssertEqual(Self.alpha(AgentState.idle.color), 0.4, accuracy: 0.001, "the idle state colour is unchanged")
    }

    /// Source guard: each changed site present once, the dim sites untouched, the island backdrop
    /// still the opaque black notch shape (so its clear panel shows no translucent fill under any
    /// setting), and no per-view system accessibility read in the changed files.
    func testIslandAndSessionsSitesGoThroughTheContrastToken() throws {
        let view = try Self.source("AgentIsland/AgentIslandView.swift")
        let model = try Self.source("AgentIsland/AgentIslandModel.swift")
        let controller = try Self.source("AgentIsland/AgentIslandController.swift")
        let win = try Self.source("AgentWindow/AgentsWindow.swift")

        let islandOnce = [
            "(s.total == 0 ? Color.white.opacity(0.35) : Neon.faded(.white, 0.9))",
            "AgentIsland.killQuestion(s.title)).foregroundStyle(Neon.faded(.white, 0.8))",
            "store.dirStatus).foregroundStyle(Neon.faded(.white, 0.6))",
            "AgentIsland.clearQuestion(n)).foregroundStyle(Neon.faded(.white, 0.8))",
            "Text(verbatim: \"Resume \\(why)\").foregroundStyle(Color.white.opacity(0.45))",
            "NotchShape(top: radii.top, bottom: radii.bottom).fill(Color.black)",
        ]
        for line in islandOnce { XCTAssertEqual(Self.count(line, in: view), 1, line) }
        XCTAssertEqual(Self.count(".foregroundStyle(Neon.faded(.white, 0.75))", in: view), 2, "two 0.75 sites")
        // #1375: the History row's title, the draft field and the prompt card take the theme's card inks (AgentIslandThemeTests).
        XCTAssertEqual(Self.count(".foregroundStyle(Neon.faded(.white, 0.8))", in: view), 5, "three bare + killQuestion + clearQuestion")
        XCTAssertEqual(Self.count(".foregroundStyle(Neon.faded(.white, 0.9))", in: view), 3, "two 0.9 sites + #1316 header")
        // #1371: 25, the session row's notice and PR chip inks are the Agent Sessions row's now (AgentIslandRowStyleTests).
        // #1375: 16, the nine faded-white inks on the History row, the prompt card and the draft field are the theme's.
        XCTAssertEqual(Self.count("Neon.faded(", in: view), 16, "the ear count, the text sites on the black shape and the shown tab's fallback")
        XCTAssertEqual(Self.count("Color.white.opacity(0.75)", in: view), 0)
        XCTAssertEqual(Self.count("case .idle: Color.white.opacity(0.4)", in: model), 1, "idle colour unchanged")
        XCTAssertEqual(Self.count("p.backgroundColor = .clear", in: controller), 1, "the panel stays clear for the notch corners")

        let sessions = [
            "foregroundStyle(Neon.faded(Neon.textSecondary, 0.8))",
            "Neon.faded(Neon.textSecondary, 0.6) : agentStateColor(row.state)",
            ".strokeBorder(Neon.faded(Neon.blue, active ? 0.9 : 0.6), lineWidth: 1))",
            ".overlay(Capsule().stroke(Neon.faded(tint, 0.45), lineWidth: 1))",
        ]
        for line in sessions { XCTAssertEqual(Self.count(line, in: win), 1, line) }
        XCTAssertEqual(Self.count(".opacity(active ? 0.9 : 0.6)", in: win), 0)
        // R1076-n3: the Reduce Transparency skip in AgentWindowChromeTests stays gone.
        let chrome = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("AgentWindowChromeTests.swift"), encoding: .utf8)
        XCTAssertEqual(Self.count("accessibilityDisplayShould", in: chrome), 0, "no Mac flag read in the chrome rows")
        XCTAssertEqual(Self.count("XCTSkip(\"System Settings", in: chrome), 0, "the Reduce Transparency skip is gone")
        for (name, text) in [("view", view), ("model", model), ("controller", controller), ("window", win)] {
            XCTAssertEqual(Self.count("accessibilityDisplayShould", in: text), 0, name)
        }
    }

    /// #1316: no island text site is left as a raw Color.white.opacity except the dim cues kept on
    /// purpose (0.35 to 0.5: told apart from primary text, at least 3:1 on the black shape; the
    /// icon-button glyph alpha is a state cue). Fills (".fill(") are tints, not text.
    func testNoIslandTextSiteIsLeftRawExceptTheKeptDimCues() throws {
        let view = try Self.source("AgentIsland/AgentIslandView.swift")
        let left = Set(view.components(separatedBy: "\n")
            .filter { $0.contains("Color.white.opacity(") && !$0.contains("fill(") }
            .map { $0.trimmingCharacters(in: .whitespaces) })
        // #1371: the session row's age, agents and merged counts and PR chip inks left (the Agent Sessions row's inks now).
        // #1375: only the dim cues drawn straight on the black shape are left; the History row (its glyph, age, end, cwd and
        // icons), the prompt card and its buttons draw the theme's card inks (AgentIslandThemeTests).
        let kept: Set<String> = [
            ".foregroundStyle(ear.state == .blocked ? ear.state.color : (s.total == 0 ? Color.white.opacity(0.35) : Neon.faded(.white, 0.9)))",
            "Text(verbatim: \"Resume \\(why)\").foregroundStyle(Color.white.opacity(0.45))",
            ".foregroundStyle(on ? AgentIslandInk.selectedTab : Color.white.opacity(0.45))",
        ]
        XCTAssertEqual(left, kept)
        XCTAssertEqual(Self.count(".opacity(0.7)", in: view), 0, "no raw 0.7 left")
        XCTAssertEqual(Self.count("text.opacity(", in: view), 0, "the answer buttons fade through the token")
        // #1375: the answer buttons' dim ink is a theme token (AgentPromptCardView.look), no fade of the label ink.
        XCTAssertEqual(Self.count("Neon.faded(text, ", in: view), 0, "digit, hint, detail take the look's dim ink")
        XCTAssertEqual(Self.count("fill(Color.white", in: view), 0, "no white wash on a card, a button or a hint")
        XCTAssertEqual(Self.count("case .plain: (Self.wash, Neon.textPrimary, Neon.textSecondary)", in: view), 1, "plain answer button")
    }
}
