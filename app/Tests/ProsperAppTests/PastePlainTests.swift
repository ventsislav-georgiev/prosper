import XCTest
@testable import ProsperApp

/// The pasteplain extension has two host-side contracts that no Lua test can see:
/// its manifest keybinding (the palette command's default ⌘⌥⇧V, claimed natively
/// through `[[contributes.keybindings]]`), and the key rules it registers for the
/// opt-in ⌘V / ⇧⌘V pair, which are resolved by the native rule engine. Both are
/// pinned here against the SHIPPED manifest and the exact rule shapes init.lua
/// emits, so a rename on either side fails loudly instead of silently doing nothing.
final class PastePlainTests: XCTestCase {

    /// …/app/Sources/ProsperApp/Resources/extensions
    private var extensionsDir: URL {
        URL(fileURLWithPath: #filePath)        // …/app/Tests/ProsperAppTests/<this file>
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/ProsperApp/Resources/extensions", isDirectory: true)
    }

    private func loadManifest() throws -> ExtensionManifest {
        let dir = extensionsDir.appendingPathComponent("pasteplain", isDirectory: true)
        try XCTSkipIf(!FileManager.default.fileExists(atPath: dir.path),
                      "in-repo extensions dir not found at \(dir.path)")
        return try ExtensionLoader.load(directory: dir, isSystem: true, hostVersion: "0.0.0").manifest
    }

    // MARK: - The contributed default shortcut

    /// The whole path from manifest to Carbon registration, minus the OS call:
    /// the keybinding decodes, names a command that actually exists, and parses
    /// into a combo that `registerHotKeys` will accept (its only filter is a
    /// non-empty modifier mask — an unparsed or bare key is skipped silently).
    func testPalettePasteKeybindingIsRegistrable() throws {
        let manifest = try loadManifest()
        let bindings = manifest.contributes?.allKeybindings ?? []
        XCTAssertEqual(bindings.count, 1)
        let kb = try XCTUnwrap(bindings.first)
        XCTAssertEqual(kb.command, "pasteplain.paste")
        XCTAssertTrue(manifest.contributes?.allCommands.contains { $0.id == kb.command } == true,
                      "the keybinding names a command the manifest does not contribute")

        let combo = try XCTUnwrap(KeyCombo.parse(kb.key), "\(kb.key) does not parse — never registered")
        XCTAssertNotEqual(combo.carbonModifiers, 0, "a bare key is skipped by registerHotKeys")
        XCTAssertEqual(KeyChord(carbonKeyCode: combo.keyCode, carbonModifiers: combo.carbonModifiers),
                       KeyChord(spec: "cmd+alt+shift+v"))
    }

    /// The mode picker lives in a Tier-B section, and the rules are (re)registered
    /// from `on_launch` — without the system.launch subscription the chosen mode
    /// would never take effect after a relaunch.
    func testSettingsSectionAndLaunchEventAreContributed() throws {
        let manifest = try loadManifest()
        let section = try XCTUnwrap(manifest.contributes?.allSettingsSections.first)
        XCTAssertEqual(section.id, "pasteplain")
        XCTAssertTrue(section.isDynamic)
        XCTAssertTrue(manifest.contributes?.allEvents.contains {
            $0.event == "system.launch" && $0.handler == "on_launch"
        } == true)
    }

    // MARK: - Rule resolution for the ⌘V / ⇧⌘V pair

    /// The rule sets `rules_for` builds, verbatim. Kept as JSON (not Lua) because
    /// this is exactly what crosses `host.keys.set_rules` into the engine.
    private static let cmdVPlain = """
    [
      { "from": "cmd+v", "invoke": "pasteplain_chord", "arg": "plain",
        "not_apps": ["com.apple.finder"] },
      { "from": "cmd+shift+v", "invoke": "pasteplain_chord", "arg": "rich" }
    ]
    """
    private static let shiftCmdVPlain = """
    [{ "from": "cmd+shift+v", "invoke": "pasteplain_chord", "arg": "plain" }]
    """

    private static let extID = "com.prosper.pasteplain"

    @MainActor
    private func resolve(_ json: String, _ spec: String, bundleID: String? = nil) -> KeyRuleResolution {
        let mgr = ExtensionKeyRules.shared
        mgr.removeRules(extensionID: Self.extID)
        mgr.setRules(extensionID: Self.extID, json: json)
        defer { mgr.removeRules(extensionID: Self.extID) }
        return mgr.evaluate(chord: KeyChord(spec: spec)!, bundleID: bundleID)
    }

    @MainActor
    func testCmdVModeClaimsBothChords() {
        XCTAssertEqual(resolve(Self.cmdVPlain, "cmd+v"),
                       .invoke(extensionID: Self.extID, handler: "pasteplain_chord", arg: "plain"))
        XCTAssertEqual(resolve(Self.cmdVPlain, "cmd+shift+v"),
                       .invoke(extensionID: Self.extID, handler: "pasteplain_chord", arg: "rich"))
        // Nothing else is touched: ⌘C, a bare V, ⌥⌘V all reach the app untouched.
        XCTAssertEqual(resolve(Self.cmdVPlain, "cmd+c"), .passThrough)
        XCTAssertEqual(resolve(Self.cmdVPlain, "v"), .passThrough)
        XCTAssertEqual(resolve(Self.cmdVPlain, "cmd+alt+v"), .passThrough)
    }

    @MainActor
    func testCmdVModeLeavesFinderAlone() {
        // Finder's ⌘V pastes files (and drives the built-in cut/paste move); the
        // pasteboard's string form there is a path, so rewriting it would be wrong.
        XCTAssertEqual(resolve(Self.cmdVPlain, "cmd+v", bundleID: "com.apple.finder"), .passThrough)
        // The rich chord has no such exclusion.
        XCTAssertEqual(resolve(Self.cmdVPlain, "cmd+shift+v", bundleID: "com.apple.finder"),
                       .invoke(extensionID: Self.extID, handler: "pasteplain_chord", arg: "rich"))
    }

    @MainActor
    func testShiftModeNeverTouchesCmdV() {
        // The whole point of the default-safe mode: an ordinary paste is not even
        // considered by the engine.
        XCTAssertEqual(resolve(Self.shiftCmdVPlain, "cmd+v"), .passThrough)
        XCTAssertEqual(resolve(Self.shiftCmdVPlain, "cmd+shift+v"),
                       .invoke(extensionID: Self.extID, handler: "pasteplain_chord", arg: "plain"))
    }

    // MARK: - Teardown: a rule must never outlive the extension that owns it

    /// The tap swallows a matched chord in its hot path and only then dispatches to
    /// the extension (AutocompleteEngine.swift:582-586), and `deliverEvent` drops
    /// silently for a non-live one — so a rule left behind by a disabled or
    /// uninstalled extension eats the keystroke system-wide with nothing to handle
    /// it. With pasteplain claiming ⌘V that means paste stops working entirely until
    /// relaunch, so both teardown paths are pinned here against the REAL services
    /// (the no-op stub other registry tests use would not exercise this at all).
    @MainActor
    private func makeRegistry(userDir: URL) -> ExtensionRegistry {
        ExtensionRegistry(
            systemDir: nil, userDir: userDir, hostVersion: "2.0.0",
            defaults: UserDefaults(suiteName: "test.\(UUID().uuidString)")!)
    }

    /// A throwaway user extension on disk. Contributes nothing but its identity —
    /// the rules under test are registered directly, exactly as `on_launch` would.
    private func writeExtension(into dir: URL, id: String) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try """
        [extension]
        id = "\(id)"
        name = "ruler"
        title = "Ruler"
        description = "Registers a key rule"
        version = "1.0.0"
        author = "tester"

        [extension.host]
        min_version = "2.0.0"
        api_level = 1

        [extension.entry]
        main = "init.lua"
        """.write(to: dir.appendingPathComponent("extension.toml"), atomically: true, encoding: .utf8)
        try "function noop() end".write(
            to: dir.appendingPathComponent("init.lua"), atomically: true, encoding: .utf8)
    }

    /// `resetResources` hops to the MainActor via a `Task`, so the removal lands on a
    /// later turn than the `setEnabled`/`uninstall` call. Yield until it does.
    @MainActor
    private func awaitRulesCleared(_ chord: KeyChord) async -> KeyRuleResolution {
        for _ in 0..<100 {
            let r = ExtensionKeyRules.shared.evaluate(chord: chord, bundleID: nil)
            if r == .passThrough { return r }
            await Task.yield()
        }
        return ExtensionKeyRules.shared.evaluate(chord: chord, bundleID: nil)
    }

    @MainActor
    private func withRuleRegisteringExtension(
        _ body: (ExtensionRegistry, String) throws -> Void
    ) async throws {
        let id = "com.test.ruler"
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: tmp)
            ExtensionKeyRules.shared.removeRules(extensionID: id)
        }
        try writeExtension(into: tmp.appendingPathComponent("user/\(id)"), id: id)

        let registry = makeRegistry(userDir: tmp.appendingPathComponent("user"))
        registry.discover()
        XCTAssertNotNil(registry.record(id: id), "fixture extension not discovered")

        let chord = KeyChord(spec: "cmd+v")!
        ExtensionKeyRules.shared.setRules(extensionID: id, json: Self.cmdVPlain)
        XCTAssertEqual(ExtensionKeyRules.shared.evaluate(chord: chord, bundleID: nil),
                       .invoke(extensionID: id, handler: "pasteplain_chord", arg: "plain"))

        try body(registry, id)

        let after = await awaitRulesCleared(chord)
        XCTAssertEqual(after, .passThrough, "the extension's key rule outlived it")
    }

    @MainActor
    func testDisablingAnExtensionDropsItsKeyRules() async throws {
        try await withRuleRegisteringExtension { registry, id in
            try registry.setEnabled(false, id: id)
        }
    }

    @MainActor
    func testUninstallingAnExtensionDropsItsKeyRules() async throws {
        try await withRuleRegisteringExtension { registry, id in
            try registry.uninstall(id: id)
        }
    }

    @MainActor
    func testOffModeRegistersNothing() {
        // `host.keys.set_rules{}` encodes an empty Lua table as `{}`, not `[]` —
        // both must clear the extension's rules rather than leave ⌘V claimed.
        XCTAssertEqual(resolve("{}", "cmd+v"), .passThrough)
        XCTAssertEqual(resolve("[]", "cmd+v"), .passThrough)
    }
}
