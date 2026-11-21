import AppKit
import Foundation
import os
import XCTest
@testable import ProsperApp

// #1866: kits.list / install / apply / repair / rollback / remove over the kit pane's fixtures (KitPaneModelTests):
// real KitStore and ManagedConfig over the row's own tempDir() roots, a recording consent, a fake owner, a registry over
// a temp user dir with scratch defaults. Never the real home, extensions folder, network or Keychain.
@MainActor
final class ControlKitsTests: XCTestCase {
    private static let ext = KitPaneModelTests.ext
    private var notices: [String] = []
    /// GitHub installs asked of the fake (the real one would reach the network).
    private var fetched: [String] = []

    override func tearDown() async throws {
        ControlKits.owner = { KitRuntimes.shared }
        ControlExtensions.registry = { (NSApp?.delegate as? AppDelegate)?.extensionRegistry }
        ControlKits.lastUndo = nil
        ControlKits.installGitHub = ControlKits.githubInstall
        ControlKits.stageRoot = FileManager.default.temporaryDirectory
        Preferences.agentControlEnabled = true
        try await super.tearDown()
    }

    private func registry() -> ControlRegistry {
        var r = ControlRegistry()
        ControlRegistry.registerKits(&r)
        let changes = ControlChanges()
        changes.present = { [weak self] text, _ in self?.notices.append(text) }
        r.changes = changes
        return r
    }

    private func call(_ reg: ControlRegistry, _ cmd: String, _ args: [String: ControlJSON] = [:]) async -> ControlReply {
        await reg.reply(to: try! JSONEncoder().encode(ControlRequest(cmd: cmd, args: args)))
    }

    private func object(_ r: ControlReply) -> [String: ControlJSON] {
        if case .object(let o)? = r.result { return o }
        return [:]
    }

    /// A trusted (or not) fixture kit record under a fake owner; the owner is the one ControlKits reads.
    private func fakeKit(_ e: KitRuntimeTests.Env, trusted: Bool = true, kit: String = KitFixture.kit) throws -> (KitRuntimes, ExtensionRecord) {
        let rec = ExtensionRecord(loaded: try kitPaneSource(e, kit: kit, extra: [("EXTRA.md", "# extra rules\n", 0o644)]), enabled: true, trusted: trusted)
        let o = kitPaneOwner(e) { [rec] }
        ControlKits.owner = { o }
        return (o, rec)
    }

    /// A registry over an empty user dir (no extension yet), the owner reading its records.
    private func installEnv(_ e: KitRuntimeTests.Env) -> (ExtensionRegistry, KitRuntimes) {
        let reg = ExtensionRegistry(systemDir: nil, userDir: e.root.appendingPathComponent("user", isDirectory: true), hostVersion: "9.0.0",
                                    defaults: scratchDefaults("ctlkits"))
        reg.discover()
        ControlExtensions.registry = { reg }
        let o = kitPaneOwner(e) { reg.records }
        ControlKits.owner = { o }
        ControlKits.installGitHub = { [weak self] _, url, _ in self?.fetched.append(url); throw ControlError("fake: no network") }
        ControlKits.stageRoot = e.root.appendingPathComponent("stage", isDirectory: true)
        return (reg, o)
    }

    private func source(_ e: KitRuntimeTests.Env, kit: String = KitRuntimePaneTests.neededKit) throws -> String {
        try kitPaneSource(e, kit: kit, extra: [("EXTRA.md", "# extra rules\n", 0o644)]).directory.path
    }

    /// A plain (non-kit) extension folder under the row's tempDir; `marker` is its init.lua's text.
    private func plainSource(_ e: KitRuntimeTests.Env, id: String = ControlKitsTests.ext, version: String = "1.0.0",
                             permissions: [String] = [], marker: String = "plain") throws -> URL {
        let dir = e.root.appendingPathComponent("plain/\(id)-\(version)-\(marker)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let perms = permissions.isEmpty ? "" : "permissions = [" + permissions.map { "\"\($0)\"" }.joined(separator: ", ") + "]\n"
        try """
        [extension]
        id = "\(id)"
        name = "plain"
        title = "Plain"
        description = "A test extension"
        version = "\(version)"
        author = "tester"
        \(perms)
        [extension.host]
        min_version = "2.0.0"
        api_level = 1

        [extension.entry]
        main = "init.lua"
        """.write(to: dir.appendingPathComponent("extension.toml"), atomically: true, encoding: .utf8)
        try "-- \(marker)".write(to: dir.appendingPathComponent("init.lua"), atomically: true, encoding: .utf8)
        return dir
    }

    /// The download work folders left in the row's stage root (none once a call is done).
    private func stageLeft(_ e: KitRuntimeTests.Env) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: e.root.appendingPathComponent("stage").path)) ?? []).filter { $0.hasPrefix("prosper-ext-") }
    }

    private func claudeMD(_ e: KitRuntimeTests.Env) -> String {
        (try? String(contentsOf: e.roots.claude.appendingPathComponent("CLAUDE.md"), encoding: .utf8)) ?? ""
    }

    // MARK: kits.list

    func testListShowsAFakeInstalledKit() async throws {
        let e = try kitPaneEnv()
        _ = try fakeKit(e)
        let r = await call(registry(), "kits.list")
        XCTAssertTrue(r.ok, r.error ?? "")
        guard case .array(let kits)? = object(r)["kits"], case .object(let k)? = kits.first else { return XCTFail("\(r)") }
        XCTAssertEqual(kits.count, 1)
        XCTAssertEqual(k["id"], .string(Self.ext))
        XCTAssertEqual(k["version"], .string("1.0.0"))
        XCTAssertEqual(k["trusted"], .bool(true))
        XCTAssertEqual(k["applied"], .bool(false))
        guard case .array(let pieces)? = k["pieces"] else { return XCTFail("no pieces") }
        XCTAssertEqual(pieces.count, 6)
        XCTAssertTrue(pieces.contains(.object(["id": .string("guard"), "kind": .string("hook"), "on": .bool(true)])), "\(pieces)")
        XCTAssertEqual(k["settings"], .array([.object(["key": .string("default_repo"), "value": .string("")])]))
        XCTAssertEqual(k["refused"], .array([]))
    }

    // MARK: kits.install

    func testInstallFromAFolderClosesTheSelectionStoresTheSettingAndAppliesOnce() async throws {
        let e = try kitPaneEnv()
        let (reg, o) = installEnv(e)
        let reply = await call(registry(), "kits.install", ["source": .string(try source(e)), "off": .array([.string("tools")]),
                                                            "settings": .object(["default_repo": .string("example/repo")])])
        XCTAssertTrue(reply.ok, reply.error ?? "")
        XCTAssertEqual(reg.record(id: Self.ext)?.trusted, true, "trusted through the Trust button's call")
        let rt = try XCTUnwrap(o.runtime(for: Self.ext))
        XCTAssertEqual(rt.off(), ["tools", "guard", "hud"], "closed as toggle closes it: the pieces that need tools go too")
        XCTAssertEqual(rt.store.readSettingsEnv()["KIT_DEFAULT_REPO"], "example/repo")
        XCTAssertEqual(e.consent.seen.count, 0, "the agent path approves its own change set: the sheet is not asked")
        XCTAssertEqual(rt.current?.live.version, "1.0.0")
        XCTAssertTrue(claudeMD(e).contains(rt.store.layout.live), "the files were written")
        let out = object(reply)
        XCTAssertEqual(out["line"], .string("done"))
        XCTAssertTrue(out["notes"] != nil && out["failures"] == .array([]), "\(out)")
        guard case .array(let files)? = out["approved"] else { return XCTFail("no approved list: \(out)") }
        XCTAssertTrue(files.contains {
            guard case .object(let f) = $0, case .string(let path)? = f["path"] else { return false }
            return path.hasSuffix("/claude home/CLAUDE.md") && f["action"] == .string("apply") && f["change"] == .string("edit")
        }, "the CLAUDE.md edit is listed: \(files)")
        XCTAssertEqual(notices.count, 1)
        XCTAssertTrue(notices.last?.hasPrefix("Agent installed an agent kit:") == true, "\(notices)")
        XCTAssertTrue(notices.last?.contains("\(files.count) config file change") == true, "the log line counts them: \(notices)")
    }

    func testARefusedSelectionWritesNothingAndPutsTheInstallBack() async throws {
        let e = try kitPaneEnv()
        let (reg, o) = installEnv(e)
        let reply = await call(registry(), "kits.install", ["source": .string(try source(e)), "off": .array([.string("rules")])])
        XCTAssertFalse(reply.ok)
        XCTAssertTrue(reply.error?.hasPrefix("the selection is refused, nothing written:") == true, reply.error ?? "")
        XCTAssertTrue(reg.record(id: Self.ext) == nil, "the extension it installed is uninstalled again")
        XCTAssertTrue(o.runtime(for: Self.ext) == nil)
        let pieces = try KitStore.layout(configHome: e.roots.configHome, extID: Self.ext).piecesJSON
        XCTAssertFalse(FileManager.default.fileExists(atPath: pieces), "no selection written")
        XCTAssertEqual(e.consent.seen.count, 0)
        XCTAssertTrue(notices.isEmpty)
    }

    func testArgumentRefusals() async throws {
        let e = try kitPaneEnv()
        let (reg, _) = installEnv(e)
        let dir = try source(e), reg2 = registry()
        for bad in ["http://github.com/example/kit", "https://example.com/example/kit", "https://github.com/example/kit?x=1",
                    "https://github.com/example/kit/blob/main", "relative/folder", dir + "/missing", "/Users/example\u{7}"] {
            let r = await call(reg2, "kits.install", ["source": .string(bad)])
            XCTAssertFalse(r.ok, bad)
        }
        let key = await call(reg2, "kits.install", ["source": .string(dir), "settings": .object(["nope": .string("x")])])
        XCTAssertTrue(key.error?.hasPrefix("unknown setting 'nope'") == true, key.error ?? "")
        let piece = await call(reg2, "kits.install", ["source": .string(dir), "off": .array([.string("nope")])])
        XCTAssertTrue(piece.error?.hasPrefix("unknown piece 'nope'") == true, piece.error ?? "")
        let ctl = await call(reg2, "kits.install", ["source": .string(dir), "settings": .object(["default_repo": .string("a\nb")])])
        XCTAssertEqual(ctl.error, "setting 'default_repo' has a control or hidden character")
        let long = await call(reg2, "kits.install", ["source": .string(dir), "settings": .object(["default_repo": .string(String(repeating: "a", count: ControlKits.maxValue + 1))])])
        XCTAssertEqual(long.error, "setting 'default_repo' is longer than 1000 characters")
        XCTAssertTrue(fetched.isEmpty, "no refused URL reached the GitHub install: \(fetched)")
        let gh = await call(reg2, "kits.install", ["source": .string("https://github.com/example/kit/tree/v1.0.0")])
        XCTAssertEqual(gh.error, "fake: no network")
        XCTAssertEqual(fetched, ["https://github.com/example/kit/tree/v1.0.0"], "a repo URL goes to the registry's GitHub install")
        XCTAssertTrue(reg.record(id: Self.ext) == nil, "every refusal put the install back")
        XCTAssertEqual(e.consent.seen.count, 0)
        XCTAssertTrue(notices.isEmpty)
        // installed kit named by id: the same checks
        let (o, _) = try fakeKit(e)
        XCTAssertTrue(o.record(Self.ext) != nil)
        let rm = await call(reg2, "kits.remove", ["id": .string(Self.ext), "pieces": .array([.string("nope")])])
        XCTAssertTrue(rm.error?.hasPrefix("unknown piece 'nope'") == true, rm.error ?? "")
        let ap = await call(reg2, "kits.apply", ["id": .string(Self.ext), "settings": .object(["nope": .string("x")])])
        XCTAssertTrue(ap.error?.hasPrefix("unknown setting 'nope'") == true, ap.error ?? "")
    }

    func testSourceCheckAcceptsTheGitHubFormsAndAFolder() throws {
        let dir = tempDir()
        XCTAssertEqual(try ControlKits.source("https://github.com/example/kit"), .github("https://github.com/example/kit"))
        XCTAssertEqual(try ControlKits.source("https://github.com/example/kit/tree/v1.0.0"), .github("https://github.com/example/kit/tree/v1.0.0"))
        XCTAssertEqual(try ControlKits.source(dir.path), .folder(dir.standardizedFileURL))
        XCTAssertThrowsError(try ControlKits.source("git@github.com:example/kit.git"))
        XCTAssertThrowsError(try ControlKits.source("https://github.com/example/kit/blob/main"))
        XCTAssertThrowsError(try ControlKits.source("https://github.com/example/kit#x"))
        XCTAssertThrowsError(try ControlKits.source(dir.appendingPathComponent("missing").path))
        let file = dir.appendingPathComponent("file.txt")
        try Data("x".utf8).write(to: file)
        XCTAssertThrowsError(try ControlKits.source(file.path), "a file is not a folder")
    }

    // MARK: the switch and busy

    func testTheSwitchOffRefusesEveryChange() async throws {
        let e = try kitPaneEnv()
        let (reg, _) = installEnv(e)
        let dir = try source(e), r = registry()
        Preferences.agentControlEnabled = false
        for (cmd, args) in [("kits.install", ["source": ControlJSON.string(dir)]), ("kits.apply", ["id": .string(Self.ext)]),
                            ("kits.repair", ["id": .string(Self.ext)]), ("kits.rollback", ["id": .string(Self.ext)]),
                            ("kits.remove", ["id": .string(Self.ext)])] {
            let reply = await call(r, cmd, args)
            XCTAssertEqual(reply.error, ControlChanges.offError, cmd)
        }
        XCTAssertTrue(reg.record(id: Self.ext) == nil, "nothing installed")
        let list = await call(r, "kits.list")
        XCTAssertTrue(list.ok, "reads still answer")
        XCTAssertTrue(notices.isEmpty)
    }

    func testABusyRuntimeIsRefusedWithThePanesBusyText() async throws {
        let rec = KitRTConsent()
        let gate = KitParkedConsent(rec)
        let e = try kitPaneEnv(rec, sheet: gate)
        let (o, _) = try fakeKit(e)
        let pane = KitPaneModel(extID: Self.ext, owner: o)
        await pane.load()?.value
        let first = pane.apply()
        let watcher = Task { await first?.value; gate.wake() }
        await gate.waitParked()
        let r = registry()
        let apply = await call(r, "kits.apply", ["id": .string(Self.ext)])
        XCTAssertEqual(apply.error, KitRuntime.busyText)
        let repair = await call(r, "kits.repair", ["id": .string(Self.ext)])
        XCTAssertEqual(repair.error, KitRuntime.busyText)
        XCTAssertTrue(notices.isEmpty)
        gate.release()
        await first?.value
        await watcher.value
        XCTAssertEqual(pane.result, "done")
    }

    // MARK: the agent consent stays with its call

    func testThePaneStillAsksTheSheet() async throws {
        let e = try kitPaneEnv()
        let (o, _) = try fakeKit(e)
        let pane = KitPaneModel(extID: Self.ext, owner: o)
        await pane.load()?.value
        await pane.apply()?.value
        XCTAssertEqual(pane.result, "done")
        XCTAssertEqual(e.consent.seen.count, 1, "the pane's apply asks the sheet")
    }

    func testAnAgentRunDoesNotLeakToTheNextPaneRun() async throws {
        let e = try kitPaneEnv()
        let (o, _) = try fakeKit(e)
        let applied = await call(registry(), "kits.apply", ["id": .string(Self.ext)])
        XCTAssertTrue(applied.ok, applied.error ?? "")
        XCTAssertEqual(e.consent.seen.count, 0)
        let pane = KitPaneModel(extID: Self.ext, owner: o)
        await pane.load()?.value
        await pane.remove()?.value
        XCTAssertEqual(e.consent.seen.count, 1, "the same runtime's pane Remove asks the sheet")
        XCTAssertEqual(pane.result, "done")
    }

    // MARK: trust and undo scope

    func testApplyPutsTrustBackWhenNothingIsApplied() async throws {
        let e = try kitPaneEnv()
        let (reg, _) = installEnv(e)
        _ = try reg.installLocal(from: URL(fileURLWithPath: try source(e), isDirectory: true))
        XCTAssertEqual(reg.record(id: Self.ext)?.trusted, false, "installed untrusted")
        let r = await call(registry(), "kits.apply", ["id": .string(Self.ext), "off": .array([.string("rules")])])
        XCTAssertTrue(r.error?.hasPrefix("the selection is refused, nothing written:") == true, r.error ?? "")
        XCTAssertEqual(reg.record(id: Self.ext)?.trusted, false, "the trust it granted is taken back")
        XCTAssertTrue(notices.isEmpty)
    }

    /// The kit store kept a live version of the id (applied before, the registry has no record of it): no Undo.
    func testAKitAppliedBeforeHasNoInstallUndo() async throws {
        let e = try kitPaneEnv()
        let (fake, _) = try fakeKit(e, kit: KitRuntimePaneTests.neededKit)
        let r = registry()
        let applied = await call(r, "kits.apply", ["id": .string(Self.ext)])
        XCTAssertTrue(applied.ok, applied.error ?? "")
        let live = try XCTUnwrap(fake.runtime(for: Self.ext)).store.layout.live
        let (reg, _) = installEnv(e)
        let again = await call(r, "kits.install", ["source": .string(try source(e))])
        XCTAssertTrue(again.ok, again.error ?? "")
        let entry = try XCTUnwrap(r.changes.entries.last)
        XCTAssertFalse(entry.undoable, "applied before this call: no Undo")
        XCTAssertTrue(entry.summary.contains("no Undo"), entry.summary)
        XCTAssertFalse(r.changes.undo(entry.id))
        await ControlKits.lastUndo?.value
        XCTAssertTrue(claudeMD(e).contains(live), "still applied")
        XCTAssertTrue(reg.record(id: Self.ext) != nil, "still installed")
    }

    // MARK: remove and undo

    func testRemoveRemovesTheAppliedKit() async throws {
        let e = try kitPaneEnv()
        let (o, _) = try fakeKit(e)
        let r = registry()
        let applied = await call(r, "kits.apply", ["id": .string(Self.ext)])
        XCTAssertTrue(applied.ok, applied.error ?? "")
        let live = try XCTUnwrap(o.runtime(for: Self.ext)).store.layout.live
        XCTAssertTrue(claudeMD(e).contains(live), "applied: the import line is in CLAUDE.md")
        let removed = await call(r, "kits.remove", ["id": .string(Self.ext)])
        XCTAssertTrue(removed.ok, removed.error ?? "")
        XCTAssertEqual(object(removed)["line"], .string("done"))
        XCTAssertFalse(claudeMD(e).contains(live), "removed")
        XCTAssertTrue(claudeMD(e).hasPrefix(KitRuntimeTests.userMD))
        XCTAssertEqual(r.changes.entries.last?.undoable, false, "remove has no undo")
    }

    func testInstallUndoRemovesWhatItAppliedAndUninstalls() async throws {
        let e = try kitPaneEnv()
        let (reg, o) = installEnv(e)
        let r = registry()
        let reply = await call(r, "kits.install", ["source": .string(try source(e))])
        XCTAssertTrue(reply.ok, reply.error ?? "")
        let live = try XCTUnwrap(o.runtime(for: Self.ext)).store.layout.live
        XCTAssertTrue(claudeMD(e).contains(live))
        let entry = try XCTUnwrap(r.changes.entries.last)
        XCTAssertTrue(entry.undoable)
        XCTAssertTrue(r.changes.undo(entry.id))
        await ControlKits.lastUndo?.value
        XCTAssertFalse(claudeMD(e).contains(live), "what it applied is removed")
        XCTAssertTrue(reg.record(id: Self.ext) == nil, "and the extension it installed is uninstalled")
    }

    /// F8: the Undo's Remove asks the person's sheet; declined, the kit stays applied, installed and trusted.
    func testADeclinedUndoKeepsTheKitInstalledAndTrusted() async throws {
        let e = try kitPaneEnv(KitRTConsent(false))
        let (reg, o) = installEnv(e)
        let r = registry()
        let reply = await call(r, "kits.install", ["source": .string(try source(e))])
        XCTAssertTrue(reply.ok, reply.error ?? "")
        let live = try XCTUnwrap(o.runtime(for: Self.ext)).store.layout.live
        let entry = try XCTUnwrap(r.changes.entries.last)
        XCTAssertTrue(r.changes.undo(entry.id))
        await ControlKits.lastUndo?.value
        XCTAssertEqual(e.consent.seen.count, 1, "the person's sheet was asked")
        XCTAssertTrue(claudeMD(e).contains(live), "declined: still applied")
        XCTAssertEqual(reg.record(id: Self.ext)?.trusted, true, "and still installed and trusted")
    }

    // MARK: #1866 follow-up: the candidate checked before the install (n185), quiet (n186), refused runs (n187), caps (n188)

    func testANonKitSourceIsRefusedBeforeAnythingIsInstalled() async throws {
        let e = try kitPaneEnv()
        let (reg, _) = installEnv(e)
        let r = registry()
        let fresh = await call(r, "kits.install", ["source": .string(try plainSource(e, id: "dev.example.plain").path)])
        XCTAssertEqual(fresh.error, "dev.example.plain is not an agent kit (no [contributes.kit])")
        XCTAssertTrue(reg.record(id: "dev.example.plain") == nil, "nothing installed")
        // the id of an installed, trusted extension: refused before the copy; its folder and trust stay
        _ = try reg.installLocal(from: try plainSource(e, marker: "installed"))
        try reg.trust(id: Self.ext)
        let installed = e.root.appendingPathComponent("user/\(Self.ext)/init.lua")
        let same = await call(r, "kits.install", ["source": .string(try plainSource(e, marker: "replacement").path)])
        XCTAssertEqual(same.error, "\(Self.ext) is not an agent kit (no [contributes.kit])")
        XCTAssertEqual(try String(contentsOf: installed, encoding: .utf8), "-- installed", "the installed folder is untouched")
        XCTAssertEqual(reg.record(id: Self.ext)?.trusted, true, "and its trust")
        // a kit under that id: kits.install never replaces an installed extension
        let kit = await call(r, "kits.install", ["source": .string(try source(e))])
        XCTAssertTrue(kit.error?.hasPrefix("\(Self.ext) is already installed:") == true, kit.error ?? "")
        XCTAssertEqual(try String(contentsOf: installed, encoding: .utf8), "-- installed")
        XCTAssertEqual(reg.record(id: Self.ext)?.trusted, true)
        XCTAssertTrue(notices.isEmpty, "\(notices)")
        XCTAssertEqual(stageLeft(e), [], "every stage is removed")
    }

    func testTheGitHubInstallIsCappedAndChecksTheManifestBeforeTheRegistryInstall() async throws {
        let e = try kitPaneEnv()
        let (reg, _) = installEnv(e)
        ControlKits.installGitHub = ControlKits.githubInstall
        let seen = OSAllocatedUnfairLock(initialState: [Int?]())
        let plain = try plainSource(e, id: "dev.example.plain")
        reg.remoteFetch = { _, cap in seen.withLock { $0.append(cap) }; return plain }
        let reply = await call(registry(), "kits.install", ["source": .string("https://github.com/example/plain")])
        XCTAssertEqual(reply.error, "dev.example.plain is not an agent kit (no [contributes.kit])")
        XCTAssertTrue(reg.record(id: "dev.example.plain") == nil, "refused before the registry install")
        XCTAssertEqual(seen.withLock { $0 }, [RemoteInstaller.maxArtifactBytes], "the download is capped at the market's cap")
        XCTAssertEqual(RemoteInstaller.maxArtifactBytes, 4 * 1_048_576)
        XCTAssertTrue(notices.isEmpty)
    }

    func testInstallRemoteWithTheQuietReviewNeverAsks() async throws {
        let e = try kitPaneEnv()
        let (reg, _) = installEnv(e)
        _ = try reg.installLocal(from: try plainSource(e, id: "dev.example.plain"))
        try reg.trust(id: "dev.example.plain")
        var asked = 0
        reg.reviewNewPermissions = { _, _ in asked += 1; return true }
        let v2 = try plainSource(e, id: "dev.example.plain", version: "2.0.0", permissions: ["full-disk-access"])
        reg.remoteFetch = { _, _ in v2 }
        do {
            _ = try await reg.installRemote(url: "https://github.com/example/plain", review: ControlKits.quiet)
            XCTFail("an update with a new permission is declined")
        } catch {}
        XCTAssertEqual(asked, 0, "the person's alert is never asked")
        XCTAssertEqual(reg.record(id: "dev.example.plain")?.manifest.extension.version, "1.0.0", "declined: the installed version stays")
        _ = try? await reg.installRemote(url: "https://github.com/example/plain")
        XCTAssertEqual(asked, 1, "without a review (Settings) the alert's seam is asked as before")
    }

    func testARefusedApplyKeepsTrustAsItWasLogsNothingAndOffersNoUndo() async throws {
        let e = try kitPaneEnv()
        let (reg, _) = installEnv(e)
        // a runtime that reads every kit as untrusted: its apply is refused after the call granted trust
        let provider = e.provider
        let o = KitRuntimes(configHome: e.roots.configHome, records: { reg.records }, loginPath: { nil },
                            make: { store, _ in KitRuntime(provider: provider, store: store, isTrusted: { _ in false }, now: { Date() }) })
        ControlKits.owner = { o }
        let r = registry()
        let fresh = await call(r, "kits.install", ["source": .string(try source(e))])
        XCTAssertTrue(fresh.error?.contains("untrusted kit") == true, fresh.error ?? "")
        XCTAssertTrue(reg.record(id: Self.ext) == nil, "the install is put back")
        _ = try reg.installLocal(from: URL(fileURLWithPath: try source(e), isDirectory: true))
        XCTAssertEqual(reg.record(id: Self.ext)?.trusted, false, "its trust went before the uninstall: a reinstall is not trusted")
        let applied = await call(r, "kits.apply", ["id": .string(Self.ext)])
        XCTAssertTrue(applied.error?.contains("untrusted kit") == true, applied.error ?? "")
        XCTAssertEqual(reg.record(id: Self.ext)?.trusted, false, "the trust it granted is taken back")
        XCTAssertTrue(notices.isEmpty, "\(notices)")
        XCTAssertTrue(r.changes.entries.isEmpty, "no log line, no Undo")
    }

    func testTheSwitchTurnedOffMidCallStopsTheRest() async throws {
        let e = try kitPaneEnv()
        let (reg, o) = installEnv(e)
        let dir = URL(fileURLWithPath: try source(e), isDirectory: true), r = registry()
        var admitted: [String] = []
        // off before the registry install: its admit refuses, nothing lands
        ControlKits.installGitHub = { reg, _, admit in
            Preferences.agentControlEnabled = false
            do { return try reg.installLocal(from: dir, review: ControlKits.quiet, admit: admit) } catch { admitted.append("\(error)"); throw error }
        }
        let early = await call(r, "kits.install", ["source": .string("https://github.com/example/kit")])
        XCTAssertEqual(early.error, ControlChanges.offError)
        XCTAssertEqual(admitted.count, 1, "the registry install itself refused it")
        XCTAssertTrue(reg.record(id: Self.ext) == nil, "nothing installed")
        // off after it: the next check puts it back before Trust
        Preferences.agentControlEnabled = true
        var trustCalls = 0
        reg.onEnabledChanged = { trustCalls += 1 }
        ControlKits.installGitHub = { reg, _, admit in
            let rec = try reg.installLocal(from: dir, review: ControlKits.quiet, admit: admit)
            Preferences.agentControlEnabled = false
            return rec
        }
        let late = await call(r, "kits.install", ["source": .string("https://github.com/example/kit")])
        XCTAssertEqual(late.error, ControlChanges.offError)
        XCTAssertEqual(trustCalls, 0, "no Trust was granted (nor taken back)")
        XCTAssertTrue(reg.record(id: Self.ext) == nil, "uninstalled again")
        // kits.apply: the switch goes off while Trust is granted; the check after it stops the apply
        Preferences.agentControlEnabled = true
        _ = try reg.installLocal(from: dir)
        reg.onEnabledChanged = { Preferences.agentControlEnabled = false }
        let applied = await call(r, "kits.apply", ["id": .string(Self.ext)])
        XCTAssertEqual(applied.error, ControlChanges.offError)
        XCTAssertEqual(reg.record(id: Self.ext)?.trusted, false, "trust put back")
        XCTAssertTrue(o.runtime(for: Self.ext)?.current == nil, "nothing applied")
        XCTAssertTrue(notices.isEmpty)
    }

    /// Counts every byte pulled (the per-byte read of a capped download).
    private struct CountedBytes: AsyncSequence, AsyncIteratorProtocol {
        typealias Element = UInt8
        let total: Int
        let pulled: OSAllocatedUnfairLock<Int>
        mutating func next() async -> UInt8? {
            let n = pulled.withLock { $0 += 1; return $0 }
            return n <= total ? 7 : nil
        }
        func makeAsyncIterator() -> CountedBytes { self }
    }

    func testADownloadOverTheCapIsRefusedAtTheFirstByteOver() async throws {
        let over = OSAllocatedUnfairLock(initialState: 0)
        do {
            _ = try await RemoteInstaller.capped(CountedBytes(total: 1_000, pulled: over), max: 16)
            XCTFail("over the cap")
        } catch {
            XCTAssertEqual("\(error)", "\(RemoteInstaller.InstallError.unsafeArchive("download over 16 bytes"))")
        }
        XCTAssertEqual(over.withLock { $0 }, 17, "nothing past the first byte over is read")
        let fits = OSAllocatedUnfairLock(initialState: 0)
        let data = try await RemoteInstaller.capped(CountedBytes(total: 16, pulled: fits), max: 16)
        XCTAssertEqual(data.count, 16)
        XCTAssertEqual(fits.withLock { $0 }, 17, "16 bytes and the end")
    }

    func testAFolderOverTheCapIsRefusedBeforeAnyCopy() async throws {
        let e = try kitPaneEnv()
        let (reg, _) = installEnv(e)
        let r = registry(), fm = FileManager.default
        // bytes: one sparse file one byte over the kit store's cap
        let big = URL(fileURLWithPath: try source(e), isDirectory: true)
        let blob = big.appendingPathComponent("blob.bin")
        XCTAssertTrue(fm.createFile(atPath: blob.path, contents: nil))
        let h = try FileHandle(forWritingTo: blob)
        try h.truncate(atOffset: UInt64(KitStore.localByteCap + 1))
        try h.close()
        var copies = 0
        XCTAssertThrowsError(try RemoteInstaller.stage(big, tempRoot: e.root.appendingPathComponent("stage"), copy: { _, _ in copies += 1 }))
        XCTAssertEqual(copies, 0, "refused before any copy")
        let bytes = await call(r, "kits.install", ["source": .string(big.path)])
        XCTAssertTrue(bytes.error?.contains("over \(KitStore.localByteCap) bytes") == true, bytes.error ?? "")
        // entries: one over KitValidator.maxEntries
        let many = e.root.appendingPathComponent("many", isDirectory: true)
        try fm.createDirectory(at: many, withIntermediateDirectories: true)
        for i in 0...KitValidator.maxEntries { XCTAssertTrue(fm.createFile(atPath: many.appendingPathComponent("f\(i)").path, contents: nil)) }
        XCTAssertThrowsError(try RemoteInstaller.stage(many, tempRoot: e.root.appendingPathComponent("stage"), copy: { _, _ in copies += 1 }))
        XCTAssertEqual(copies, 0)
        let files = await call(r, "kits.install", ["source": .string(many.path)])
        XCTAssertTrue(files.error?.contains("over \(KitValidator.maxEntries) files") == true, files.error ?? "")
        XCTAssertTrue(reg.record(id: Self.ext) == nil)
        XCTAssertEqual(stageLeft(e), [], "no stage left")
        XCTAssertTrue(notices.isEmpty)
    }

    // MARK: n189: the slots an agent's yes covered

    func testInstallNamesTheSlotsItWrites() async throws {
        let e = try kitPaneEnv()
        _ = installEnv(e)
        let kit = KitRuntimePaneTests.neededKit.replacingOccurrences(of: "\n[[contributes.kit.settings]]", with: """

        [[contributes.kit.pieces]]
        id   = "auto"
        kind = "env"
        vars = { CLAUDE_CODE_ENABLE_AUTO_MODE = "1" }

        [[contributes.kit.settings]]
        """)
        let reply = await call(registry(), "kits.install", ["source": .string(try source(e, kit: kit))])
        XCTAssertTrue(reply.ok, reply.error ?? "")
        guard case .array(let slots)? = object(reply)["slots"] else { return XCTFail("no slots: \(reply)") }
        XCTAssertEqual(slots.first, .string("Claude Code env CLAUDE_CODE_ENABLE_AUTO_MODE=1: Claude Code sessions act without asking you."), "the warned slot first")
        XCTAssertTrue(slots.contains(.string(#"Claude Code permissions.allow adds ["Bash(calm-note:*)"]"#)), "\(slots)")
        XCTAssertTrue(notices.last?.contains("CLAUDE_CODE_ENABLE_AUTO_MODE=1: Claude Code sessions act without asking you.") == true, "\(notices)")
    }

    func testSlotLinesNameTheKindOfSlot() {
        let env = { (v: String) in
            ManagedConfigPiece(id: "e", kind: .json, target: "claude:settings.json", path: ["env", "CLAUDE_CODE_ENABLE_AUTO_MODE"], op: .set, value: v)
        }
        let warned = "Claude Code env CLAUDE_CODE_ENABLE_AUTO_MODE=1: Claude Code sessions act without asking you."
        XCTAssertEqual(KitAgentConsent.slot(env(#""1""#)), warned)
        XCTAssertEqual(KitAgentConsent.slot(env(#""0""#)), "Claude Code env CLAUDE_CODE_ENABLE_AUTO_MODE=0", "clearly off: no warning")
        XCTAssertEqual(KitAgentConsent.slot(ManagedConfigPiece(id: "b", kind: .json, target: "claude:settings.json",
                                                               path: ManagedConfigPlanner.bypassPath, op: .set, value: #""disable""#)),
                       "Claude Code bypass permissions mode switched off")
        XCTAssertEqual(KitAgentConsent.slot(ManagedConfigPiece(id: "s", kind: .block, target: "shellrc:.zshrc", text: "x")), "shell startup block in ~/.zshrc")
        let md = ManagedConfigPiece(id: "m", kind: .block, target: "claude:CLAUDE.md", text: "x")
        XCTAssertTrue(KitAgentConsent.slot(md) == nil)
        let a = KitAgentConsent()
        a.planned([md, env(#""0""#), env(#""1""#), env(#""1""#)])
        XCTAssertEqual(a.slots, [warned, "Claude Code env CLAUDE_CODE_ENABLE_AUTO_MODE=0"], "warned first, each once")
    }
}
