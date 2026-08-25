import XCTest
@testable import ProsperApp

/// Settings search index: the generated native table, and the runtime extension one.
///
/// The generated table's whole anti-rot story is `testGeneratedIndexIsCurrent` —
/// nothing regenerates it at build time, so a stale checkout has to fail here.
final class SettingsSearchTests: XCTestCase {

    /// `app/`, walked up from this file the same way `SystemExtensionsParityTests` does.
    private var appRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // ProsperAppTests
            .deletingLastPathComponent()      // Tests
            .deletingLastPathComponent()      // app
    }

    // MARK: - 1. The generated table is not stale

    func testGeneratedIndexIsCurrent() throws {
        let script = appRoot.appendingPathComponent("scripts/gen-settings-index.py")
        try XCTSkipIf(!FileManager.default.fileExists(atPath: script.path),
                      "generator missing — source checkout only")

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        task.arguments = ["python3", script.path, "--check"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        try task.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        task.waitUntilExit()

        XCTAssertEqual(task.terminationStatus, 0,
                       "SettingsIndex.generated.swift is stale — run "
                       + "app/scripts/gen-settings-index.py.\n\(output)")
    }

    // MARK: - 2. Every pane the sidebar can show is searchable

    /// The one failure the generator cannot see itself: a new pane whose `case` the
    /// struct→id scrape missed, so it silently never enters the index.
    @MainActor
    func testEveryPaneIsIndexed() {
        let indexed = Set(nativeSettingsIndex.map(\.paneID))
        XCTAssertFalse(indexed.isEmpty, "generated index is empty")
        for (group, tabs) in settingsSidebarGroups(registry: nil) {
            for tab in tabs {
                XCTAssertTrue(indexed.contains(tab.id),
                              "pane '\(tab.id)' (\(group)) is not in nativeSettingsIndex")
            }
        }
    }

    /// Every indexed pane row carries the sidebar's own title, so results read right.
    @MainActor
    func testPaneTitlesMatchTheSidebar() {
        let titles = Dictionary(
            nativeSettingsIndex.map { ($0.paneID, $0.paneTitle) }, uniquingKeysWith: { a, _ in a })
        for (_, tabs) in settingsSidebarGroups(registry: nil) {
            for tab in tabs where titles[tab.id] != nil {
                XCTAssertEqual(titles[tab.id], tab.title, "pane '\(tab.id)' title drifted")
            }
        }
    }

    // MARK: - 3. Anchors are unique

    /// Two sections with the same title in one pane collide on `.id`, and SwiftUI
    /// then scrolls to whichever it feels like. A failure here is a rename.
    func testAnchorsAreUniqueWithinPane() {
        var seen = Set<SettingsAnchor>()
        for entry in nativeSettingsIndex {
            XCTAssertTrue(seen.insert(entry.anchor).inserted,
                          "duplicate anchor: pane '\(entry.paneID)' section '\(entry.section)'")
        }
    }

    // MARK: - 4. Matching

    func testMatching() {
        let entry = SettingsIndexEntry(
            paneID: "demo", paneTitle: "Générale", section: "Clipboard", keywords: ["pasteboard"])

        // Case folding lowercases; diacritic folding strips the accent.
        XCTAssertEqual(SettingsSearch.fold("Générale"), "generale")
        XCTAssertTrue(SettingsSearch.matches("generale", entry), "case + diacritic folded")
        XCTAssertTrue(SettingsSearch.matches("CLIP", entry), "section substring")
        XCTAssertTrue(SettingsSearch.matches("paste", entry), "keyword substring")
        XCTAssertFalse(SettingsSearch.matches("", entry), "empty query matches nothing")
        XCTAssertFalse(SettingsSearch.matches("   ", entry), "whitespace-only matches nothing")
        XCTAssertFalse(SettingsSearch.matches("nonsense", entry))

        XCTAssertTrue(SettingsSearch.results("", index: nativeSettingsIndex).isEmpty)

        // Known queries land on the expected pane.
        let mixer = SettingsSearch.results("mixer", index: nativeSettingsIndex)
        XCTAssertTrue(mixer.allSatisfy { $0.paneID == "audio-mixer" }, "\(mixer)")
        XCTAssertFalse(mixer.isEmpty)

        let clipboard = SettingsSearch.results("clipboard", index: nativeSettingsIndex)
        XCTAssertTrue(clipboard.contains { $0.paneID == "general" && $0.section == "Clipboard" })

        // Pane-level escape-hatch keywords apply to the pane row only.
        let hotkey = SettingsSearch.results("hotkey", index: nativeSettingsIndex)
        XCTAssertEqual(hotkey.map(\.anchor), [SettingsAnchor(pane: "shortcuts", section: "")])

        // Results keep index order.
        let all = SettingsSearch.results("e", index: nativeSettingsIndex)
        XCTAssertEqual(all, nativeSettingsIndex.filter { SettingsSearch.matches("e", $0) })
    }

    // MARK: - 5. Extension index, straight off the manifest

    private static let manifest = """
    [extension]
    id = "com.test.searchindex"
    name = "searchindex"
    title = "Search Index"
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
    id = "searchindex.noop"
    title = "Noop"
    mode = "no-view"
    match = "^__never__"

    [[contributes.settings_sections]]
    id = "static"
    title = "Static Section"
    placement = "sidebar"
    dynamic = false

      [[contributes.settings_sections.controls]]
      kind = "group"
      title = "First Group"

      [[contributes.settings_sections.controls]]
      kind = "toggle"
      key = "flag"
      title = "Enable Widget"

      [[contributes.settings_sections.controls]]
      kind = "group"
      title = "Second Group"

      [[contributes.settings_sections.controls]]
      kind = "text"
      key = "token"
      title = "API Token"

    [[contributes.settings_sections]]
    id = "dyn"
    title = "Dynamic Section"
    placement = "sidebar"
    dynamic = true
    """

    @MainActor
    private func makeRegistry() throws -> ExtensionRegistry {
        let systemRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("prosper-search-index-\(UUID().uuidString)", isDirectory: true)
        let dir = systemRoot.appendingPathComponent("searchindex", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Self.manifest.write(to: dir.appendingPathComponent("extension.toml"),
                                atomically: true, encoding: .utf8)
        try "error('settings search must never spawn Lua')"
            .write(to: dir.appendingPathComponent("init.lua"), atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: systemRoot) }

        let registry = ExtensionRegistry(
            systemDir: systemRoot,
            userDir: FileManager.default.temporaryDirectory
                .appendingPathComponent("prosper-search-index-user-\(UUID().uuidString)",
                                        isDirectory: true),
            hostVersion: "2.0.0",
            defaults: UserDefaults(suiteName: "search-index-\(UUID().uuidString)")!)
        registry.discover()
        return registry
    }

    /// The fixture's `init.lua` does nothing but `error(...)`, and the index builder is
    /// synchronous while every render path is `async` — so a Lua spawn here would be
    /// both impossible to await and loud if it happened.
    @MainActor
    func testExtensionIndexFromManifest() throws {
        let registry = try makeRegistry()
        try XCTSkipIf(registry.record(id: "com.test.searchindex") == nil,
                      "synthetic extension not discovered")

        let index = extensionSettingsIndex(registry: registry)
        let staticRows = index.filter { $0.paneID == "ext:com.test.searchindex|static" }
        let dynamicRows = index.filter { $0.paneID == "ext:com.test.searchindex|dyn" }

        // Static section: the pane row plus one row per `group` control.
        XCTAssertEqual(staticRows.map(\.section), ["", "First Group", "Second Group"])
        XCTAssertEqual(staticRows[0].paneTitle, "Static Section")
        // Non-group controls ride along as keywords on their enclosing group.
        XCTAssertEqual(staticRows[1].keywords, ["Enable Widget"])
        XCTAssertEqual(staticRows[2].keywords, ["API Token"])
        XCTAssertTrue(SettingsSearch.matches("api token", staticRows[2]))

        // Dynamic section: pane granularity only — its rows come from Lua.
        XCTAssertEqual(dynamicRows.map(\.section), [""])
        XCTAssertEqual(dynamicRows[0].paneTitle, "Dynamic Section")

        XCTAssertEqual(dynamicRows[0].anchor,
                       SettingsAnchor(pane: "ext:com.test.searchindex|dyn", section: ""))
    }

    // MARK: - 6. The sidebar's combined index

    /// What the search field actually searches: native + extension rows, minus every
    /// pane the rail is not currently showing. A hidden pane that stays searchable
    /// selects a pane the user then cannot navigate back to.
    @MainActor
    func testSidebarIndexIsUnionNarrowedToVisiblePanes() throws {
        let registry = try makeRegistry()
        try XCTSkipIf(registry.record(id: "com.test.searchindex") == nil,
                      "synthetic extension not discovered")

        let groups = settingsSidebarGroups(registry: registry)
        let index = settingsSearchIndex(registry: registry, groups: groups)
        let visible = Set(groups.flatMap { $0.1.map(\.id) })

        XCTAssertFalse(index.isEmpty)
        // Union: both halves are present.
        XCTAssertTrue(index.contains { $0.paneID == "general" }, "native half missing")
        XCTAssertTrue(index.contains { $0.paneID.hasPrefix("ext:") }, "extension half missing")
        // Nothing outside the rail.
        XCTAssertTrue(index.allSatisfy { visible.contains($0.paneID) })

        // Drop a group and its panes leave the index with it.
        let trimmed = groups.filter { $0.0 != "General" }
        let dropped = Set(groups.first { $0.0 == "General" }?.1.map(\.id) ?? [])
        try XCTSkipIf(dropped.isEmpty, "no General group to trim")
        let narrowed = settingsSearchIndex(registry: registry, groups: trimmed)
        XCTAssertTrue(narrowed.allSatisfy { !dropped.contains($0.paneID) })

        // No registry at all → native rows only, never a crash.
        let nativeOnly = settingsSearchIndex(registry: nil, groups: groups)
        XCTAssertFalse(nativeOnly.isEmpty)
        XCTAssertFalse(nativeOnly.contains { $0.paneID.hasPrefix("ext:") })
    }
}
