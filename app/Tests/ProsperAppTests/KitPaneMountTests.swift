import Foundation
import XCTest
@testable import ProsperApp

/// #1425 (#918 S5): the kit pane mounted as a Settings tab. No window is built or shown: the sidebar groups, the
/// selection fallback, the search index and the tab resolver are plain functions over a registry discovered from the
/// row's own tempDir() (user dir only, scratch defaults). The spawn-env and liveBins rows run over the KitPaneModelTests
/// fixtures (every write under the row's tempDir); KitRuntimes.shared is set by a row and put back to nil in tearDown.
@MainActor
final class KitPaneMountTests: XCTestCase {
    static let ext = "com.example.kit"
    static let plain = "com.example.plain"
    static let tab = "ext:com.example.kit|kit"
    static let base = ["PATH": "/Users/example/bin:/usr/bin", "HOME": "/Users/example"]

    override func tearDown() {
        KitRuntimes.shared = nil
        super.tearDown()
    }

    /// The fake kit and a plain extension (no kit table) in a temp user dir, discovered. `trusted` false: the trust
    /// list is seeded empty first, so the kit lands untrusted.
    private func registry(_ e: KitRuntimeTests.Env, trusted: Bool = true) throws -> ExtensionRegistry {
        _ = try kitPaneSource(e, id: Self.ext)
        let plain = e.root.appendingPathComponent("sources/plain", isDirectory: true)
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        let toml = "[extension]\nid = \"\(Self.plain)\"\nname = \"plain\"\ntitle = \"Plain Example\"\n"
            + "description = \"An example extension\"\nversion = \"1.0.0\"\nauthor = \"Example Org\"\n\n"
            + "[extension.host]\nmin_version = \"1.0.0\"\napi_level = 1\n\n[extension.entry]\nmain = \"init.lua\"\n"
        try Data(toml.utf8).write(to: plain.appendingPathComponent("extension.toml"))
        try Data("-- noop\n".utf8).write(to: plain.appendingPathComponent("init.lua"))
        let defaults = scratchDefaults("kit-pane-mount")
        if !trusted { defaults.set([String](), forKey: "trustedExtensionIDs") }
        let r = ExtensionRegistry(systemDir: nil, userDir: e.root.appendingPathComponent("sources", isDirectory: true),
                                  hostVersion: "2.0.0", defaults: defaults)
        r.discover()
        XCTAssertTrue(r.record(id: Self.ext) != nil && r.record(id: Self.plain) != nil, "both discovered: \(r.records.map(\.id))")
        return r
    }

    private func tabs(_ r: ExtensionRegistry) -> [SettingsTab] { settingsSidebarGroups(registry: r).flatMap { $0.1 } }

    // MARK: S5 rows

    /// The kit gets its tab (its title), resolved to the kit pane with no settings_sections of its own; the plain
    /// extension gets no kit tab.
    func testSidebarListsTheKitTabAndOnlyForTheKit() throws {
        let e = try kitPaneEnv()
        let r = try registry(e)
        let tab = tabs(r).first { $0.id == Self.tab }
        XCTAssertEqual(tab?.title, "Calm Agent Kit")
        XCTAssertTrue(r.record(id: Self.ext)?.manifest.contributes?.allSettingsSections.isEmpty ?? true, "the fixture kit has no settings_sections")
        XCTAssertEqual(settingsKitRecord(registry: r, selection: Self.tab)?.id, Self.ext, "the kit tab resolves to the kit pane")
        XCTAssertFalse(tabs(r).contains { $0.id.hasPrefix("ext:\(Self.plain)|") }, "no tab for the plain extension")
        XCTAssertTrue(settingsKitRecord(registry: r, selection: "ext:\(Self.plain)|kit") == nil, "a non-kit never resolves as a kit")
        XCTAssertEqual(r.kitRecords.map(\.id), [Self.ext])
    }

    /// An untrusted enabled kit keeps its tab (read-only in the pane: S4's untrusted row).
    func testUntrustedKitIsStillListed() throws {
        let e = try kitPaneEnv()
        let r = try registry(e, trusted: false)
        XCTAssertEqual(r.record(id: Self.ext)?.trusted, false, "the kit landed untrusted")
        XCTAssertTrue(tabs(r).contains { $0.id == Self.tab }, "an untrusted kit is listed")
        XCTAssertEqual(settingsKitRecord(registry: r, selection: Self.tab)?.id, Self.ext)
    }

    /// Disabling the kit drops its tab; a selection on it falls back to General (and stays while the tab is shown).
    func testDisablingTheKitDropsTheTabAndTheSelectionFallsBack() throws {
        let e = try kitPaneEnv()
        let r = try registry(e)
        XCTAssertEqual(settingsHealedSelection(Self.tab, groups: settingsSidebarGroups(registry: r)), Self.tab, "shown: kept")
        try r.setEnabled(false, id: Self.ext)
        XCTAssertFalse(tabs(r).contains { $0.id == Self.tab }, "disabled: no tab")
        XCTAssertEqual(settingsHealedSelection(Self.tab, groups: settingsSidebarGroups(registry: r)), "general")
        XCTAssertTrue(settingsKitRecord(registry: r, selection: Self.tab) == nil, "a disabled kit does not resolve")
        XCTAssertFalse(settingsSearchIndex(registry: r, groups: settingsSidebarGroups(registry: r)).contains { $0.paneID == Self.tab })
    }

    /// The search field finds the kit's tab by its title.
    func testSearchFindsTheKitByTitle() throws {
        let e = try kitPaneEnv()
        let r = try registry(e)
        let index = settingsSearchIndex(registry: r, groups: settingsSidebarGroups(registry: r))
        let hits = SettingsSearch.results("calm agent", index: index)
        XCTAssertTrue(hits.contains { $0.paneID == Self.tab && $0.paneTitle == "Calm Agent Kit" }, "\(hits.map(\.paneID))")
    }

    // MARK: #1423 left 1: the registered contributor

    /// One applied, trusted kit in a fake KitRuntimes.shared: the registered contributors give a spawn's PATH its bin
    /// last; without an owner the env is spawnEnv's alone.
    func testSpawnEnvPathEndsWithTheLiveKitBin() async throws {
        let e = try kitPaneEnv()
        let rec = ExtensionRecord(loaded: try kitPaneSource(e, id: Self.ext), enabled: true, trusted: true)
        let o = kitPaneOwner(e) { [rec] }
        let rt = try XCTUnwrap(o.runtime(for: Self.ext))
        let res = await rt.apply(rec.loaded, source: .local, otherKitSlugs: [])
        XCTAssertTrue(res.refused == nil && res.failures.isEmpty, "\(String(describing: res.refused)) \(res.failures)")
        let bin = try KitStore.layout(configHome: e.roots.configHome, extID: Self.ext).bin
        XCTAssertEqual(AgentIslandController.spawnEnv(Self.base, argv: ["claude"], AgentIslandController().sessionEnvContributors()),
                       AgentIsland.spawnEnv(Self.base), "no owner: no bins")
        KitRuntimes.shared = o
        let env = AgentIslandController.spawnEnv(Self.base, argv: ["claude"], AgentIslandController().sessionEnvContributors())
        XCTAssertEqual(env["PATH"], "/Users/example/bin:/usr/bin:" + bin, "the kit bin last")
    }

    // MARK: R1423-i2: a live bin only when validated

    /// A relaunch (a new owner over the same roots) lists nothing until the live kit is validated again; a live copy
    /// that restoreKits refuses ("not validated again") stays out; once it validates, its bin is listed.
    func testLiveBinsSkipAKitNotValidatedAgain() async throws {
        let e = try kitPaneEnv()
        let rec = ExtensionRecord(loaded: try kitPaneSource(e, id: Self.ext), enabled: true, trusted: true)
        let first = kitPaneOwner(e) { [rec] }
        let firstRT = try XCTUnwrap(first.runtime(for: Self.ext))
        let applied = await firstRT.apply(rec.loaded, source: .local, otherKitSlugs: [])
        XCTAssertTrue(applied.refused == nil && applied.failures.isEmpty, "\(String(describing: applied.refused)) \(applied.failures)")
        let layout = try KitStore.layout(configHome: e.roots.configHome, extID: Self.ext)
        XCTAssertEqual(first.liveBins(), [layout.bin], "validated by its own apply")

        let again = kitPaneOwner(e) { [rec] }
        let rt = try XCTUnwrap(again.runtime(for: Self.ext))
        XCTAssertEqual(rt.current?.live.version, "1.0.0", "the state file still names a live version")
        XCTAssertEqual(again.liveBins(), [], "after a relaunch, not validated yet")

        let toml = URL(fileURLWithPath: layout.live).appendingPathComponent("extension.toml")
        let original = try Data(contentsOf: toml)
        let mode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: toml.path)[.posixPermissions] as? NSNumber)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: toml.path)
        try Data(String(decoding: original, as: UTF8.self).replacingOccurrences(of: "\"1.0.0\"", with: "\"1.0.9\"").utf8).write(to: toml)
        let refused = await rt.refresh(rec.loaded)
        XCTAssertTrue(refused?.notes.contains { $0.hasSuffix(KitPaneModel.notValidated) } == true, "\(String(describing: refused?.notes))")
        XCTAssertEqual(again.liveBins(), [], "not validated again: no bin")

        try original.write(to: toml)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: toml.path) // the tree hash counts modes
        let ok = await rt.refresh(rec.loaded)
        XCTAssertEqual(ok?.live, "1.0.0", "\(String(describing: ok?.notes))")
        XCTAssertEqual(again.liveBins(), [layout.bin], "validated again: listed")
    }

    /// Counts the config provider's get() calls (a spawn's liveBins must make none).
    final class Gets: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func hit() { lock.withLock { n += 1 } }
        var count: Int { lock.withLock { n } }
    }

    /// The supervisor's ruling on R1423-i2: liveBins reads the runtime's validated live entry under its lock only, so a
    /// spawn's read makes no config provider call. Validated (own apply): listed; after a relaunch: not; after an update
    /// and a relaunch whose live copy is refused while the previous one validates: not (the live version decides).
    func testLiveBinsMakeNoProviderCallAndNeedTheLiveVersionValidated() async throws {
        final class Box { var rec: ExtensionRecord? }
        let e = try kitPaneEnv()
        guard case .success(let config) = e.provider.get() else { return XCTFail("the row's config") }
        let gets = Gets()
        let counting = type(of: e.provider).init(make: { gets.hit(); return .success(config) }, stateOnly: { config })
        let box = Box()
        box.rec = ExtensionRecord(loaded: try kitPaneSource(e, id: Self.ext), enabled: true, trusted: true)
        func owner() -> KitRuntimes {
            KitRuntimes(configHome: e.roots.configHome, records: { box.rec.map { [$0] } ?? [] }, loginPath: { "/Users/example/bin" },
                        make: { store, trusted in KitRuntime(provider: counting, store: store, isTrusted: trusted) })
        }
        let layout = try KitStore.layout(configHome: e.roots.configHome, extID: Self.ext)
        let first = owner()
        let rt = try XCTUnwrap(first.runtime(for: Self.ext))
        let one = await rt.apply(try XCTUnwrap(box.rec).loaded, source: .local, otherKitSlugs: [])
        XCTAssertTrue(one.refused == nil && one.failures.isEmpty, "\(String(describing: one.refused)) \(one.failures)")
        let before = gets.count
        XCTAssertEqual(first.liveBins(), [layout.bin], "validated by its own apply")
        KitRuntimes.shared = first
        let env = AgentIslandController.spawnEnv(Self.base, argv: ["claude"], AgentIslandController().sessionEnvContributors())
        XCTAssertEqual(env["PATH"], "/Users/example/bin:/usr/bin:" + layout.bin)
        XCTAssertEqual(gets.count, before, "no provider call at the spawn's read")

        box.rec = ExtensionRecord(loaded: try kitPaneSource(e, id: Self.ext, version: "1.0.1"), enabled: true, trusted: true)
        let two = await rt.apply(try XCTUnwrap(box.rec).loaded, source: .local, otherKitSlugs: [])
        XCTAssertTrue(two.refused == nil && two.failures.isEmpty, "\(String(describing: two.refused)) \(two.failures)")
        let again = owner()
        let rt2 = try XCTUnwrap(again.runtime(for: Self.ext))
        XCTAssertEqual(rt2.current?.live.version, "1.0.1")
        XCTAssertEqual(rt2.current?.previous?.version, "1.0.0", "the update kept a previous copy")
        let n = gets.count
        XCTAssertEqual(again.liveBins(), [], "after a relaunch, not validated yet")
        XCTAssertEqual(gets.count, n, "no provider call")

        let toml = URL(fileURLWithPath: layout.live).appendingPathComponent("extension.toml")
        let original = try Data(contentsOf: toml)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: toml.path)
        try Data(String(decoding: original, as: UTF8.self).replacingOccurrences(of: "\"1.0.1\"", with: "\"1.0.9\"").utf8).write(to: toml)
        let st = await rt2.refresh(try XCTUnwrap(box.rec).loaded)
        let notes = st?.notes ?? []
        XCTAssertTrue(notes.contains { $0.hasPrefix("kit 1.0.1 ") && $0.hasSuffix(KitPaneModel.notValidated) }, "\(notes)")
        XCTAssertFalse(notes.contains { $0.hasPrefix("kit 1.0.0 ") }, "the previous copy validated: \(notes)")
        XCTAssertEqual(again.liveBins(), [], "the live version is not validated, the previous one is: no bin")
    }

    // MARK: R1424-s1: the Update control's version

    /// The Update control's title and label carry the header's cleaned, capped version, never the raw one.
    func testUpdateControlVersionIsCleanedAndCapped() async throws {
        final class Box { var rec: ExtensionRecord? }
        let e = try kitPaneEnv()
        let box = Box()
        box.rec = ExtensionRecord(loaded: try kitPaneSource(e, id: Self.ext), enabled: true, trusted: true)
        let m = KitPaneModel(extID: Self.ext, owner: kitPaneOwner(e) { box.rec.map { [$0] } ?? [] })
        await m.load()?.value
        await m.apply()?.value
        XCTAssertEqual(m.result, "done")
        let raw = "1.0.1\u{202E}" + String(repeating: "9", count: 100)
        box.rec = ExtensionRecord(loaded: try kitPaneSource(e, id: Self.ext, version: raw), enabled: true, trusted: true)
        await m.load()?.value
        let update = KitPaneView.controls(m).first { $0.id == "update" }
        let shown = OutsideText.shown(raw, max: 64)
        XCTAssertLessThanOrEqual(shown.count, 64)
        XCTAssertEqual(update?.title, "Update to " + shown)
        XCTAssertEqual(update?.label, "Update Calm Agent Kit to version " + shown)
        XCTAssertFalse((update?.title ?? "\u{202E}").unicodeScalars.contains("\u{202E}"), "no bidi control")
        XCTAssertFalse((update?.label ?? "\u{202E}").unicodeScalars.contains("\u{202E}"), "no bidi control")
    }
}
