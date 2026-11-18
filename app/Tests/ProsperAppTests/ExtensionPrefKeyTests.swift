import XCTest
@testable import ProsperApp

/// #1542: an extension id that is a prefix of another (com.prosper vs com.prosper.x) must not reach the other's
/// prefs through the "ext.<id>.<key>" name. Every row uses a scratch suite, never the app's defaults.
final class ExtensionPrefKeyTests: XCTestCase {

    private let short = "com.example"
    private let long = "com.example.x"

    func testPrefixIDsDoNotReadOrOverwriteEachOther() {
        let d = scratchDefaults("prefkey")
        let host = LiveExtensionHostServices(defaults: d)
        host.prefSet(extensionID: long, key: "foo", value: "long-value")
        XCTAssertTrue(host.prefGet(extensionID: short, key: "x.foo") == nil, "the shorter id read the longer id's key")

        host.prefSet(extensionID: short, key: "x.foo", value: "short-value")
        XCTAssertEqual(host.prefGet(extensionID: long, key: "foo"), "long-value")
        XCTAssertEqual(host.prefGet(extensionID: short, key: "x.foo"), "short-value")

        host.prefSet(extensionID: long, key: "foo", value: "long-2")
        XCTAssertEqual(host.prefGet(extensionID: short, key: "x.foo"), "short-value")
        XCTAssertEqual(host.prefGet(extensionID: long, key: "foo"), "long-2")
    }

    /// The host has no remove: an extension clears a pref by setting "" (appupdates does). Each side's clear
    /// leaves the other's value alone.
    func testClearingOneIDLeavesTheOther() {
        let d = scratchDefaults("prefkey")
        let host = LiveExtensionHostServices(defaults: d)
        host.prefSet(extensionID: long, key: "foo", value: "long-value")
        host.prefSet(extensionID: short, key: "x.foo", value: "short-value")

        host.prefSet(extensionID: short, key: "x.foo", value: "")
        XCTAssertEqual(host.prefGet(extensionID: long, key: "foo"), "long-value")
        host.prefSet(extensionID: short, key: "x.foo", value: "short-value")
        host.prefSet(extensionID: long, key: "foo", value: "")
        XCTAssertEqual(host.prefGet(extensionID: short, key: "x.foo"), "short-value")
    }

    /// Hostile shapes: trailing and doubled dots, an empty key, the escape text itself. Every pair from two
    /// different ids gets its own name (a literal list, each pair one collision before #1542).
    func testHostileIDsAndKeysNeverShareAName() {
        let pairs: [(id: String, key: String)] = [
            ("com.example", "x.foo"), ("com.example.x", "foo"),
            ("a.", "b"), ("a", ".b"),
            ("a.b", ""), ("a", "b."),
            ("a..b", "c"), ("a", ".b.c"),
            ("", ".a"), (".", "a"),
        ]
        let names = pairs.map { LiveExtensionHostServices.prefKey($0.id, $0.key) }
        XCTAssertEqual(Set(names).count, pairs.count, "two ids share a pref name: \(names)")
        XCTAssertEqual(LiveExtensionHostServices.prefKey("com.example", "x.foo"), "ext.com.example.x%2Efoo")
        XCTAssertEqual(LiveExtensionHostServices.prefKey("a.b", ""), "ext.a.b.")

        let d = scratchDefaults("prefkey")
        let host = LiveExtensionHostServices(defaults: d)
        host.prefSet(extensionID: "a.", key: "b", value: "one")
        host.prefSet(extensionID: "a", key: ".b", value: "two")
        XCTAssertEqual(host.prefGet(extensionID: "a.", key: "b"), "one")
        XCTAssertEqual(host.prefGet(extensionID: "a", key: ".b"), "two")
    }

    /// A key with no dot keeps its pre-#1542 name, so the native stores (snippets items, quicklinks links,
    /// quickdirs dirs, currency fetchedAt) and values saved before the change read back unchanged.
    func testUndottedKeysKeepTheirOldName() {
        XCTAssertEqual(LiveExtensionHostServices.prefKey("com.prosper.snippets", "items"),
                       "ext.com.prosper.snippets.items")
        XCTAssertEqual(LiveExtensionHostServices.prefKey("com.prosper.currency", "fetchedAt"),
                       "ext.com.prosper.currency.fetchedAt")
        let d = scratchDefaults("prefkey")
        d.set("old-value", forKey: "ext.com.example.plain")
        XCTAssertEqual(LiveExtensionHostServices(defaults: d).prefGet(extensionID: "com.example", key: "plain"),
                       "old-value")
    }

    /// A dotted key saved before #1542 reads back after the migration; a second run changes nothing and never
    /// overwrites a value written since.
    func testMigrationKeepsOldDottedKeysAndRunsTwice() {
        let d = scratchDefaults("prefkey")
        d.set("false", forKey: "ext.com.example.bookmarks.source.safari")
        let ids = ["com.example.bookmarks"]
        LiveExtensionHostServices.migrateDottedPrefKeys(ids: ids, in: d)
        let host = LiveExtensionHostServices(defaults: d)
        XCTAssertEqual(host.prefGet(extensionID: "com.example.bookmarks", key: "source.safari"), "false")
        XCTAssertEqual(d.string(forKey: "ext.com.example.bookmarks.source.safari"), "false", "the old name was removed")

        let afterOne = d.dictionaryRepresentation().filter { $0.key.hasPrefix("ext.") }.mapValues { "\($0)" }
        LiveExtensionHostServices.migrateDottedPrefKeys(ids: ids, in: d)
        let afterTwo = d.dictionaryRepresentation().filter { $0.key.hasPrefix("ext.") }.mapValues { "\($0)" }
        XCTAssertEqual(afterOne, afterTwo)

        host.prefSet(extensionID: "com.example.bookmarks", key: "source.safari", value: "true")
        LiveExtensionHostServices.migrateDottedPrefKeys(ids: ids, in: d)
        XCTAssertEqual(host.prefGet(extensionID: "com.example.bookmarks", key: "source.safari"), "true")
    }

    /// The old name "ext.com.example.x.foo" is now com.example.x's own "foo": with that id loaded the migration
    /// does not hand it to com.example as "x.foo". A dotted key no loaded id can claim is still migrated.
    func testMigrationLeavesALoadedLongerIDsKeyAlone() {
        let d = scratchDefaults("prefkey")
        d.set("long-value", forKey: "ext.com.example.x.foo")
        d.set("short-value", forKey: "ext.com.example.y.k")
        LiveExtensionHostServices.migrateDottedPrefKeys(ids: [short, long], in: d)
        let host = LiveExtensionHostServices(defaults: d)
        XCTAssertTrue(host.prefGet(extensionID: short, key: "x.foo") == nil, "the migration gave the shorter id the longer id's key")
        XCTAssertEqual(host.prefGet(extensionID: long, key: "foo"), "long-value")
        XCTAssertEqual(host.prefGet(extensionID: short, key: "y.k"), "short-value")
    }

    /// #1596 row 1: migrated once with com.example.x loaded; once it is gone (uninstalled with prefs kept, or
    /// refused) the next run must not hand its old "foo" or its post-update "bar" to com.example as "x.foo"/"x.bar".
    func testMigrationDoesNotRunAgainAfterTheLongerIDIsUnloaded() {
        let d = scratchDefaults("prefkey")
        d.set("long-value", forKey: "ext.com.example.x.foo")
        LiveExtensionHostServices.migrateDottedPrefKeys(ids: [short, long], in: d)
        XCTAssertTrue(d.bool(forKey: LiveExtensionHostServices.dottedPrefsMigratedKey), "the first run set no marker")
        let host = LiveExtensionHostServices(defaults: d)
        host.prefSet(extensionID: long, key: "bar", value: "long-later")

        LiveExtensionHostServices.migrateDottedPrefKeys(ids: [short], in: d)
        XCTAssertTrue(host.prefGet(extensionID: short, key: "x.foo") == nil, "the shorter id read the unloaded id's key")
        XCTAssertTrue(host.prefGet(extensionID: short, key: "x.bar") == nil, "the shorter id read the unloaded id's later write")
        let copied = d.dictionaryRepresentation().keys.filter { $0.hasPrefix("ext.com.example.x%2E") }
        XCTAssertEqual(copied, [], "a later run made new names")
    }

    /// #1596 row 2: with the marker set, a run copies nothing, even a fresh dotted key of a loaded id.
    func testMigrationCopiesNothingOnceTheMarkerIsSet() {
        let d = scratchDefaults("prefkey")
        d.set(true, forKey: LiveExtensionHostServices.dottedPrefsMigratedKey)
        d.set("fresh", forKey: "ext.com.example.y.k")
        let before = d.dictionaryRepresentation().filter { $0.key.hasPrefix("ext.") }.mapValues { "\($0)" }
        LiveExtensionHostServices.migrateDottedPrefKeys(ids: [short], in: d)
        let after = d.dictionaryRepresentation().filter { $0.key.hasPrefix("ext.") }.mapValues { "\($0)" }
        XCTAssertEqual(before, after)
        XCTAssertTrue(d.object(forKey: "ext.com.example.y%2Ek") == nil, "a marked domain was migrated again")
    }

    /// #1596 row 3: the first run still migrates, never overwrites a new name already set, and an empty scan
    /// (no id found) does not use up the one run.
    func testFirstRunMigratesWithoutOverwritingAndAnEmptyScanSetsNoMarker() {
        let d = scratchDefaults("prefkey")
        d.set("old", forKey: "ext.com.example.y.k")
        d.set("old", forKey: "ext.com.example.y.z")
        d.set("newer", forKey: "ext.com.example.y%2Ez")
        LiveExtensionHostServices.migrateDottedPrefKeys(ids: [], in: d)
        XCTAssertFalse(d.bool(forKey: LiveExtensionHostServices.dottedPrefsMigratedKey), "an empty scan set the marker")
        LiveExtensionHostServices.migrateDottedPrefKeys(ids: [short], in: d)
        XCTAssertEqual(d.string(forKey: "ext.com.example.y%2Ek"), "old")
        XCTAssertEqual(d.string(forKey: "ext.com.example.y%2Ez"), "newer", "the migration overwrote a newer value")
        XCTAssertTrue(d.bool(forKey: LiveExtensionHostServices.dottedPrefsMigratedKey))
    }

    /// discover() runs the migration on the registry's defaults, so an installed extension's old dotted key
    /// reads back on the next launch.
    @MainActor
    func testDiscoverMigratesOldDottedKeys() throws {
        let systemRoot = tempDir()
        let userRoot = tempDir()
        let dir = systemRoot.appendingPathComponent("prefkeyprobe", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Self.manifest.write(to: dir.appendingPathComponent("extension.toml"), atomically: true, encoding: .utf8)
        try "".write(to: dir.appendingPathComponent("init.lua"), atomically: true, encoding: .utf8)
        let d = scratchDefaults("prefkey")
        d.set("kept", forKey: "ext.com.test.prefkeyprobe.source.safari")
        let registry = ExtensionRegistry(systemDir: systemRoot, userDir: userRoot, hostVersion: "2.0.0",
                                         defaults: d, services: LiveExtensionHostServices(defaults: d))
        registry.discover()
        try XCTSkipIf(registry.record(id: "com.test.prefkeyprobe") == nil, "synthetic ext not discovered")
        XCTAssertEqual(d.string(forKey: "ext.com.test.prefkeyprobe.source%2Esafari"), "kept")

        // #1596: a later discover (each launch, each uninstall) migrates nothing more.
        d.set("fresh", forKey: "ext.com.test.prefkeyprobe.source.chrome")
        registry.discover()
        XCTAssertTrue(d.object(forKey: "ext.com.test.prefkeyprobe.source%2Echrome") == nil, "discover migrated again")
    }

    private static let manifest = """
    [extension]
    id = "com.test.prefkeyprobe"
    name = "prefkeyprobe"
    title = "Pref Key Probe"
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
    id = "prefkeyprobe.noop"
    title = "Noop"
    mode = "no-view"
    """
}
