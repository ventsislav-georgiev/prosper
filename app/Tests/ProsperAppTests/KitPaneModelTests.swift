import Foundation
import XCTest
@testable import ProsperApp

// #1423 (#918 S3): KitPaneModel over the app-lifetime KitRuntimes. Model only, no view: real KitStore and ManagedConfig
// over the row's own tempDir() roots, a recording consent, a fake registry lookup and a fake login PATH (no login shell
// is run, no kit file is run). Every write is under the row's tempDir().
@MainActor
final class KitPaneModelTests: XCTestCase {
    typealias Env = KitRuntimeTests.Env
    static let ext = KitRuntimeTests.ext

    /// Counts the fake login PATH's calls (the seam: LoginPath is never reached).
    final class FakeLogin: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        let path: String
        init(_ path: String) { self.path = path }
        func read() -> String? { lock.withLock { n += 1 }; return path }
        var calls: Int { lock.withLock { n } }
    }

    private func env(_ consent: KitRTConsent = KitRTConsent(), sheet: (any ManagedConfigConsent)? = nil, label: String = #function) throws -> Env {
        try kitPaneEnv(consent, sheet: sheet, label: label)
    }

    private func source(_ e: Env, id: String = KitPaneModelTests.ext, name: String = KitRuntimeTests.slug, version: String = "1.0.0",
                        kit: String = KitFixture.kit, updateURL: String? = nil, extra: [(String, String, Int)] = []) throws -> LoadedExtension {
        try kitPaneSource(e, id: id, name: name, version: version, kit: kit, updateURL: updateURL, extra: extra)
    }

    private func owner(_ e: Env, _ records: @escaping @MainActor () -> [ExtensionRecord], login: FakeLogin = FakeLogin("/Users/example/bin")) -> KitRuntimes {
        kitPaneOwner(e, records, login: { login.read() })
    }

    private func layout(_ e: Env, _ id: String = KitPaneModelTests.ext) throws -> KitStoreLayout {
        try KitStore.layout(configHome: e.roots.configHome, extID: id)
    }

    private func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }

    // MARK: the shared owner

    /// Two models of one kit share one runtime: the second's apply while the first is parked at its sheet shows busy.
    func testTwoModelsOfOneKitShareOneRuntime() async throws {
        let rec = KitRTConsent()
        let gate = KitParkedConsent(rec)
        let e = try env(rec, sheet: gate)
        let r = ExtensionRecord(loaded: try source(e), enabled: true, trusted: true)
        let o = owner(e) { [r] }
        let a = KitPaneModel(extID: Self.ext, owner: o), b = KitPaneModel(extID: Self.ext, owner: o)
        await a.load()?.value
        await b.load()?.value
        XCTAssertTrue(o.runtime(for: Self.ext) === o.runtime(for: Self.ext), "one runtime per kit")
        let first = a.apply()
        let watcher = Task { await first?.value; gate.wake() } // an apply that never asks cannot leave the row waiting
        await gate.waitParked()
        XCTAssertTrue(gate.didPark, "the first apply is parked at its sheet")
        XCTAssertTrue(a.running)
        await b.apply()?.value
        XCTAssertEqual(b.busy, KitRuntime.busyText, "the second model shows the runtime's busy refusal")
        XCTAssertEqual(b.result, KitRuntime.busyText)
        XCTAssertEqual(rec.seen.count, 0, "no sheet answered while the first is parked")
        gate.release()
        await first?.value
        await watcher.value
        XCTAssertEqual(rec.seen.count, 1, "the sheet was seen once")
        XCTAssertEqual(a.result, "done")
        XCTAssertTrue(a.busy == nil)
        XCTAssertEqual(a.live, "1.0.0")
    }

    /// A relaunch (a new owner over the same roots): the model shows the live version after load.
    func testModelShowsLiveVersionAfterARelaunch() async throws {
        let e = try env()
        let r = ExtensionRecord(loaded: try source(e), enabled: true, trusted: true)
        let m = KitPaneModel(extID: Self.ext, owner: owner(e) { [r] })
        await m.load()?.value
        XCTAssertTrue(m.live == nil, "never applied")
        await m.apply()?.value
        XCTAssertEqual(m.result, "done")
        XCTAssertEqual(m.live, "1.0.0")
        let again = KitPaneModel(extID: Self.ext, owner: owner(e) { [r] })
        await again.load()?.value
        XCTAssertEqual(again.live, "1.0.0", "refresh restored the live kit")
        XCTAssertEqual(again.version, "1.0.0")
        XCTAssertEqual(again.title, "Calm Agent Kit")
        XCTAssertEqual(again.author, "Example Author")
        XCTAssertEqual(again.warnings, [])
    }

    /// Untrusted (spec 4.9): facts read, every writing action refused before the runtime: no sheet, no pieces.json.
    func testUntrustedKitIsReadOnly() async throws {
        let e = try env()
        let r = ExtensionRecord(loaded: try source(e), enabled: true, trusted: false)
        let m = KitPaneModel(extID: Self.ext, owner: owner(e) { [r] })
        await m.load()?.value
        XCTAssertFalse(m.trusted)
        XCTAssertFalse(m.canAct)
        if case .ok? = m.facts?.preview {} else { XCTFail("the facts are read: \(String(describing: m.facts?.preview))") }
        m.installOff = ["hud"]
        for t in [m.apply(), m.repair(), m.rollback(), m.saveSettings()] { XCTAssertTrue(t == nil) }
        XCTAssertEqual(m.result, KitPaneModel.untrustedText)
        XCTAssertEqual(e.consent.seen.count, 0)
        XCTAssertFalse(exists(try layout(e).piecesJSON), "the install selection is never written")
        XCTAssertFalse(exists(try KitStore(configHome: e.roots.configHome, extID: Self.ext).runtimeStatePath), "apply never ran")
    }

    func testSourceLabelFromTheUpdateURL() {
        XCTAssertEqual(KitPaneModel.source(updateURL: "prosper://market/com.example.kit"), .market)
        XCTAssertEqual(KitPaneModel.source(updateURL: "https://github.com/example-org/kit"), .github)
        XCTAssertEqual(KitPaneModel.source(updateURL: nil), .local)
        XCTAssertEqual(KitPaneModel.source(updateURL: ""), .local)
    }

    /// A market kit applies with the market byte cap: a 300 KiB source is refused, nothing asked.
    func testMarketKitAppliesWithTheMarketCap() async throws {
        let e = try env()
        let big = String(repeating: "x", count: 300 << 10)
        let r = ExtensionRecord(loaded: try source(e, updateURL: "prosper://market/com.example.kit", extra: [("big.txt", big, 0o644)]),
                                enabled: true, trusted: true)
        let m = KitPaneModel(extID: Self.ext, owner: owner(e) { [r] })
        await m.load()?.value
        XCTAssertEqual(m.source, .market)
        await m.apply()?.value
        XCTAssertEqual(m.result?.hasPrefix("source:"), true, "\(String(describing: m.result))")
        XCTAssertTrue(m.live == nil)
        XCTAssertEqual(e.consent.seen.count, 0)
    }

    /// Switching off a needed piece names its dependents before anything is written; the confirm writes the closed set.
    func testToggleShowsDependentsBeforeWriting() async throws {
        let e = try env()
        let r = ExtensionRecord(loaded: try source(e, kit: KitRuntimePaneTests.neededKit, extra: [("EXTRA.md", "# extra rules\n", 0o644)]),
                                enabled: true, trusted: true)
        let m = KitPaneModel(extID: Self.ext, owner: owner(e) { [r] })
        await m.load()?.value
        m.toggle("tools", on: false)
        XCTAssertEqual(m.pendingOff, ["tools"])
        XCTAssertEqual(m.alsoOff, ["guard", "hud"])
        let pieces = try layout(e).piecesJSON
        XCTAssertFalse(exists(pieces), "nothing written before the confirm")
        await m.confirmToggle()?.value
        XCTAssertEqual(m.result, "done")
        XCTAssertTrue(m.pendingOff == nil)
        XCTAssertEqual(m.facts?.status?.off, ["tools", "guard", "hud"])
        XCTAssertEqual(e.consent.seen.count, 0, "never applied: the selection only")
    }

    /// Saving settings writes .settings.env 0600 and asks no sheet.
    func testSavingSettingsWritesTheEnvFileWithoutConsent() async throws {
        let e = try env()
        let r = ExtensionRecord(loaded: try source(e), enabled: true, trusted: true)
        _ = try KitStore(configHome: e.roots.configHome, extID: Self.ext).recordSlug(KitRuntimeTests.slug)
        let m = KitPaneModel(extID: Self.ext, owner: owner(e) { [r] })
        await m.load()?.value
        XCTAssertEqual(m.settings, ["default_repo": ""])
        m.settings["default_repo"] = "example-org/it's kit"
        await m.saveSettings()?.value
        XCTAssertEqual(m.result, "saved")
        let file = e.roots.configHome.appendingPathComponent(KitRuntimeTests.slug + "/.settings.env").path
        let mode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: file)[.posixPermissions] as? Int)
        XCTAssertEqual(mode & 0o777, 0o600)
        XCTAssertEqual(e.consent.seen.count, 0)
        await m.load()?.value
        XCTAssertEqual(m.settings, ["default_repo": "example-org/it's kit"], "read back through the quoting inverse")
    }

    /// The requirements go through the injected login PATH (the seam; no login shell) and the stat/access probe.
    func testRequirementsUseTheLoginPathSeam() async throws {
        let e = try env()
        let bin = e.root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let node = bin.appendingPathComponent("node")
        try Data("#!/bin/sh\n".utf8).write(to: node)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: node.path)
        let login = FakeLogin("/Users/example/bin:" + bin.path)
        let r = ExtensionRecord(loaded: try source(e), enabled: true, trusted: true)
        let m = KitPaneModel(extID: Self.ext, owner: owner(e, { [r] }, login: login))
        await m.load()?.value
        XCTAssertEqual(m.facts?.requirements, [.init(name: "node", found: true)])
        XCTAssertEqual(login.calls, 1)
    }

    // MARK: liveBins (#1426)

    /// An applied, trusted kit with its tools piece on: its bin. A never-applied kit, the same kit untrusted, and its
    /// tools piece off add nothing.
    func testLiveBinsLeaveOutUntrustedAndOffTools() async throws {
        let e = try env()
        let a = ExtensionRecord(loaded: try source(e), enabled: true, trusted: true)
        let b = ExtensionRecord(loaded: try source(e, id: "com.example.other", name: "other-kit"), enabled: true, trusted: true)
        let o = owner(e) { [a, b] }
        XCTAssertEqual(o.liveBins(), [], "never applied")
        let rt = try XCTUnwrap(o.runtime(for: a.id))
        let res = await rt.apply(a.loaded, source: .local, otherKitSlugs: o.otherKitSlugs(except: a.id))
        XCTAssertTrue(res.refused == nil && res.failures.isEmpty, "\(String(describing: res.refused)) \(res.failures)")
        let bin = try layout(e).bin
        XCTAssertEqual(o.liveBins(), [bin], "the never-applied kit adds nothing")
        a.trusted = false
        XCTAssertEqual(o.liveBins(), [], "an untrusted kit adds nothing")
        a.trusted = true
        XCTAssertEqual(o.liveBins(), [bin])
        try rt.setOff(["tools"])
        XCTAssertEqual(o.liveBins(), [], "an off tools piece adds nothing")
    }

    // MARK: #1424 riders

    /// #1423 left 3 (#1428): b never applied, so its apply writes the install selection first; that write is refused
    /// busy while a's apply holds the runtime, parked at its sheet (the KitParkedConsent seam holds it, no timing): b
    /// shows the plain busy text, never "not written: refused(...)", and pieces.json keeps a's selection.
    func testInstallSelectionWriteDuringAParkedApplyShowsBusy() async throws {
        let rec = KitRTConsent()
        let gate = KitParkedConsent(rec)
        let e = try env(rec, sheet: gate)
        let r = ExtensionRecord(loaded: try source(e), enabled: true, trusted: true)
        let o = owner(e) { [r] }
        let a = KitPaneModel(extID: Self.ext, owner: o), b = KitPaneModel(extID: Self.ext, owner: o)
        await a.load()?.value
        await b.load()?.value
        let first = a.apply()
        let watcher = Task { await first?.value; gate.wake() }
        await gate.waitParked()
        XCTAssertTrue(gate.didPark, "a's apply holds the runtime at its sheet")
        let before = try Data(contentsOf: URL(fileURLWithPath: try layout(e).piecesJSON))
        b.installOff = ["perms"]
        await b.apply()?.value
        XCTAssertEqual(b.busy, KitRuntime.busyText)
        XCTAssertEqual(b.result, KitRuntime.busyText)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: try layout(e).piecesJSON)), before, "b's selection was not written")
        gate.release()
        await first?.value
        await watcher.value
        XCTAssertEqual(a.result, "done")
    }

    /// An applied kit and its model (the fixture's CLAUDE.md holds the local.md import line and {{kit_bin}}).
    private func applied(_ e: Env) async throws -> (KitPaneModel, KitStoreLayout) {
        let r = ExtensionRecord(loaded: try source(e), enabled: true, trusted: true)
        let m = KitPaneModel(extID: Self.ext, owner: owner(e) { [r] })
        await m.load()?.value
        await m.apply()?.value
        XCTAssertEqual(m.result, "done")
        return (m, try layout(e))
    }

    /// R1423-i1: right after a clean apply the RENDERED live copy is not "edited" (its *.md differ from the source).
    func testFilesEditedIsFalseRightAfterACleanApply() async throws {
        let e = try env()
        let (m, l) = try await applied(e)
        let live = try String(contentsOfFile: l.live + "/CLAUDE.md", encoding: .utf8)
        XCTAssertFalse(live.contains("{{kit_config}}"), "the live copy is rendered")
        XCTAssertEqual(m.facts?.filesEdited, false)
        let again = KitPaneModel(extID: Self.ext, owner: owner(e) { [m.owner.record(Self.ext)].compactMap { $0 } })
        await again.load()?.value
        XCTAssertEqual(again.facts?.filesEdited, false, "after a relaunch too (the rendered tree is in runtime.json)")
    }

    func testOneByteEditInTheLiveCopyReadsEdited() async throws {
        let e = try env()
        let (m, l) = try await applied(e)
        let f = URL(fileURLWithPath: l.live + "/init.lua")
        try Data("return {}\n ".utf8).write(to: f)
        await m.load()?.value
        XCTAssertEqual(m.facts?.filesEdited, true)
    }

    /// A link in live/ makes the hash throw: that counts as edited, never as clean.
    func testALinkInTheLiveCopyReadsEdited() async throws {
        let e = try env()
        let (m, l) = try await applied(e)
        try FileManager.default.createSymbolicLink(atPath: l.live + "/extra-link", withDestinationPath: "init.lua")
        await m.load()?.value
        XCTAssertEqual(m.facts?.filesEdited, true)
    }

    /// R1409-i1: after a relaunch whose re-validation fails, the warnings and a repair say "not validated again".
    func testFailedRevalidationShowsNotValidatedAgain() async throws {
        let e = try env()
        let (m, l) = try await applied(e)
        try FileManager.default.removeItem(atPath: l.live + "/README.md")
        let again = KitPaneModel(extID: Self.ext, owner: owner(e) { [m.owner.record(Self.ext)].compactMap { $0 } })
        await again.load()?.value
        XCTAssertTrue(again.warnings.contains { $0.hasSuffix(": not validated again") }, "\(again.warnings)")
        await again.repair()?.value
        XCTAssertEqual(again.result?.hasSuffix(": not validated again"), true, "\(String(describing: again.result))")
        XCTAssertFalse((again.warnings + [again.result ?? ""]).contains { $0.contains("nothing applied") })
    }

    /// R1409-i1: a refused state file (the restore refusal) reads "not validated again" in the warnings and the result.
    func testRestoreRefusalShowsNotValidatedAgain() async throws {
        let e = try env()
        let (m, _) = try await applied(e)
        let state = try KitStore(configHome: e.roots.configHome, extID: Self.ext).runtimeStatePath
        try Data("{".utf8).write(to: URL(fileURLWithPath: state))
        let again = KitPaneModel(extID: Self.ext, owner: owner(e) { [m.owner.record(Self.ext)].compactMap { $0 } })
        await again.load()?.value
        XCTAssertEqual(again.warnings.count, 1, "\(again.warnings)")
        XCTAssertEqual(again.warnings.first?.hasSuffix(": not validated again"), true, "\(again.warnings)")
        await again.repair()?.value
        XCTAssertEqual(again.result?.hasSuffix(": not validated again"), true, "\(String(describing: again.result))")
        XCTAssertFalse((again.warnings + [again.result ?? ""]).contains { $0.contains("nothing applied") })
    }

    // MARK: R1422-i1

    func testRequirementNamesAreShownAsOutsideText() {
        let got = KitPaneFacts.requirements(["no\u{202E}de", "jq"], path: "/Users/example/bin") { _ in true }
        XCTAssertEqual(got.first?.name, "node", "the override is dropped from the shown name")
        XCTAssertEqual(got.last, .init(name: "jq", found: true))
    }

    func testIsExecutableIsAStatAndAccessProbe() throws {
        let dir = tempDir()
        let fm = FileManager.default
        for (n, m) in [("tool", 0o755), ("text", 0o644)] {
            let p = dir.appendingPathComponent(n).path
            try Data("#!/bin/sh\nexit 1\n".utf8).write(to: URL(fileURLWithPath: p))
            try fm.setAttributes([.posixPermissions: m], ofItemAtPath: p)
        }
        try fm.createDirectory(at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
        XCTAssertTrue(KitPaneFacts.isExecutable(dir.appendingPathComponent("tool").path))
        XCTAssertFalse(KitPaneFacts.isExecutable(dir.appendingPathComponent("text").path))
        XCTAssertFalse(KitPaneFacts.isExecutable(dir.appendingPathComponent("sub").path), "a dir is not a tool")
        XCTAssertFalse(KitPaneFacts.isExecutable(dir.appendingPathComponent("missing").path))
    }

    func testHooksDisabledReadIsBounded() throws {
        let dir = tempDir()
        let small = dir.appendingPathComponent("settings.json"), big = dir.appendingPathComponent("big.json")
        try Data(#"{"disableAllHooks": true}"#.utf8).write(to: small)
        let pad = String(repeating: " ", count: KitPaneFacts.settingsJSONMaxBytes)
        try Data((#"{"disableAllHooks": true,"# + pad + #""x": 1}"#).utf8).write(to: big)
        XCTAssertTrue(KitPaneFacts.hooksDisabled(settingsAt: small))
        XCTAssertFalse(KitPaneFacts.hooksDisabled(settingsAt: big), "over the cap reads as false")
        XCTAssertFalse(KitPaneFacts.hooksDisabled(settingsAt: dir), "a dir is not read")
        XCTAssertFalse(KitPaneFacts.hooksDisabled(settingsAt: dir.appendingPathComponent("missing.json")))
    }
}

/// The KitPaneModel rows' fixtures, shared with KitPaneViewTests (#1424): roots, ManagedConfig and every write under the
/// row's own tempDir(); a fake registry lookup and a fake login PATH.
@MainActor
extension XCTestCase {
    func kitPaneEnv(_ consent: KitRTConsent = KitRTConsent(), sheet: (any ManagedConfigConsent)? = nil, label: String = #function) throws -> KitRuntimeTests.Env {
        let root = tempDir(label)
        let roots = ManagedConfigRoots(claude: root.appendingPathComponent("claude home", isDirectory: true),
                                       configHome: root.appendingPathComponent("config", isDirectory: true),
                                       stateDir: root.appendingPathComponent("state", isDirectory: true))
        for d in [roots.claude, roots.configHome] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        try Data(KitRuntimeTests.userMD.utf8).write(to: roots.claude.appendingPathComponent("CLAUDE.md"))
        try Data(KitRuntimeTests.userSettings.utf8).write(to: roots.claude.appendingPathComponent("settings.json"))
        let clock = MCClock()
        let mc = ManagedConfig(roots: roots, consent: sheet ?? consent, writer: ManagedConfigPOSIXWriter(), now: { clock.now() })
        return KitRuntimeTests.Env(root: root, roots: roots, consent: consent, provider: ManagedConfigProvider(mc))
    }

    /// A kit source dir under the row's tempDir (every piece kind, two tools). `updateURL` goes into [extension].
    func kitPaneSource(_ e: KitRuntimeTests.Env, id: String = KitPaneModelTests.ext, name: String = KitRuntimeTests.slug, version: String = "1.0.0",
                        kit: String = KitFixture.kit, updateURL: String? = nil, extra: [(String, String, Int)] = [],
                        title: String = "Calm Agent Kit", author: String = "Example Author") throws -> LoadedExtension {
        let dir = e.root.appendingPathComponent("sources/\(id)-\(version)", isDirectory: true)
        var head = KitFixture.head.replacingOccurrences(of: "\"dev.example.kit.calm-agent\"", with: "\"\(id)\"")
            .replacingOccurrences(of: "\"1.0.0\"", with: "\"\(version)\"")
            .replacingOccurrences(of: "\"2.170.0\"", with: "\"0.0.1\"")
            .replacingOccurrences(of: "name        = \"calm-agent\"", with: "name        = \"\(name)\"")
            .replacingOccurrences(of: "\"Calm Agent Kit\"", with: "\"\(title)\"").replacingOccurrences(of: "\"Example Author\"", with: "\"\(author)\"")
        if let updateURL { head = head.replacingOccurrences(of: "license     = \"MIT\"", with: "license     = \"MIT\"\nupdate_url  = \"\(updateURL)\"") }
        let files: [(String, String, Int)] = [
            ("extension.toml", head + "\n" + kit + "\n", 0o644), ("README.md", KitDirFixture.readme, 0o644),
            ("CLAUDE.md", KitDirFixture.claudeMD, 0o644), ("init.lua", "return {}\n", 0o644),
            ("hooks/guard.sh", KitDirFixture.guardScript, 0o755), ("statusline/hud.mjs", "console.log('calm')\n", 0o644),
            ("tools/calm-note", "#!/bin/sh\necho note\n", 0o755), ("tools/calm-todo", "#!/bin/sh\necho todo\n", 0o755),
            ("seed/notes.toml", "# your notes\n", 0o644)] + extra
        for (rel, text, mode) in files {
            let u = dir.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: u)
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: u.path)
        }
        return LoadedExtension(manifest: try KitFixture.manifest(kit, head: head), directory: dir, isSystem: false)
    }

    func kitPaneOwner(_ e: KitRuntimeTests.Env, _ records: @escaping @MainActor () -> [ExtensionRecord], login: @escaping @Sendable () -> String? = { "/Users/example/bin" }) -> KitRuntimes {
        let provider = e.provider
        return KitRuntimes(configHome: e.roots.configHome, records: records, loginPath: login,
                           make: { store, trusted in KitRuntime(provider: provider, store: store, isTrusted: trusted, now: { Date() }) })
    }
}
