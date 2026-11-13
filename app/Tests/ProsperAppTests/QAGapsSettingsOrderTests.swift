import XCTest
@testable import ProsperApp

/// #1002 (QA #4, QA #59): the Settings sidebar and the search index, pinned to literal lists.
final class QAGapsSettingsOrderTests: XCTestCase {

    private let switchKeys = ["autocompleteEnabled", "agentEnabled"]
    private var savedSwitches: [String: Any] = [:]

    override func setUp() {
        super.setUp()
        for k in switchKeys { if let v = Preferences.defaults.object(forKey: k) { savedSwitches[k] = v } }
    }

    override func tearDown() {
        for k in switchKeys { Preferences.defaults.set(savedSwitches[k], forKey: k) }
        super.tearDown()
    }

    private var appRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // ProsperAppTests
            .deletingLastPathComponent()      // Tests
            .deletingLastPathComponent()      // app
    }

    private static let manifest = """
    [extension]
    id = "com.test.qagapsorder"
    name = "qagapsorder"
    title = "QA Gaps Order"
    description = "fixture"
    version = "1.0.0"
    author = "test"
    system = true

    [extension.host]
    min_version = "2.0.0"
    api_level = 1

    [extension.entry]
    main = "init.lua"

    [[contributes.commands]]
    id = "qagapsorder.noop"
    title = "Noop"
    mode = "no-view"
    match = "^__never__"

    [[contributes.settings_sections]]
    id = "side"
    title = "Side Section"
    placement = "sidebar"
    dynamic = false
    """

    @MainActor
    private func makeRegistry() throws -> ExtensionRegistry {
        let systemRoot = tempDir("qagaps-order-system")
        let dir = systemRoot.appendingPathComponent("qagapsorder", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Self.manifest.write(to: dir.appendingPathComponent("extension.toml"), atomically: true, encoding: .utf8)
        try "error('the sidebar must never spawn Lua')"
            .write(to: dir.appendingPathComponent("init.lua"), atomically: true, encoding: .utf8)
        let registry = ExtensionRegistry(
            systemDir: systemRoot, userDir: tempDir("qagaps-order-user"),
            hostVersion: "2.0.0", defaults: scratchDefaults("qagaps-order"))
        registry.discover()
        return registry
    }

    // MARK: - QA #4: sidebar groups and their tabs

    /// Every group shown: both feature switches on and an extension with a sidebar section.
    @MainActor
    func testSidebarGroupsAndTabsWithEveryGroupShown() throws {
        Preferences.autocompleteEnabled = true
        Preferences.agentEnabled = true
        let registry = try makeRegistry()
        XCTAssertNotNil(registry.record(id: "com.test.qagapsorder"), "fixture extension not discovered")

        let groups = settingsSidebarGroups(registry: registry)
        let names = ["General", "System Stats", "Volume Mixer", "Extension Settings", "AI Models",
                     "Inline Autocomplete", "Coding Agent", "More"]
        XCTAssertEqual(groups.map(\.0), names)
        XCTAssertEqual(Set(groups.map(\.0)), Set(names))
        XCTAssertEqual(groups.map { $0.1.map(\.id) }, [
            ["general", "shortcuts", "appearance", "extensions"],
            ["system-stats"],
            ["audio-mixer"],
            ["ext:com.test.qagapsorder|side"],
            ["ai-models"],
            ["completions", "context", "apps", "personalization", "statistics"],
            ["agent", "agent-mcp", "agent-plugins", "agent-commands", "agent-personas", "agent-permissions"],
            ["account", "sync", "analytics", "about"],
        ])
        XCTAssertEqual(groups.first?.1.map(\.title), ["General", "Shortcuts", "Appearance", "Extensions"])
    }

    /// Both switches off and no registry: the two feature groups, Extension Settings
    /// and the Extensions tab are gone; the rest keep their order.
    @MainActor
    func testSidebarGroupsWithFeaturesOffAndNoRegistry() {
        Preferences.autocompleteEnabled = false
        Preferences.agentEnabled = false
        let groups = settingsSidebarGroups(registry: nil)
        XCTAssertEqual(groups.map(\.0), ["General", "System Stats", "Volume Mixer", "AI Models", "More"])
        XCTAssertEqual(groups.first?.1.map(\.id), ["general", "shortcuts", "appearance"])
        XCTAssertEqual(groups.last?.1.map(\.id), ["account", "sync", "analytics", "about"])
    }

    /// The General pane's sections, in order. The index is the generator's scrape of
    /// GeneralPane and testGeneratedIndexIsCurrent keeps it current, so a reorder of the
    /// pane fails there (stale) or here (regenerated).
    func testGeneralPaneSectionOrder() {
        let general = nativeSettingsIndex.filter { $0.paneID == "general" }
        XCTAssertEqual(general.map(\.section),
                       ["", "Essentials", "Permissions", "Clipboard", "Quick-select", "Remote Terminal", "Local AI"])
    }

    // MARK: - QA #59: System Stats module rows, the section title, the ⌘ conversion

    @MainActor
    func testModuleSearchIndexPerModule() {
        let ramp = ["Show in menu bar", "Display", "Show label", "Show unit",
                    "Low colour", "Medium colour", "High colour"]
        func row(_ section: String, _ keywords: [String]) -> SettingsIndexEntry {
            SettingsIndexEntry(paneID: "system-stats", paneTitle: "System Stats", section: section, keywords: keywords)
        }
        XCTAssertEqual(SystemStatsPane.moduleSearchIndex, [
            row("CPU — Processor", ramp),
            row("RAM — Memory", ramp),
            row("Disk — Storage", ramp),
            row("NET — Network", ["Show in menu bar", "Download colour", "Upload colour"]),
            row("GPU — Graphics", ramp),
            row("Power — Power", ramp),
            row("Sensor — Temperature", ["Show in menu bar", "Show label", "Show unit",
                                         "Low colour", "Medium colour", "High colour", "Fast manual fan re-engage"]),
            row("BAT — Battery", ["Show in menu bar", "Show label", "Show unit",
                                  "Low colour", "Medium colour", "High colour"]),
        ])
    }

    /// The index anchors on moduleTitle(m); the pane's section must use the same title or
    /// a search hit scrolls nowhere.
    func testModuleSectionUsesModuleTitle() throws {
        let source = try String(contentsOf: appRoot.appendingPathComponent(
            "Sources/ProsperApp/SystemStats/SystemStatsPane.swift"), encoding: .utf8)
        XCTAssertEqual(source.components(separatedBy: "NeonSection(Self.moduleTitle(m))").count - 1, 1)
    }

    /// gen-settings-index.py turns a `\u{2318}` escape in a row title into the character;
    /// without it the index would carry the escape text and "⌘Q" would find nothing.
    func testGeneratorConvertsUnicodeEscapes() {
        let quit = nativeSettingsIndex.first { $0.paneID == "shortcuts" && $0.section == "Quit Guard" }
        XCTAssertEqual(quit?.keywords, ["Require a double-tap of ⌘Q to quit"])
        let finder = nativeSettingsIndex.first { $0.paneID == "shortcuts" && $0.section == "Finder" }
        XCTAssertEqual(finder?.keywords, ["Press F2 to rename the selected file", "Press ⌘X then ⌘V to move files",
                                          "Press ⌘V to save a copied image as a PNG file"])
        XCTAssertFalse(nativeSettingsIndex.contains { $0.keywords.contains { $0.contains("\\u{") } })
    }
}
