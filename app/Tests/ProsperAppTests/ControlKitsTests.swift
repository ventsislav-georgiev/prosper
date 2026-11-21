import AppKit
import Foundation
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
        ControlKits.installGitHub = { try await $0.installRemote(url: $1) }
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
        ControlKits.installGitHub = { [weak self] _, url in self?.fetched.append(url); throw ControlError("fake: no network") }
        return (reg, o)
    }

    private func source(_ e: KitRuntimeTests.Env, kit: String = KitRuntimePaneTests.neededKit) throws -> String {
        try kitPaneSource(e, kit: kit, extra: [("EXTRA.md", "# extra rules\n", 0o644)]).directory.path
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

    func testReinstallOfAnAppliedKitHasNoUndo() async throws {
        let e = try kitPaneEnv()
        let (reg, o) = installEnv(e)
        let r = registry(), dir = try source(e)
        let first = await call(r, "kits.install", ["source": .string(dir)])
        XCTAssertTrue(first.ok, first.error ?? "")
        let live = try XCTUnwrap(o.runtime(for: Self.ext)).store.layout.live
        let again = await call(r, "kits.install", ["source": .string(dir)])
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
}
