import AppKit
import Foundation
import XCTest
@testable import ProsperApp

/// #1811: extensions.list / enable / disable over a fake registry (temp dirs, scratch defaults) and themes.list / set
/// over ThemeStore.shared with fake descriptors (its writes land in the in-memory XCTest defaults; each row restores).
@MainActor
final class ControlExtensionsTests: XCTestCase {
    private var notices: [String] = []
    private var defaults: UserDefaults!

    private func write(_ root: URL, _ sub: String, id: String, title: String, system: Bool, commands: Int) throws {
        let dir = root.appendingPathComponent(sub, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var toml = """
        [extension]
        id          = "\(id)"
        name        = "\(sub.split(separator: "/").last ?? "x")"
        title       = "\(title)"
        description = "Test fixture"
        version     = "1.2.3"
        author      = "example"
        license     = "MIT"
        system      = \(system)

        [extension.host]
        min_version = "2.0.0"
        api_level   = 1

        [extension.entry]
        main = "init.lua"

        """
        for i in 0..<commands {
            toml += """

            [[contributes.commands]]
            id    = "\(id).c\(i)"
            title = "Command \(i)"
            mode  = "no-view"
            match = "^__never\(i)__"

            """
        }
        try toml.write(to: dir.appendingPathComponent("extension.toml"), atomically: true, encoding: .utf8)
        try "".write(to: dir.appendingPathComponent("init.lua"), atomically: true, encoding: .utf8)
    }

    /// One trusted system extension with two commands, one user extension the user has not trusted.
    private func fakeRegistry() throws -> ExtensionRegistry {
        let root = tempDir()
        try write(root, "system/fake", id: "com.example.fake", title: "Fake Tools", system: true, commands: 2)
        try write(root, "user/stranger", id: "com.example.stranger", title: "Stranger", system: false, commands: 1)
        defaults = scratchDefaults("ctlext")
        defaults.set([String](), forKey: "trustedExtensionIDs") // the trust gate is past its first run: nothing trusted
        let registry = ExtensionRegistry(systemDir: root.appendingPathComponent("system"),
                                         userDir: root.appendingPathComponent("user"),
                                         hostVersion: "2.0.0", defaults: defaults)
        registry.discover()
        addTeardownBlock { @MainActor in ControlExtensions.registry = { (NSApp?.delegate as? AppDelegate)?.extensionRegistry } }
        ControlExtensions.registry = { registry }
        return registry
    }

    private func registry() -> ControlRegistry {
        var r = ControlRegistry()
        ControlRegistry.registerExtensions(&r)
        let changes = ControlChanges()
        changes.present = { [weak self] text, _ in self?.notices.append(text) }
        r.changes = changes
        return r
    }

    private func call(_ reg: ControlRegistry, _ cmd: String, _ args: [String: ControlJSON] = [:]) async -> ControlReply {
        await reg.reply(to: try! JSONEncoder().encode(ControlRequest(cmd: cmd, args: args)))
    }

    private func rows(_ reply: ControlReply, _ key: String) -> [String: [String: ControlJSON]] {
        guard case .object(let o)? = reply.result, case .array(let list)? = o[key] else { return [:] }
        var out: [String: [String: ControlJSON]] = [:]
        for case .object(let a) in list { if case .string(let id)? = a["id"] { out[id] = a } }
        return out
    }

    // MARK: extensions

    func testListCarriesEveryFieldForEachExtension() async throws {
        _ = try fakeRegistry()
        let reply = await call(registry(), "extensions.list")
        XCTAssertTrue(reply.ok, "\(reply)")
        let all = rows(reply, "extensions")
        XCTAssertEqual(all.count, 2, "\(all.keys.sorted())")
        let fake = all["com.example.fake"]
        XCTAssertEqual(fake?["title"], .string("Fake Tools"))
        XCTAssertEqual(fake?["version"], .string("1.2.3"))
        XCTAssertEqual(fake?["enabled"], .bool(true))
        XCTAssertEqual(fake?["trusted"], .bool(true))
        XCTAssertEqual(fake?["builtIn"], .bool(true))
        XCTAssertEqual(fake?["commands"], .number(2))
        let stranger = all["com.example.stranger"]
        XCTAssertEqual(stranger?["trusted"], .bool(false))
        XCTAssertEqual(stranger?["builtIn"], .bool(false))
        XCTAssertEqual(stranger?["commands"], .number(1))
        XCTAssertTrue(notices.isEmpty, "a list changes nothing")
    }

    func testDisableAndEnableGoThroughTheRegistryAndUndoFlipsBack() async throws {
        let ext = try fakeRegistry()
        let reg = registry()
        let off = await call(reg, "extensions.disable", ["id": .string("com.example.fake")])
        XCTAssertTrue(off.ok, "\(off)")
        XCTAssertEqual(ext.record(id: "com.example.fake")?.enabled, false)
        XCTAssertEqual(defaults.stringArray(forKey: "disabledExtensionIDs"), ["com.example.fake"], "persisted as the pane's toggle does")
        XCTAssertTrue(ext.command(id: "com.example.fake.c0") == nil, "routes rebuilt without it")
        XCTAssertEqual(notices.last, "Agent changed: Fake Tools off")
        guard case .object(let row)? = off.result else { return XCTFail("\(off)") }
        XCTAssertEqual(row["enabled"], .bool(false))

        XCTAssertTrue(reg.changes.undo(reg.changes.entries.last?.id ?? -1))
        XCTAssertEqual(ext.record(id: "com.example.fake")?.enabled, true, "undo turns it back on")
        XCTAssertTrue(ext.command(id: "com.example.fake.c0") != nil, "routed again")
        XCTAssertEqual(defaults.stringArray(forKey: "disabledExtensionIDs") ?? [], [])

        try ext.setEnabled(false, id: "com.example.fake")
        let on = await call(reg, "extensions.enable", ["id": .string("com.example.fake")])
        XCTAssertTrue(on.ok, "\(on)")
        XCTAssertEqual(ext.record(id: "com.example.fake")?.enabled, true)
        XCTAssertEqual(notices.last, "Agent changed: Fake Tools on")
        XCTAssertTrue(reg.changes.undo(reg.changes.entries.last?.id ?? -1))
        XCTAssertEqual(ext.record(id: "com.example.fake")?.enabled, false, "undo of an enable turns it back off")
    }

    /// setEnabled is not a no-op (drops the async runtime, rebuilds routes), so a same-state call never reaches it.
    func testSameStateIsRefusedWithoutTouchingTheRegistry() async throws {
        let ext = try fakeRegistry()
        var hits = 0
        ext.onEnabledChanged = { hits += 1 }
        let reg = registry()
        let on = await call(reg, "extensions.enable", ["id": .string("com.example.fake")])
        XCTAssertEqual(on.error, "Fake Tools is already on")
        try ext.setEnabled(false, id: "com.example.fake")
        XCTAssertEqual(hits, 1)
        let off = await call(reg, "extensions.disable", ["id": .string("com.example.fake")])
        XCTAssertEqual(off.error, "Fake Tools is already off")
        XCTAssertEqual(hits, 1, "the registry's setEnabled was never called by the control")
        XCTAssertTrue(reg.changes.entries.isEmpty)
        XCTAssertTrue(notices.isEmpty)
    }

    func testUntrustedExtensionIsRefusedWithTheReasonAndNothingChanges() async throws {
        let ext = try fakeRegistry()
        let reg = registry()
        for cmd in ["extensions.enable", "extensions.disable"] {
            let reply = await call(reg, cmd, ["id": .string("com.example.stranger")])
            XCTAssertFalse(reply.ok, cmd)
            XCTAssertTrue(reply.error?.contains("needs a trust approval") == true, "\(reply)")
        }
        XCTAssertEqual(ext.record(id: "com.example.stranger")?.enabled, true)
        XCTAssertEqual(ext.record(id: "com.example.stranger")?.trusted, false)
        XCTAssertTrue(reg.changes.entries.isEmpty)
        XCTAssertTrue(notices.isEmpty)
    }

    func testUnknownIdAndAMissingRegistryAreErrors() async throws {
        _ = try fakeRegistry()
        let reg = registry()
        let unknown = await call(reg, "extensions.disable", ["id": .string("com.example.nope")])
        XCTAssertTrue(unknown.error?.contains("unknown extension") == true, "\(unknown)")
        ControlExtensions.registry = { nil }
        let list = await call(reg, "extensions.list")
        XCTAssertEqual(list.error, "extensions are not loaded yet")
        XCTAssertTrue(reg.changes.entries.isEmpty)
    }

    // MARK: extensions.update (#1869): market seams only (index, download into the row's tempDir), never the network

    private struct UpdateFixture { let ext: ExtensionRegistry; let root: URL; let fetched: FetchLog }

    private func writeUser(_ dir: URL, id: String, version: String, permissions: [String] = [], market: Bool = true,
                           url: String? = nil, tail: String = "") throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let perms = permissions.isEmpty ? "" : "permissions = [" + permissions.map { "\"\($0)\"" }.joined(separator: ", ") + "]\n"
        let source = url ?? (market ? "prosper://market/\(id)" : nil)
        try ("""
        [extension]
        id = "\(id)"
        name = "\(id.split(separator: ".").last ?? "x")"
        title = "Upd \(id.split(separator: ".").last ?? "x")"
        description = "Test fixture"
        version = "\(version)"
        author = "example"
        \(perms)\(source.map { "update_url = \"\($0)\"\n" } ?? "")
        [extension.host]
        min_version = "2.0.0"
        api_level = 1

        [extension.entry]
        main = "init.lua"
        """ + "\n" + tail).write(to: dir.appendingPathComponent("extension.toml"), atomically: true, encoding: .utf8)
        try "-- \(version)".write(to: dir.appendingPathComponent("init.lua"), atomically: true, encoding: .utf8)
    }

    /// A system extension, two trusted market extensions at 1.0.0 (alpha, beta) and one with no update source. The index
    /// lists `listed`; a download of <id> copies the source written by `offer` (1.1.0 with `newPerms` for alpha).
    private func updateFixture(listed: [String: String], newPerms: [String] = [], fail: Bool = false) throws -> UpdateFixture {
        let root = tempDir()
        try write(root, "system/fake", id: "com.example.fake", title: "Fake Tools", system: true, commands: 0)
        let user = root.appendingPathComponent("user")
        for id in ["com.example.alpha", "com.example.beta"] {
            try writeUser(user.appendingPathComponent(id), id: id, version: "1.0.0")
            try writeUser(root.appendingPathComponent("offer/\(id)"), id: id, version: "1.1.0",
                          permissions: id == "com.example.alpha" ? newPerms : [])
        }
        try writeUser(user.appendingPathComponent("com.example.local"), id: "com.example.local", version: "1.0.0", market: false)
        defaults = scratchDefaults("ctlext-update")
        defaults.set([String](), forKey: "trustedExtensionIDs")
        let ext = ExtensionRegistry(systemDir: root.appendingPathComponent("system"), userDir: user,
                                    hostVersion: "2.0.0", defaults: defaults)
        ext.discover()
        for id in ["com.example.alpha", "com.example.beta"] { try ext.trust(id: id) }
        let work = root.appendingPathComponent("work"), fetched = FetchLog()
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        ext.marketTempRoot = work
        ext.marketIndex = { listed }
        ext.marketFetch = { id, _ in
            let n = fetched.add(id)
            if fail { throw FakeDownloadError() }
            let folder = work.appendingPathComponent("prosper-market-\(n)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let dir = folder.appendingPathComponent("src", isDirectory: true)
            try FileManager.default.copyItem(at: root.appendingPathComponent("offer/\(id)"), to: dir)
            return dir
        }
        addTeardownBlock { @MainActor in ControlExtensions.registry = { (NSApp?.delegate as? AppDelegate)?.extensionRegistry } }
        ControlExtensions.registry = { ext }
        return UpdateFixture(ext: ext, root: root, fetched: fetched)
    }

    private func version(_ f: UpdateFixture, _ id: String) -> String? { f.ext.record(id: id)?.manifest.extension.version }

    func testUpdateInstallsANewerVersionReportsUpToDateAndHasNoUndo() async throws {
        let f = try updateFixture(listed: ["com.example.alpha": "1.1.0", "com.example.beta": "1.0.0"])
        let reg = registry()
        let reply = await call(reg, "extensions.update")
        XCTAssertTrue(reply.ok, "\(reply)")
        let all = rows(reply, "results")
        XCTAssertEqual(all.keys.sorted(), ["com.example.alpha", "com.example.beta"], "user extensions with an update source only")
        XCTAssertEqual(all["com.example.alpha"], ["id": .string("com.example.alpha"), "from": .string("1.0.0"),
                                                  "to": .string("1.1.0"), "outcome": .string("updated")])
        XCTAssertEqual(all["com.example.beta"], ["id": .string("com.example.beta"), "from": .string("1.0.0"), "outcome": .string("upToDate")])
        XCTAssertEqual(version(f, "com.example.alpha"), "1.1.0")
        XCTAssertEqual(version(f, "com.example.beta"), "1.0.0")
        XCTAssertEqual(f.fetched.ids, ["com.example.alpha"])
        XCTAssertEqual(reg.changes.entries.last?.command, "extensions.update")
        XCTAssertTrue(notices.last?.contains("1 updated, 0 held, 0 failed (no Undo") == true, "\(notices)")
        XCTAssertFalse(reg.changes.undo(reg.changes.entries.last?.id ?? -1), "an update is a reinstall: no Undo")
        XCTAssertTrue(defaults.object(forKey: "extensionsUpdateLastCheck") != nil, "a check of all of them sets the daily date")
    }

    /// The person's alert is the registry's seam: a recorder that would accept, so an asked update would install.
    func testUpdateAddingAPermissionIsHeldWithoutAnAlert() async throws {
        let f = try updateFixture(listed: ["com.example.alpha": "1.1.0"], newPerms: ["full-disk-access"])
        var asked = 0
        f.ext.reviewNewPermissions = { _, _ in asked += 1; return true }
        let reg = registry()
        for pass in 1...2 {
            let reply = await call(reg, "extensions.update")
            XCTAssertTrue(reply.ok, "\(reply)")
            let alpha = rows(reply, "results")["com.example.alpha"]
            XCTAssertEqual(alpha?["outcome"], .string("held"), "pass \(pass)")
            XCTAssertEqual(alpha?["to"], .string("1.1.0"))
            guard case .string(let why)? = alpha?["reason"] else { return XCTFail("pass \(pass): \(reply)") }
            XCTAssertTrue(why.contains("full-disk-access"), why)
        }
        XCTAssertEqual(asked, 0, "extensions.update never shows the new-permissions alert")
        XCTAssertEqual(f.fetched.ids, ["com.example.alpha"], "a held pair is not downloaded again")
        XCTAssertEqual(version(f, "com.example.alpha"), "1.0.0")
        XCTAssertTrue(f.ext.updateWaitingNote(id: "com.example.alpha") != nil, "held for the person's Check for Updates")
        XCTAssertTrue(f.ext.isTrusted(id: "com.example.alpha"))
    }

    func testFailedDownloadIsReportedWithACleanedReason() async throws {
        let f = try updateFixture(listed: ["com.example.alpha": "1.1.0"], fail: true)
        let reply = await call(registry(), "extensions.update", ["id": .string("com.example.alpha")])
        XCTAssertTrue(reply.ok, "\(reply)")
        let alpha = rows(reply, "results")["com.example.alpha"]
        XCTAssertEqual(alpha?["outcome"], .string("failed"))
        XCTAssertEqual(alpha?["to"], .string("1.1.0"))
        guard case .string(let why)? = alpha?["reason"] else { return XCTFail("\(reply)") }
        XCTAssertTrue(why.contains("the server said no") && !why.contains("\u{7}"), why)
        XCTAssertEqual(version(f, "com.example.alpha"), "1.0.0")
    }

    func testUpdateOfOneIdLeavesTheOthersAndTheDailyDateAlone() async throws {
        let f = try updateFixture(listed: ["com.example.alpha": "1.1.0", "com.example.beta": "1.1.0"])
        let reply = await call(registry(), "extensions.update", ["id": .string("com.example.beta")])
        XCTAssertTrue(reply.ok, "\(reply)")
        XCTAssertEqual(rows(reply, "results").keys.sorted(), ["com.example.beta"])
        XCTAssertEqual(version(f, "com.example.beta"), "1.1.0")
        XCTAssertEqual(version(f, "com.example.alpha"), "1.0.0", "the other updatable extension is untouched")
        XCTAssertEqual(f.fetched.ids, ["com.example.beta"])
        XCTAssertTrue(defaults.object(forKey: "extensionsUpdateLastCheck") == nil, "one id does not postpone the daily check")
    }

    func testUpdateRefusesAnUnknownABuiltInAndANonUpdatableId() async throws {
        let f = try updateFixture(listed: ["com.example.alpha": "1.1.0"])
        let reg = registry()
        let cases = [("com.example.nope", "unknown extension 'com.example.nope'"), ("com.example.fake", "com.example.fake is built in"),
                     ("com.example.local", "com.example.local has no update source")]
        for (id, text) in cases {
            let reply = await call(reg, "extensions.update", ["id": .string(id)])
            XCTAssertTrue(reply.error?.contains(text) == true, "\(id): \(reply)")
        }
        XCTAssertTrue(f.fetched.ids.isEmpty)
        XCTAssertEqual(version(f, "com.example.alpha"), "1.0.0")
        XCTAssertTrue(reg.changes.entries.isEmpty, "a refusal logs nothing")
    }

    // MARK: extensions.update, the GitHub path (#1870): the registry's remoteFetch seam, never the network

    private struct GitHubFixture {
        let ext: ExtensionRegistry; let root: URL; let fetched: FetchLog; let caps: FetchLog
        func installedManifest(_ id: String) throws -> String {
            try String(contentsOf: root.appendingPathComponent("user/\(id)/extension.toml"), encoding: .utf8)
        }
    }

    private static let kitTail = """
    [contributes.kit]
    schema = 1

    [[contributes.kit.pieces]]
    id = "perms"
    kind = "permissions"
    allow = ["Bash(calm-note:*)"]
    """

    /// Trusted alpha and beta at 1.0.0 with a github.com update_url; a fetch of one copies its 1.1.0 offer (no update_url:
    /// the registry stamps it). `fetch` replaces the copy (a refusal, a wait for cancellation); `kit` makes both agent kits.
    private func githubFixture(kit: Bool = false, fetch: (@Sendable (String) async throws -> Void)? = nil) throws -> GitHubFixture {
        let root = tempDir(), user = root.appendingPathComponent("user")
        try write(root, "system/fake", id: "com.example.fake", title: "Fake Tools", system: true, commands: 0)
        let ids = ["com.example.alpha", "com.example.beta"]
        for id in ids {
            try writeUser(user.appendingPathComponent(id), id: id, version: "1.0.0", market: false,
                          url: "https://github.com/example/\(id)", tail: kit ? Self.kitTail : "")
            try writeUser(root.appendingPathComponent("offer/\(id)"), id: id, version: "1.1.0", market: false, tail: kit ? Self.kitTail : "")
        }
        defaults = scratchDefaults("ctlext-github")
        defaults.set([String](), forKey: "trustedExtensionIDs")
        let ext = ExtensionRegistry(systemDir: root.appendingPathComponent("system"), userDir: user, hostVersion: "2.0.0", defaults: defaults)
        ext.discover()
        for id in ids { try ext.trust(id: id) }
        let work = root.appendingPathComponent("work"), fetched = FetchLog(), caps = FetchLog()
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        ext.remoteFetch = { url, maxBytes in
            let id = String(url.split(separator: "/").last ?? "")
            let n = fetched.add(id)
            _ = caps.add(maxBytes.map(String.init) ?? "nil")
            try await fetch?(id)
            let folder = work.appendingPathComponent("prosper-github-\(n)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let dir = folder.appendingPathComponent("src", isDirectory: true)
            try FileManager.default.copyItem(at: root.appendingPathComponent("offer/\(id)"), to: dir)
            return dir
        }
        addTeardownBlock { @MainActor in ControlExtensions.registry = { (NSApp?.delegate as? AppDelegate)?.extensionRegistry } }
        ControlExtensions.registry = { ext }
        return GitHubFixture(ext: ext, root: root, fetched: fetched, caps: caps)
    }

    /// The GitHub branch: a newer manifest version installs, the download is capped at the artifact cap, the origin stays.
    func testUpdateFromGitHubInstallsTheNewerVersionWithTheDownloadCapped() async throws {
        let f = try githubFixture()
        let reply = await call(registry(), "extensions.update", ["id": .string("com.example.alpha")])
        XCTAssertTrue(reply.ok, "\(reply)")
        XCTAssertEqual(rows(reply, "results")["com.example.alpha"], ["id": .string("com.example.alpha"), "from": .string("1.0.0"),
                                                                    "to": .string("1.1.0"), "outcome": .string("updated")])
        XCTAssertEqual(f.fetched.ids, ["com.example.alpha"])
        XCTAssertEqual(f.caps.ids, [String(RemoteInstaller.maxArtifactBytes)], "the download is capped")
        XCTAssertEqual(f.ext.record(id: "com.example.alpha")?.manifest.extension.version, "1.1.0")
        XCTAssertTrue(try f.installedManifest("com.example.alpha").contains("update_url = \"https://github.com/example/com.example.alpha\""),
                      "the origin stays")
    }

    /// RemoteInstaller's own refusal of an over-cap download is the row's reason; nothing changes.
    func testAnOverCapGitHubDownloadIsAFailedRowWithItsReason() async throws {
        let f = try githubFixture { _ in throw RemoteInstaller.InstallError.unsafeArchive("download over \(RemoteInstaller.maxArtifactBytes) bytes") }
        let reply = await call(registry(), "extensions.update", ["id": .string("com.example.alpha")])
        XCTAssertTrue(reply.ok, "\(reply)")
        let alpha = rows(reply, "results")["com.example.alpha"]
        XCTAssertEqual(alpha?["outcome"], .string("failed"))
        guard case .string(let why)? = alpha?["reason"] else { return XCTFail("\(reply)") }
        XCTAssertTrue(why.contains("download over \(RemoteInstaller.maxArtifactBytes) bytes"), why)
        XCTAssertEqual(f.ext.record(id: "com.example.alpha")?.manifest.extension.version, "1.0.0")
    }

    /// An updated agent kit carries the note about kits.apply; a plain extension's row has none.
    func testAnUpdatedKitHasTheNoteAndAPlainExtensionHasNone() async throws {
        for kit in [true, false] {
            let f = try githubFixture(kit: kit)
            let reply = await call(registry(), "extensions.update", ["id": .string("com.example.alpha")])
            let alpha = rows(reply, "results")["com.example.alpha"]
            XCTAssertEqual(alpha?["outcome"], .string("updated"), "kit \(kit): \(reply)")
            XCTAssertEqual(f.ext.record(id: "com.example.alpha")?.manifest.contributes?.kit != nil, kit)
            if kit {
                guard case .string(let note)? = alpha?["note"] else { return XCTFail("no note: \(reply)") }
                XCTAssertTrue(note.contains("kits.apply"), note)
            } else {
                XCTAssertNil(alpha?["note"])
            }
        }
    }

    /// The deadline passes while the first download waits: the reply is the late error, the cancelled pass stops before the
    /// next extension, and no extension changed version.
    func testUpdatePastTheDeadlineStopsBeforeTheNextExtensionAndChangesNothing() async throws {
        let f = try githubFixture { _ in try await Task.sleep(nanoseconds: 30_000_000_000) } // ends early, by the cancel
        let deadline = ControlExtensions.updateDeadline
        defer { ControlExtensions.updateDeadline = deadline }
        ControlExtensions.updateDeadline = 0.2
        let reply = await call(registry(), "extensions.update")
        XCTAssertEqual(reply.error, ControlExtensions.updateLate)
        XCTAssertLessThanOrEqual(f.fetched.ids.count, 1, "the second extension was never fetched: \(f.fetched.ids)") // 0 when the deadline beats the first fetch
        for id in ["com.example.alpha", "com.example.beta"] {
            XCTAssertEqual(f.ext.record(id: id)?.manifest.extension.version, "1.0.0", id)
        }
    }

    // MARK: themes

    private func fakeThemes() {
        let store = ThemeStore.shared
        let saved = Preferences.defaults.object(forKey: "prosper.activeThemeID")
        addTeardownBlock { @MainActor in
            if let saved { Preferences.defaults.set(saved, forKey: "prosper.activeThemeID") }
            else { Preferences.defaults.removeObject(forKey: "prosper.activeThemeID") }
            ThemeStore.shared.setAvailable([])
        }
        Preferences.defaults.removeObject(forKey: "prosper.activeThemeID")
        store.setAvailable([
            ThemeDescriptor(id: "com.example.theme.paper", title: "Paper", appearance: .light,
                            extensionID: "com.example.fake", jsonPath: nil),
            ThemeDescriptor(id: "com.example.theme.night", title: "Night", appearance: .dark,
                            extensionID: "com.example.stranger", jsonPath: nil),
        ])
    }

    func testThemesListMarksAppearanceBuiltInAndCurrent() async throws {
        _ = try fakeRegistry()
        fakeThemes()
        let reply = await call(registry(), "themes.list")
        XCTAssertTrue(reply.ok, "\(reply)")
        let all = rows(reply, "themes")
        XCTAssertEqual(all.count, 3, "\(all.keys.sorted())")
        XCTAssertEqual(all[ThemeDescriptor.builtInID]?["builtIn"], .bool(true))
        XCTAssertEqual(all[ThemeDescriptor.builtInID]?["current"], .bool(true))
        XCTAssertEqual(all[ThemeDescriptor.builtInID]?["extension"], .null)
        XCTAssertEqual(all["com.example.theme.paper"]?["appearance"], .string("light"))
        XCTAssertEqual(all["com.example.theme.paper"]?["builtIn"], .bool(true), "from a system extension")
        XCTAssertEqual(all["com.example.theme.paper"]?["current"], .bool(false))
        XCTAssertEqual(all["com.example.theme.night"]?["builtIn"], .bool(false), "from a user extension")
        XCTAssertEqual(all["com.example.theme.night"]?["title"], .string("Night"))
    }

    func testThemesSetGoesThroughTheThemeSettingAndUndoRestores() async throws {
        fakeThemes()
        let reg = registry()
        let reply = await call(reg, "themes.set", ["id": .string("com.example.theme.paper")])
        XCTAssertTrue(reply.ok, "\(reply)")
        XCTAssertEqual(ThemeStore.shared.activeID, "com.example.theme.paper")
        XCTAssertEqual(Preferences.defaults.string(forKey: "prosper.activeThemeID"), "com.example.theme.paper")
        XCTAssertEqual(reply.result, .object(["theme": .string("com.example.theme.paper")]), "settings.set's own reply")
        XCTAssertEqual(reg.changes.entries.last?.command, "themes.set")
        XCTAssertTrue(reg.changes.undo(reg.changes.entries.last?.id ?? -1))
        XCTAssertEqual(ThemeStore.shared.activeID, ThemeDescriptor.builtInID, "undo restores the previous theme")

        let bad = await call(reg, "themes.set", ["id": .string("com.example.theme.none")])
        XCTAssertFalse(bad.ok)
        XCTAssertTrue(bad.error?.contains("theme must be one of") == true, "\(bad)")
        XCTAssertEqual(ThemeStore.shared.activeID, ThemeDescriptor.builtInID)
        XCTAssertEqual(reg.changes.entries.count, 1, "a refused set logs nothing")
    }

    func testDescribeMarksTheWritesAsMutating() {
        let cmds = registry().commands
        for name in ["extensions.enable", "extensions.disable", "extensions.update", "themes.set"] { XCTAssertEqual(cmds[name]?.mutates, true, name) }
        for name in ["extensions.list", "themes.list"] { XCTAssertEqual(cmds[name]?.mutates, false, name) }
    }
}

/// #1869: the ids the fake market download was asked for (called off the main actor).
private final class FetchLog: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [String] = []
    var ids: [String] { lock.withLock { list } }
    func add(_ id: String) -> Int { lock.withLock { list.append(id); return list.count } }
}

private struct FakeDownloadError: LocalizedError {
    var errorDescription: String? { "the server said no\u{7}" }
}
