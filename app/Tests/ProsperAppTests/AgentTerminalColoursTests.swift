import AppKit
import GhosttyTerminal
import XCTest
@testable import ProsperApp

/// #1456 (OQ-153): "Terminal colours: Prosper / My Ghostty theme". Every Ghostty config here is a fixture under the
/// row's tempDir, found through the home-parameterised locator; no row reads the real home or runs anything it reads.
final class AgentTerminalColoursTests: XCTestCase {

    /// A fake Ghostty config at `<home>/<relative>`.
    private func fixture(_ home: URL, _ relative: String, _ text: String) throws -> URL {
        let url = home.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func pairs(_ kept: [(key: String, value: String)]) -> [String] { kept.map { "\($0.key)=\($0.value)" } }

    func testKeepsOnlyTheColourKeysOfTheUsersConfig() throws {
        let home = tempDir()
        _ = try fixture(home, ".config/ghostty/config", """
            # a comment = ignored
            theme = Example Dark
            palette = 0=#1d1f21
            background = #101010
            keybind = super+k=text:hello
            clipboard-read = allow
            command = /bin/example
            config-file = /Users/example/other
            shell-integration = none
            not-a-ghostty-key = #ffffff
            cursor-color = "#a0b0c0"
            """)
        _ = try fixture(home, "Library/Application Support/com.mitchellh.ghostty/config", "foreground = #eeeeee\nworking-directory = /tmp\n")
        let kept = GhosttyUserColours.read(GhosttyUserColours.files(home: home, xdgConfigHome: nil))
        XCTAssertEqual(pairs(kept), ["palette=0=#1d1f21", "background=#101010", "cursor-color=#a0b0c0",
                                     "foreground=#eeeeee"], "colours only, in Ghostty's load order (Application Support last); "
                       + "no theme pair, and no themes dir given so the theme adds nothing")
    }

    func testTheLocatorFollowsXDGConfigHomeAndBothFileNames() {
        let home = URL(fileURLWithPath: "/Users/example")
        XCTAssertEqual(GhosttyUserColours.files(home: home, xdgConfigHome: "/Users/example/xdg").map(\.path), [
            "/Users/example/xdg/ghostty/config", "/Users/example/xdg/ghostty/config.ghostty",
            "/Users/example/Library/Application Support/com.mitchellh.ghostty/config",
            "/Users/example/Library/Application Support/com.mitchellh.ghostty/config.ghostty",
        ])
        XCTAssertEqual(GhosttyUserColours.files(home: home, xdgConfigHome: nil).first?.path, "/Users/example/.config/ghostty/config")
        XCTAssertEqual(GhosttyUserColours.files(home: home, xdgConfigHome: "relative").first?.path, "/Users/example/.config/ghostty/config",
                       "a relative XDG_CONFIG_HOME is ignored, as the spec says")
    }

    func testRefusesPathThemesAndBadColourValues() {
        let refused = """
            theme = ../x
            theme = /Users/example/themes/x
            theme = ..
            theme = light:../x,dark:Example
            theme = light:Example,dark:/Users/example/x
            palette = 300=#ffffff
            palette = -1=#ffffff
            palette = 1=#fff
            background = red;rm
            foreground = #12345g
            selection-background = $(example)
            """
        XCTAssertEqual(pairs(GhosttyUserColours.lines(refused)), [], "every one refused")
        let ok = "theme = light:Example Light,dark:Example Dark\npalette = 255=#00ff00\nbold-color = dark slate gray\n"
        XCTAssertEqual(pairs(GhosttyUserColours.lines(ok)),
                       ["theme=light:Example Light,dark:Example Dark", "palette=255=#00ff00", "bold-color=dark slate gray"])
    }

    /// #1752: Ghostty's `window-colorspace` decides how every colour value is drawn, so "My Ghostty theme" keeps it;
    /// only its two values pass. Red on the parent: the key was not in the allowlist ([]).
    func testKeepsWindowColorspaceWithItsTwoValuesOnly() {
        XCTAssertEqual(pairs(GhosttyUserColours.lines("window-colorspace = display-p3\nwindow-colorspace = \"srgb\"\n")),
                       ["window-colorspace=display-p3", "window-colorspace=srgb"])
        XCTAssertEqual(pairs(GhosttyUserColours.lines("window-colorspace = rec2020\nwindow-colorspace = display-p3;x\n"
                                                      + "window-colorspace = red\n")), [], "anything else is refused")
    }

    @MainActor
    func testAMissingFileGivesTheProsperLook() {
        let home = tempDir()
        let kept = AgentTerminalLook.userColours(choice: "ghostty", files: GhosttyUserColours.files(home: home, xdgConfigHome: nil),
                                                 themeDirs: [], appearance: .dark)
        XCTAssertTrue(kept.isEmpty)
        XCTAssertEqual(AgentTerminalLook.theme(colours: kept), AgentTerminalLook.theme(), "Prosper's background and text")
        XCTAssertEqual(AgentTerminalLook.configuration(colours: kept), AgentTerminalLook.configuration)
    }

    @MainActor
    func testTheProsperChoiceIgnoresAFixtureConfig() throws {
        let file = try fixture(tempDir(), "ghostty/config", "background = #101010\n")
        XCTAssertTrue(AgentTerminalLook.userColours(choice: "prosper", files: [file], themeDirs: [], appearance: .dark).isEmpty)
        XCTAssertEqual(pairs(AgentTerminalLook.userColours(choice: "ghostty", files: [file], themeDirs: [], appearance: .dark)),
                       ["background=#101010"], "the same file is read when chosen")
    }

    /// The kept lines go first; every Prosper line comes after them, unchanged, and libghostty takes the result with the
    /// user's background showing (no Prosper theme over it).
    @MainActor
    func testUserColoursComeBeforeProsperLinesWhichAreUnchanged() throws {
        let file = try fixture(tempDir(), "ghostty/config", "palette = 1=#c0ffee\nbackground = #101010\nkeybind = clear\n")
        let kept = GhosttyUserColours.read([file])
        XCTAssertEqual(pairs(kept), ["palette=1=#c0ffee", "background=#101010"])
        let rendered = AgentTerminalLook.configuration(colours: kept).rendered
        let palette = try XCTUnwrap(rendered.range(of: "palette = 1=#c0ffee"))
        let deny = try XCTUnwrap(rendered.range(of: "clipboard-read = deny"))
        let clear = try XCTUnwrap(rendered.range(of: "keybind = clear"))
        XCTAssertTrue(palette.upperBound <= deny.lowerBound && palette.upperBound <= clear.lowerBound, "user lines first")
        let prosperOnly = rendered.components(separatedBy: "\n")
            .filter { $0 != "palette = 1=#c0ffee" && $0 != "background = #101010" }.joined(separator: "\n")
        XCTAssertEqual(prosperOnly, AgentTerminalLook.configuration.rendered, "Prosper's lines unchanged")

        let c = AgentTerminalLook.make(colours: kept)
        XCTAssertTrue(c.lastConfigurationIssue == nil, "libghostty accepted the overlay")
        let live = c.renderedConfig
        let userBackground = try XCTUnwrap(live.range(of: "background = #101010"))
        let lastDeny = try XCTUnwrap(live.range(of: "clipboard-read = deny", options: .backwards))
        XCTAssertTrue(userBackground.upperBound <= lastDeny.lowerBound, "Prosper's clipboard rule is the last word")
        XCTAssertEqual(live.components(separatedBy: "\n").last { $0.hasPrefix("background = ") }, "background = #101010",
                       "no Prosper background after the user's")
        // Back to Prosper: the overlay goes and Prosper's colours return.
        AgentTerminalLook.refresh(c, colours: [])
        XCTAssertFalse(c.renderedConfig.contains("#101010"))
        XCTAssertTrue(c.renderedConfig.contains("background = \(AgentTerminalLook.vivid(ThemeStore.shared.appearance).background)"))
    }

    /// A value the allowlist passes but libghostty refuses rolls the overlay back: Prosper's config and colours stay.
    @MainActor
    func testARefusedColourKeepsTheProsperLook() {
        let c = AgentTerminalLook.make(colours: [("background", "notacolourname")])
        XCTAssertFalse(c.renderedConfig.contains("notacolourname"))
        XCTAssertTrue(c.renderedConfig.contains("clipboard-read = deny"))
        XCTAssertTrue(c.renderedConfig.contains("background = \(AgentTerminalLook.vivid(ThemeStore.shared.appearance).background)"))
    }

    /// #1754 (operator: "Make the Prosper look vivid"): under "Prosper" the cells are a pure pair (black and white in a
    /// dark theme, white and black in a light one) and a saturated palette whose colours 1-15 are each at least 4.5:1 on
    /// that background, drawn as Display P3; "My Ghostty theme" gets none of it. Red on the parent: no vivid(), and the
    /// theme was hex(Neon.bgBottom) / hex(Neon.textPrimary) with no palette or window-colorspace line.
    @MainActor
    func testTheProsperLookIsVividInBothAppearances() {
        func srgb(_ hex: String) -> NSColor {
            let v = AgentTerminalTests.rgb(hex).map { CGFloat($0) / 255 }
            return NSColor(srgbRed: v[0], green: v[1], blue: v[2], alpha: 1)
        }
        let c = AgentTerminalLook.make(colours: [])
        for (appearance, bg, fg) in [(ThemeAppearance.dark, "#000000", "#ffffff"), (.light, "#ffffff", "#000000")] {
            let look = AgentTerminalLook.vivid(appearance)
            XCTAssertEqual([look.background, look.foreground], [bg, fg], "\(appearance)")
            XCTAssertEqual(look.palette.count, 16, "\(appearance): all 16 ANSI colours")
            for (i, colour) in look.palette.enumerated() where i > 0 {
                XCTAssertGreaterThanOrEqual(ThemeContrastTests.contrast(srgb(colour), on: srgb(bg)), 4.5,
                                            "\(appearance) palette \(i) \(colour) on \(bg)")
            }
            c.setTheme(AgentTerminalLook.theme(appearance: appearance))
            XCTAssertTrue(c.lastConfigurationIssue == nil, "libghostty accepted the \(appearance) look")
            let live = c.renderedConfig.components(separatedBy: "\n")
            XCTAssertTrue(live.contains("background = \(bg)") && live.contains("foreground = \(fg)"), "\(appearance)")
            XCTAssertTrue(live.contains("window-colorspace = display-p3"), "\(appearance): Display P3")
            for (i, colour) in look.palette.enumerated() {
                XCTAssertTrue(live.contains("palette = \(i)=\(colour)"), "\(appearance) palette \(i)")
            }
        }
        XCTAssertEqual(AgentTerminalLook.theme(colours: [("background", "#101010")]), TerminalTheme(),
                       "My Ghostty theme: no Prosper colours and no display-p3 over the user's lines")
    }

    /// QA r1418 m1: a theme file is a whole Ghostty config: only its colour lines are kept, its own `theme` is not
    /// followed, and no `theme` line ever reaches libghostty.
    @MainActor
    func testAThemeIsResolvedByProsperToItsColourLinesOnly() throws {
        let home = tempDir()
        let config = try fixture(home, ".config/ghostty/config", "theme = Example\n")
        _ = try fixture(home, ".config/ghostty/themes/Example", """
            background = #202020
            shell-integration = none
            keybind = super+k=text:x
            clipboard-write = allow
            theme = Other
            """)
        _ = try fixture(home, ".config/ghostty/themes/Other", "foreground = #303030\n")
        let dirs = GhosttyUserColours.themeDirs(home: home, xdgConfigHome: nil, bundled: home.appendingPathComponent("bundled"))
        let kept = AgentTerminalLook.userColours(choice: "ghostty", files: [config], themeDirs: dirs, appearance: .dark)
        XCTAssertEqual(pairs(kept), ["background=#202020"], "colours only, the theme file's own theme not followed")
        let rendered = AgentTerminalLook.configuration(colours: kept).rendered.components(separatedBy: "\n")
        XCTAssertFalse(rendered.contains { $0.hasPrefix("theme") }, "no theme line for libghostty")
        try "theme = Missing\n".write(to: config, atomically: true, encoding: .utf8)
        XCTAssertEqual(pairs(GhosttyUserColours.read([config], themeDirs: dirs, appearance: .dark)), [], "a missing theme file adds nothing")
    }

    func testThemeLinesComeBeforeTheConfigsOwnColours() throws {
        let home = tempDir()
        let config = try fixture(home, "ghostty/config", "background = #101010\ntheme = Example\n")
        let themes = home.appendingPathComponent("themes")
        _ = try fixture(home, "themes/Example", "background = #202020\n")
        XCTAssertEqual(pairs(GhosttyUserColours.read([config], themeDirs: [themes], appearance: .dark)),
                       ["background=#202020", "background=#101010"], "the config's own colour is last, so it wins")
    }

    func testTheUserThemesFolderWinsOverGhosttyAppsBundledThemes() throws {
        let home = tempDir()
        let config = try fixture(home, ".config/ghostty/config", "theme = Example\n")
        let bundled = home.appendingPathComponent("Ghostty.app/Contents/Resources/ghostty/themes")
        _ = try fixture(home, "Ghostty.app/Contents/Resources/ghostty/themes/Example", "background = #bbbbbb\n")
        _ = try fixture(home, "Ghostty.app/Contents/Resources/ghostty/themes/Bundled Only", "background = #cccccc\n")
        _ = try fixture(home, ".config/ghostty/themes/Example", "background = #aaaaaa\n")
        let dirs = GhosttyUserColours.themeDirs(home: home, xdgConfigHome: nil, bundled: bundled)
        XCTAssertEqual(pairs(GhosttyUserColours.read([config], themeDirs: dirs, appearance: .dark)), ["background=#aaaaaa"], "user folder first")
        try "theme = Bundled Only\n".write(to: config, atomically: true, encoding: .utf8)
        XCTAssertEqual(pairs(GhosttyUserColours.read([config], themeDirs: dirs, appearance: .dark)), ["background=#cccccc"],
                       "Ghostty.app's theme when the user folder has none")
    }

    /// light:A,dark:B follows Prosper's own theme appearance (the terminal follows Prosper's theme, not the system).
    func testLightDarkThemePicksTheSideOfProsperAppearance() throws {
        let home = tempDir()
        let config = try fixture(home, "ghostty/config", "theme = light:Example Day,dark:Example Night\n")
        let themes = home.appendingPathComponent("themes")
        _ = try fixture(home, "themes/Example Day", "background = #eeeeee\n")
        _ = try fixture(home, "themes/Example Night", "background = #111111\n")
        XCTAssertEqual(pairs(GhosttyUserColours.read([config], themeDirs: [themes], appearance: .light)), ["background=#eeeeee"])
        XCTAssertEqual(pairs(GhosttyUserColours.read([config], themeDirs: [themes], appearance: .dark)), ["background=#111111"])
    }

    /// QA r1418 s1: a FIFO at the config path is refused at once (non-blocking open, regular files only), even with a
    /// colour line waiting in it; the parent's blocking open hung here until a writer came.
    func testAFifoAtTheConfigPathIsRefusedWithoutBlocking() throws {
        let fifo = tempDir().appendingPathComponent("config")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        let holder = open(fifo.path, O_RDONLY | O_NONBLOCK)   // keeps the written line in the pipe
        XCTAssertTrue(holder >= 0)
        defer { close(holder) }
        let writer = open(fifo.path, O_WRONLY | O_NONBLOCK)
        XCTAssertTrue(writer >= 0)
        let line = Array("background = #101010\n".utf8)
        XCTAssertEqual(write(writer, line, line.count), line.count)
        close(writer)
        let done = expectation(description: "read() returned [] for a FIFO")
        DispatchQueue.global().async {   // off-thread so a blocking open fails the row instead of hanging it
            if GhosttyUserColours.read([fifo]).isEmpty { done.fulfill() }
        }
        wait(for: [done], timeout: 2)
        // Unblock a reader still waiting for a writer (the parent's open), so nothing stays blocked.
        let unblock = open(fifo.path, O_WRONLY | O_NONBLOCK)
        if unblock >= 0 { close(unblock) }
    }

    @MainActor
    func testTheSettingsRowOffersProsperAndMyGhosttyThemeDefaultProsper() {
        let key = "agentTerminalColours"
        Preferences.defaults.removeObject(forKey: key)
        defer { Preferences.defaults.removeObject(forKey: key) }
        XCTAssertEqual(Preferences.agentTerminalColours, "prosper", "Prosper when unset")
        XCTAssertEqual(AgentSessionsSection.colourChoices.map(\.0), ["prosper", "ghostty"])
        XCTAssertEqual(AgentSessionsSection.colourChoices.map(\.1), ["Prosper", "My Ghostty theme"])
        XCTAssertEqual(AgentSessionsSection.coloursFooter, "Colours only; Prosper keeps its own keys and clipboard rules.")
        Preferences.defaults.set("something-else", forKey: key)
        XCTAssertEqual(Preferences.agentTerminalColours, "prosper", "an unknown value reads as Prosper")
        Preferences.agentTerminalColours = "ghostty"
        XCTAssertEqual(Preferences.defaults.string(forKey: key), "ghostty")
    }
}
