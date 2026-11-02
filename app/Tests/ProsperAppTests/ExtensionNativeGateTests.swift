import XCTest
@testable import ProsperApp

/// No-op host services: setEnabled's teardown reaches `resetResources`, which must
/// touch nothing real.
private final class GateNoopServices: ExtensionHostServices, @unchecked Sendable {
    func clipboardRead() -> String? { nil }
    func clipboardWrite(_ text: String) {}
    func clipboardHistory(limit: Int) -> [String] { [] }
    func llmComplete(_ prompt: String) async -> String { "" }
    func llmTranslate(_ text: String, target: String, source: String?) async -> String { "" }
    func llmChat(_ prompt: String) async -> String { "" }
    func shellRun(_ command: String) async -> String { "" }
    func httpRequest(method: String, url: String, headers: [String: String],
                     body: String?, timeout: TimeInterval) async -> HTTPResponse? { nil }
    func currentEpochSeconds() -> Double { 0 }
    func focusedWindowFrame() -> WindowFrame? { nil }
    func setFocusedWindowFrame(x: Double, y: Double, width: Double, height: Double) -> Bool { false }
    func prefGet(extensionID: String, key: String) -> String? { nil }
    func prefSet(extensionID: String, key: String, value: String) {}
    func notify(title: String, body: String) {}
    func listDirectories(_ path: String) -> [String] { [] }
}

/// Synthetic system extensions (manifest + an empty init.lua; no VM is ever spawned)
/// on scratch defaults. `registry()` is one launch: a second call over the same
/// fixture is a relaunch reading the persisted enabled state.
struct GateFixture {
    let systemDir: URL
    let userDir: URL
    let defaults: UserDefaults

    @MainActor func registry() -> ExtensionRegistry {
        let r = ExtensionRegistry(systemDir: systemDir, userDir: userDir, hostVersion: "2.0.0",
                                  defaults: defaults, services: GateNoopServices())
        r.discover()
        return r
    }
}

extension XCTestCase {
    /// One system extension per id, each contributing the given command ids
    /// (no `match`, no `prefix`, so nothing routes to the empty Lua).
    func gateFixture(_ exts: [(id: String, commands: [String])]) throws -> GateFixture {
        let root = tempDir("native-gate")
        let systemDir = root.appendingPathComponent("system", isDirectory: true)
        for ext in exts {
            let dir = systemDir.appendingPathComponent(ext.id, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var toml = """
            [extension]
            id = "\(ext.id)"
            name = "gate"
            title = "Gate"
            description = "native gate fixture"
            version = "1.0.0"
            author = "tester"
            system = true

            [extension.host]
            min_version = "2.0.0"
            api_level = 1

            [extension.entry]
            main = "init.lua"

            """
            for c in ext.commands {
                toml += """

                [[contributes.commands]]
                id = "\(c)"
                title = "\(c)"
                mode = "no-view"

                """
            }
            try toml.write(to: dir.appendingPathComponent("extension.toml"), atomically: true, encoding: .utf8)
            try "".write(to: dir.appendingPathComponent("init.lua"), atomically: true, encoding: .utf8)
        }
        return GateFixture(systemDir: systemDir,
                           userDir: root.appendingPathComponent("user", isDirectory: true),
                           defaults: scratchDefaults("native-gate"))
    }
}

/// #703: a disabled system extension stops its NATIVE behaviour too, not only its
/// Lua side. One test per extension the audit fixed (fallback search lives in
/// FallbackSearchTests).
@MainActor
final class ExtensionNativeGateTests: XCTestCase {

    /// Point the router at `registry` for the test; restored on teardown.
    private func install(_ registry: ExtensionRegistry) {
        let previous = CommandRouter.registry
        CommandRouter.registry = registry
        addTeardownBlock { @MainActor in CommandRouter.registry = previous }
    }

    /// Set a `Preferences.defaults` key (the XCTest in-memory store) for the test only.
    private func setPref(_ value: Any, _ key: String) {
        let d = Preferences.defaults
        let old = d.object(forKey: key)
        d.set(value, forKey: key)
        addTeardownBlock {
            if let old { d.set(old, forKey: key) } else { d.removeObject(forKey: key) }
        }
    }

    func testRegistryCachesLiveFlagsAndRefreshesThemOnToggle() throws {
        let fx = try gateFixture([(FallbackSearchStore.extensionID, []), (SnippetStore.extensionID, [])])
        let reg = fx.registry()
        XCTAssertTrue(reg.fallbackSearchLive)
        XCTAssertTrue(reg.snippetsLive)
        try reg.setEnabled(false, id: FallbackSearchStore.extensionID)
        XCTAssertFalse(reg.fallbackSearchLive)
        XCTAssertTrue(reg.snippetsLive, "one extension's flag never moves another's")
        try reg.setEnabled(false, id: SnippetStore.extensionID)
        XCTAssertFalse(reg.snippetsLive)
        try reg.setEnabled(true, id: SnippetStore.extensionID)
        XCTAssertTrue(reg.snippetsLive)
        XCTAssertFalse(fx.registry().fallbackSearchLive, "disabled state must survive a relaunch")
    }

    func testSnippetAutoExpandStopsWithTheExtension() throws {
        let fx = try gateFixture([(SnippetStore.extensionID, ["snippets.run"])])
        let reg = fx.registry()
        install(reg)
        setPref(true, "snippetsEnabled")
        setPref(true, "snippetsAutoExpand")
        XCTAssertTrue(SnippetExpander.autoExpandActive)
        try reg.setEnabled(false, id: SnippetStore.extensionID)
        XCTAssertFalse(SnippetExpander.autoExpandActive,
                       "a disabled Snippets extension must not expand keywords inline")
        try reg.setEnabled(true, id: SnippetStore.extensionID)
        XCTAssertTrue(SnippetExpander.autoExpandActive)
        // The user's own toggle still applies on top of the extension gate.
        setPref(false, "snippetsAutoExpand")
        XCTAssertFalse(SnippetExpander.autoExpandActive)
    }

    func testQuicklinksListingAndSearchStopWithTheExtension() async throws {
        let fx = try gateFixture([(CommandRouter.quicklinksID, ["quicklinks.run"])])
        let reg = fx.registry()
        install(reg)
        // QuicklinkStore reads this key; set in the in-memory store (never `save`,
        // which mirrors to ~/.config/prosper/quicklinks.json).
        setPref(#"{"zzqlinkgate":"https://example.com/"}"#, "ext.com.prosper.quicklinks.links")

        func isListing(_ o: RunnerOutcome) -> Bool { if case .quicklinks = o { return true }; return false }
        func linkHits(_ o: RunnerOutcome) -> Int {
            guard case .search(let hits) = o else { return 0 }
            return hits.filter { $0.kind == .quicklink }.count
        }

        let o1 = await CommandRouter.run("ql")
        XCTAssertTrue(isListing(o1))
        let o2 = await CommandRouter.run("zzqlinkgate")
        XCTAssertEqual(linkHits(o2), 1)

        try reg.setEnabled(false, id: CommandRouter.quicklinksID)
        let o3 = await CommandRouter.run("ql")
        XCTAssertFalse(isListing(o3), "disabled: no native `ql` listing")
        let o4 = await CommandRouter.run("zzqlinkgate")
        XCTAssertEqual(linkHits(o4), 0,
                       "disabled: no quicklink rows in the universal search")

        try reg.setEnabled(true, id: CommandRouter.quicklinksID)
        let o5 = await CommandRouter.run("zzqlinkgate")
        XCTAssertEqual(linkHits(o5), 1, "re-enabled: links are back")
    }

    func testQuickdirsVerbAndDynamicPrefixesStopWithTheExtension() async throws {
        let fx = try gateFixture([(CommandRouter.quickdirsID, ["quickdirs.run"])])
        let reg = fx.registry()
        install(reg)
        setPref(#"[{"name":"gatedir","path":"/nonexistent-703","prefix":"zq","action":"","actionLabel":""}]"#,
                "ext.com.prosper.quickdirs.dirs")
        reg.dynamicModeProvider = { QuickdirStore.modeSpecs() }

        func isPicker(_ o: RunnerOutcome) -> Bool { if case .quickdirsMenu = o { return true }; return false }
        func hasPrefix() -> Bool { reg.modeTriggers().contains { $0.prefix == "zq " } }

        let o6 = await CommandRouter.run("qd")
        XCTAssertTrue(isPicker(o6))
        XCTAssertTrue(hasPrefix())

        try reg.setEnabled(false, id: CommandRouter.quickdirsID)
        let o7 = await CommandRouter.run("qd")
        XCTAssertFalse(isPicker(o7), "disabled: no native `qd` picker")
        XCTAssertFalse(hasPrefix(), "disabled: a quickdir's own prefix must not lock the runner")

        try reg.setEnabled(true, id: CommandRouter.quickdirsID)
        XCTAssertTrue(hasPrefix())
    }

    func testOpenInlinePathStopsWithTheExtension() async throws {
        let fx = try gateFixture([(CommandRouter.openID, ["open.run"])])
        let reg = fx.registry()
        install(reg)
        let q = "o zzznoappgate703"
        // The native `o ` path answers for the bare app name; anything else means
        // the query fell through to the universal search.
        func nativeOpen(_ o: RunnerOutcome) -> Bool {
            if case .noResults(let name) = o { return name == "zzznoappgate703" }
            if case .apps = o { return true }
            return false
        }
        let o8 = await CommandRouter.run(q)
        XCTAssertTrue(nativeOpen(o8))
        try reg.setEnabled(false, id: CommandRouter.openID)
        let o9 = await CommandRouter.run(q)
        XCTAssertFalse(nativeOpen(o9), "disabled: no native `o ` app search")
    }

    /// Shell (`>`) and the menu walk run real side effects (a login shell, an AX walk
    /// of the frontmost app), so only their shared predicate is exercised here.
    func testExtensionLivePredicateFollowsTheRegistry() throws {
        let previous = CommandRouter.registry
        CommandRouter.registry = nil
        XCTAssertTrue(CommandRouter.extensionLive(CommandRouter.shellID), "no registry = ungated")
        CommandRouter.registry = previous

        let fx = try gateFixture([(CommandRouter.shellID, ["shell.run"]), (CommandRouter.menusID, ["menus.run"])])
        let reg = fx.registry()
        install(reg)
        XCTAssertTrue(CommandRouter.extensionLive(CommandRouter.shellID))
        XCTAssertTrue(CommandRouter.extensionLive(CommandRouter.menusID))
        XCTAssertFalse(CommandRouter.extensionLive("com.prosper.absent"), "unknown id = not live")
        try reg.setEnabled(false, id: CommandRouter.shellID)
        try reg.setEnabled(false, id: CommandRouter.menusID)
        XCTAssertFalse(CommandRouter.extensionLive(CommandRouter.shellID))
        XCTAssertFalse(CommandRouter.extensionLive(CommandRouter.menusID))
    }
}
