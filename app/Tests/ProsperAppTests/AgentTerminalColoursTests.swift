import Foundation
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
        XCTAssertEqual(pairs(kept), ["theme=Example Dark", "palette=0=#1d1f21", "background=#101010", "cursor-color=#a0b0c0",
                                     "foreground=#eeeeee"], "colours only, in Ghostty's load order (Application Support last)")
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

    @MainActor
    func testAMissingFileGivesTheProsperLook() {
        let home = tempDir()
        let kept = AgentTerminalLook.userColours(choice: "ghostty", files: GhosttyUserColours.files(home: home, xdgConfigHome: nil))
        XCTAssertTrue(kept.isEmpty)
        XCTAssertEqual(AgentTerminalLook.theme(colours: kept), AgentTerminalLook.theme(), "Prosper's background and text")
        XCTAssertEqual(AgentTerminalLook.configuration(colours: kept), AgentTerminalLook.configuration)
    }

    @MainActor
    func testTheProsperChoiceIgnoresAFixtureConfig() throws {
        let file = try fixture(tempDir(), "ghostty/config", "background = #101010\n")
        XCTAssertTrue(AgentTerminalLook.userColours(choice: "prosper", files: [file]).isEmpty)
        XCTAssertEqual(pairs(AgentTerminalLook.userColours(choice: "ghostty", files: [file])), ["background=#101010"], "the same file is read when chosen")
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
        XCTAssertTrue(c.renderedConfig.contains("background = \(AgentTerminalLook.hex(Neon.bgBottom))"))
    }

    /// A value the allowlist passes but libghostty refuses rolls the overlay back: Prosper's config and colours stay.
    @MainActor
    func testARefusedColourKeepsTheProsperLook() {
        let c = AgentTerminalLook.make(colours: [("background", "notacolourname")])
        XCTAssertFalse(c.renderedConfig.contains("notacolourname"))
        XCTAssertTrue(c.renderedConfig.contains("clipboard-read = deny"))
        XCTAssertTrue(c.renderedConfig.contains("background = \(AgentTerminalLook.hex(Neon.bgBottom))"))
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
