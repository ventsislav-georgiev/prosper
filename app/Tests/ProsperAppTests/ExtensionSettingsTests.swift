import XCTest
@testable import ProsperApp

/// Minimal host services for the settings tests: an in-memory `host.prefs` store
/// plus inert stubs for everything else. Matches the `ExtensionHostServices`
/// protocol (settings use PermissionsManager natively, not a host capability).
private final class SettingsFakeServices: ExtensionHostServices, @unchecked Sendable {
    var prefs: [String: String] = [:]
    func clipboardRead() -> String? { nil }
    func clipboardWrite(_ text: String) {}
    func clipboardHistory(limit: Int) -> [String] { [] }
    func llmComplete(_ prompt: String) async -> String { "" }
    func llmTranslate(_ text: String, target: String, source: String?) async -> String { "" }
    func shellRun(_ command: String) async -> String { "" }
    func httpRequest(method: String, url: String, headers: [String: String],
                     body: String?, timeout: TimeInterval) async -> HTTPResponse? { nil }
    func focusedWindowFrame() -> WindowFrame? { nil }
    func setFocusedWindowFrame(x: Double, y: Double, width: Double, height: Double) -> Bool { false }
    func currentEpochSeconds() -> Double { 0 }
    func prefGet(extensionID: String, key: String) -> String? { prefs["ext.\(extensionID).\(key)"] }
    func prefSet(extensionID: String, key: String, value: String) { prefs["ext.\(extensionID).\(key)"] = value }
    func notify(title: String, body: String) {}
    func listDirectories(_ path: String) -> [String] { [] }
}

final class ExtensionSettingsTests: XCTestCase {

    // MARK: - Temp-extension helpers (mirrors ExtensionManifestTests)

    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("prosper-settings-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    private func writeExtension(in parent: URL, dir: String, toml: String, lua: String) throws -> URL {
        let d = parent.appendingPathComponent(dir, isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        try toml.write(to: d.appendingPathComponent("extension.toml"), atomically: true, encoding: .utf8)
        try lua.write(to: d.appendingPathComponent("init.lua"), atomically: true, encoding: .utf8)
        return d
    }

    // MARK: - Manifest decode

    private static let sectionedManifest = """
    [extension]
    id = "com.test.settings"
    name = "settingsdemo"
    title = "Settings Demo"
    description = "demo"
    version = "1.0.0"
    author = "test"
    system = true

    [extension.host]
    min_version = "2.0.0"
    api_level = 1

    [extension.entry]
    main = "init.lua"

    [[contributes.commands]]
    id = "settingsdemo.noop"
    title = "Noop"
    mode = "no-view"
    match = "^__never__"

    [[contributes.settings_sections]]
    id = "main"
    title = "Demo"
    icon = "slider.horizontal.3"
    accent = "mo"
    subtitle = "sub"
    placement = "sidebar"
    dynamic = false

      [[contributes.settings_sections.controls]]
      kind = "group"
      title = "Group"
      footer = "foot"

      [[contributes.settings_sections.controls]]
      kind = "toggle"
      key = "flag"
      title = "Flag"
      default = true

      [[contributes.settings_sections.controls]]
      kind = "enum"
      key = "mode"
      title = "Mode"
      values = ["a", "b"]
      value_labels = ["A", "B"]
      default = "a"

      [[contributes.settings_sections.controls]]
      kind = "number"
      key = "n"
      title = "N"
      default = 5
      min = 0
      max = 10
      step = 1

      [[contributes.settings_sections.controls]]
      kind = "permission"
      name = "full-disk-access"
      title = "Full Disk Access"

      [[contributes.settings_sections.controls]]
      kind = "button"
      id = "go"
      title = "Go"
      style = "neon"
    """

    func testManifestDecodesSettingsSections() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeExtension(in: dir, dir: "settingsdemo", toml: Self.sectionedManifest,
                           lua: "-- noop")
        let loaded = try ExtensionLoader.load(
            directory: dir.appendingPathComponent("settingsdemo"),
            isSystem: true, hostVersion: "2.0.0")

        let sections = loaded.manifest.contributes?.allSettingsSections ?? []
        XCTAssertEqual(sections.count, 1)
        let s = try XCTUnwrap(sections.first)
        XCTAssertEqual(s.id, "main")
        XCTAssertEqual(s.accent, "mo")
        XCTAssertFalse(s.isInline)
        XCTAssertFalse(s.isDynamic)
        XCTAssertEqual(s.allControls.count, 6)
        XCTAssertEqual(s.allControls[0].kind, .group)
        XCTAssertEqual(s.allControls[1].kind, .toggle)
        XCTAssertEqual(s.allControls[1].default?.stringValue, "true")
        XCTAssertEqual(s.allControls[2].kind, .enumeration)
        XCTAssertEqual(s.allControls[2].values, ["a", "b"])
        XCTAssertEqual(s.allControls[2].value_labels, ["A", "B"])
        XCTAssertEqual(s.allControls[3].kind, .number)
        XCTAssertEqual(s.allControls[3].min, 0)
        XCTAssertEqual(s.allControls[4].kind, .permission)
        XCTAssertEqual(s.allControls[4].name, "full-disk-access")
        XCTAssertEqual(s.allControls[5].kind, .button)
        XCTAssertEqual(s.allControls[5].id, "go")
    }

    // MARK: - Tier A: manifest controls → SettingsUI

    func testFromManifestMapsControlsAndReadsPrefs() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeExtension(in: dir, dir: "settingsdemo", toml: Self.sectionedManifest, lua: "-- noop")
        let loaded = try ExtensionLoader.load(
            directory: dir.appendingPathComponent("settingsdemo"), isSystem: true, hostVersion: "2.0.0")
        let section = try XCTUnwrap(loaded.manifest.contributes?.allSettingsSections.first)

        // Stored value overrides the manifest default; unset falls back to default.
        let prefs = ["mode": "b"]
        let ui = SettingsUI.fromManifest(section) { prefs[$0] }

        // The leading `group` opens its own titled sub-section holding the rest.
        XCTAssertEqual(ui.subtitle, "sub")
        let group = try XCTUnwrap(ui.sections.first { $0.title == "Group" })
        XCTAssertEqual(group.footer, "foot")
        let rows = group.rows
        XCTAssertEqual(rows.first { $0.key == "flag" }?.value, "true")     // default
        XCTAssertEqual(rows.first { $0.key == "mode" }?.value, "b")        // from prefs
        XCTAssertEqual(rows.first { $0.key == "mode" }?.optionLabels, ["A", "B"])
        XCTAssertEqual(rows.first { $0.kind == "permission" }?.name, "full-disk-access")
        XCTAssertEqual(rows.first { $0.kind == "button" }?.actionID, "go")
    }

    // MARK: - SettingsUI.decode (Tier B tree)

    func testSettingsUIDecode() throws {
        let json = """
        {"title":"T","sections":[
          {"id":"s","title":"Sec","footer":"f","rows":[
            {"id":"r","kind":"records","addLabel":"Add","revealFile":"~/x.json","records":[
              {"id":"a","title":"Alpha","subtitle":"one","icon":"circle","fields":[
                {"id":"name","label":"Name","kind":"text","value":"Alpha"}]}
            ]}
          ]}
        ]}
        """
        let ui = try SettingsUI.decode(json: json)
        XCTAssertEqual(ui.title, "T")
        let row = try XCTUnwrap(ui.sections.first?.rows.first)
        XCTAssertEqual(row.kind, "records")
        XCTAssertEqual(row.addLabel, "Add")
        XCTAssertEqual(row.records?.count, 1)
        XCTAssertEqual(row.records?.first?.title, "Alpha")
        XCTAssertEqual(row.records?.first?.fields?.first?.id, "name")
    }

    // MARK: - Tier B round-trip through the registry (synthetic extension)

    private static let dynamicManifest = """
    [extension]
    id = "com.test.dynsettings"
    name = "dynsettings"
    title = "Dyn Settings"
    description = "demo"
    version = "1.0.0"
    author = "test"
    system = true

    [extension.host]
    min_version = "2.0.0"
    api_level = 1

    [extension.entry]
    main = "init.lua"

    [[contributes.commands]]
    id = "dynsettings.noop"
    title = "Noop"
    mode = "no-view"
    match = "^__never__"

    [[contributes.settings_sections]]
    id = "items"
    title = "Items"
    dynamic = true
    """

    /// A records-backed dynamic section persisting to host.prefs "items".
    private static let dynamicLua = """
    local function load()
        local raw = host.prefs.get("items")
        local t = raw and host.json.decode(raw) or {}
        if type(t) ~= "table" then t = {} end
        return t
    end
    local function save(t) host.prefs.set("items", host.json.encode(t)) end

    function settings_render(section_id, state)
        local items = load()
        local recs = {}
        for i, it in ipairs(items) do
            recs[i] = { id = it.name, title = it.name, subtitle = it.value, icon = "circle",
                fields = {
                    { id = "name",  label = "Name",  kind = "text", value = it.name },
                    { id = "value", label = "Value", kind = "text", value = it.value },
                } }
        end
        return host.ui.settings.render(host.ui.settings.ui{
            sections = { { id = "items", title = "Items",
                rows = { host.ui.settings.records{ id = "items", records = recs, addLabel = "Add" } } } } })
    end

    function settings_action(section_id, action_id, value, form_json)
        local items = load()
        local form = host.json.decode(form_json or "{}") or {}
        if action_id == "record.add:items" then
            items[#items + 1] = { name = "row" .. (#items + 1), value = "" }
        elseif action_id:find("^record%.delete:items:") then
            local id = action_id:gsub("^record%.delete:items:", "")
            for i, it in ipairs(items) do if it.name == id then table.remove(items, i); break end end
        elseif action_id:find("^record%.save:items:") then
            local id = action_id:gsub("^record%.save:items:", "")
            for _, it in ipairs(items) do
                if it.name == id then it.value = form.value or it.value end
            end
        end
        save(items)
        return settings_render(section_id, "{}")
    end
    """

    @MainActor
    private func makeDynRegistry() throws -> (ExtensionRegistry, SettingsFakeServices) {
        let systemRoot = try tempDir()
        let userRoot = try tempDir()
        try writeExtension(in: systemRoot, dir: "dynsettings",
                           toml: Self.dynamicManifest, lua: Self.dynamicLua)
        let fake = SettingsFakeServices()
        let registry = ExtensionRegistry(
            systemDir: systemRoot, userDir: userRoot, hostVersion: "2.0.0",
            defaults: UserDefaults(suiteName: "set-test-\(UUID().uuidString)")!,
            services: fake)
        registry.discover()
        return (registry, fake)
    }

    @MainActor
    func testDynamicSectionRoundTrip() async throws {
        let (registry, fake) = try makeDynRegistry()
        try XCTSkipIf(registry.record(id: "com.test.dynsettings") == nil, "synthetic ext not discovered")

        // Initial render: empty records list.
        let ui0 = await registry.renderSettingsAsync(extensionID: "com.test.dynsettings", sectionID: "items")
        let records0 = try XCTUnwrap(ui0?.sections.first?.rows.first)
        XCTAssertEqual(records0.kind, "records")
        XCTAssertEqual(records0.records?.count ?? 0, 0)

        // Add → one record "row1".
        let ui1 = await registry.dispatchSettingsActionAsync(
            extensionID: "com.test.dynsettings", sectionID: "items",
            actionID: "record.add:items", value: nil, formValues: [:])
        XCTAssertEqual(ui1?.sections.first?.rows.first?.records?.count, 1)
        XCTAssertEqual(ui1?.sections.first?.rows.first?.records?.first?.id, "row1")

        // Save value onto row1.
        let ui2 = await registry.dispatchSettingsActionAsync(
            extensionID: "com.test.dynsettings", sectionID: "items",
            actionID: "record.save:items:row1", value: nil, formValues: ["value": "hello"])
        XCTAssertEqual(ui2?.sections.first?.rows.first?.records?.first?.subtitle, "hello")
        // Persisted to the shared host.prefs key.
        XCTAssertTrue(fake.prefs["ext.com.test.dynsettings.items"]?.contains("hello") == true)

        // Delete → empty again.
        let ui3 = await registry.dispatchSettingsActionAsync(
            extensionID: "com.test.dynsettings", sectionID: "items",
            actionID: "record.delete:items:row1", value: nil, formValues: [:])
        XCTAssertEqual(ui3?.sections.first?.rows.first?.records?.count ?? 0, 0)
    }

    // MARK: - Registry section enumeration

    @MainActor
    func testRegistryEnumeratesSidebarSections() throws {
        let (registry, _) = try makeDynRegistry()
        let sidebar = registry.settingsSections(placement: "sidebar")
        XCTAssertTrue(sidebar.contains { $0.section.id == "items" })
        XCTAssertNotNil(registry.settingsSection(extensionID: "com.test.dynsettings", sectionID: "items"))
    }

    // MARK: - PermissionsManager dispatch

    func testPermissionsDispatchLabels() {
        XCTAssertEqual(PermissionsManager.label(forPermission: "full-disk-access"), "Full Disk Access")
        XCTAssertEqual(PermissionsManager.label(forPermission: "unknown"), "unknown")
        XCTAssertFalse(PermissionsManager.isGranted("unknown"))
    }
}
